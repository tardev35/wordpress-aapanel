# 03 — Tuning

จูนระบบให้รองรับ ~100 เว็บ WordPress บน RAM 16 GB

> ⚠️ **กฎเหล็ก:** สำรองไฟล์ก่อนแก้เสมอ และตรวจ syntax ก่อน reload ทุกครั้ง
> **ห้ามใช้ `sed -i` กับไฟล์ config** — เคยทำ php-fpm พังจนเว็บล่ม (ดู [07-troubleshooting](07-troubleshooting.md))

---

## 3.1 sysctl + BBR

```bash
# เปิด BBR module
echo "tcp_bbr" | sudo tee /etc/modules-load.d/bbr.conf
sudo modprobe tcp_bbr

sudo tee /etc/sysctl.d/99-tuning.conf > /dev/null <<'EOF'
# ใช้ RAM ให้เต็มที่ก่อนแตะ swap
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# รองรับ connection จำนวนมาก
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535

# BBR - อัลกอริทึมควบคุมความแออัดของ Google
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

fs.file-max = 2097152
EOF

sudo sysctl --system
```

**ตรวจผล:**
```bash
sysctl net.ipv4.tcp_congestion_control   # ต้องได้ bbr
cat /proc/sys/vm/swappiness               # ต้องได้ 10
```

> **BBR คุ้มที่สุดต่อความพยายาม** — ลดเวลาส่งข้อมูลข้ามทวีปได้ 10–25%
> โดยเฉพาะเมื่อผู้เข้าชมอยู่ไกลจากสิงคโปร์

---

## 3.2 PHP-FPM 8.3 ⭐ ส่วนสำคัญที่สุด

### คณิตศาสตร์เบื้องหลัง

- 35 children × ~80 MB = **2.8 GB สูงสุด**
- ค่าเริ่มต้นของ aaPanel คือ `pm = dynamic` / `max_children = 150`
  → 150 × 80 MB = **12 GB** ซึ่งอันตรายมาก

### ทำไม `ondemand` คือหัวใจ

| โหมด | พฤติกรรม | ผลกับ 100 เว็บ |
|---|---|---|
| `dynamic` | สร้าง worker ค้างไว้ตลอด | RAM โตตามจำนวนเว็บ |
| **`ondemand`** | **เกิดเมื่อมี request ตายเมื่อว่าง 30 วินาที** | **เว็บที่ไม่มีคนเข้ากิน RAM = 0** |

**นี่คือเหตุผลเดียวที่ 100 เว็บอยู่บน 16 GB ได้**

### ไฟล์ที่ถูกต้อง

ดู [`configs/php-fpm-83.conf`](../configs/php-fpm-83.conf)

**แก้ผ่าน:** aaPanel → App Store → PHP-8.3 → Setting → Configuration modification

**ตรวจก่อน start ทุกครั้ง:**
```bash
/www/server/php/83/sbin/php-fpm -t -y /www/server/php/83/etc/php-fpm.conf
```
ต้องขึ้น **`test is successful`** เท่านั้น

> ⚠️ อย่าใช้ `php-fpm -t` เปล่า ๆ — มันชี้ไปเวอร์ชันอื่น ต้องระบุ path เต็มเสมอ

**เริ่มใหม่:**
```bash
/etc/init.d/php-fpm-83 stop
sleep 2
/etc/init.d/php-fpm-83 start
ls -la /tmp/php-cgi-83.sock   # ต้องมีไฟล์นี้
```

### ยืนยันว่า ondemand ทำงาน

```bash
ps aux | grep php-fpm | grep -v grep
```

**ตอนไม่มีทราฟฟิก ต้องเห็นแค่ master process ตัวเดียว ไม่มี worker เลย**

### ถ้าใช้หลายเวอร์ชัน

`pm.max_children` เป็นค่าของ **แต่ละเวอร์ชันแยกกัน** ไม่ใช่รวม

> **กฎ: ผลรวม `max_children` ของทุกเวอร์ชันต้องไม่เกิน 40**

| สถานการณ์ | ตั้งอย่างไร |
|---|---|
| 8.3 เป็นหลักตัวเดียว | 8.3 = **35**, 8.4 = **5** |
| แบ่งครึ่ง | ทั้งคู่ = **20** |

---

## 3.3 OPcache + php.ini

**aaPanel → PHP-8.3 → Config → php.ini**

ดู [`configs/php-ini-83.ini`](../configs/php-ini-83.ini)

```ini
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 1024
opcache.interned_strings_buffer = 64
opcache.max_accelerated_files = 200000
opcache.revalidate_freq = 60
opcache.validate_timestamps = 1
opcache.save_comments = 1

memory_limit = 256M
max_execution_time = 300
max_input_time = 300
upload_max_filesize = 64M
post_max_size = 64M
max_input_vars = 3000
realpath_cache_size = 4096k
realpath_cache_ttl = 600
expose_php = Off
```

**ตรวจผล:**
```bash
/www/server/php/83/bin/php -i | grep -E "opcache.enable =>|opcache.memory_consumption|memory_limit"
```

### ⚠️ กับดัก: `php.ini` มี opcache ซ้ำสองชุด

บนเครื่องอ้างอิง ค่า opcache ปรากฏสองรอบในไฟล์เดียว — ชุดของ aaPanel เอง แล้วตามด้วยชุดที่เติมทีหลัง

```
1931:opcache.memory_consumption=128        <- ของ aaPanel
1943:opcache.memory_consumption = 1024     <- ที่เราเติม
```

PHP อ่านไฟล์จากบนลงล่างและ **ค่าท้ายสุดชนะ** ค่าที่มีผลจริงจึงเป็น 1024 ตามที่ตั้งใจ
แต่เปราะมาก: ถ้าอัปเดต aaPanel แล้วมันไปเติมบล็อกของตัวเองต่อท้ายไฟล์ ค่าจะพลิกกลับทันที
โดยไม่มี error ให้เห็น

**เวลาตรวจอย่าดูแค่ `grep -c`** ให้ดูเลขบรรทัดด้วย (`grep -n`) แล้วยืนยันด้วยค่าที่ PHP
รายงานจริงจาก `php -i` ซึ่งเป็นผลลัพธ์หลังอ่านทั้งไฟล์แล้ว

### ⚠️ ไม่เปิด JIT

WordPress เป็นงานที่รอฐานข้อมูลและดิสก์เป็นหลัก ไม่ใช่งานคำนวณ **JIT จึงแทบไม่ช่วย**
และเคยมีรายงานว่าทำให้ปลั๊กอินบางตัวมีปัญหา — เป็นตัวอย่างคลาสสิกของการจูนที่ฟังดูดีแต่ไม่ให้ผลจริง

### หมายเหตุเรื่อง OPcache 1 GB

ไม่พอเก็บโค้ดครบทั้ง 100 เว็บพร้อมกัน **แต่ไม่ใช่ปัญหา** เพราะมันเก็บเฉพาะเว็บที่มีคนเข้าจริง
โดยอัตโนมัติ — เว็บที่ไม่มีทราฟฟิกไม่จำเป็นต้องอยู่ใน cache

---

## 3.4 MariaDB

### ⭐ ทางที่เร็วที่สุด: รันสคริปต์ตัวเดียวจบ

```powershell
ssh root@SERVER_IP "bash /tmp/wpaa/scripts/apply-mysql-config.sh --check"     # ดูก่อน
ssh root@SERVER_IP "bash /tmp/wpaa/scripts/apply-mysql-config.sh --restart"   # แก้แล้ว restart
```

ตั้งครบทั้ง 12 ค่าในหน้านี้ รวมของที่ GUI ไม่มีให้แก้ · รายละเอียดและความปลอดภัยที่ใส่ไว้
อยู่ที่ [หัวข้อย่อยด้านล่าง](#-ทางที่เร็วกว่า-ให้สคริปต์ทำให้)

**ถ้าอยากเข้าใจว่าแต่ละค่าคืออะไรก่อน** อ่านสองหัวข้อถัดไปแล้วค่อยรันสคริปต์ก็ได้ —
ผลลัพธ์เหมือนกัน

### ทางที่ทำผ่าน GUI ได้

**aaPanel → Databases → Settings → Performance tuning**

**เลือก Optimization plan = `4-8GB`** (ไม่ใช่ `8-16GB` แม้เครื่องจะมี RAM 16 GB)

> **เหตุผลสำคัญ:** โปรไฟล์เหล่านี้สมมติว่า MySQL ได้ใช้ RAM เกือบทั้งเครื่อง
> แต่ของเราต้องแบ่งให้ PHP-FPM, Redis, OPcache, FastCGI cache ด้วย
> ถ้าเลือก `8-16GB` มันจะตั้ง buffer pool ไว้ 8–10 GB → **แย่ง RAM จนเว็บล่ม**

### ค่าที่ต้องแก้ด้วยมือหลังเลือกโปรไฟล์

| ช่อง | ค่าจากโปรไฟล์ | **แก้เป็น** | เหตุผล |
|---|---|---|---|
| `innodb_buffer_pool_size` | ตรวจให้เป็น 4096 MB | **4096** | |
| `query_cache_size` | 128 | **0** | ⭐ ดูด้านล่าง |
| `join_buffer_size` | 2048 KB | **256** | × 200 conn = 400 MB เปล่าประโยชน์ |
| `read_rnd_buffer_size` | 768 KB | **256** | เช่นกัน |
| `table_open_cache` | — | **2048** | หมายเหตุ GUI บอกห้ามเกิน 2048 |
| `max_connections` | 500 | **200** | ดูด้านล่าง |

จากนั้นกด **Save** แล้ว **Restart Mysql Service** (จำเป็น ค่าจึงมีผล)

### ⭐ ทำไมต้อง `query_cache_size = 0`

**การปรับที่สำคัญที่สุดและขัดกับสัญชาตญาณ**

Query cache ใช้ **global lock** — ทุกครั้งที่เว็บใดเว็บหนึ่งเขียนข้อมูล มันจะล็อกทั้งระบบเพื่อล้าง cache

**เมื่อมี 100 ฐานข้อมูล การเขียนจากเว็บใดก็ตามจะทำให้อีก 99 เว็บรอ**
→ กลายเป็นคอขวดร้ายแรงแทนที่จะช่วยเร่ง

MySQL 8.0 ถอดฟีเจอร์นี้ออกแล้วด้วยเหตุผลนี้ **เราใช้ Redis object cache แทน**

### ทำไมลด `max_connections` เหลือ 200

buffer หลายตัวจอง **แยกต่อ connection** (สังเกตคำอธิบาย "KB * Num of connections" ใน GUI)

กรณีเลวร้ายที่สุดถ้าตั้ง 500:
```
(sort 4 MB + read 4 MB + read_rnd 0.25 + join 0.25 + stack 0.29) × 500 ≈ 4,400 MB
```
บวก buffer pool 4 GB = **เกิน RAM ที่มี**

100 เว็บที่มี PHP-FPM แค่ 35 workers ไม่มีทางใช้ connection ถึง 200 อยู่แล้ว

### ค่าเพิ่มเติมที่ GUI ไม่มี (แก้ที่ `/etc/my.cnf`)

```ini
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
innodb_io_capacity = 2000
innodb_io_capacity_max = 4000
table_definition_cache = 2000
open_files_limit = 20000
slow_query_log = 1
long_query_time = 2
```

**ปลดล็อกเพดานไฟล์ระดับ systemd** (ถ้าไม่ทำ `open_files_limit` ไม่มีผลจริง):
```bash
sudo mkdir -p /etc/systemd/system/mysqld.service.d
sudo tee /etc/systemd/system/mysqld.service.d/override.conf > /dev/null <<'EOF'
[Service]
LimitNOFILE=infinity
EOF
sudo systemctl daemon-reload
```

### ⚠️ `innodb_flush_log_at_trx_commit = 2` — ข้อแลกเปลี่ยน

แลกความปลอดภัยข้อมูลกับความเร็ว: ถ้าเซิร์ฟเวอร์**ดับกะทันหัน** อาจสูญเสียธุรกรรม 1 วินาทีสุดท้าย

- **เว็บบล็อก/บริษัท** → รับได้ (เสียแค่คอมเมนต์หรือการแก้ไขวินาทีสุดท้าย)
- **WooCommerce ที่รับคำสั่งซื้อจริง** → **เปลี่ยนกลับเป็น `1`**

### ⭐ ทางที่เร็วกว่า: ให้สคริปต์ทำให้

GUI ต้องกดหลายหน้าและยังมีค่าที่ GUI ไม่มีให้แก้อยู่ดี (หัวข้อถัดไป)
[`scripts/apply-mysql-config.sh`](../scripts/apply-mysql-config.sh) ตั้งให้ครบทุกค่าในหน้านี้:

```powershell
ssh root@SERVER_IP "bash /root/wpaa/scripts/apply-mysql-config.sh --check"     # ดูก่อน
ssh root@SERVER_IP "bash /root/wpaa/scripts/apply-mysql-config.sh --restart"   # แก้แล้ว restart
```

**ไม่ใส่ `--restart` = แก้ไฟล์อย่างเดียว** ให้ไป restart เองตอนที่สะดวก เพราะค่าพวกนี้
มีผลก็ต่อเมื่อ restart เท่านั้น เปลี่ยนขณะรันไม่ได้

ความปลอดภัยที่ใส่ไว้ · ตรวจก่อนว่าทุก option มีอยู่จริงใน mysqld รุ่นนั้น ·
สำรอง `/etc/my.cnf` ไป `/root/wpaa/backups/` เสมอ ·
**ถ้า restart แล้วไม่กลับมาใน 60 วินาที จะกู้ไฟล์เดิมแล้ว restart ใหม่ให้เอง**

### 🔴 กับดัก: `restart` คืน exit 0 โดยที่ MariaDB ไม่เคยลง

เจอจริงบน `187.52.125.203` เมื่อ 2026-08-27 — **ทั้งสองคำสั่งคืน 0 แต่ `Uptime` ไม่ขยับเลย**

```bash
/etc/init.d/mysqld restart      # Restarting mysqld (via systemctl)... exit=0
systemctl restart mysqld        # exit=0
```

**สาเหตุ: ไฟล์ pid หาย** (`/www/server/data/$(uname -n).pid`) init script หาโปรเซสจาก
ไฟล์นี้เท่านั้น พอไม่มีก็สรุปว่า "ไม่ได้รันอยู่" → `stop` ผ่านไปเฉย ๆ ส่วน `start`
ไปเจอ socket ถูกใช้อยู่แล้วก็เงียบ **ค่าใหม่ใน `my.cnf` จึงไม่เคยมีผล**

ตรวจให้ชัดด้วย `Uptime` เสมอ อย่าเชื่อ exit code:

```bash
mysql -u<user> -p<pass> -Nse "SHOW GLOBAL STATUS LIKE 'Uptime';"
```

แก้: สร้าง pid file กลับให้ตรงกับโปรเซสจริง แล้ว restart ใหม่

```bash
P=/www/server/data/$(uname -n).pid
pgrep -f 'mariadbd --basedir' | head -1 > "$P"
chown mysql:mysql "$P"; chmod 644 "$P"
/etc/init.d/mysqld restart
```

> [`apply-mysql-config.sh`](../scripts/apply-mysql-config.sh) สร้าง pid file ให้เองถ้าหาย
> และ**เทียบ pid ก่อน/หลังเพื่อยืนยันว่า restart เกิดขึ้นจริง** ถ้า pid ไม่เปลี่ยนมันจะ
> รายงานว่าล้มเหลวแทนที่จะบอกว่าสำเร็จ — `mysqladmin ping` อย่างเดียวแยกสองกรณีนี้ไม่ออก
> เพราะตัวเดิมที่ยังวิ่งอยู่ก็ตอบ ping ได้

> ⚠️ **MariaDB ไม่มีตัวตรวจ syntax แบบ `nginx -t`** — ทดสอบแล้วว่า
> `mysqld --verbose --help` ผ่านแม้ใส่ option มั่ว ๆ และ `--validate-config` รันเป็น root
> ไม่ได้ สคริปต์จึงกันด้วยวิธีอื่นแทน: เทียบชื่อ option กับหน้า help ก่อนเขียน
> แล้วกู้อัตโนมัติถ้า restart ไม่ขึ้น

### ✅ ทำจริงแล้วเมื่อ 2026-08-25

ก่อนหน้านี้ **ไม่เคยมีเครื่องไหนตั้งค่าในหน้านี้จริงเลย** ทั้ง 2 เครื่องเป็น
`innodb_buffer_pool_size = 1024M`, `max_connections = 400`, `join_buffer_size = 4096K`
มาตลอด เพิ่งมาเจอตอนเพิ่มด่าน MariaDB เข้า `verify-config.sh`

| เครื่อง | ไซต์ | restart ใช้เวลา | ผลหลังทำ |
|---|---|---|---|
| `187.52.125.203` | 7 | **2 วินาที** | ทุกไซต์ 200 |
| `187.52.122.249` | 84 | **2 วินาที** | ทุกไซต์ 200 |
| `187.52.122.249` (รอบ 2026-08-27) | **145** | **2 วินาที** | ทุกไซต์ 200 |

### 🔴 ค่าเหล่านี้ถอยกลับเองได้ — จึงมีตาข่ายรอบกลางคืน

หน้า **Databases → Performance tuning** ของ aaPanel เขียนทับ `/etc/my.cnf` ทั้งไฟล์
ยืนยันแล้ว 2026-08-27: ค่าที่ตั้งไว้เมื่อ 25 ส.ค. **ถอยกลับหมดทั้ง 2 เครื่อง** และ
MariaDB ถูก restart ไปแล้วด้วย จึงวิ่งด้วยค่าเก่าจริง ๆ ไม่ใช่แค่ไฟล์เพี้ยน

[`nightly-check.sh`](../scripts/nightly-check.sh) จึงตรวจ `my.cnf` ทุกคืนแล้ว
**ตั้งค่ากลับพร้อม restart ให้เอง** — ข้อนี้เป็นข้อเดียวในสคริปต์นั้นที่ restart service
ยอมรับได้เพราะยิงตอน 23:00 และวัดจริงได้ 2–3 วินาทีบนเครื่อง 145 ไซต์
(ทดสอบด้วยการแกล้งเปลี่ยน `max_connections` เป็น 400 แล้วดูว่ามันกู้กลับ — ผ่าน)

`SHOW VARIABLES` ยืนยันครบทั้ง 11 ค่าทั้งสองเครื่อง

> ระหว่าง restart หน้าที่อยู่ใน FastCGI cache ยังเสิร์ฟได้ปกติ เพราะไม่แตะ PHP/MySQL เลย
> ถ้าจะให้กระทบน้อยที่สุดจริง ๆ ให้ทำตอนแคชอุ่นแล้วและทราฟฟิกต่ำ

### ตรวจผล

```bash
mysql -uroot -p -e "SHOW VARIABLES WHERE Variable_name IN \
('innodb_buffer_pool_size','query_cache_size','table_open_cache','max_connections','join_buffer_size');"
```

| ตัวแปร | ค่าที่ต้องได้ |
|---|---|
| innodb_buffer_pool_size | `4294967296` |
| query_cache_size | `0` |
| table_open_cache | `2048` |
| max_connections | `200` |
| join_buffer_size | `262144` |

> **หมายเหตุ:** RAM used จะยังไม่ขึ้นถึง 4 GB ทันที เพราะ InnoDB จองแบบ lazy
> ค่อย ๆ ใช้เมื่อมีข้อมูลจริง

---

## 3.5 Redis

> ✅ **ตั้งแล้วบนเครื่องอ้างอิงเมื่อ 2026-08-23** — `maxmemory 1gb` + `maxmemory-policy allkeys-lru`
>
> ก่อนหน้านั้นเป็น `maxmemory 0` มาตลอด ทั้งที่ CHANGELOG รุ่นแรกเขียนว่าตั้งไปแล้วตั้งแต่ 08-22
> เป็นตัวอย่างว่าทำไมต้องเชื่อ `verify-config.sh` มากกว่าบรรทัดในเอกสาร

**วิธีที่แนะนำ — ใช้สคริปต์ ตั้งให้ครบทั้งคู่และ restart ให้:**

```powershell
cd C:\wordpress-aapanel
scp scripts/set-redis-limit.sh root@SERVER_IP:/tmp/wpaa/scripts/
ssh root@SERVER_IP "bash /tmp/wpaa/scripts/set-redis-limit.sh"
```

> สคริปต์นี้ไม่ได้อ่านไฟล์ใน `configs/` จึงจะส่งผ่าน stdin แทนก็ได้ **แต่บน PowerShell
> ต้องผ่าน `cmd`**: `cmd /c "ssh root@SERVER_IP ""bash -s"" < scripts\set-redis-limit.sh"`
> — `ssh ... < file` ตรง ๆ ใช้ไม่ได้ ดู [README](../README.md)

**ถ้าอยากทำเอง:**

```bash
grep -n "maxmemory" /www/server/redis/redis.conf

# ถ้ายังไม่มี
cp -p /www/server/redis/redis.conf /www/server/redis/redis.conf.bak-$(date +%F)
cat >> /www/server/redis/redis.conf <<'RCONF'

maxmemory 1gb
maxmemory-policy allkeys-lru
RCONF

/etc/init.d/redis restart    # ไม่ใช้ systemctl (กฎข้อ 1 ของ repo นี้)
redis-cli ping               # PONG
```

> ❌ **อย่าใช้ช่อง `maxmemory` ในหน้า Redis ของ aaPanel เป็นทางหลัก**
> ช่องนั้นรับ **ตัวเลขหน่วย MB** (พิมพ์ `1gb` ไม่ได้ ต้องพิมพ์ `1024`) และมันตั้งให้แค่
> `maxmemory` ตัวเดียว ไม่ได้ตั้ง policy — ซึ่งเป็นครึ่งที่สำคัญกว่า

**ทำไมต้องจำกัด:** ถ้าไม่ตั้ง Redis จะโตไม่มีขีดจำกัดจนแย่ง RAM กับ MariaDB

### 🔴 ตั้ง `maxmemory` อย่างเดียวไม่พอ — จะแย่กว่าเดิม

ช่อง `maxmemory` ในหน้า Redis ของ aaPanel (หน่วยเป็น **MB** ใส่ `1024`) ตั้งได้แค่ตัวเลข
**แต่ไม่ได้ตั้ง `maxmemory-policy` ให้** และค่าเริ่มต้นของ Redis คือ:

```
maxmemory-policy  noeviction
```

`noeviction` แปลว่า **พอเต็มเพดานแล้ว Redis จะปฏิเสธคำสั่งเขียนทั้งหมด** ไม่ใช่ทิ้งคีย์เก่า
สำหรับ object cache นี่คืออาการที่แย่กว่าไม่จำกัดเลย — WordPress จะเริ่มได้ error ตอนเขียน cache
แทนที่จะแค่ใช้ RAM เยอะ

**ต้องตั้งคู่กันเสมอ** ผ่านแท็บ **Config file** ในหน้า Redis เดียวกัน:

```
maxmemory 1gb
maxmemory-policy allkeys-lru
```

แล้วกด **Restart Redis Service** (reload ไม่พอ)

**ยืนยันว่าติดจริง:**
```bash
redis-cli config get maxmemory        # ต้องได้ 1073741824
redis-cli config get maxmemory-policy # ต้องได้ allkeys-lru
```

> `allkeys-lru` = พอเต็มให้ทิ้งคีย์ที่ไม่ได้ใช้นานที่สุด ซึ่งเป็นพฤติกรรมที่ถูกต้องของ cache

---

## Checklist

- [ ] BBR = `bbr`, swappiness = `10`
- [ ] Swap 4 GB
- [ ] PHP-FPM 8.3 = `ondemand` / 35 / 30s
- [ ] `php-fpm -t` = test is successful
- [ ] `ps aux | grep php-fpm` เห็นแค่ master ตอนไม่มีทราฟฟิก
- [ ] OPcache เปิด, memory_limit 256M
- [ ] MySQL buffer pool = 4294967296
- [ ] query_cache_size = 0
- [ ] Redis maxmemory 1gb

---

**ถัดไป:** [04-cache.md](04-cache.md)

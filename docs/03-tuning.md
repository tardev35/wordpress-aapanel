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

บนเครื่อง A ค่า opcache ปรากฏสองรอบในไฟล์เดียว — ชุดของ aaPanel เอง แล้วตามด้วยชุดที่เติมทีหลัง

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

### ทางที่แนะนำ: ใช้ GUI

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

> 🔴 **สถานะจริงบนเครื่อง A (2026-08-23): ยังไม่ได้ตั้ง `maxmemory`**
> CHANGELOG รุ่นแรกเขียนว่าตั้งไปแล้ว แต่ `grep '^maxmemory' /www/server/redis/redis.conf`
> ไม่คืนอะไรเลย แปลว่า Redis ยังโตได้ไม่จำกัดและจะไปแย่ง RAM กับ MariaDB
> — เป็นช่องโหว่ของงบ RAM ที่เปิดอยู่จริง ไม่ใช่แค่รายการใน TODO

```bash
grep -n "maxmemory" /www/server/redis/redis.conf

# ถ้ายังไม่มี
sudo tee -a /www/server/redis/redis.conf > /dev/null <<'EOF'

maxmemory 1gb
maxmemory-policy allkeys-lru
EOF

sudo systemctl restart redis
redis-cli ping   # PONG
```

**ทำไมต้องจำกัด:** ถ้าไม่ตั้ง Redis จะโตไม่มีขีดจำกัดจนแย่ง RAM กับ MariaDB

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

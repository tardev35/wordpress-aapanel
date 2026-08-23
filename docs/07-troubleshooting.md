# 07 — Troubleshooting

ปัญหาที่เจอจริงระหว่างติดตั้งเซิร์ฟเวอร์นี้ พร้อมวิธีแก้ที่ใช้ได้ผล

---

## 🔥 ปัญหาที่พบบ่อยที่สุด

### 1. `systemctl` รายงานสถานะไม่ตรงความจริง

**อาการ:**
```
nginx  : failed      ← แต่เว็บใช้งานได้ปกติ
redis  : activating  ← แต่ redis-cli ping ตอบ PONG
```

**สาเหตุ:** aaPanel รัน service ผ่าน `/etc/init.d/` ไม่ใช่ systemd native
พอสั่ง `systemctl start` ตอนที่ service รันอยู่แล้ว → เจอ port/socket ถูกยึด → รายงาน `failed`

**วิธียืนยันความจริง:**
```bash
ps aux | grep nginx | grep -v grep
sudo ss -tulpn | grep -E ":80|:443"
curl -sI http://127.0.0.1 | head -3     # ได้ 200 = ทำงานปกติ
redis-cli ping                           # PONG = ทำงานปกติ
```

**วิธีแก้ที่ถูกต้อง:**
```bash
/etc/init.d/nginx restart
/etc/init.d/php-fpm-83 restart
sudo systemctl reset-failed nginx        # ล้างสถานะค้าง
sudo systemctl disable nginx             # ไม่ให้ systemd แย่งเริ่มตอนรีบูต
```

> aaPanel มี **Daemon** ที่เช็คทุก 1 นาทีและเริ่ม service ให้อัตโนมัติ — ดีกว่า systemd สำหรับกรณีนี้

---

### 2. 502 Bad Gateway

**สาเหตุที่พบ:** nginx ต่อ php-fpm socket ไม่ได้

**วินิจฉัย:**
```bash
sudo tail -20 /www/wwwlogs/DOMAIN.TLD.error.log
ls -la /tmp/php-cgi-*.sock
ps aux | grep php-fpm | grep -v grep
```

**ข้อความที่บอกสาเหตุ:**
```
connect() to unix:/tmp/php-cgi-83.sock failed (2: No such file or directory)
```

**สาเหตุที่เป็นไปได้:**

| สาเหตุ | วิธีแก้ |
|---|---|
| php-fpm ไม่ได้รัน | `/etc/init.d/php-fpm-83 start` |
| config พัง | ตรวจด้วย `php-fpm -t` (ดูข้อ 3) |
| เว็บชี้ไป PHP เวอร์ชันที่ถอนไปแล้ว | เปลี่ยนเว็บให้ใช้ 8.3 |

---

### 3. php-fpm ไม่ยอมสตาร์ท — config พัง

**อาการ:**
```
ERROR: [php-fpm.conf:17] unable to parse value for entry 'pm.max_children': is not a valid number
ERROR: FPM initialization failed
```

**สาเหตุจริงที่เกิดขึ้น:** ใช้ `sed -i` แก้ config แล้วบรรทัดเชื่อมติดกัน

```ini
pm.max_children = 200pm.process_idle_timeout = 30s   ← เสียหาย
pm.start_servers = 15;                                ← ; อยู่ผิดที่ (ต้องอยู่หน้าบรรทัด)
```

**วินิจฉัยเสมอด้วย:**
```bash
/www/server/php/83/sbin/php-fpm -t -y /www/server/php/83/etc/php-fpm.conf
```

> ⚠️ **อย่าใช้ `php-fpm -t` เปล่า ๆ** — มันชี้ไปเวอร์ชันอื่น (เคยไปทดสอบ 8.0 แทน 8.3)

**วิธีแก้:** เขียนไฟล์ใหม่ทั้งไฟล์จาก [`configs/php-fpm-83.conf`](../configs/php-fpm-83.conf)

**บทเรียน:** 🔴 **ห้ามใช้ `sed -i` กับ config หลายบรรทัด** ใช้ aaPanel GUI แทน

---

### 4. "Another FPM instance seems to already listen"

**อาการ:**
```
ERROR: Another FPM instance seems to already listen on /tmp/php-cgi-84.sock
Unit process 89275 (php-fpm) remains running after unit stopped
```

**สาเหตุ:** process เก่ายังไม่ตาย แต่สั่งสตาร์ทตัวใหม่แล้ว

**วิธีแก้:**
```bash
sudo systemctl stop php-fpm-83
sudo pkill -9 -f "php-fpm.*83"
sleep 3
ps aux | grep php-fpm | grep -v grep    # ต้องไม่คืนอะไรเลย
sudo rm -f /tmp/php-cgi-83.sock
sudo systemctl start php-fpm-83
```

---

### 5. Orphan worker process กิน RAM ทิ้ง

**อาการ:** มี `php-fpm: pool www` หลายสิบตัว **แต่ไม่มี master process**

เคยพบ ~75 orphan กิน RAM ราว 300–400 MB โดยไม่ทำงานอะไรเลย

**สาเหตุ:** `pkill -9` ฆ่า master แต่ worker ไม่ตายตาม

**วิธีแก้:**
```bash
for v in 80 81 82 83 84; do sudo systemctl stop php-fpm-$v 2>/dev/null; done
sleep 3
sudo pkill -9 -f "php-fpm"
sleep 3
ps aux | grep php-fpm | grep -v grep    # ต้องเกลี้ยง
sudo rm -f /tmp/php-cgi-*.sock
/etc/init.d/php-fpm-83 start
```

**บทเรียน:** ใช้ `reload` หรือ `stop && sleep && start` แทน `pkill -9`

---

### 6. "The website has been stopped"

**ไม่ใช่ error ของเว็บ** — เป็นหน้าของ aaPanel เมื่อเว็บถูกตั้งสถานะ Stopped

**วิธีแก้:** WP Toolkit → คลิกไอคอน ⏸️ วงกลมแดง → เปลี่ยนเป็นเขียว

⚠️ **แล้วต้องล้าง cache ทันที** ไม่งั้น cache จะเก็บหน้า error นี้ไว้:
```bash
sudo rm -rf /www/server/fastcgi_cache/*
/etc/init.d/nginx reload
```

---

### 7. MySQL "Access denied for user 'root'@'localhost'"

**ไม่ใช่ปัญหา** — aaPanel ตั้งรหัสผ่าน root ไว้ (ไม่ใช่ passwordless)

```bash
mysql -uroot -p -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';"
```

หารหัสได้จาก **aaPanel → Databases → root password**

> เป็นพฤติกรรมที่ถูกต้องด้านความปลอดภัย

---

### 8. SSH: "REMOTE HOST IDENTIFICATION HAS CHANGED"

**สาเหตุ:** ติดตั้ง OS ใหม่ → host key เปลี่ยน

**แก้บนเครื่องตัวเอง (ไม่ใช่บนเซิร์ฟเวอร์):**
```powershell
ssh-keygen -R <SERVER_IP>
ssh root@<SERVER_IP>       # พิมพ์ yes
```

---

### 9. ตัวเลข CPU ใน Dashboard กระโดดไปมา

**เคยเห็น 4% → 28% → 50% ทั้งที่ไม่มีเว็บเลย**

**สาเหตุ:** panel วัดแบบ snapshot ชั่วขณะ และนับ `%nice` (งาน background priority ต่ำ) รวมด้วย

**ยืนยันความจริง:**
```bash
uptime                    # ดู load average
mpstat 2 5                # ดู %idle เฉลี่ย
ps -eo pid,ni,pcpu,comm --sort=-pcpu | awk '$2 > 0' | head -10
```

**ตัวอย่างผลจริงที่พิสูจน์ว่าเครื่องว่าง:**
```
load average: 0.13, 0.12, 0.04    ← บน 4 cores = ใช้ 3%
%idle 91.25    %usr 0.22    %nice 7.32    %steal 0.00
```

> `%steal = 0` เป็นข่าวดี — แปลว่าลูกค้าคนอื่นบน host เดียวกันไม่ได้แย่ง CPU

---

### 10. โดเมนเปิดแล้วได้เว็บของลูกค้าคนอื่น (เฉพาะ https)

**อาการ:** เปิดโดเมนตัวเองแล้วเจอเว็บของอีกรายเต็มหน้า **URL ยังเป็นของตัวเอง**
มักเจอกับโดเมนที่เพิ่งชี้ DNS มา หรือเพิ่งกด Add site ไปไม่นาน

**ตัวแยกโรคที่ชัดที่สุด — เทียบ http กับ https ของโดเมนเดียวกัน:**

```
http://DOMAIN.TLD   -> "Website not found"   (ถูกต้อง)
https://DOMAIN.TLD  -> เว็บของคนอื่น          (ผิด)
```

**สาเหตุ:** catch-all ของ aaPanel ครอบแค่พอร์ต 80 พอเป็น 443 ไม่มีใครรับ nginx จึงโยนไปให้
server block แรกที่ listen 443 — อธิบายเต็มใน [02-hardening §2.8](02-hardening.md)

**สาเหตุร่วมข้อที่สอง:** ถึงจะ Add site แล้ว ถ้า **nginx ยังไม่ reload** server block ใหม่ก็ยัง
ไม่มีอยู่ในคอนฟิกที่รันอยู่ ผลเหมือนกันเป๊ะ

**แก้:**
```bash
# ครั้งเดียวต่อเครื่อง - ต้อง scp ก่อน เพราะสคริปต์อ่านไฟล์ใน configs/
scp -r configs scripts root@SERVER_IP:/tmp/wpaa/
ssh root@SERVER_IP "bash /tmp/wpaa/scripts/harden-nginx.sh && /etc/init.d/nginx reload"

# ทุกครั้งหลัง Add site
ssh root@SERVER_IP "/root/stamp-site.sh DOMAIN.TLD"
```

**ตรวจว่าปิดรูแล้วจริง — ต้องได้ 404:**
```bash
curl -sk --resolve nosuch.invalid:443:SERVER_IP https://nosuch.invalid/ -o /dev/null -w '%{http_code}\n'
```

---

### 11. แก้ vhost ถูกแล้ว แต่ยังได้เว็บผิดอยู่ดี

**อาการ:** ทำตามข้อ 10 แล้ว โดเมนมี vhost มี WordPress มี DB ของตัวเองครบ แต่หน้าแรกยังผิด

**ตัวแยกโรค — เติม query string:**
```bash
curl -sI https://DOMAIN.TLD/       | grep -i x-cache    # HIT    -> เว็บผิด
curl -sI "https://DOMAIN.TLD/?x=1" | grep -i x-cache    # BYPASS -> เว็บถูก
```

**สาเหตุ:** FastCGI cache เก็บ HTML ของเว็บอื่นไว้ใต้คีย์ของโดเมนนี้ ตั้งแต่ตอนที่ยังมีรูตามข้อ 10
เพราะ cache key ใช้ `$host` (Host header) แต่เนื้อหามาจาก docroot ของ default server

รายละเอียดเต็มใน [04-cache §4.5](04-cache.md)

**แก้:**
```bash
bash scripts/clear-cache.sh
```

> ⚠️ ถ้าเครื่องยังใช้ config โรงงาน (`fastcgi_cache_valid 200 1d`) ขยะนี้ค้าง **1 วัน**
> ไม่ใช่ 1 ชั่วโมง — ต้องล้าง ไม่ใช่รอ

---

### 12. `chown -R` ที่ site root ล้มเหลวทั้งที่เป็น root

**อาการ:**
```
chown: changing ownership of '/www/wwwroot/DOMAIN.TLD/.user.ini': Operation not permitted
```
สคริปต์ที่มี `set -e` จะตัดจบตรงนี้ โดยที่ขั้นตอนก่อนหน้า (เช่น `tar` แตกไฟล์) ทำไปแล้ว
กลายเป็นงานค้างครึ่ง ๆ

**สาเหตุ:** aaPanel ตั้ง immutable flag ไว้ที่ `.user.ini` ทุกไซต์

```bash
lsattr /www/wwwroot/DOMAIN.TLD/.user.ini
# ----i---------e------- .user.ini
```

ไฟล์ที่ติด `+i` แม้แต่ root ก็แก้ owner/permission ไม่ได้

**แก้ที่ถูก — ข้ามไฟล์กลุ่มนั้นไป อย่าไปปลดล็อกมัน:**
```bash
KEEP="! -name .user.ini ! -name .htaccess ! -name 502.html"
find /www/wwwroot/DOMAIN.TLD -mindepth 1 $KEEP -exec chown www:www {} +
find /www/wwwroot/DOMAIN.TLD -mindepth 1 $KEEP -type d -exec chmod 755 {} +
find /www/wwwroot/DOMAIN.TLD -mindepth 1 $KEEP -type f -exec chmod 644 {} +
```

---

### 13. `www.DOMAIN.TLD` ไม่ redirect ไป non-www

**ตรวจก่อนว่าใครเป็นคน redirect:**
```bash
curl -sI https://www.DOMAIN.TLD/ | grep -iE 'location|x-redirect-by'
```

**ถ้าเห็น `x-redirect-by: WordPress`** แปลว่า redirect นั้นมาจาก WordPress ไม่ใช่ nginx
ซึ่งใช้ได้เฉพาะเมื่อ WP ติดตั้งและทำงานอยู่ — ไซต์ที่เพิ่งสร้างยังไม่ได้ลง WP จะไม่มี redirect เลย
และถ้ามีคนแก้ `siteurl`/`home` ในหลังบ้าน redirect ก็หายทันที

**แก้ให้ nginx เป็นคนทำแทน:**
```bash
ssh root@SERVER_IP "/root/stamp-site.sh DOMAIN.TLD"
```

`00-common.conf` ที่สคริปต์ใส่ให้จะ redirect ตั้งแต่ก่อนถึง PHP และใช้ได้กับเว็บ static ด้วย

> ไซต์ที่ panel ไม่ได้ใส่ `www` ไว้ใน `server_name` ก็ยังได้ redirect เพราะ catch-all
> ใน §2.8 รับช่วงต่อให้

---

## 📌 กฎที่สรุปได้จากปัญหาทั้งหมด

1. **สำรองก่อนแก้เสมอ** — `cp <file> <file>.bak-$(date +%F)`
2. **ตรวจ syntax ก่อน start/reload ทุกครั้ง**
   ```bash
   /www/server/php/83/sbin/php-fpm -t -y /www/server/php/83/etc/php-fpm.conf
   /www/server/nginx/sbin/nginx -t
   ```
3. **ห้าม `sed -i` กับไฟล์ config** → ใช้ GUI
4. **ใช้ `/etc/init.d/` หรือ GUI ไม่ใช่ `systemctl`**
5. **อย่าเชื่อ `systemctl is-active`** → ยืนยันด้วย `curl` / `ps` / `redis-cli ping`
6. **ระบุ path เต็มเสมอ** เวลาเรียก `php-fpm` หรือ `php`
7. **หลีกเลี่ยง `pkill -9`** → ใช้ `stop && sleep 3 && start`
8. **เจอเนื้อหาผิดเว็บ ให้เทียบ `http` กับ `https` ของโดเมนเดียวกันก่อน** — ต่างกันแปลว่าเป็นเรื่อง default_server ไม่ใช่เรื่องเว็บนั้นเอง
9. **แล้วเติม `?x=1` ต่อ** — ถ้าเนื้อหากลับมาถูก ปัญหาอยู่ที่ cache ไม่ใช่ที่ vhost อย่าเพิ่งไปรื้อ config
10. **หลัง Add site ต้อง reload nginx เสมอ** — `stamp-site.sh` ทำให้แล้ว ช่วงที่ยังไม่ reload คือช่วงที่โดเมนใหม่ไปหยิบเว็บคนอื่นมาแสดงและป้อนขยะเข้า cache

---

## เครื่องมือวินิจฉัยเร็ว

```bash
bash scripts/healthcheck.sh      # สถานะ service ตอนนี้
bash scripts/inventory.sh        # ค่าจริงทั้งเครื่อง (อ่านอย่างเดียว)
bash scripts/verify-config.sh    # ค่าที่เอกสารอ้าง ยังอยู่ไหม
```

หรือดูปัญหาจากรากเสมอ:
```bash
# nginx
sudo tail -30 /www/wwwlogs/DOMAIN.TLD.error.log

# php-fpm
sudo tail -30 /www/server/php/83/var/log/php-fpm.log

# mysql
sudo tail -30 /www/server/data/*.err

# systemd
sudo journalctl -xeu <service> --no-pager | tail -30
```

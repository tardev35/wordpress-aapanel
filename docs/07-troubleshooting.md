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

**อาการนี้แปลว่า** บรรทัดหนึ่งใน `php-fpm.conf` มีสองค่าติดกัน เพราะตัวขึ้นบรรทัดหายไป

เจอมาแล้ว 2 ครั้ง จากคนละสาเหตุ — ครั้งแรกใช้ `sed -i` แก้ ครั้งที่สองแก้ด้วยมือ
ในหน้า panel แล้วเผลอลบตัวขึ้นบรรทัดท้ายค่า

**หน้าตาที่พัง** — สองค่าอยู่บรรทัดเดียวกัน ไม่มีตัวขึ้นบรรทัดคั่น:

| บรรทัด 17 | ผล |
|---|---|
| `pm.max_children` `=` `200` ต่อด้วย `pm.process_idle_timeout = 30s` ทันที | php-fpm อ่านค่าเป็น `200pm.process_idle_timeout = 30s` → ไม่ใช่ตัวเลข → ดับ |
| `pm.start_servers = 15;` | `;` ต้องอยู่**หน้า**บรรทัดถึงจะเป็นคอมเมนต์ ไปอยู่ท้ายจะพัง |

> 🚫 **ไม่ใส่ตัวอย่างที่พังเป็น code block ในหน้านี้โดยตั้งใจ**
> GitHub มีปุ่มก๊อปที่มุมขวาของทุก code block — เคยมีคนก๊อปตัวอย่างที่พังไปวางจริง
> แล้วเว็บล่มยกเครื่อง (2026-08-29, godbet-88.com ขึ้น 502 อยู่ 8 ชั่วโมง)
> **ใน repo นี้ code block ต้องก๊อปไปใช้ได้เสมอ ไม่มีข้อยกเว้น**

**วินิจฉัยเสมอด้วย:**
```bash
/www/server/php/83/sbin/php-fpm -t -y /www/server/php/83/etc/php-fpm.conf
```

> ⚠️ **อย่าใช้ `php-fpm -t` เปล่า ๆ** — มันชี้ไปเวอร์ชันอื่น (เคยไปทดสอบ 8.0 แทน 8.3)

**วิธีแก้ — ค่าที่ถูกต้อง** (ก๊อปไปวางได้เลย ทั้ง block นี้ถูกต้อง):

```ini
pm = ondemand
pm.status_path = /phpfpm_83_status
pm.max_children = 35
pm.process_idle_timeout = 30s
pm.max_requests = 1000
```

ไฟล์เต็มอยู่ที่ [`configs/php-fpm-83.conf`](../configs/php-fpm-83.conf)
แก้ผ่าน aaPanel → App Store → PHP-8.3 → Setting → Configuration modification
แล้วตรวจด้วยคำสั่งข้างบน **ก่อน** สั่ง start ทุกครั้ง

**ถ้าเครื่องไม่ใช่ 4 vCPU / 16 GB** ค่า `35` เปลี่ยนตามเครื่อง ดู [10 §10.8](10-bare-linux.md)
แต่ค่าอื่นในบล็อกนี้ไม่ต้องแก้

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

### 14. ขอ Let's Encrypt ไม่ผ่าน — "Verification failed / verification URL cannot be accessed"

**อาการ:** กด Apply SSL แล้วขึ้น

```
Invalid response from http://DOMAIN/.well-known/acme-challenge/xxxxx: 404
```

และในคอลัมน์ SSL ของ WP Toolkit ขึ้น `Not Set`

### 🔴 cron ต่ออายุ SSL ไม่ได้ช่วยเคสนี้

งาน `Domain SSL Renew` ตอน 08:46 คือ `acme_v2.py --renew_v3=1` — **`--renew` ต่ออายุเฉพาะ
ใบที่ออกสำเร็จไปแล้ว** ไซต์ที่ยังไม่เคยมีใบเลยจึงไม่มีอะไรให้ต่อ ต้องออกให้ผ่านเองก่อนหนึ่งครั้ง
แล้ว cron ถึงจะดูแลต่อให้ตลอดไป

### วินิจฉัย — วางไฟล์จริงแล้วยิงเทียบ 3 ทาง

อย่ายิงชื่อไฟล์มั่ว เพราะไฟล์ที่ไม่มีอยู่จริงก็ต้องได้ 404 อยู่แล้ว ไม่ได้พิสูจน์อะไร

```bash
D=DOMAIN.TLD
ssh root@SERVER_IP "mkdir -p /www/wwwroot/$D/.well-known/acme-challenge &&   echo PROBE-OK > /www/wwwroot/$D/.well-known/acme-challenge/probe &&   chown -R www:www /www/wwwroot/$D/.well-known"

curl -s  --resolve $D:80:SERVER_IP  "http://$D/.well-known/acme-challenge/probe"   # origin http
curl -s                              "http://$D/.well-known/acme-challenge/probe"   # ผ่าน DNS จริง
```

| origin http | ผ่าน DNS จริง | แปลว่า |
|---|---|---|
| `PROBE-OK` | `PROBE-OK` | เซิร์ฟเวอร์ปกติ ปัญหาอยู่ที่อื่น (ดู "ถ้า DNS ถูกแล้วยังไม่ผ่าน") |
| `PROBE-OK` | **หน้าอื่น / 404** | 🎯 **DNS ไม่ได้ชี้มาที่เครื่องนี้** |
| 404 | 404 | ไซต์บนเครื่องมีปัญหาเอง — เช็ค vhost |

**อย่าลืมลบไฟล์ probe ทิ้งหลังทดสอบ**

### เคสจริง 2026-08-23

3 โดเมน (`ufamax789pro.com`, `temtem168pro.com`, `bbc29pro.com`) ขอ SSL ไม่ผ่าน

- ยิงตรงที่ origin ทาง http → **`PROBE-OK` (200)** = เซิร์ฟเวอร์เสิร์ฟ challenge ได้ปกติ
- ยิงผ่าน DNS จริง → ได้ **หน้า "This Page Does Not Exist" ที่มี Google Analytics
  และ bootstrapcdn อยู่ข้างใน** ซึ่งเป็นหน้า parking ของผู้ให้บริการอื่น
  **เซิร์ฟเวอร์เราไม่มีทางเสิร์ฟหน้านั้น**

สรุป: **DNS ของ 3 โดเมนนี้ยังไม่ได้ชี้มาที่เครื่อง** ตรงกับคำเตือนที่หน้า Apply SSL
เขียนไว้เองว่า *"Please check whether the A record resolution of the domain points to
this server IP"*

เทียบกับ `yes989-club.com` ที่ขอผ่าน: ทั้ง origin และผ่าน DNS จริงได้เนื้อหาเดียวกัน

**แก้:** ไปตั้ง A record ใน Cloudflare ให้ชี้มาที่ IP ของเครื่อง แล้วกด Apply SSL ใหม่

### ถ้า DNS ถูกแล้วยังไม่ผ่าน

เช็คสองอย่างนี้ต่อ:

1. **Cloudflare → SSL/TLS → Edge Certificates → Always Use HTTPS**
   ถ้าเปิดอยู่ CF จะ redirect challenge ไป https ซึ่งตอนนั้นไซต์ยังไม่มี cert
   origin จึงไม่มี server block ที่ตรงชื่อ → ตกไปที่ catch-all → 404
   **ปิดชั่วคราวตอนขอ cert แล้วเปิดกลับ** หรือปิดเมฆส้มชั่วคราว
2. **ใช้ DNS Verification แทน File Verification** ในหน้า Apply SSL
   (ปุ่มอยู่ข้าง ๆ กัน) เลี่ยงเรื่อง HTTP ทั้งหมด

---

### 15. Search Console บอก "ถูกยกเว้นโดยแท็ก noindex" ทั้งที่เว็บไม่ได้ตั้ง noindex

**อาการ:** Google Search Console → ตรวจสอบ URL → ขึ้น
*"จัดทำดัชนีหน้านี้ไม่ได้: ถูกยกเว้นโดยแท็ก noindex"*
และกด "ทดสอบ URL ที่เผยแพร่จริง" ก็ไม่ผ่าน

### 🎯 อ่านช่องในหน้า Live Test ก่อนเดา — มันบอกเองว่าเป็นเคสไหน

| ช่องในหน้า Live Test | ค่า | แปลว่า |
|---|---|---|
| **การดึงหน้าเว็บ** | **สำเร็จ** | Google โหลดหน้าได้ → **ไม่ได้โดนบล็อก** ไปดูข้อ 16 (noindex ของจริง) |
| การดึงหน้าเว็บ | ล้มเหลว / ไม่สำเร็จ | โดนอะไรขวางอยู่ → ข้อนี้ (Cloudflare/WAF) |
| อนุญาตให้ทำการ Crawl | ไม่ | ติด `robots.txt` |

**ผมเองพลาดตรงนี้มาแล้ว** — เห็น Cloudflare ตอบ 403 กับ curl ก็รีบสรุปว่า Google โดนบล็อก
ทั้งที่หน้าจอ Live Test เขียนไว้ชัดว่า *"การดึงหน้าเว็บ: สำเร็จ"* ซึ่งแปลว่า Google
โหลดหน้าได้ตั้งแต่แรก ตัวจริงคือ `noindex` ที่อยู่ในหน้าเว็บจริง ๆ (ข้อ 16)
เสีย 2 รอบไปกับการไล่ผิดทาง

**อย่าเพิ่งไปแก้ WordPress** — เช็คก่อนว่า noindex มาจากเว็บเราจริงไหม

```bash
# ผ่านโดเมนจริง
curl -s https://DOMAIN/ | grep -iEo '<title>[^<]*</title>|<meta[^>]*robots[^>]*>'

# ยิงตรงที่ origin (ข้ามทุกอย่างที่อยู่ข้างหน้า)
curl -s --resolve DOMAIN:80:SERVER_IP http://DOMAIN/ | grep -iEo '<meta[^>]*robots[^>]*>'
```

| ผ่านโดเมนจริง | origin | แปลว่า |
|---|---|---|
| มี noindex | มี noindex | WordPress ตั้ง `Settings → Reading → Discourage search engines` ไว้ |
| **มี noindex** | **ไม่มี** | 🎯 **มีอะไรบางอย่างขวางอยู่ข้างหน้า ไม่ใช่เว็บเรา** |

### เคสจริง 2026-08-23 — Cloudflare บล็อก

`brazil999-vvip.com` ขึ้น noindex ใน GSC แต่บน origin **ไม่มี meta robots เลย**
(ตรวจครบทั้ง 43 ไซต์บนเครื่อง — **ไม่มีไซต์ไหนตั้ง noindex สักตัว**)

เปิดผ่านโดเมนจริงแล้วดูว่าได้อะไรมา:

```
HTTP 403
<title>Attention Required! | Cloudflare</title>
<meta name="robots" content="noindex, nofollow" />
"Sorry, you have been blocked"
```

**Cloudflare บล็อก request นั้นอยู่ และหน้าบล็อกของ Cloudflare เองมี `noindex` ติดมาด้วย**
เทียบกับโดเมนอื่นบนเครื่องเดียวกันที่ตอบ HTTP 200 ปกติ — **เป็นที่ zone นี้ zone เดียว
ไม่ใช่ที่เซิร์ฟเวอร์**

### ⚠️ แต่ต้องทดสอบต่อว่าใครโดนบล็อกกันแน่ — อย่าเดาว่า Googlebot โดนด้วย

การบล็อกของ Cloudflare มักผูกกับ **User-Agent** ทดสอบเทียบสองตัว:

```bash
D=DOMAIN.TLD
curl -s -o /dev/null -w 'curl ธรรมดา: %{http_code}
' "https://$D/"
curl -s -o /dev/null -w 'Googlebot  : %{http_code}
'   -A "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" "https://$D/"
```

ผลจริงของเคสนี้:

```
curl ธรรมดา: 403
Googlebot  : 200      <- ผ่าน
```

**Googlebot ไม่ได้โดนบล็อก** สิ่งที่โดนคือ user-agent ที่หน้าตาเหมือนบอททั่วไป
ซึ่งรวมถึง **เครื่องมือเช็ค redirect ออนไลน์** ที่ใช้ UA ชื่อ `ToolBot` ด้วย

👉 **เครื่องมือเช็ค redirect ภายนอกใช้ทดสอบโดเมนที่อยู่หลัง Cloudflare ไม่ได้**
มันจะรายงาน 403 เสมอ ซึ่งไม่ได้แปลว่า redirect พัง ให้ยิงที่ origin เองแทน:

```bash
curl -sk --resolve $D:443:SERVER_IP -o /dev/null -w '%{http_code} -> %{redirect_url}
' "https://$D/"
```

### ถ้า Googlebot ผ่านแล้วแต่ GSC ยังบอก noindex

หน้า **Live Test** ของ Search Console ไม่ได้ใช้ UA ของ Googlebot แต่ใช้
**Google Inspection Tool** ซึ่งเป็นคนละตัวและมักโดน WAF บล็อกบ่อยกว่า
ให้ดู **Security → Events** ใน Cloudflare ว่ามี request จาก Google โดนบล็อกในช่วงเวลาที่ทดสอบไหม
แล้วเพิ่มข้อยกเว้นให้ ASN ของ Google หรือผ่อน rule ที่ยิงโดน

**แก้:** เข้า Cloudflare zone ของโดเมนนั้น

1. **Security → Events** — ดูว่า rule ไหนเป็นคนบล็อก (บอกชื่อ rule ตรง ๆ) เริ่มที่นี่เสมอ
2. **Security → WAF → Custom rules** — rule ที่เขียนกว้างเกินไปจะกิน Googlebot ไปด้วย
3. **Security → Bots → Bot Fight Mode** — ของฟรีตัวนี้ท้าทาย crawler ที่ถูกต้องได้
4. **Security → Settings → Security Level** — ถ้าเป็น "I'm Under Attack" ให้ลดลง

> ⚠️ **[02 §2.7](02-hardening.md) ของ repo นี้แนะนำให้เปิด WAF rules และ Bot Fight Mode**
> ซึ่งจำเป็นจริงเพราะบอทสแกนหนักมาก **แต่ต้องตรวจหลังตั้งทุกครั้งว่า Googlebot ไม่โดนไปด้วย**
> ไม่งั้นจะได้เว็บที่ปลอดภัยแต่ไม่มีใครหาเจอ ซึ่งสำหรับเว็บที่ทำมาเพื่อ SEO คือพังทั้งงาน
>
> ตรวจง่าย ๆ: `curl -s -o /dev/null -w '%{http_code}' -A "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" https://DOMAIN/`
> ต้องได้ **200** ไม่ใช่ 403

---

### 16. noindex ที่มาจาก WordPress เอง (และแคชที่ทำให้แก้แล้วเหมือนไม่ได้แก้)

ต่อจากข้อ 15 — เมื่อพิสูจน์แล้วว่า noindex **มีที่ origin ด้วย** แปลว่ามาจาก WordPress จริง
ไม่ใช่อะไรที่อยู่ข้างหน้า

**ตัวที่ทำ:** `Settings → Reading → Discourage search engines from indexing this site`
เก็บเป็น option `blog_public = 0` ทำให้ WordPress ใส่
`<meta name='robots' content='noindex, nofollow'>` ให้ทุกหน้า

> สังเกต **single quote** รอบ `'robots'` — เป็นสไตล์ของ WordPress core
> ถ้าเป็น double quote มักมาจากปลั๊กอินหรืออย่างอื่น

มักติดจากตอนสร้างเว็บ/ติดตั้งธีมแล้วลืมปลดก่อนเปิดใช้จริง

### สแกนทุกไซต์

```bash
bash /root/wpaa/scripts/fix-noindex.sh                    # ดูอย่างเดียว
bash /root/wpaa/scripts/fix-noindex.sh --apply            # แก้ทุกไซต์
bash /root/wpaa/scripts/fix-noindex.sh --apply DOMAIN.TLD # แก้ไซต์เดียว
```

อ่าน/เขียนผ่าน `wp-load.php` ของไซต์เอง จึงไม่ต้องดึงรหัสผ่านฐานข้อมูลออกมา

> 🔴 **ตรวจครั้งแรกผมได้ผลผิดเพราะสแกนผิดวิธี** — ยิง `http://` แล้วเจอ 301 จึงไปอ่าน
> หน้า redirect ที่ไม่มี meta อะไรเลย แล้วสรุปว่า "0 ไซต์ติด noindex"
> **ต้องใส่ `-L` ตามลูกโซ่ให้จบก่อนเสมอ** พอทำถูกก็เจอ 28–30 ไซต์

### 🔴 แก้แล้วต้องล้างแคชด้วย ไม่งั้นเหมือนไม่ได้แก้

เคสจริง: `brazil999-vvip.com` ตั้ง `blog_public = 1` เรียบร้อยแล้ว แต่หน้าเว็บยังส่ง
`noindex` อยู่

```
ไม่มี query : X-Cache: HIT     -> noindex, nofollow          <- หน้าเก่าในแคช
มี query    : X-Cache: BYPASS  -> index, follow, max-image-preview:large
```

FastCGI cache เก็บหน้าเก่าไว้ตาม `fastcgi_cache_valid` (1 ชั่วโมง) — **ถ้า Googlebot มา
ในช่วงนั้นพอดี ก็ยังเห็น noindex อยู่ดี** และ **ปลั๊กอิน Nginx Helper ไม่ช่วย** เพราะมันล้าง
ตอน publish/edit โพสต์ ไม่ได้ล้างตอนเปลี่ยน setting

`fix-noindex.sh --apply` จึงล้าง cache ให้เองเมื่อมีการแก้จริง ถ้าแก้ผ่านหน้า wp-admin
ต้องล้างเอง:

```bash
bash /root/wpaa/scripts/clear-cache.sh
```

### ⚠️ ระวังแคชซ้อนแคช

`brazil999-vvip.com` ติดตั้งปลั๊กอิน **`wp-fastest-cache`** ไว้ด้วย ซึ่งเป็น page cache
อีกชั้นซ้อนบน FastCGI cache ของ nginx **เวลามีปัญหาเนื้อหาไม่อัปเดตจะแยกไม่ออกว่าใครเก็บไว้**
ต้องล้างทั้งสองที่ ถ้าไม่ได้ต้องการจริง ๆ แนะนำให้ถอนออกแล้วใช้ FastCGI + Nginx Helper อย่างเดียว
ตาม [04 §4.7](04-cache.md)

---

### 17. กดปุ่ม Purge ในหน้า WP แล้วแคชไม่หาย (เงียบสนิท ไม่มี error)

**อาการ:** แก้หน้าเว็บแล้วกด Update / กด Purge Cache แต่คนทั่วไปยังเห็นของเก่า
ตัวเองเห็นของใหม่เพราะ **login อยู่** (คุกกี้ `wordpress_logged_in` อยู่ใน `$skip_cache`)

**ตัวแยกโรค — เทียบหน้าที่ผ่านแคชกับหน้าสด:**

```bash
D=DOMAIN.TLD
curl -sk --resolve $D:443:127.0.0.1 "https://$D/"          | grep -o '<h1[^>]*>.\{0,80\}'
curl -sk --resolve $D:443:127.0.0.1 "https://$D/?nocache=1" | grep -o '<h1[^>]*>.\{0,80\}'
```

ถ้าอันล่างถูก อันบนผิด = **บันทึกสำเร็จแล้ว ติดที่แคชล้วน ๆ** ไม่ต้องไปไล่หาว่าลืมกด Update

**สาเหตุ:** มีได้ 5 อย่าง และเจอมาแล้วทุกอย่าง — ดูตารางเต็มใน [04 §4.7](04-cache.md)

ที่เจอบ่อยที่สุด 3 อย่าง:

1. `purge_method = get_request` → ยิง HTTP หาตัวเองแล้วโดน `deny all` เพราะวนออกไป
   เจอ Cloudflare แล้วกลับมาด้วย IP อื่น
2. `open_basedir` ของ `.user.ini` กั้น PHP ไม่ให้แตะโฟลเดอร์แคช
3. 🔴 **`RT_WP_NGINX_HELPER_CACHE_PATH` ชี้ไปโฟลเดอร์ที่ไม่ใช่ที่ nginx ใช้จริง**

**ข้อ 3 คือข้อที่หลอกที่สุด** — เจอ 97 จาก 136 ไซต์ชี้ไป `/dev/shm/nginx-cache/wp`
ซึ่งว่างเปล่า ปลั๊กอินจึงลบไฟล์ในโฟลเดอร์ที่ไม่มีอะไรอยู่ **รายงานว่าสำเร็จทุกครั้ง**
อาการที่ได้คือ "เปิดปลั๊กอินแล้วก็ยังไม่หาย" ทั้งที่ปลั๊กอินทำงานปกติทุกอย่าง

เทียบสองค่านี้ก่อนเสมอ:

```bash
grep -oP 'fastcgi_cache_path \K[^ ]+' /www/server/panel/vhost/nginx/0.fastcgi_cache.conf
grep -h RT_WP_NGINX_HELPER_CACHE_PATH /www/wwwroot/*/wp-config.php | sort | uniq -c
```

**ยืนยันสาเหตุด้วยการให้ PHP ของไซต์นั้นพูดเอง:**

```bash
D=DOMAIN.TLD
F=$(grep -rlaE "^KEY: httpsGET${D}/$" /www/server/fastcgi_cache | head -1)
cat > /www/wwwroot/$D/probe.php <<PHP
<?php \$f='$F';
echo ini_get('open_basedir')."
";
echo (@file_exists(\$f)?'เห็นไฟล์':'ไม่เห็นไฟล์')."
";
PHP
chown www:www /www/wwwroot/$D/probe.php
curl -sk --resolve $D:443:127.0.0.1 "https://$D/probe.php?x=1"
rm -f /www/wwwroot/$D/probe.php      # 🔴 ลบทิ้งทุกครั้ง อย่าทิ้งไว้ใน web root
```

ถ้าได้ `open_basedir restriction in effect` = ใช่เคสนี้

**แก้:**

```powershell
ssh root@SERVER_IP "bash /root/wpaa/scripts/fix-cache-purge.sh"      # ให้ปุ่มใช้ได้ถาวร (ทั้ง 5 ข้อ)
ssh root@SERVER_IP "bash /root/wpaa/scripts/clear-cache.sh DOMAIN"   # ล้างของที่ค้างอยู่ตอนนี้
```

**แล้วพิสูจน์ว่าใช้ได้จริง** ด้วยวิธีใน [04 §4.7](04-cache.md) — อย่าเชื่อว่า "เปิดแล้ว"
เท่ากับใช้ได้ เพราะทุกความผิดพลาดในหมวดนี้เงียบเหมือนกันหมด

**ถ้ายังไม่หายหลังจากนั้น** = ค้างที่ Cloudflare ไม่ใช่ที่เครื่อง แยกชั้นจาก response header
ในเบราว์เซอร์ (DevTools → Network):

| เห็น | ค้างที่ | ล้างที่ |
|---|---|---|
| `cf-cache-status: HIT` | Cloudflare | Cloudflare → Caching → Purge Everything |
| `x-cache: HIT` แต่เนื้อหาเก่า | เครื่องเรา | `clear-cache.sh DOMAIN` |

---

### 18. หัว panel โชว์ IP ของเครื่องอื่น

**อาการ:** เปิด aaPanel ที่ `https://187.52.125.203:PORT` แต่หัวหน้า Home โชว์
`89.116.52.173` ซึ่งไม่ใช่ IP ของเครื่องนี้เลย

**นี่ไม่ใช่เรื่องความสวยงาม** — หัว panel เป็นที่แรกที่คนมองเวลาจะยืนยันว่า "ตอนนี้อยู่บน
เครื่องไหน" ถ้ามันโชว์ IP ของเครื่องอื่น มีโอกาสที่คนจะก๊อป IP นั้นไปรันคำสั่งผิดเครื่อง

**สาเหตุ:** aaPanel เก็บ IP ไว้ในไฟล์เดียว `/www/server/panel/data/iplist.txt` และ
`GetLocalIp()` จะไปถาม `ifconfig.me` ใหม่**ก็ต่อเมื่อไฟล์นั้นว่าง**เท่านั้น:

```python
filename = 'data/iplist.txt'
ipaddress = readFile(filename)
if not ipaddress:                    # <-- ถามใหม่เฉพาะตอนไฟล์ว่าง
    url = 'https://ifconfig.me/ip'
```

ค่าผิดจึงไม่มีวันแก้ตัวเอง — และบนเครื่องที่เช่าจาก Hostinger ค่านี้ติดมากับ image
**เจอค่าเดียวกัน (`89.116.52.173`) บนทั้ง 2 เครื่อง** ลงวันที่เดียวกันคือวันสร้าง image
เครื่องใหม่ทุกเครื่องจึงน่าจะเป็นแบบนี้หมด

**แก้:**

```bash
F=/www/server/panel/data/iplist.txt
REAL=$(ip -4 addr show scope global | grep -oP 'inet \K[0-9.]+' | head -1)
cp -p "$F" "/root/wpaa/backups/iplist.txt.bak-$(date +%F-%H%M%S)"
printf '%s' "$REAL" > "$F"
chown root:root "$F"; chmod 600 "$F"
```

แล้ว **refresh หน้า panel** (F5) · ถ้ายังไม่เปลี่ยน `/etc/init.d/bt restart`
(รีแค่ตัว panel เว็บลูกค้าไม่กระทบ)

**ยืนยันด้วยฟังก์ชันของ panel เอง ไม่ใช่แค่ดูไฟล์:**

```bash
cd /www/server/panel && ./pyenv/bin/python3 -c "
import sys; sys.path.insert(0,'class')
from public import get_ip
print(get_ip())"
```

> ถ้าไม่อยากใส่ค่าเอง ลบไฟล์ทิ้งก็ได้ — panel จะไปถาม `ifconfig.me` ใหม่แล้วเขียนกลับ
> แต่แบบนั้นต้องให้เครื่องออกเน็ตได้ตอนนั้นพอดี การเขียนค่าตรง ๆ ไม่พึ่งอะไรเลย
>
> `verify-config.sh` มีด่าน **`IP ที่หัว panel`** ตรวจให้แล้ว

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

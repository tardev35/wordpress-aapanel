# 04 — Cache

ส่วนที่ให้ผลด้านความเร็วมากที่สุด

---

## 4.1 โครงสร้างที่ aaPanel ออกแบบไว้ ⭐

**นี่คือเรื่องสำคัญที่สุดในเอกสารนี้** — aaPanel มีจุดกลางให้แก้ครั้งเดียว ใช้ได้ทุกเว็บ
**ไม่ต้องตามแก้ทีละโดเมน**

```
/www/server/panel/vhost/nginx/
└── 0.fastcgi_cache.conf              ← ประกาศ cache zone (ระดับ http)

/www/server/nginx/conf/
└── enable-php-83-wpfastcgi.conf      ← location + cache directive ⭐ แก้ที่นี่

/www/server/panel/vhost/nginx/
└── <domain>.conf                     ← แค่ include ไม่ต้องแตะ
```

ไฟล์เว็บจะมีบรรทัด:
```nginx
include enable-php-83-wpfastcgi.conf;
```

**ไฟล์ที่ลงท้าย `-wpfastcgi` คือเวอร์ชันที่เปิด cache แล้ว**
ส่วน `enable-php-83.conf` (214 bytes) คือเวอร์ชันธรรมดาไม่มี cache

> **กฎ: ทุกเว็บต้องใช้ PHP 8.3 เหมือนกันหมด**
> ไม่งั้นจะมีหลายไฟล์ให้ตามแก้ (`enable-php-84-wpfastcgi.conf`, ฯลฯ)

### วิธีเปิด cache ให้เว็บ

**WP Toolkit → คลิกโดเมน → ปุ่ม ⚡ (accelerate)**

WP Toolkit จะสลับ include จาก `enable-php-83.conf` เป็น `enable-php-83-wpfastcgi.conf` ให้เอง

---

## 4.2 ไฟล์ config ที่ควรใช้

> ✅ **ติดตั้งแล้วบนเครื่องอ้างอิงเมื่อ 2026-08-23** — วัดได้ MISS 62 ms / HIT 0.25–0.44 ms
>
> ก่อนหน้านั้นไฟล์บนเครื่องเป็น**ฉบับโรงงานของ WP Toolkit ทุกบรรทัด** ทั้งที่เอกสารรุ่นแรก
> เขียนเหมือนปรับไปแล้ว
>
> 🔴 **แต่ยังไม่จบ** — WP Toolkit เขียนทับไฟล์นี้ทุกครั้งที่เพิ่มไซต์ใหม่ (ดูหัวข้อถัดไป)
> ไม่ใช่ตั้งครั้งเดียวจบ · **วิธีที่ไม่ต้องมานั่งจำ: ตั้ง cron ให้กู้กลับเองทุกคืน**
> ดู [05 §5.1b](05-operations.md)
>
> **ติดตั้งฉบับที่จูนแล้ว:**
> ```powershell
> scp -r configs scripts root@SERVER_IP:/tmp/wpaa/
> ssh root@SERVER_IP "bash /tmp/wpaa/scripts/apply-cache-config.sh"
> ssh root@SERVER_IP "/etc/init.d/nginx reload"
> ssh root@SERVER_IP "bash /tmp/wpaa/scripts/clear-cache.sh"
> ```
> สคริปต์สำรองของเดิมให้ก่อน และ **ถ้า `nginx -t` ไม่ผ่านจะกู้ไฟล์เดิมกลับอัตโนมัติ**
>
> ผลที่ตามมาไม่ใช่แค่ "ช้ากว่าที่ควร" — `fastcgi_cache_valid 200 1d` ของฉบับโรงงาน
> ทำให้หน้าที่ cache ผิดพลาดค้างอยู่ **1 วัน** แทนที่จะเป็น 1 ชั่วโมง (ดู §4.5)

ไฟล์ที่ WP Toolkit สร้างให้ใช้ได้ดีอยู่แล้ว แต่มี 4 จุดที่ควรปรับ

| จุด | ค่าเดิม | แก้เป็น | เหตุผล |
|---|---|---|---|
| `fastcgi_cache_valid` | `200 1d` | **`200 301 302 1h`** | 1 วันนานเกินไป |
| `add_header Cache-Control max-age=0` | มี | **ลบ** | ⭐ ดูด้านล่าง |
| `add_header Last-Modified $date_gmt` | มี | **ลบ** | ตั้งเป็นเวลาปัจจุบันทุกครั้ง ทำให้ conditional request ใช้ไม่ได้ |
| Regex `wp-.*.php` | จุดไม่ escape | **`wp-.*\.php`** | ตรงกับตัวอักษรใดก็ได้ |

### ⭐ ทำไมต้องลบ `Cache-Control: max-age=0`

มันทำให้:
- เบราว์เซอร์ผู้ใช้ไม่ cache → โหลดใหม่ทุกครั้ง
- **Cloudflare ไม่ cache HTML** → เสียประโยชน์ edge สิงคโปร์ทั้งหมด

**เป็นตัวที่ขวางแผน Cloudflare โดยตรง**

### คำสั่งที่เพิ่มเข้าไป

| คำสั่ง | ประโยชน์ |
|---|---|
| `fastcgi_cache_lock on` | 100 คนเข้าพร้อมกันตอน cache หมดอายุ → PHP ทำงานแค่ครั้งเดียว **สำคัญมากเมื่อมี 100 เว็บ** |
| `fastcgi_cache_background_update on` | อัปเดต cache เบื้องหลัง ผู้ใช้ไม่ต้องรอ |
| `fastcgi_cache_use_stale` | **ถ้า PHP ล่ม ยังเสิร์ฟ cache เก่าได้ → เว็บไม่ขึ้น 502** |
| `/wp-login.php`, `/wp-json/` ใน skip | ป้องกัน cache หน้า login และ REST API |

> `fastcgi_cache_use_stale` มีประโยชน์มาก — เคยเกิดเหตุ php-fpm ตายจนเว็บขึ้น Bad Gateway
> ถ้ามีคำสั่งนี้ เว็บจะยังเสิร์ฟหน้าเก่าได้แทน

**ไฟล์เต็ม:** [`configs/enable-php-83-wpfastcgi.conf`](../configs/enable-php-83-wpfastcgi.conf)

### 🔴 WP Toolkit เขียนทับไฟล์นี้ — และบ่อยกว่าที่คิด

เดิมเข้าใจว่าเสี่ยงเฉพาะตอน "อัปเดต aaPanel" **ของจริงแรงกว่านั้น**

หลักฐานจากเครื่องอ้างอิง: `enable-php-83-wpfastcgi.conf` มี mtime เป็น **06:34** ซึ่งเป็น
**นาทีเดียวกับที่ vhost ของไซต์ใหม่ถูกสร้าง** และเนื้อไฟล์กลับไปเป็นฉบับโรงงานขนาดเท่าเดิมเป๊ะ
(1265 ไบต์) เท่ากับ backup ของเมื่อวาน

แปลว่า **การเพิ่มไซต์ใหม่ที่เปิด cache (ปุ่ม ⚡) เขียนไฟล์กลางตัวนี้ใหม่ทั้งไฟล์**
ไม่ใช่แค่ไปแก้ include ของไซต์นั้น — ไซต์ที่มีอยู่เดิมทั้งหมดจึงเสียค่าที่จูนไว้ไปพร้อมกัน
โดยไม่มีสัญญาณอะไรเตือน

**กติกาที่ตามมา: ต้องเช็คหลังเพิ่มไซต์ ไม่ใช่แค่หลังอัปเดต panel**

และเนื่องจากทีมเพิ่มเว็บกันวันละหลายตัว การมานั่งรันเองทุกครั้งไม่รอด —
**ให้ตั้ง cron กู้กลับเองทุกคืนแทน** ([05 §5.1b](05-operations.md)):

```powershell
scp -r configs scripts root@SERVER_IP:/tmp/wpaa/
ssh root@SERVER_IP "bash /tmp/wpaa/scripts/install-autoheal.sh"
```

จะเช็คเองก็ยังทำได้ทุกเมื่อ:

```powershell
ssh root@SERVER_IP "bash /tmp/wpaa/scripts/verify-config.sh"
```

### วิธีติดตั้ง

```bash
# สำรองก่อนเสมอ
sudo cp /www/server/nginx/conf/enable-php-83-wpfastcgi.conf \
        /www/server/nginx/conf/enable-php-83-wpfastcgi.conf.bak-$(date +%F)
```

**แก้ผ่าน:** aaPanel → App Store → Nginx → Config file

```bash
# ตรวจก่อน reload เสมอ
/www/server/nginx/sbin/nginx -t
/etc/init.d/nginx reload
```

---

## 4.3 ทดสอบ

```bash
sudo rm -rf /www/server/fastcgi_cache/*
/etc/init.d/nginx reload

curl -sI http://127.0.0.1 -H "Host: DOMAIN.TLD" | grep -iE "x-cache|cache-control"
curl -sI http://127.0.0.1 -H "Host: DOMAIN.TLD" | grep -iE "x-cache|cache-control"

for i in 1 2 3; do
  curl -o /dev/null -sw "TTFB: %{time_starttransfer}s\n" http://127.0.0.1 -H "Host: DOMAIN.TLD"
done
```

### ผลจริงที่วัดได้

```
X-Cache: MISS From DOMAIN.TLD      ← ครั้งแรก
X-Cache: HIT From DOMAIN.TLD       ← ครั้งที่สอง

TTFB: 0.035723s   (35 ms)   ← MISS ผ่าน PHP + MySQL
TTFB: 0.000286s   (0.29 ms) ← HIT
TTFB: 0.000307s   (0.31 ms) ← HIT
```

**cache ลดภาระลง ~117 เท่า**

---

## 4.4 ⚠️ ระวัง: cache หน้า "website has been stopped"

ถ้าเว็บอยู่สถานะ Stopped ใน aaPanel แล้วมีคนเข้า **cache จะเก็บหน้า error นั้นไว้**
และเสิร์ฟต่อไปแม้เปิดเว็บแล้ว

**หลังเปิดเว็บทุกครั้ง ต้องล้าง cache:**
```bash
sudo rm -rf /www/server/fastcgi_cache/*
/etc/init.d/nginx reload
```

---

## 4.4b ล้างแคชด้วยอะไรดี — มีหลายตัว เลือกให้ถูก

เครื่องนี้มีของที่แคชได้อยู่หลายชั้น ตารางนี้คือตัวตัดสิน

| สถานการณ์ | ใช้ตัวนี้ |
|---|---|
| แก้ setting ใน WordPress ที่มีผลทุกหน้า (เช่นปลด noindex) **ไซต์เดียว** | `clear-cache.sh DOMAIN.TLD` |
| เปลี่ยนไฟล์ `enable-php-83-wpfastcgi.conf` / เปิดเว็บที่เคย Stopped | `clear-cache.sh` (ทั้งเครื่อง) |
| แก้/เผยแพร่โพสต์หรือหน้า | **ไม่ต้องทำอะไร** — Nginx Helper ล้างให้เอง |
| ปลด noindex หลายไซต์พร้อมกัน | `fix-noindex.sh --apply` (ล้างให้ในตัว) |
| กู้ config ที่โดนเขียนทับ | `nightly-check.sh` (ล้างให้ในตัว) |

```bash
bash /root/wpaa/scripts/clear-cache.sh                 # ทุกไซต์
bash /root/wpaa/scripts/clear-cache.sh DOMAIN.TLD      # เฉพาะไซต์เดียว
```

### ทำไมต้องมีแบบเลือกไซต์

ล้างทั้งเครื่องแปลว่า **ทุกไซต์ต้องสร้าง cache ใหม่หมด** ตอนมี 40+ ไซต์ การแก้ setting
ของเว็บเดียวไม่ควรไปรีเซ็ตของอีก 40 เว็บ

ทำได้เพราะ cache key คือ `$scheme$request_method$host$request_uri` — **ชื่อโฮสต์ฝังอยู่
ในไฟล์แคช** จึงเลือกลบเฉพาะไฟล์ที่ตรงกับโดเมนนั้นได้

ทดสอบแล้ว: ล้าง `at1985.co` → มันเป็น `MISS` ส่วน `yes9899.com` ยัง `HIT` ตามเดิม

### 🔴 Nginx Helper ไม่ได้ล้างทุกกรณี

มันล้างตอน **publish / edit / delete โพสต์** เท่านั้น
**การเปลี่ยน setting ไม่ทริกเกอร์มัน** — เคสจริงคือปลด `noindex` แล้วหน้าเว็บยังส่ง
`noindex` ต่ออีกเป็นชั่วโมงเพราะไม่มีใครล้างให้ (ดู [07 ข้อ 16](07-troubleshooting.md))

**และถ้าตั้ง Purge Method ผิด มันจะไม่ล้างเลยแม้แต่กรณีที่ควรล้าง** — เงียบสนิท
ไม่มี error ให้เห็น ดู [§4.7](#47-nginx-helper-จำเป็น) ก่อนสรุปว่า "แคชมันดื้อ"

### ชั้นอื่นที่อาจแคชซ้อนอยู่

| ชั้น | สถานะบนเครื่องนี้ | ล้างยังไง |
|---|---|---|
| **FastCGI cache** (nginx) | ใช้อยู่ทุกไซต์ WP | `clear-cache.sh` |
| **Cloudflare** | ไม่ได้แคช HTML (`cf-cache-status: DYNAMIC`) | ไม่ต้องทำอะไร เว้นแต่ไปเปิด Cache Everything |
| **ปลั๊กอิน page cache** เช่น `wp-fastest-cache` | มีบางไซต์ติดตั้งไว้ | ต้องล้างในหน้า wp-admin ของไซต์นั้นแยก |
| **aaPanel Speed** | ติดตั้งแล้วแต่ไม่ได้เปิดใช้ต่อไซต์ | — |

> ⚠️ **ปลั๊กอิน page cache ซ้อนบน FastCGI cache คือปัญหาที่รอเกิด** เวลาเนื้อหาไม่อัปเดต
> จะแยกไม่ออกว่าใครเก็บไว้ ถ้าไม่ได้ตั้งใจใช้ควรถอนออก แล้วเหลือ FastCGI + Nginx Helper
> ชั้นเดียวตาม §4.7

---

## 4.5 🔴 cache เก็บเนื้อหาของเว็บอื่นไว้ใต้โดเมนเรา

เกิดขึ้นจริงเมื่อ 2026-08-23 กับ 2 โดเมนบนเครื่องอ้างอิง **นี่คือกรณีที่ร้ายกว่า §4.4 มาก**
เพราะไม่ใช่หน้า error ของตัวเอง แต่เป็น**เว็บของลูกค้าอีกราย**

### อาการ

โดเมนมี vhost ของตัวเองเรียบร้อย มี WordPress ของตัวเอง มีฐานข้อมูลของตัวเอง
แต่เปิดหน้าแรกแล้วได้เว็บของโดเมนอื่น

### วิธีแยกว่าใช่เคสนี้ไหม — เติม query string เข้าไป

```bash
curl -sI https://DOMAIN.TLD/       | grep -i x-cache    # X-Cache: HIT   -> ได้เว็บผิด
curl -sI "https://DOMAIN.TLD/?x=1" | grep -i x-cache    # X-Cache: BYPASS -> ได้เว็บถูก
```

**ถ้าใส่ `?x=1` แล้วเนื้อหากลับมาถูก แปลว่าปัญหาอยู่ที่ cache ไม่ใช่ที่ vhost**
เพราะ `enable-php-83-wpfastcgi.conf` มีบรรทัด `if ($query_string != "") { set $skip_cache 1; }`
การมี query string จึงเลี่ยง cache ไปหา PHP ตรง ๆ

### ทำไมถึงเกิด

cache key คือ:

```nginx
fastcgi_cache_key "$scheme$request_method$host$request_uri";
```

`$host` มาจาก **Host header ที่ผู้ใช้ส่งมา** ไม่ใช่จาก server block ที่ถูกเลือก

ระหว่างที่โดเมนใหม่ยังไม่มี server block ในคอนฟิกที่ nginx รันอยู่ (เพิ่ง Add site
แต่ยังไม่ reload — ดู [07-troubleshooting ข้อ 10](07-troubleshooting.md)) request จะตกไปที่
**default server** ตาม [02-hardening §2.8](02-hardening.md) แล้ว:

- เนื้อหา → มาจาก docroot ของ default server (เว็บคนอื่น)
- cache key → ใช้ `$host` = โดเมนใหม่

**HTML ของเว็บ A จึงถูกเก็บใต้คีย์ของเว็บ B** และอยู่ต่อไปแม้ vhost จะถูกโหลดถูกต้องแล้ว
ด้วยอายุ `fastcgi_cache_valid` ซึ่งบนเครื่องที่ยังใช้ config โรงงาน = **1 วัน**

### แก้

```bash
bash scripts/clear-cache.sh
```

> ไม่ต้อง restart nginx — เป็น cache บนดิสก์ที่ `/www/server/fastcgi_cache`
> `reload` พอ และ `clear-cache.sh` ทำให้แล้ว

### กันไม่ให้เกิดซ้ำ

ต้องอุดที่ต้นทาง ไม่ใช่ไล่ล้าง cache:

1. ปิดรู default_server → [02-hardening §2.8](02-hardening.md)
2. รัน `stamp-site.sh` ทุกครั้งหลัง Add site → ตัว `nginx -s reload` ในสคริปต์คือสิ่งที่
   ปิดช่วงหน้าต่างอันตราย

---

## 4.6 ปรับให้เร็วขึ้นอีก (ทางเลือก): ย้าย cache ไป RAM

แก้ `/www/server/panel/vhost/nginx/0.fastcgi_cache.conf`:

```nginx
fastcgi_cache_path /dev/shm/ngxcache levels=1:2 keys_zone=WORDPRESS:200m inactive=60m max_size=1g;
```

**เหตุผล:** `/dev/shm` เป็น RAM disk เร็วกว่า NVMe หลายเท่า
cache หายตอนรีบูตก็ไม่เสียหาย เพราะสร้างใหม่ได้เอง

เพิ่ม zone จาก `100m` → `200m` ด้วย เพราะ 100 เว็บต้องการ key space มากกว่า

⚠️ ต้องนับ RAM 1 GB นี้เข้าไปในงบ (ซึ่งวางแผนไว้แล้ว)

---

## 4.7 Nginx Helper (จำเป็น)

**ถ้าไม่ติดตั้ง แก้บทความแล้วจะไม่เห็นการเปลี่ยนแปลงจนกว่า cache หมดอายุ 1 ชั่วโมง**

wp-admin → Plugins → ค้นหา **Nginx Helper** → Install → Activate

**Settings:**
- Caching Method: **Nginx Fastcgi cache**
- Purge Method: **Delete local server cache files** ← 🔴 **ไม่ใช่ GET request**
- ✅ Purge on post publish / edit / delete

### 🔴 ทำไมไม่ใช้ "Using a GET request to PURGE/url" ทั้งที่เครื่องมีโมดูลให้

เอกสารฉบับก่อนแนะนำค่านั้น **และมันใช้ไม่ได้จริงบนเครื่องที่ตั้งตามคู่มือนี้**
ทั้งสองทางของปลั๊กอินตันคนละเหตุผล — ปุ่มกดได้ ไม่มี error แต่ไม่มีอะไรถูกลบ:

| ทาง | ตันเพราะ |
|---|---|
| `Using a GET request` | PHP ยิง HTTP ไปที่ตัวเองแล้วให้ nginx ลบให้ แต่ `location /purge` ตั้ง `allow 127.0.0.1; deny all;` — ไซต์อยู่หลัง **Cloudflare** PHP จึง resolve ได้ IP ของ Cloudflare คำขอวิ่งออกนอกเครื่องแล้ววนกลับ ต้นทางไม่ใช่ `127.0.0.1` อีกต่อไป → โดน deny (Cloudflare ตอบ `403` ให้ด้วยซ้ำ) |
| `Delete local server cache files` | PHP ลบไฟล์ตรง ๆ แต่ aaPanel ใส่ `.user.ini` ล็อก `open_basedir` ให้ PHP อยู่แต่ในโฟลเดอร์ไซต์ตัวเอง → `open_basedir restriction in effect. File(/www/server/fastcgi_cache/...)` |

**เลือกทาง 2 แล้วเปิดทางให้มัน** ด้วย [`scripts/fix-cache-purge.sh`](../scripts/fix-cache-purge.sh)
ซึ่งเติม path ของโฟลเดอร์แคชเข้า `open_basedir` และตั้ง `purge_method` ให้ทุกไซต์:

```powershell
ssh root@SERVER_IP "bash /root/wpaa/scripts/fix-cache-purge.sh --check"   # ดูก่อน
ssh root@SERVER_IP "bash /root/wpaa/scripts/fix-cache-purge.sh"           # แก้จริง
```

เลือกทาง 2 เพราะมันไม่ยิง HTTP ออกไปเลย จึงไม่มีอะไรให้ Cloudflare, WAF, หรือ
`deny all` มาขวางได้ในอนาคต ส่วนทาง 1 ต้องให้ทุกอย่างระหว่างทางเรียงถูกหมดทุกชั้น

> **ผลข้างเคียงที่ต้องรับ:** ทุกไซต์ใช้โฟลเดอร์แคชร่วมกัน การเปิด `open_basedir`
> แปลว่า PHP ของไซต์หนึ่งอ่าน/ลบไฟล์แคชของไซต์อื่นบนเครื่องเดียวกันได้
> รับได้เมื่อทุกเว็บเป็นของเจ้าของเดียวกัน — **ถ้าวันหนึ่งเครื่องนี้ขายพื้นที่ให้คนนอก
> ต้องกลับมาทบทวนข้อนี้**

> `.user.ini` ถูก aaPanel ตั้ง `chattr +i` ไว้ ต้อง `chattr -i` ก่อนแก้แล้วใส่กลับ
> (สาเหตุเดียวกับ [07 ข้อ 12](07-troubleshooting.md)) และค่าใหม่จะมีผลหลัง
> `user_ini.cache_ttl` 300 วินาที — สคริปต์ reload php-fpm ให้เลยไม่ต้องรอ

> ไซต์ใหม่ที่ทีมเพิ่มหลังจากนี้ [`watch-new-sites.sh`](../scripts/watch-new-sites.sh)
> เติม `open_basedir` ให้เองตอน stamp ([05 §5.1c](05-operations.md)) — ไม่ต้องมารันซ้ำ

### 🔴 ต้องครบ 5 ข้อ ปุ่มถึงจะล้างแคชได้จริง

ขาดข้อเดียวปุ่มก็กดได้ตามปกติ **ไม่มี error ให้เห็น แต่ไม่มีอะไรถูกลบ**
ทั้ง 5 ข้อนี้เจอผิดมาแล้วจริงบนเครื่องจริงระหว่าง 2026-08-25 ถึง 2026-08-27:

| # | ต้องเป็น | เคยผิดยังไง |
|---|---|---|
| 1 | `RT_WP_NGINX_HELPER_CACHE_PATH` ใน `wp-config.php` ชี้ไป**โฟลเดอร์ที่ nginx ใช้จริง** | **97 จาก 136 ไซต์** ชี้ไป `/dev/shm/nginx-cache/wp` ซึ่งว่างเปล่า |
| 2 | `.user.ini` เปิด `open_basedir` ให้ PHP แตะโฟลเดอร์นั้นได้ | aaPanel ล็อกไว้ที่โฟลเดอร์ไซต์ → `open_basedir restriction in effect` |
| 3 | มีไฟล์ปลั๊กอิน `nginx-helper` ในไซต์ | **48 ไซต์ไม่มีไฟล์เลย** |
| 4 | ปลั๊กอินถูก activate | **59 ไซต์ปิดอยู่** หลายไซต์เปิด `litespeed-cache` แทน |
| 5 | `purge_method = unlink_files` | ค่าเริ่มต้นคือ `get_request` ซึ่งตันเพราะ Cloudflare |

**ข้อ 1 คือข้อที่หลอกที่สุด** — ปลั๊กอินลบไฟล์ในโฟลเดอร์ที่ไม่มีอะไรอยู่ แล้วรายงานว่าสำเร็จ
ทีมจึงกดปุ่มซ้ำแล้วสรุปว่า "เปิดปลั๊กอินแล้วก็ยังไม่หาย" ทั้งที่ปลั๊กอินทำงานปกติทุกอย่าง

[`fix-cache-purge.sh`](../scripts/fix-cache-purge.sh) จัดการให้ครบทั้ง 5 ข้อ:

```powershell
ssh root@SERVER_IP "bash /root/wpaa/scripts/fix-cache-purge.sh --check"   # ดูก่อน
ssh root@SERVER_IP "bash /root/wpaa/scripts/fix-cache-purge.sh"           # แก้จริง
```

มันอ่านโฟลเดอร์แคชจาก `0.fastcgi_cache.conf` เอง ไม่ได้เขียนตายตัว — ถ้าวันหนึ่งย้ายแคช
ไป RAM ตาม [§4.6](#46-ปรับให้เร็วขึ้นอีก-ทางเลือก-ย้าย-cache-ไป-ram) สคริปต์จะตามไปเอง ·
`wp-config.php` ตรวจ `php -l` ก่อนทับเสมอ · สำรองทุกไฟล์ไว้นอก web root ที่ `/root/wpaa/backups/`

### ✅ วิธีพิสูจน์ว่าปุ่มใช้ได้จริง (อย่าเชื่อว่า "เปิดแล้ว" = ใช้ได้)

ยิง hook ตัวเดียวกับที่ปุ่มเรียก แล้วดูว่าไฟล์แคชหายจริงไหม:

```bash
D=DOMAIN.TLD
curl -sk --resolve $D:443:127.0.0.1 "https://$D/" -o /dev/null      # อุ่นแคช
F=$(grep -rlaE "^KEY: httpsGET${D}/$" /www/server/fastcgi_cache | head -1)

cat > /www/wwwroot/$D/purgetest.php <<'PHP'
<?php
define('WP_USE_THEMES', false);
require __DIR__ . '/wp-load.php';
echo "path = " . RT_WP_NGINX_HELPER_CACHE_PATH . "\n";
echo "active = " . (is_plugin_active('nginx-helper/nginx-helper.php') ? 'yes' : 'no') . "\n";
do_action('rt_nginx_helper_purge_all');
PHP
chown www:www /www/wwwroot/$D/purgetest.php
curl -sk --resolve $D:443:127.0.0.1 "https://$D/purgetest.php?x=1"
rm -f /www/wwwroot/$D/purgetest.php      # 🔴 ลบทิ้งทุกครั้ง อย่าทิ้งไว้ใน web root

[ -f "$F" ] && echo "ยังอยู่ = ยังไม่ได้ผล" || echo "หายแล้ว = ใช้ได้จริง"
```

ถ้ามันพ่น `open_basedir restriction in effect` ออกมา คือข้อ 2 ยังไม่ผ่าน ·
ถ้า `path =` ไม่ตรงกับโฟลเดอร์จริง คือข้อ 1 ยังไม่ผ่าน

> ⚠️ **แก้ `wp-config.php` แล้วต้อง reload php-fpm** ไม่งั้น OPcache ยังใช้ bytecode เดิม
> แล้วปลั๊กอินจะยังเห็น path เก่า — เจอมาแล้วจริง ๆ ตอนแก้ครบ 97 ไซต์แต่ยังไม่มีผล
> (สคริปต์ reload ให้เองแล้ว)

> เซิร์ฟเวอร์นี้มี module `ngx_cache_purge` ติดตั้งมาแล้ว
> (ยืนยันด้วย `nginx -V 2>&1 | grep purge`) กลไก purge เองไม่ได้เสีย
> ทดสอบยิงจาก `127.0.0.1` ตรง ๆ ได้ `200` แล้วหน้าเป็น `MISS` ทันที — ที่เสียคือทางเข้า

---

## 4.8 Redis Object Cache

FastCGI cache ช่วยเฉพาะหน้าที่ cache ได้ ส่วน **หน้า wp-admin และหน้าที่มีคนล็อกอิน**
ต้องพึ่ง Redis object cache

### ตั้ง prefix ก่อนเสมอ ⚠️

**สำคัญมากเมื่อมี 100 เว็บ** ไม่งั้นข้อมูลแต่ละเว็บจะปนกัน

`wp-config.php`:
```php
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_PREFIX', 'site01_');   // ⚠️ ต้องไม่ซ้ำกันทุกเว็บ
define('WP_REDIS_DATABASE', 0);
```

จากนั้นติดตั้งปลั๊กอิน **Redis Object Cache** → Settings → Enable

**ตรวจผล:**
```bash
redis-cli info keyspace
redis-cli --scan --pattern "site01_*" | head -5
```

---

## 4.9 Cloudflare

### ค่าที่เปิดในโปรเจกต์นี้

| เมนู | สถานะ |
|---|---|
| **Caching → Tiered Cache** | ✅ **เปิด** |
| SSL/TLS | 🔴 **ของจริงตอนนี้เป็น Full ธรรมดา** — ควรเป็น Full (Strict) โดยออก Let's Encrypt ที่ origin ก่อน |
| Proxy (เมฆส้ม) | ✅ เปิด — ซ่อน IP จริงของ VPS |

> **ทำไม Full ธรรมดาไม่พอ:** มันเข้ารหัสก็จริง แต่ **ไม่ตรวจว่า cert ตรงกับชื่อโดเมนไหม**
> ผลคือตอนที่เครื่องมีรู `default_server` (§2.8 ของ [02-hardening](02-hardening.md))
> origin ส่ง cert ของเว็บอื่นกลับมา Cloudflare ก็ยอมรับและส่งต่อเนื้อหาผิดเว็บให้ผู้ใช้ตามปกติ
> **Full (Strict) จะจับได้ทันทีและขึ้น error 526 แทนที่จะโชว์เว็บของคนอื่น**
>
> **อย่าใช้ SSL mode `Flexible`** — ข้อมูลระหว่าง Cloudflare↔เซิร์ฟเวอร์ไม่เข้ารหัส
> และทำให้ WordPress เกิด redirect loop บ่อยมาก
>
> ถ้า Let's Encrypt ออกไม่ได้เพราะ proxy บัง: ปิดเมฆส้มชั่วคราว → ออก SSL → เปิดเมฆกลับ

### ตัวเลือกที่ยังไม่ได้เปิด (พิจารณาภายหลัง)

<details>
<summary>Cache Everything Rule — cache HTML ที่ edge</summary>

**Caching → Cache Rules → Create rule**
```
If:
  URI Path does not contain "/wp-admin"
  AND URI Path does not equal "/wp-login.php"
  AND URI Path does not contain "/wp-json"
  AND Cookie does not contain "wordpress_logged_in"
Then:
  Cache eligibility → Eligible for cache
  Edge TTL         → 2 hours
  Browser TTL      → 4 hours
```

**ให้ผลมากที่สุดสำหรับผู้เข้าชมชาวไทย** เพราะเสิร์ฟจาก edge สิงคโปร์
ไม่ต้องวิ่งถึงเซิร์ฟเวอร์เลย
</details>

<details>
<summary>Speed → Optimization</summary>

- Brotli
- Early Hints
- HTTP/3
</details>

### ตรวจผล

```bash
curl -sI https://DOMAIN.TLD | grep -i cf-cache-status
```

---

## ลำดับตามผลกระทบ

| ลำดับ | สิ่งที่ทำ | ผล | เวลา |
|---|---|---|---|
| 1 | **FastCGI Cache** | ⭐⭐⭐⭐⭐ | 20 นาที |
| 2 | Cloudflare Cache Everything | ⭐⭐⭐⭐⭐ | 10 นาที |
| 3 | Redis Object Cache | ⭐⭐⭐ | 10 นาที |
| 4 | Nginx Helper | ⭐⭐⭐ (ความถูกต้อง) | 5 นาที |
| 5 | ย้าย cache ไป /dev/shm | ⭐⭐ | 10 นาที |

---

**ถัดไป:** [05-operations.md](05-operations.md)

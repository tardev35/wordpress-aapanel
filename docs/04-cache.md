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

> 🔴 **สถานะจริงบนเครื่องอ้างอิง (2026-08-23): ยังไม่ได้ใช้ไฟล์นี้**
> `/www/server/nginx/conf/enable-php-83-wpfastcgi.conf` บนเครื่องยังเป็น**ฉบับโรงงานของ
> WP Toolkit ทุกบรรทัด** ทั้งที่เอกสารรุ่นแรกเขียนเหมือนปรับไปแล้ว
>
> ยืนยันได้ทุกเมื่อ: `ssh root@SERVER_IP "bash -s" < scripts/verify-config.sh`
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

**กติกาที่ตามมา: หลังเพิ่มไซต์ทุกครั้ง ไม่ใช่แค่หลังอัปเดต panel**

```powershell
ssh root@SERVER_IP "bash -s" < scripts/verify-config.sh
```

ถ้าขึ้นแดง ให้รัน `apply-cache-config.sh` ซ้ำ — เป็นงานที่ต้องทำเรื่อย ๆ ตราบใดที่ยังเพิ่มไซต์อยู่
ไม่ใช่ตั้งครั้งเดียวจบ

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
- Purge Method: **Using a GET request to PURGE/url**
- ✅ Purge on post publish / edit / delete

> เซิร์ฟเวอร์นี้มี module `ngx_cache_purge` ติดตั้งมาแล้ว
> (ยืนยันด้วย `nginx -V 2>&1 | grep purge`) จึงล้าง cache ทีละหน้าได้

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

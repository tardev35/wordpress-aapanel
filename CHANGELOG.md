# Changelog

## 2026-08-23 — ตรวจสภาพจริงแล้วแก้เอกสารให้ตรง + ปิดรู nginx

### 🔴 เหตุการณ์ที่เป็นจุดตั้งต้น

โดเมนของทีมงานที่ชี้ DNS มาที่เครื่องแล้วแต่ยังไม่ได้ Add site **เปิดแล้วได้เว็บของลูกค้าอีกราย
เต็มหน้า โดย URL ยังเป็นโดเมนตัวเอง** ตามด้วยอีก 2 โดเมนที่ยังผิดอยู่แม้จะ Add site แล้ว

สาเหตุเป็นคนละเรื่องกัน 2 ชั้น:

1. **ไม่มี `default_server` บนพอร์ต 443** — `0.default.conf` ของ aaPanel ครอบแค่พอร์ต 80
   nginx จึงเลือก server block แรกที่ listen 443 ตามลำดับตัวอักษรมาเป็น default
2. **FastCGI cache เก็บ HTML ของเว็บผิดไว้ใต้คีย์ของโดเมนถูก** — cache key ใช้ `$host`
   (Host header) แต่เนื้อหามาจาก docroot ของ default server ขยะจึงค้างต่อแม้แก้ข้อ 1 แล้ว

### แก้บนเครื่องอ้างอิง

- เพิ่ม `configs/0.catchall_ssl.conf` — `listen 443 ssl default_server`, self-signed cert,
  `www.* → 301 apex`, ที่เหลือ `404` · แตะเฉพาะพอร์ต 443 ไม่แตะ 80 (Let's Encrypt HTTP-01 ใช้ต่อได้)
- เพิ่ม `configs/common-site.conf` — www → non-www ที่ระดับ nginx symlink เข้าทุกไซต์
  ผ่าน `extension/<domain>/00-common.conf` (เดิม redirect นี้เป็นหน้าที่ของ WordPress
  ซึ่งไซต์ที่ยังไม่ได้ลง WP จะไม่มีเลย)
- เพิ่ม `scripts/harden-nginx.sh` (ครั้งเดียวต่อเครื่อง) และ `scripts/stamp-site.sh`
  (ทุกครั้งหลัง Add site — ตัว reload ในนั้นคือสิ่งที่ปิดช่วงหน้าต่างที่ป้อนขยะเข้า cache)

**ผลหลังปิด:** โดเมนแปลกหน้า → 404 · `www.*` → 301 ไป apex ทุกไซต์ รวมถึงไซต์ที่ panel
ไม่ได้ใส่ `www` ใน `server_name`

### 🔎 drift ที่เจอตอนเทียบเอกสารกับเครื่องจริง

เอกสารรุ่นแรกบรรยายสภาพที่เครื่องไม่ได้เป็น:

| เอกสารเขียนว่า | ความจริงบนเครื่องอ้างอิง |
|---|---|
| ปรับ `enable-php-83-wpfastcgi.conf` แล้ว 4 จุด | **ยังเป็นฉบับโรงงานทุกบรรทัด** — มี `Cache-Control: max-age=0`, `Last-Modified`, `fastcgi_cache_valid 200 1d`, ไม่มี `cache_lock`/`use_stale` |
| Redis `maxmemory 1gb` | **ไม่ได้ตั้ง** |
| PHP 8.3 หลัก + 8.4 สำรอง | **ไม่มี 8.4** · 8.0/8.1/8.2 ยังไม่ได้ถอน |
| Cloudflare SSL = Full (Strict) | เป็น **Full ธรรมดา** ซึ่งยอมรับ cert ที่ไม่ตรงชื่อ — เป็นเหตุผลหนึ่งที่รู 443 ไม่ถูกจับได้เร็วกว่านี้ |
| Fail2ban ยังไม่ทำ | **ติดตั้งแล้ว** |

> `fastcgi_cache_valid 200 1d` ของฉบับโรงงานคือเหตุผลที่หน้าเว็บผิดค้าง **1 วัน** ไม่ใช่ 1 ชั่วโมง

### เอกสารและสคริปต์

- **ใหม่:** `docs/09-static-sites.md` — โฮสต์เว็บ Astro บนเครื่องเดียวกัน (`enable-php-00`),
  กับดัก `.user.ini` ที่ติด `chattr +i`, กฎ cache ของ `/_astro/`
- **ใหม่:** `scripts/inventory.sh` — เก็บค่าจริงทั้งเครื่องแบบอ่านอย่างเดียว เพื่อให้ตาราง
  ใน README มาจากของจริงไม่ใช่ความจำ
- **แก้:** `scripts/verify-config.sh` — เพิ่มเช็ค `cache_valid`, `max-age=0`, `Last-Modified`,
  catch-all, และไซต์ที่ยังไม่ได้ stamp · เช็คเดิมชื่อ "ไม่มี max-age=0" แต่ไปทดสอบ
  `fastcgi_cache WORDPRESS` แทน ซึ่งไม่เกี่ยวกัน
- **แก้:** README เป็นตาราง inventory ที่ทุกค่ามาจาก `inventory.sh` ไม่ใช่จากความจำ
- **แก้:** `docs/07` เพิ่มเคสจริง 4 ข้อ (ข้อ 10–13)
- **ใหม่:** `docs/00-new-server.md` — จุดเริ่มสำหรับเครื่องที่เพิ่งเช่ามา: ลำดับการอ่าน,
  ลำดับที่ห้ามสลับ (ล็อก panel ก่อนทุกอย่าง · ปิดรู 443 ก่อนเอาเว็บขึ้น · backup ก่อนรับงานจริง),
  และรายการสิ่งที่เครื่องอ้างอิงเองยังไม่ได้ทำ เพื่อไม่ให้เครื่องใหม่ลอกข้อบกพร่องไปด้วย
- **แก้:** เอกสารรุ่นก่อนหน้าวันนี้เคยระบุว่ามี VPS 2 เครื่อง — **ของจริงมีเครื่องเดียว**
  เปลี่ยนคำเรียกเป็น "เครื่องอ้างอิง" ซึ่งอ่านถูกทั้งตอนมีเครื่องเดียวและตอนเพิ่มเครื่องใหม่

### ยังค้าง

ดูรายการเต็มใน README — ที่เร่งที่สุด: cache config ยังเป็นฉบับโรงงาน, Redis ไม่มี `maxmemory`,
panel ยังพอร์ต 8888, และยังไม่มี backup

---

## 2026-08-22 — ตั้งค่าเริ่มต้น

> ⚠️ **entry นี้บันทึกสิ่งที่ "ตั้งใจทำ" ไม่ใช่สิ่งที่ลงเครื่องจริงทั้งหมด**
> การตรวจเมื่อ 2026-08-23 พบว่าอย่างน้อย **FastCGI cache config** และ **Redis `maxmemory`**
> ไม่ได้อยู่บนเครื่องอ้างอิง เก็บ entry ไว้ตามเดิมเพื่อไม่ให้ประวัติหาย แต่ให้ยึดผลจาก
> `scripts/verify-config.sh` เป็นความจริง ไม่ใช่บรรทัดด้านล่างนี้

### เปลี่ยนแปลงหลัก
- รื้อ CyberPanel ติดตั้ง **aaPanel 8.0.5** แทน (ดู ADR-002)
- ติดตั้ง LNMP: Nginx 1.30 / MariaDB 10.11 / PHP 8.3

### จูน
- sysctl + **BBR** + swap 4 GB
- PHP-FPM 8.3: `dynamic/150` → **`ondemand`/35** + idle_timeout 30s
- OPcache 1 GB, memory_limit 128M → **256M**
- MariaDB: buffer_pool **1 GB → 4 GB**, `query_cache_size` → **0**,
  `max_connections` 500 → **200**, `join_buffer_size` 2048 → **256 KB**
- Redis `maxmemory 1gb` + `allkeys-lru`
- FastCGI Cache: ปรับ `enable-php-83-wpfastcgi.conf`
  (เพิ่ม `cache_lock`, `background_update`, `use_stale`; ลบ `Cache-Control: max-age=0`)
- Cloudflare: เปิด **Tiered Cache**

### ผลที่วัดได้
| สถานะ | TTFB |
|---|---|
| Cache MISS | 35 ms |
| **Cache HIT** | **0.3 ms** |

### ยังค้าง
- ล็อก panel (พอร์ต / security entrance / password)
- Backup + ทดสอบ restore
- SSH hardening, Fail2ban
- SMTP ภายนอก
- Nginx Helper, ปิด wp-cron
- ถอน PHP 8.0/8.1/8.2
- Cloudflare WAF rules

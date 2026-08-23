# 06 — เพิ่มเว็บใหม่

Checklist สำหรับสร้างเว็บ WordPress ใหม่ให้ได้มาตรฐานเดียวกันทุกเว็บ

---

## 6.1 ทางที่แนะนำ: WP Toolkit (GUI ล้วน)

**aaPanel → WP Toolkit → Add WordPress**

| ช่อง | ค่า |
|---|---|
| Domain | โดเมนจริง |
| **PHP Version** | **8.3** ⚠️ ต้องเป็น 8.3 เสมอ |
| WordPress version | เลือกอะไรก็ได้ — **มันไม่อยู่กับที่** ดูด้านล่าง |
| Database | ✅ สร้างใหม่ (แยก user ต่อเว็บ) |
| FTP | ❌ ไม่ต้อง |

**ทีมงานไม่ต้องแตะ CLI เลย** — หลังติดตั้งเสร็จเข้า wp-admin ทำงานได้ตามปกติ

### ⚠️ เวอร์ชัน WordPress ที่เลือกตอนติดตั้ง ไม่ใช่เวอร์ชันที่จะได้

ตั้งแต่ **WordPress 5.6** เป็นต้นมา การติดตั้งใหม่จะ**เปิด auto-update ระดับ major
ให้เองโดยอัตโนมัติ** WP Toolkit ติดตั้งเวอร์ชันที่เลือกจริง แต่ WordPress อัปตัวเองขึ้น
ตัวล่าสุดภายในไม่กี่ชั่วโมง

หลักฐานจากเครื่องนี้ (2026-08-23): เลือก `6.5.10` ตอนติดตั้งทุกไซต์ แต่กลับมาดูเป็น **7.1**
ทั้งหมด ยกเว้นไซต์ที่เพิ่งสร้างล่าสุดซึ่งยังค้างที่ 6.5.10 เพราะ cron ของ WordPress
ยังไม่ถึงรอบ — พอถึงรอบก็ตามขึ้นไป

**เครื่องนี้เลือกปิด auto-update ทั้งหมด** (ดู [08 ADR-012](08-decisions.md))
`nightly-check.sh` จะไล่ปิดให้ไซต์ใหม่ทุกคืน แต่ถ้าอยากปิดทันทีไม่ต้องรอ:

```powershell
ssh root@SERVER_IP "bash /root/wpaa/scripts/set-wp-autoupdate.sh"
```

### 🔴 แล้วรัน `stamp-site.sh` ทันที — ข้ามไม่ได้

```bash
ssh root@SERVER_IP "/root/stamp-site.sh DOMAIN.TLD"
```

**สองอย่างที่มันทำ และทั้งสองอย่างจำเป็น:**

1. ใส่กฎ **www → non-www** ที่ระดับ nginx ให้ไซต์ใหม่ (ไม่ต้องรอ WordPress ทำ ซึ่งไซต์ที่ยัง
   ไม่ได้ลง WP ก็ยังไม่มีคนทำให้)
2. **`nginx -s reload`** — ข้อนี้สำคัญกว่าที่คิด

   ระหว่างที่ panel สร้าง vhost เสร็จแต่ nginx ยังไม่ reload โดเมนใหม่ยัง**ไม่มี server block
   ในคอนฟิกที่รันอยู่** ทุก request จึงตกไปที่ default server = ผู้ใช้เห็นเว็บของลูกค้าอีกราย
   และถ้าไซต์นั้นเปิด FastCGI cache ไว้ HTML ของเว็บผิดจะถูกเก็บใต้คีย์ของโดเมนใหม่
   ค้างข้ามวัน แม้ reload ทีหลังแล้วก็ยังผิดอยู่

   เกิดขึ้นจริงมาแล้วกับ 2 โดเมน — ดู [07-troubleshooting ข้อ 10–11](07-troubleshooting.md)

> ถ้ายังไม่เคยรัน [`scripts/harden-nginx.sh`](../scripts/harden-nginx.sh) บนเครื่องนั้น
> ให้ทำก่อน 1 ครั้ง ไม่งั้น `stamp-site.sh` จะหา `common-site.conf` ไม่เจอ

---

## 6.1b เว็บที่ไม่ใช่ WordPress

ถ้าเว็บที่จะขึ้นเป็น HTML ล้วน (เช่น build จาก Astro) **อย่าใช้ WP Toolkit** เพราะมันจะลง
WordPress ทับ — ให้ Add site แบบ PHP version = **Static** แล้วดู
[09-static-sites.md](09-static-sites.md)

---

## 6.2 ถ้ายังไม่มีโดเมน (สำหรับทดสอบ)

### ใช้ nip.io — ฟรี ไม่ต้องตั้ง DNS

```bash
curl -s ifconfig.me     # สมมติได้ 203.0.113.45
```

**ชื่อโดเมนที่ใช้ได้ทันที:**
```
203-0-113-45.nip.io
```
(เปลี่ยนจุดเป็นขีด)

**ข้อดี:** มี DNS จริง ออก Let's Encrypt SSL ได้ ทดสอบได้ครบเหมือนเว็บจริง

> **หมายเหตุ:** subdomain ของ hostname ที่ Hostinger ให้มา (`test.srvXXXX.hstgr.cloud`)
> มักใช้ไม่ได้ เพราะเราไม่มีสิทธิ์จัดการ DNS ของโดเมน `hstgr.cloud`
> ทดสอบก่อนด้วย `ping -c 2 test.srvXXXX.hstgr.cloud`

---

## 6.3 ทางสำรอง: WP-CLI

ใช้เมื่อ installer ของ panel มีปัญหา หรือเมื่อต้องการสร้างหลายเว็บด้วยสคริปต์

```bash
# ติดตั้ง WP-CLI (ครั้งเดียว)
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
sudo mv wp-cli.phar /usr/local/bin/wp
wp --info --allow-root
```

**สร้าง DB ผ่าน GUI ก่อน** (aaPanel → Databases → Create Database)
เพื่อให้ระบบบันทึกและ backup/restore ทำงานถูกต้อง

```bash
SITE=/www/wwwroot/DOMAIN.TLD
cd $SITE

sudo -u www -H wp core download

sudo -u www -H wp config create \
  --dbname='DBNAME' --dbuser='DBUSER' --dbpass='DBPASS' --dbhost=localhost

sudo -u www -H wp core install \
  --url='https://DOMAIN.TLD' \
  --title='SITE TITLE' \
  --admin_user='CHANGEME' \
  --admin_password='LONG_RANDOM_PASSWORD' \
  --admin_email='admin@example.com'
```

> ⚠️ **อย่าตั้ง `admin_user` เป็น `admin`** — เป็นชื่อแรกที่บอทเดา

**เปรียบเทียบเวลา:** GUI ~3–5 นาที/เว็บ vs WP-CLI ~30 วินาที/เว็บ
สำหรับ 100 เว็บ = ประหยัด 5–8 ชั่วโมง

---

## 6.4 ทางลัดสำหรับ 100 เว็บ: Clone

WP Toolkit มีฟีเจอร์ **Clone site** ที่สร้างเว็บใหม่โดยใช้ปลั๊กอิน ธีม ฐานข้อมูล และไฟล์
ของเว็บต้นแบบ

**วิธีที่เร็วที่สุด:**
1. ตั้งเว็บต้นแบบ 1 เว็บให้สมบูรณ์ (ธีม + ปลั๊กอิน + cache + SMTP + security)
2. Clone ออกไปเป็นเว็บที่ 2–100
3. แก้เฉพาะเนื้อหาและโดเมน

---

## 6.5 Checklist หลังสร้างเว็บ

### ความปลอดภัย
- [ ] **auto-update ถูกปิด** — `grep AUTOMATIC_UPDATER_DISABLED wp-config.php`
      (ถ้ายังไม่มี รัน `set-wp-autoupdate.sh` หรือรอ cron รอบกลางคืน)
- [ ] `wp-config.php` permission = **640**
  ```bash
  chmod 640 /www/wwwroot/DOMAIN.TLD/wp-config.php
  ```
- [ ] Database user **แยกจากเว็บอื่น**
- [ ] Admin username **ไม่ใช่ `admin`**
- [ ] เปิด `open_basedir` (aaPanel → Website → Settings)

### nginx
- [ ] **รัน `stamp-site.sh DOMAIN.TLD`** (§6.1) — ทำทันทีหลัง Add site
- [ ] ยืนยันว่าโดเมนเสิร์ฟเว็บตัวเอง ไม่ใช่ของคนอื่น:
  ```bash
  curl -sk --resolve DOMAIN.TLD:443:SERVER_IP https://DOMAIN.TLD/ | grep -o '<title>[^<]*</title>'
  ```

### SSL
- [ ] ออก Let's Encrypt ที่ origin
- [ ] Cloudflare SSL mode = **Full (Strict)** — 🔴 ตอนนี้ทั้งเครื่องยังเป็น Full ธรรมดา ซึ่งยอมรับ cert ที่ไม่ตรงชื่อโดเมน (ดู [04-cache §4.9](04-cache.md))
- [ ] เปิด Proxy (เมฆส้ม) เพื่อซ่อน IP จริง

### Cache
- [ ] เปิด FastCGI Cache (WP Toolkit → ปุ่ม ⚡)
- [ ] ยืนยัน include ใช้ `enable-php-83-wpfastcgi.conf`
- [ ] ติดตั้งปลั๊กอิน **Nginx Helper** + ตั้งค่า
- [ ] ตั้ง `WP_REDIS_PREFIX` **ไม่ซ้ำกับเว็บอื่น** ใน `wp-config.php`
- [ ] ติดตั้งปลั๊กอิน **Redis Object Cache** → Enable
- [ ] ทดสอบ: `curl -sI ... | grep -i x-cache` → ครั้งที่สองได้ **HIT**

### wp-config.php
```php
define('DISABLE_WP_CRON', true);
define('WP_POST_REVISIONS', 5);
define('EMPTY_TRASH_DAYS', 14);
define('AUTOSAVE_INTERVAL', 120);
define('WP_REDIS_PREFIX', 'siteNN_');
```

### อีเมล
- [ ] ติดตั้ง **WP Mail SMTP** → ชี้ไป Brevo/SES
- [ ] ทดสอบส่งเมลจริง

### Cron
- [ ] เพิ่ม system cron (กระจายเวลา ไม่ให้ยิงพร้อมกัน)

### Backup
- [ ] เพิ่มเว็บเข้า schedule backup
- [ ] **ทดสอบ restore อย่างน้อย 1 ครั้ง**

### Monitoring
- [ ] เพิ่มเข้า Uptime Kuma / UptimeRobot

---

## 6.6 การย้ายเว็บเก่ามา

1. **ลด TTL ของ DNS เหลือ 300 วินาที** ล่วงหน้า 24 ชั่วโมง
2. ย้ายทีละ 5–10 เว็บ **เริ่มจากเว็บสำคัญน้อยที่สุด**
3. ใช้ WP Toolkit → **Migrate Site** หรือ **Other Panel Migrate**
4. ทดสอบก่อนสลับ DNS
5. สลับ DNS → ตรวจ → ค่อยย้ายชุดถัดไป

---

**ถัดไป:** [07-troubleshooting.md](07-troubleshooting.md) · เว็บ static ดู [09-static-sites.md](09-static-sites.md)

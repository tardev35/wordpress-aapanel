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

### ⚠️ ทำไมเว็บถึงไม่ได้เวอร์ชันที่ตั้งใจ — มี 2 สาเหตุ คนละเรื่องกัน

**สาเหตุที่ 1: ช่องเลือกเวอร์ชันในฟอร์ม Add WordPress**

WP Toolkit เก็บแพ็กเกจไว้หลายเวอร์ชันที่ `/www/server/panel/data/wp_packages/`
ตอนตรวจ 2026-08-23 มี `6.5.10` `6.7.7` `6.8.8` `7.1` — **มันติดตั้งตามเวอร์ชันที่เลือกในฟอร์มตรง ๆ**

ยืนยันจาก timestamp ของไฟล์:

| ไซต์ | เวอร์ชัน | `version.php` ลงวันที่ | สร้างไซต์ |
|---|---|---|---|
| `ufamax789pro.com` | 6.5.10 | **2026-08-12** (วันที่แพ็กเกจ 6.5.10) | 08-23 14:36 |
| `22bunnybn.com` | 7.1 | 08-23 **15:52** | 08-23 16:00 |

ไซต์ 6.5.10 ได้ไฟล์จากแพ็กเกจเก่าที่ค้างอยู่ · ไซต์ 7.1 ได้ไฟล์ที่แตกออกมาไม่กี่นาที
ก่อนสร้างไซต์ **ทั้งคู่คือ "ติดตั้งมาแบบนั้น" ไม่ใช่ "อัปทีหลัง"**
ถ้าเป็นการอัปเดตทีหลัง `version.php` จะมีวันที่**หลัง**วันสร้างไซต์ ไม่ใช่ก่อน

**และ WP Toolkit ไม่ได้ทำตามที่เลือกเสมอไป** — เจ้าของยืนยันว่าเลือก `6.5` ทุกครั้ง
แต่จากไซต์ทั้งหมดบนเครื่อง มีแค่ **3 ไซต์** ที่ได้ไฟล์จาก `wordpress-6.5.10.zip` จริง
ที่เหลือทั้งหมด panel **ไปโหลดตัวล่าสุดมาสด ๆ ตอนติดตั้ง**

วิธีแยกสองกรณีออกจากกัน: ดูวันที่ของ `wp-settings.php` เทียบกับวันที่ข้างในไฟล์ zip

```bash
ssh root@SERVER_IP "bash /root/wpaa/scripts/check-wp-versions.sh"
```

```
bbc29pro.com          6.5.10   wordpress-6.5.10.zip        <- ทำตามที่เลือก
22bunnybn.com         7.1      โหลดสด (2026-08-23 15:52)   <- ไม่ทำตาม
```

🔴 **panel ไม่ได้บันทึกว่าตอนสร้างเลือกเวอร์ชันอะไร** (ตาราง `wordpress_onekey` มีแค่
prefix / user / pass / site_type) จึงพิสูจน์ย้อนหลังจากบันทึกไม่ได้ **ต้องดูจากไฟล์จริงเท่านั้น**

### 👉 กติกาที่ตามมา: ตรวจทุกครั้งหลังสร้างเว็บเป็นชุด

```bash
ssh root@SERVER_IP "bash /root/wpaa/scripts/check-wp-versions.sh"
```

ถ้าไซต์ไหนได้เวอร์ชันผิด **และยังไม่ได้ใส่เนื้อหาอะไร ให้ลบแล้วสร้างใหม่**
อย่าไปสลับไฟล์ core ทับเอง เพราะ WordPress เขียน `db_version` ลงฐานข้อมูลตอนติดตั้งไปแล้ว
การเอา core เก่าไปทับตัวใหม่จะทำให้ WP คิดว่าฐานข้อมูลใหม่กว่าโค้ด แล้วมีพฤติกรรมประหลาด
ตามมาแทนที่จะได้เวอร์ชันที่ต้องการสะอาด ๆ

**สาเหตุที่ 2: auto-update ของ WordPress เอง**

ตั้งแต่ WP 5.6 การติดตั้งใหม่จะเปิด auto-update ระดับ major ให้เอง ไซต์ที่ลงเวอร์ชันเก่าไว้
จึงไต่ขึ้นตัวล่าสุดเองภายในไม่กี่ชั่วโมง — เกิดขึ้นจริงกับ `mooyim99-hub.com` ซึ่งเป็น
`6.5.10` ตอนบ่ายสองโมงและกลายเป็น `7.1` ภายในครึ่งชั่วโมงถัดมา

ข้อนี้ปิดไปแล้วด้วย [08 ADR-012](08-decisions.md)

> 🔴 **การปิด auto-update ไม่ได้ย้อนเวอร์ชันกลับ** ไซต์ที่ขึ้น 7.1 ไปแล้วจะอยู่ที่ 7.1 ต่อไป
> มันแค่หยุดไม่ให้เปลี่ยนอีก การถอยเวอร์ชันเป็นงานคนละอย่างและมีความเสี่ยง (ฐานข้อมูลถูก
> อัปโครงสร้างไปแล้ว) — ถ้าจำเป็นจริงให้ทำจากการสร้างไซต์ใหม่ด้วยเวอร์ชันที่ต้องการ

**เครื่องนี้เลือกปิด auto-update ทั้งหมด** (ดู [08 ADR-012](08-decisions.md)) โดยมีสองชั้น:

| ชั้น | ปิดให้เมื่อไหร่ |
|---|---|
| `stamp-site.sh` (รันเองหลัง Add site) | **ทันที** |
| `nightly-check.sh` (cron 23:00) | ตาข่ายรับกรณีที่คนลืม stamp |

ปิดเองทันทีก็ได้ถ้าอยาก: `ssh root@SERVER_IP "bash /root/wpaa/scripts/set-wp-autoupdate.sh"`

### 🔴 แล้วรัน `stamp-site.sh` ทันที — ข้ามไม่ได้

```bash
ssh root@SERVER_IP "/root/stamp-site.sh DOMAIN.TLD"
```

**สามอย่างที่มันทำ และจำเป็นทั้งหมด:**

1. ใส่กฎ **www → non-www** ที่ระดับ nginx ให้ไซต์ใหม่ (ไม่ต้องรอ WordPress ทำ ซึ่งไซต์ที่ยัง
   ไม่ได้ลง WP ก็ยังไม่มีคนทำให้)
2. **ปิด auto-update ของ WordPress ให้ไซต์นั้นทันที** — ไม่ต้องรอ cron รอบ 5 ทุ่ม
   (ไซต์ที่สร้างตอนเช้าจะมี auto-update เปิดอยู่ทั้งวัน และ cron ของ WordPress เองอาจ
   ยิงอัป major ไปก่อนในช่วงนั้น — ดู [08 ADR-012](08-decisions.md))

3. **`nginx -s reload`** — ข้อนี้สำคัญกว่าที่คิด

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
- [ ] **ตั้ง A record ให้ชี้มาที่ IP ของเครื่องนี้ก่อน** แล้วค่อยกด Apply SSL
      ถ้า DNS ยังไม่ชี้มา การขอ cert จะไม่ผ่าน และ **cron ต่ออายุจะไม่มาช่วย**
      เพราะมันต่อได้เฉพาะใบที่ออกสำเร็จแล้ว ([07 ข้อ 14](07-troubleshooting.md))
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

# 05 — Operations

งานประจำและการดูแลระยะยาว

---

## 5.1 ตารางงานประจำ

| ความถี่ | งาน | ทำที่ไหน | เวลา |
|---|---|---|---|
| ทุกวัน | ดูอีเมลแจ้งเตือน backup ว่าสำเร็จ | อีเมล | 1 นาที |
| ทุกสัปดาห์ | อัปเดต WP core / plugin / theme | WP Toolkit | 20 นาที |
| ทุกสัปดาห์ | ดู resource usage | aaPanel Dashboard | 2 นาที |
| **ทุกเดือน** | **อัปเดต aaPanel** + **`verify-config.sh`** | GUI + CLI | 15 นาที |
| ทุกเดือน | `apt update && apt upgrade -y` | CLI | 5 นาที |
| **ทุกไตรมาส** | **ทดสอบ restore backup 1 เว็บ** | aaPanel | 30 นาที |
| ทุกปี | ตรวจราคาต่ออายุ VPS ก่อนครบกำหนด | Hostinger | 10 นาที |

รวมประมาณ **2–3 ชั่วโมง/เดือน**

---

## 5.2 ⚠️ หลังอัปเดต aaPanel ทุกครั้ง

**การอัปเดตอาจเขียนทับไฟล์ที่เราแก้เอง** (สังเกตว่าไฟล์ `enable-php-*` ตัวอื่นลงวันที่จากตัวติดตั้ง)

### สคริปต์ตรวจ

```bash
ssh root@SERVER_IP "bash -s" < scripts/verify-config.sh
```

> 📌 **รอบ 2026-08-23 สคริปต์นี้จับ drift ได้จริง** — รายงานว่าเครื่องอ้างอิง ไม่มี `fastcgi_cache_lock`,
> ไม่มี `use_stale`, ยังมี `Cache-Control: max-age=0` และ Redis ไม่มี `maxmemory`
> ทั้งที่เอกสารรุ่นแรกเขียนเหมือนทำครบแล้วทุกข้อ
>
> บทเรียน: **"เขียนไว้ในเอกสาร" กับ "ทำแล้วบนเครื่อง" เป็นคนละเรื่อง** และต่างกันได้ตั้งแต่วันแรก
> ไม่ใช่แค่ตอนอัปเดต panel เขียนทับ — ให้รันสคริปต์นี้ตอนรับเครื่องใหม่มาดูแลด้วย ไม่ใช่เฉพาะหลังอัปเดต

หรือตรวจด้วยมือ:

```bash
# FastCGI cache config
grep -c "fastcgi_cache_lock" /www/server/nginx/conf/enable-php-83-wpfastcgi.conf
# ได้ 0 = โดนเขียนทับ → กู้จาก .bak-*

# PHP-FPM
grep -E "^pm |^pm\.max_children" /www/server/php/83/etc/php-fpm.conf
# ต้องได้ ondemand / 35

# MySQL
mysql -uroot -p -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';"
# ต้องได้ 4294967296
```

### ไฟล์ที่ต้องเฝ้าระวัง

| ไฟล์ | ความเสี่ยง |
|---|---|
| `/www/server/nginx/conf/enable-php-83-wpfastcgi.conf` | **สูง** — WP Toolkit เขียนทับได้ |
| `/www/server/php/83/etc/php-fpm.conf` | ปานกลาง |
| `/www/server/php/83/etc/php.ini` | ปานกลาง |
| `/etc/my.cnf` | ต่ำ |
| `/etc/sysctl.d/99-tuning.conf` | ต่ำ (ไม่ใช่ของ aaPanel) |

---

## 5.3 Backup 🔴

> **สถานะปัจจุบัน: ยังไม่ได้ตั้ง — นี่คืองานที่เร่งด่วนที่สุด**
> เว็บ production ที่ไม่มี backup = ถ้าพัง ข้อมูลหายถาวร

### หลักการ 3-2-1

- **3** สำเนา
- **2** สื่อที่ต่างกัน
- **1** อยู่นอกสถานที่ (offsite)

### ชั้นที่ 1 — Hostinger VPS Backup (มีอยู่แล้ว)

- อัตโนมัติ **รายสัปดาห์** ฟรี เก็บสูงสุด 4 ชุด
- เก็บแยกจากเซิร์ฟเวอร์ ไม่หักโควตาดิสก์
- **ไม่สามารถเปลี่ยนเวลาได้**

### ⚠️ ข้อจำกัดของ Snapshot

- **เก็บได้ครั้งละ 1 ชุดเท่านั้น** — สร้างใหม่จะเขียนทับของเดิม
- **หมดอายุใน 1 วัน**
- **ถูกลบถ้าติดตั้ง OS ใหม่หรือ restore จาก backup**

**แปลว่า snapshot ใช้เป็นตาข่ายชั่วคราวระหว่างทำงานวันนั้นเท่านั้น ไม่ใช่ backup จริง**

### ชั้นที่ 2 — aaPanel → Offsite (ต้องตั้ง)

**aaPanel → Cron → Add task**

| ช่อง | ค่า |
|---|---|
| Type | Backup site / Backup database |
| Schedule | ทุกวัน 03:00 |
| Backup to | **S3-compatible** (Backblaze B2 / Cloudflare R2) |
| Keep | 7 ชุด |

**ค่าใช้จ่าย:** ~200 GB ≈ **฿600/ปี**
เทียบกับ Hostinger daily backup add-on ฿419/เดือน = ฿5,028/ปี → **ต่างกัน 8 เท่า**

### 🔴 ข้อที่ห้ามข้าม

> **หลังตั้ง backup เสร็จ ต้อง restore จริง 1 เว็บทันที**
> **backup ที่ไม่เคยกู้คืนสำเร็จ ยังไม่นับว่าเป็น backup**

---

## 5.4 SMTP ภายนอก 🔴

**อย่าให้ WordPress ส่งอีเมลจาก VPS โดยตรง** — IP ใหม่ไม่มีชื่อเสียง เมลจะเข้า spam
หรือถูกปฏิเสธ (ผู้ให้บริการอีเมลปฏิเสธเมลจาก IP ที่ forward/reverse DNS ไม่ตรงกัน)

### ติดตั้งทุกเว็บ

ปลั๊กอิน **WP Mail SMTP** → ชี้ไปบริการภายนอก

| บริการ | ฟรี | เหมาะกับ |
|---|---|---|
| Brevo | 300 เมล/วัน | ทีมเล็ก, ฟอร์มติดต่อ |
| Amazon SES | ~$0.10/1,000 | ปริมาณเยอะ ถูกที่สุด |
| Resend | 3,000/เดือน | ตั้งค่าง่ายที่สุด |

**ตั้ง SPF, DKIM, DMARC ใน DNS ของ Cloudflare ด้วย**

---

## 5.5 wp-cron

**ปิด wp-cron ในตัว** — ถ้าปล่อยไว้ 100 เว็บจะทริกเกอร์ cron ทุกครั้งที่มีคนเข้า

`wp-config.php`:
```php
define('DISABLE_WP_CRON', true);
define('WP_POST_REVISIONS', 5);
define('EMPTY_TRASH_DAYS', 14);
define('AUTOSAVE_INTERVAL', 120);
```

**ตั้ง system cron แทน — กระจายเวลาไม่ให้ยิงพร้อมกัน:**

```
# เว็บ 1-25   นาทีที่ 0,30
*/30 * * * *  cd /www/wwwroot/site01 && /www/server/php/83/bin/php wp-cron.php >/dev/null 2>&1

# เว็บ 26-50  นาทีที่ 5,35
5,35 * * * *  cd /www/wwwroot/site26 && /www/server/php/83/bin/php wp-cron.php >/dev/null 2>&1
```

---

## 5.6 Monitoring

### คำสั่งตรวจสถานะ

```bash
bash scripts/healthcheck.sh
```

### ⚠️ อย่าเชื่อตัวเลข % ใน aaPanel Dashboard

CyberPanel/aaPanel วัด CPU แบบ **snapshot ชั่วขณะ** ทำให้กระโดดไปมา (เคยเห็น 4% → 50% → 28%)
และมันนับ `%nice` (งาน background priority ต่ำ) รวมเข้าไปด้วย ทั้งที่งานพวกนั้นไม่ขวางทางเว็บเลย

| เครื่องมือ | เชื่อถือได้ |
|---|---|
| **`load average`** (`uptime`) | ✅ **ใช้ตัวนี้เป็นหลัก** |
| `mpstat 2 5` | ✅ |
| **Swap used** | ✅ ตัวเตือน RAM ไม่พอที่ดีที่สุด |
| aaPanel Dashboard % | ❌ |

### เกณฑ์สำหรับเครื่อง 4 cores

| Load average (5 นาที) | สถานะ |
|---|---|
| < 1.0 | ว่าง |
| 1.0 – 2.0 | ปกติ |
| 2.0 – 4.0 | เริ่มหนัก ควรดูสาเหตุ |
| > 4.0 | เกินกำลัง |

### แนะนำติดตั้งเพิ่ม

- **Uptime Kuma** (self-host ฟรี) หรือ UptimeRobot — แจ้งเตือนเข้า LINE/Discord เมื่อเว็บล่ม
- **Netdata** — กราฟย้อนหลังละเอียดวินาทีต่อวินาที (กิน RAM ~100–200 MB)

---

## 5.7 Runbook & Bus Factor

> **ถ้ามีคนเดียวที่รู้ว่าเซิร์ฟเวอร์ตั้งค่าอย่างไร แล้ววันหนึ่งคนนั้นลาออก — ระบบจะดูแลไม่ได้**

repo นี้คือ runbook นั้น **ต้องอัปเดตทุกครั้งที่เปลี่ยนแปลงระบบ**

---

**ถัดไป:** [06-new-site.md](06-new-site.md)

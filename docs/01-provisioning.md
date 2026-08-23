# 01 — Provisioning

ขั้นตอนตั้งแต่เช่า VPS จนได้ stack ครบพร้อมใช้งาน

---

## 1.1 เช่า VPS

**Hostinger → VPS → KVM 4**

| ตัวเลือก | ค่าที่เลือก | เหตุผล |
|---|---|---|
| ระยะสัญญา | **12 เดือน** | ไม่ล็อกยาว คงอิสระในการย้าย |
| Data Center | **Singapore** | latency จากไทย ~30–40 ms |
| OS Template | **aaPanel** (Ubuntu 22.04) | มี panel มาให้ ไม่ต้องติดตั้งเอง |
| Daily Backup add-on | **ไม่ซื้อ** | ฿419/เดือน = ฿5,028/ปี ใช้ B2 ~฿600/ปี แทน |

### ⚠️ ราคาต่ออายุ

ราคาโปรโมชันเป็นราคาปีแรกเท่านั้น **ต้องตั้งเตือนในปฏิทินก่อนวันต่ออายุ 1 เดือน**
และ **ปิด auto-renew** ไว้ก่อนเพื่อไม่ให้ถูกตัดเงินโดยไม่ทันตั้งตัว

---

## 1.2 เข้า aaPanel ครั้งแรก

```bash
ssh root@<SERVER_IP>
bt default
```

จะแสดง URL / username / password

> **ถ้า SSH ขึ้น `REMOTE HOST IDENTIFICATION HAS CHANGED`**
> เป็นเรื่องปกติหลังติดตั้ง OS ใหม่ (host key เปลี่ยน) แก้บนเครื่องตัวเอง:
> ```powershell
> ssh-keygen -R <SERVER_IP>
> ```

**เปิดพอร์ตใน hPanel → VPS → Security → Firewall:** `22`, `80`, `443`, `8888`

---

## 1.3 ล็อก panel ทันที ⚠️

**ทำก่อนอย่างอื่นทั้งหมด** — ดูรายละเอียดใน [02-hardening.md](02-hardening.md)

---

## 1.4 ติดตั้ง Stack

หน้าแรกของ aaPanel จะให้เลือกระหว่าง **Multi-WebServer Hosting** กับ **Single WebServer model**

### เลือก Single WebServer model

| | Single | Multi |
|---|---|---|
| Web server | Nginx อย่างเดียว | Nginx proxy + Apache/OLS backend |
| PHP หลายเวอร์ชัน | ✅ ได้ | ✅ ได้ (เหมือนกัน) |
| RAM | ต่ำ | สูงกว่า ~30–40% |
| `.htaccess` | ❌ | ✅ |
| FastCGI Cache | ✅ ตั้งง่าย | ⚠️ ซับซ้อนกว่ามาก |

**เหตุผล:** WordPress ไม่ต้องการ `.htaccess` เมื่อใช้ Nginx และ Multi จะทำให้ FastCGI Cache
(ซึ่งเป็นหัวใจของแผนนี้) ตั้งยากขึ้นมาก

> **ข้อเข้าใจผิดที่พบบ่อย:** ตัวเลือกนี้ **ไม่ได้** ตัดสินว่าใช้ PHP หลายเวอร์ชันได้หรือไม่
> ทั้งสองแบบติดตั้ง PHP เพิ่มจาก App Store แล้วเลือกต่อเว็บได้เหมือนกัน

### ค่าที่เลือก

| ส่วน | เลือก |
|---|---|
| Web Server | Nginx 1.30 |
| Database | MariaDB 10.11 (LTS ถึงปี 2028) |
| PHP | 8.3 เป็นตัวหลักของทุกเว็บ |
| phpMyAdmin | 5.2 |
| **Pure-Ftpd** | ❌ **ไม่ติดตั้ง** |
| DNS-Server | ❌ ใช้ Cloudflare |
| Mail-Server | ❌ ใช้ SMTP ภายนอก |
| Method | **Quick install** (Compiled ช้ากว่ามากและไม่คุ้ม) |

**ทำไมไม่ติดตั้ง FTP:** FTP ส่งรหัสผ่านแบบไม่เข้ารหัสและเป็นเป้าหมายยอดนิยมของบอท
ใช้ **SFTP** (ผ่าน SSH port 22) หรือ **File Manager ใน aaPanel** แทน
ถ้าทีมคุ้นกับ FileZilla ก็ยังใช้ได้ แค่เปลี่ยนโปรโตคอลเป็น SFTP

ใช้เวลาติดตั้ง 10–20 นาที

---

## 1.5 ติดตั้ง PHP 8.3 (ตัวหลัก)

**App Store → PHP-8.3 → Install**

> ⚠️ **ติดตั้งทีละเวอร์ชัน** อย่ากดหลายตัวพร้อมกัน — แต่ละตัวกิน ~500 MB disk และ CPU สูงตอน compile

### เวอร์ชันที่ควรมี

| เวอร์ชัน | สถานะ | ใช้ไหม | มีบนเครื่อง A จริงไหม |
|---|---|---|---|
| 8.3 | Active support | ✅ **หลัก — ทุกเว็บ** | ✅ มี และใช้อยู่ |
| 8.4 | ล่าสุด | ⚠️ สำรอง (ปลั๊กอินบางตัวยังตามไม่ทัน) | ❌ **ไม่ได้ติดตั้ง** |
| 8.2 | Security support | ❌ ควรถอน | ⚠️ ยังอยู่ ไม่มีเว็บไหนใช้ |
| 8.1 / 8.0 | **หมดอายุแล้ว** | ❌ ควรถอน — ไม่ได้รับ security patch | ⚠️ ยังอยู่ ไม่มีเว็บไหนใช้ |

> เอกสารรุ่นแรกเขียนว่าติดตั้ง 8.4 ไว้เป็นตัวสำรอง — **ของจริงไม่มี**
> และงบ RAM ใน README ก็ไม่ต้องกันส่วนของ 8.4 อีกต่อไป
> เช็กรายการจริงได้ด้วย `ls /www/server/php/` หรือ `scripts/inventory.sh`

**ทำไมเลือก 8.3 ไม่ใช่ 8.4:** ปลั๊กอิน WordPress รองรับ 8.3 กว้างที่สุดในตอนนี้
และ 8.3 ยังอยู่ในช่วง active support ยาวกว่า

---

## 1.6 Extension ที่ต้องติดตั้งเพิ่ม

**App Store → PHP-8.3 → Setting → Install extensions**

- ✅ **redis** — จำเป็นสำหรับ object cache
- ✅ **imagick** — จัดการรูปดีกว่า GD
- ✅ ตรวจว่า **opcache** ติดตั้งแล้ว

```bash
/www/server/php/83/bin/php -m | grep -iE "redis|opcache|imagick"
```

---

## 1.7 ติดตั้ง Redis

**App Store → Redis → Install**

```bash
redis-cli ping   # ต้องได้ PONG
```

> **หมายเหตุ:** `systemctl is-active redis` อาจแสดง `activating` ค้างไว้
> เพราะ service file ตั้ง `Type=` ไม่ตรงกับโหมด daemon ของ Redis
> **ให้เชื่อ `redis-cli ping` แทน** — ถ้าได้ `PONG` คือทำงานปกติ

---

## 1.8 ตรวจสอบว่าติดตั้งครบ

```bash
cat /etc/os-release | head -2
ls /www/server/php/
redis-cli ping
curl -sI http://127.0.0.1 | head -3
mysql -uroot -p -e "SELECT VERSION();"
free -h
df -h /
```

**หมายเหตุเรื่อง MySQL:** aaPanel ตั้งรหัสผ่าน root ไว้ (ไม่ใช่ passwordless)
หารหัสได้จาก **aaPanel → Databases → root password**

---

**ถัดไป:** [02-hardening.md](02-hardening.md)

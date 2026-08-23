# 00 — เพิ่งเช่า VPS ใหม่? เริ่มที่นี่

หน้านี้คือลำดับเดียวที่ต้องจำ ที่เหลือคือกดตามลิงก์

**เป้าหมาย:** ได้เครื่องที่ตั้งค่าเหมือน "เครื่องอ้างอิง" ใน [README](../README.md)
**เวลารวม:** ~2–3 ชั่วโมง โดยส่วนใหญ่เป็นเวลารอ installer

> ⚠️ **อย่าลอกเครื่องอ้างอิงแบบดิบ ๆ** — ตัวมันเองยังมีของค้างอยู่หลายอย่าง
> (cache config ยังเป็นฉบับโรงงาน, Redis ไม่มี `maxmemory`, panel ยังพอร์ต 8888)
> เครื่องใหม่มีข้อได้เปรียบตรงที่ยังไม่มีเว็บ production อยู่ **ทำให้ครบตั้งแต่แรกง่ายกว่าตามแก้ทีหลังมาก**
> ดูหัวข้อ [0.9](#09-สิ่งที่เครื่องอ้างอิงยังไม่ได้ทำ--เครื่องใหม่ควรทำให้ครบ)

---

## 0.1 ลำดับการอ่าน

| # | ทำอะไร | อ่าน | เวลา |
|---|---|---|---|
| 1 | เช่า VPS + เข้า aaPanel ครั้งแรก | [01 §1.1–1.2](01-provisioning.md) | 15 นาที |
| 2 | 🔴 **ล็อก panel ทันที** ก่อนทำอย่างอื่น | [02 §2.1](02-hardening.md) | 10 นาที |
| 3 | ติดตั้ง stack (Nginx/MariaDB/PHP 8.3/Redis) | [01 §1.4–1.7](01-provisioning.md) | 30 นาที |
| 4 | Swap + sysctl + BBR | [02 §2.2](02-hardening.md) · [03 §3.1](03-tuning.md) | 10 นาที |
| 5 | จูน PHP-FPM / OPcache / MariaDB / Redis | [03](03-tuning.md) ทั้งหน้า | 40 นาที |
| 6 | 🔴 **ปิดรู default_server 443** ก่อนเอาเว็บขึ้น | [02 §2.8](02-hardening.md) | 5 นาที |
| 7 | FastCGI Cache (`apply-cache-config.sh`) | [04](04-cache.md) | 20 นาที |
| 8 | SSH hardening + Fail2ban | [02 §2.3–2.4](02-hardening.md) | 15 นาที |
| 9 | 🔴 **Backup + ทดสอบ restore** | [05 §5.3](05-operations.md) | 40 นาที |
| 10 | เว็บแรก | [06](06-new-site.md) (WordPress) · [09](09-static-sites.md) (static) | 10 นาที |

**ลำดับที่ห้ามสลับ:**

- **ข้อ 2 ก่อนทุกอย่าง** — บอทสแกนเจอเครื่องใหม่ภายในไม่กี่ชั่วโมง
- **ข้อ 6 ก่อนข้อ 10** — ถ้าเอาเว็บขึ้นก่อนปิดรู โดเมนที่ชี้มาแล้วแต่ยังไม่ Add site
  จะไปหยิบเว็บอื่นมาแสดง แล้วขยะจะเข้าไปติดใน cache ต่อ (ดู [04 §4.5](04-cache.md))
- **ข้อ 9 ก่อนรับงานลูกค้าจริง** — backup ที่ไม่เคย restore สำเร็จ ยังไม่นับว่าเป็น backup

---

## 0.2 อัป repo นี้ขึ้นเครื่องก่อน

`harden-nginx.sh` กับ `apply-cache-config.sh` เปิดไฟล์ใน `configs/` จึงต้องอัป**ทั้งสองโฟลเดอร์**
ไม่ใช่ไฟล์เดียว

```powershell
scp -r configs scripts root@SERVER_IP:/tmp/wpaa/
```

> ⚠️ **นี่คือการ sync ไม่ใช่ทำครั้งเดียวจบ** ของใน `/tmp/wpaa/` คือสำเนาแช่แข็งของตอนที่อัป
> ถ้าดึง repo เวอร์ชันใหม่มาแล้วสั่งรันเลย จะเจอ `No such file or directory` สำหรับสคริปต์ที่
> เพิ่งเพิ่มเข้ามา — **รัน `scp -r` ซ้ำทุกครั้งที่ repo เปลี่ยน**
>
> สคริปต์ส่วนใหญ่เลี่ยงปัญหานี้ได้ด้วยการส่งผ่าน stdin แทน ซึ่งได้เวอร์ชันล่าสุดเสมอ:
> ```powershell
> ssh root@SERVER_IP "bash -s" < scripts/set-redis-limit.sh
> ```
> ดูตารางว่าตัวไหนใช้วิธีไหนได้ใน [README](../README.md#สคริปต์ใน-repo)

---

## 0.3 เก็บสภาพก่อนแตะอะไร

```powershell
ssh root@SERVER_IP "bash -s" < scripts/inventory.sh
```

เก็บผลไว้เทียบตอนจบ และเทียบกับตารางเครื่องอ้างอิงใน README

---

## 0.4 คัดลอก config ที่จูนแล้ว

ไฟล์ใน [`configs/`](../configs/) คือค่าที่ควรได้ **แก้ผ่าน aaPanel GUI ไม่ใช่ `sed -i`**
(เคยทำ php-fpm พังจนเว็บล่ม — [07 ข้อ 3](07-troubleshooting.md))

| ไฟล์ในrepo | เอาไปไว้ไหน | แก้ผ่าน |
|---|---|---|
| [`php-fpm-83.conf`](../configs/php-fpm-83.conf) | `/www/server/php/83/etc/php-fpm.conf` | App Store → PHP-8.3 → Configuration |
| [`php-ini-83.ini`](../configs/php-ini-83.ini) | `/www/server/php/83/etc/php.ini` | App Store → PHP-8.3 → php.ini |
| [`my.cnf-additions.ini`](../configs/my.cnf-additions.ini) | `[mysqld]` ใน `/etc/my.cnf` | Databases → Performance tuning + แก้ไฟล์ |
| [`99-tuning.conf`](../configs/99-tuning.conf) | `/etc/sysctl.d/99-tuning.conf` | CLI (`sysctl --system`) |
| [`enable-php-83-wpfastcgi.conf`](../configs/enable-php-83-wpfastcgi.conf) | `/www/server/nginx/conf/` | App Store → Nginx → Config file |

**สำรองก่อนทับเสมอ:** `cp <file> <file>.bak-$(date +%F)`

---

## 0.5 nginx ระดับเครื่อง — ทำครั้งเดียว

```powershell
ssh root@SERVER_IP "bash /tmp/wpaa/scripts/harden-nginx.sh"
ssh root@SERVER_IP "/etc/init.d/nginx reload"
```

ได้อะไรมา: catch-all พอร์ต 443, กฎ www→non-www, และ `/root/stamp-site.sh`
รายละเอียดใน [02 §2.8](02-hardening.md)

---

## 0.6 ทุกครั้งที่เพิ่มเว็บหลังจากนี้

```powershell
ssh root@SERVER_IP "/root/stamp-site.sh DOMAIN.TLD"
```

ไม่ใช่ทางเลือก — ตัว `reload` ในสคริปต์คือสิ่งที่ปิดช่วงหน้าต่างที่โดเมนใหม่ไปหยิบเว็บคนอื่น
([06 §6.1](06-new-site.md))

---

## 0.7 ยืนยันว่าได้เหมือนเครื่องอ้างอิงแล้ว

```powershell
ssh root@SERVER_IP "bash -s" < scripts/verify-config.sh
```

**ต้องขึ้น `ผ่านทั้งหมด`** ถ้ายังมีข้อไหนแดง แปลว่าข้อนั้นยังไม่ได้ทำจริง ไม่ใช่สคริปต์ผิด

แล้วทดสอบรูที่ปิดไป — **ต้องได้ 404**:

```powershell
curl -sk --resolve nosuch.invalid:443:SERVER_IP https://nosuch.invalid/ -o /dev/null -w '%{http_code}'
```

และไล่ทุกโดเมนบนเครื่องว่าเสิร์ฟเว็บของตัวเองจริง:

```bash
for h in $(ls /www/wwwroot | grep '\.'); do
  printf '%-28s ' "$h"
  curl -sk --resolve $h:443:127.0.0.1 https://$h/ | grep -o '<title>[^<]*</title>' | head -1
done
```

---

## 0.8 อัปเดตเอกสารด้วย

repo นี้ยึดหลัก **บรรยายสภาพจริง** เครื่องใหม่ = ต้องมีแถวของตัวเองใน README

```powershell
ssh root@SERVER_IP "bash -s" < scripts/inventory.sh
```

เอาผลไปเติมตาราง **อย่าคัดลอกค่าจากเครื่องอ้างอิงมาเติมแทน** — ถ้าเดา เอกสารก็จะกลับไปเป็น
สิ่งที่เคยเป็นก่อน 2026-08-23 คือคำอธิบายของเครื่องที่ไม่มีอยู่จริง

---

## 0.9 สิ่งที่เครื่องอ้างอิงยังไม่ได้ทำ — เครื่องใหม่ควรทำให้ครบ

ทำตอนเครื่องยังว่างใช้เวลาไม่กี่นาที ตามแก้ตอนมีเว็บลูกค้า 12 เว็บแล้วเป็นอีกเรื่อง

- [ ] **`enable-php-83-wpfastcgi.conf`** ใช้ฉบับใน `configs/` ตั้งแต่แรก อย่าปล่อยฉบับโรงงานไว้
      (ฉบับโรงงานตั้ง `fastcgi_cache_valid 200 1d` = หน้าที่ cache ผิดค้าง 1 วัน)
- [ ] **Redis `maxmemory 1gb` + `allkeys-lru`** (`scripts/set-redis-limit.sh`) — ไม่ตั้ง = Redis โตไปแย่ง RAM กับ MariaDB · ตั้งแต่ `maxmemory` อย่างเดียวแย่กว่าไม่ตั้ง ([03 §3.5](03-tuning.md))
- [ ] **เปลี่ยนพอร์ต panel + security entrance + password** ([02 §2.1](02-hardening.md))
- [ ] **ปิด SSH password login** หลังยืนยันว่า key ใช้ได้ ([02 §2.3](02-hardening.md))
- [ ] **Cloudflare SSL = Full (Strict)** ไม่ใช่ Full ธรรมดา — Full ธรรมดาไม่ตรวจว่า cert
      ตรงชื่อโดเมน จึงกลบอาการของรู default_server ไว้ ([04 §4.9](04-cache.md))
- [ ] **ติดตั้งเฉพาะ PHP 8.3** อย่าลง 8.0/8.1/8.2 ที่หมดอายุแล้วมาให้ต้องถอนทีหลัง
- [ ] **Backup + restore จริง 1 รอบ** ([05 §5.3](05-operations.md))

---

**ถัดไป:** [01-provisioning.md](01-provisioning.md)

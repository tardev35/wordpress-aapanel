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

> **เครื่องที่ไม่มี OS template ของ aaPanel ให้เลือก** (Contabo, DigitalOcean, Vultr
> หรือ Hostinger ที่เลือก image Ubuntu เปล่า) — ทำ [10-bare-linux](10-bare-linux.md)
> ให้จบก่อน แล้วค่อยเข้าตารางนี้ที่ข้อ 3

| # | ทำอะไร | อ่าน | เวลา |
|---|---|---|---|
| 1 | เช่า VPS + เข้า aaPanel ครั้งแรก | [01 §1.1–1.2](01-provisioning.md) · เครื่องเปล่า: [10](10-bare-linux.md) | 15 นาที |
| 2 | 🔴 **ล็อก panel ทันที** ก่อนทำอย่างอื่น | [02 §2.1](02-hardening.md) | 10 นาที |
| 3 | ติดตั้ง stack (Nginx/MariaDB/PHP 8.3/Redis) | [01 §1.4–1.7](01-provisioning.md) | 30 นาที |
| 4 | Swap + sysctl + BBR | [02 §2.2](02-hardening.md) · [03 §3.1](03-tuning.md) | 10 นาที |
| 5 | จูน PHP-FPM / OPcache / MariaDB / Redis | [03](03-tuning.md) ทั้งหน้า | 40 นาที |
| 6 | 🔴 **ปิดรู default_server 443** ก่อนเอาเว็บขึ้น | [02 §2.8](02-hardening.md) | 5 นาที |
| 7 | FastCGI Cache (`apply-cache-config.sh`) | [04](04-cache.md) | 20 นาที |
| 8 | SSH hardening + Fail2ban | [02 §2.3–2.4](02-hardening.md) | 15 นาที |
| 9 | 🔴 **Backup + ทดสอบ restore** | [05 §5.3](05-operations.md) | 40 นาที |
| 9b | ตั้ง cron ตรวจ+ซ่อมเองทุกคืน (**ตั้งในหน้า Cron ของ panel**) | [05 §5.1b](05-operations.md) | 3 นาที |
| 9c | 🔴 **ให้เครื่อง stamp ไซต์ใหม่เอง** (`install-site-watcher.sh`) | [05 §5.1c](05-operations.md) · [§0.6](#06--ให้เครื่อง-stamp-ไซต์ใหม่เอง--ข้อที่ห้ามข้ามที่สุดในหน้านี้) | 2 นาที |
| 9d | ให้ปุ่ม Purge ในหน้า WP ใช้ได้ (`fix-cache-purge.sh`) | [04 §4.7](04-cache.md) | 2 นาที |
| 10 | เว็บแรก | [06](06-new-site.md) (WordPress) · [09](09-static-sites.md) (static) | 10 นาที |

**ลำดับที่ห้ามสลับ:**

- **ข้อ 2 ก่อนทุกอย่าง** — บอทสแกนเจอเครื่องใหม่ภายในไม่กี่ชั่วโมง
- **ข้อ 6 ก่อนข้อ 10** — ถ้าเอาเว็บขึ้นก่อนปิดรู โดเมนที่ชี้มาแล้วแต่ยังไม่ Add site
  จะไปหยิบเว็บอื่นมาแสดง แล้วขยะจะเข้าไปติดใน cache ต่อ (ดู [04 §4.5](04-cache.md))
- **ข้อ 9 ก่อนรับงานลูกค้าจริง** — backup ที่ไม่เคย restore สำเร็จ ยังไม่นับว่าเป็น backup
- **ข้อ 9c ก่อนข้อ 10** — เว็บแรกที่ขึ้นก่อนตั้ง watcher จะเปิด auto-update ค้างไว้ และ
  WordPress อัปตัวเองขึ้นตัวล่าสุดภายในชั่วโมงเดียว (วัดจากเครื่องจริง 2 เครื่อง ดู
  [§0.6](#06--ให้เครื่อง-stamp-ไซต์ใหม่เอง--ข้อที่ห้ามข้ามที่สุดในหน้านี้)) —
  ปิดทีหลังไม่ได้ย้อนเวอร์ชันกลับ

---

## 0.1b สรุปคำสั่งทั้งหมด (ก๊อปวางได้)

ทำหลังจากติดตั้ง stack + จูนตามข้อ 1–5 ในตารางแล้ว ส่วนนี้คือของที่ repo นี้เตรียมไว้ให้

```powershell
cd C:\wordpress-aapanel

# อัปไฟล์ขึ้นเครื่อง
scp -r configs scripts root@NEW_IP:/tmp/wpaa/

# 1) ปิดรู default_server 443 + กฎ www  (ต้องทำก่อนเอาเว็บขึ้น)
ssh root@NEW_IP "bash /tmp/wpaa/scripts/harden-nginx.sh"
ssh root@NEW_IP "/etc/init.d/nginx reload"

# 2) FastCGI cache ฉบับที่จูนแล้ว
ssh root@NEW_IP "bash /tmp/wpaa/scripts/apply-cache-config.sh"
ssh root@NEW_IP "/etc/init.d/nginx reload"

# 3) จำกัด RAM ของ Redis พร้อม policy
ssh root@NEW_IP "bash /tmp/wpaa/scripts/set-redis-limit.sh"

# 4) วางไฟล์ถาวรไว้ให้ cron ใช้ (ยังไม่แตะ crontab)
ssh root@NEW_IP "bash /tmp/wpaa/scripts/install-autoheal.sh --no-cron"

# 5) ให้เครื่อง stamp ไซต์ใหม่เอง  <-- ห้ามข้าม ดู 0.6
ssh root@NEW_IP "bash /tmp/wpaa/scripts/install-site-watcher.sh"

# 5b) ให้ปุ่ม Purge ในหน้า WP ล้างแคชได้จริง (ดู 04 §4.7)
ssh root@NEW_IP "bash /tmp/wpaa/scripts/fix-cache-purge.sh"

# 5c) แก้ IP ที่หัว panel ให้ตรงเครื่อง - image ของ Hostinger ติดค่าของเครื่องอื่นมา
#     ถ้าปล่อยไว้ คนจะก๊อป IP ผิดไปรันคำสั่งผิดเครื่อง (ดู 07 ข้อ 18)
ssh root@NEW_IP "F=/www/server/panel/data/iplist.txt; mkdir -p /root/wpaa/backups; cp -p \$F /root/wpaa/backups/ 2>/dev/null; printf '%s' \$(ip -4 addr show scope global | grep -oP 'inet \K[0-9.]+' | head -1) > \$F; cat \$F"

# 6) ยืนยัน - ต้องขึ้น "ผ่านทั้งหมด"
ssh root@NEW_IP "bash /tmp/wpaa/scripts/verify-config.sh"

# 7) ทดสอบว่ารูปิดจริง - ต้องได้ 404
curl -sk --resolve nosuch.invalid:443:NEW_IP https://nosuch.invalid/ -o /dev/null -w "%{http_code}"
```

**ข้อ 4 ยังไม่จบ** — ไปตั้งงานใน **aaPanel → Cron Job → Add Task** ต่อ
(Daily · **16:00** เพราะเครื่องเป็น UTC · Script content = `/root/wpaa/scripts/nightly-check.sh`)
รายละเอียดและกับดักเรื่องเวลาอยู่ที่ [05 §5.1b](05-operations.md)

**หลังข้อ 5 ทีมงานกด Add site ในแผงได้เลย ไม่ต้องสั่งอะไรต่อ** — ดูเหตุผลใน 0.6

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
> เลี่ยงได้ด้วยการส่งสคริปต์ผ่าน stdin แทน ซึ่งได้เวอร์ชันล่าสุดเสมอ **แต่บน PowerShell
> ต้องผ่าน `cmd` เท่านั้น** เพราะ PowerShell ไม่รองรับ `<` และถ้าใช้ `Get-Content | ssh`
> มันจะใส่ BOM ทำให้บรรทัด shebang พัง:
> ```powershell
> cmd /c "ssh root@SERVER_IP ""bash -s"" < scripts\set-redis-limit.sh"
> ```
> รายละเอียดและตารางว่าตัวไหนใช้วิธีไหนได้อยู่ใน [README](../README.md)

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

## 0.6 🔴 ให้เครื่อง stamp ไซต์ใหม่เอง — ข้อที่ห้ามข้ามที่สุดในหน้านี้

```powershell
ssh root@SERVER_IP "bash /tmp/wpaa/scripts/install-site-watcher.sh"
```

ได้ systemd 2 ตัวที่เรียก [`watch-new-sites.sh`](../scripts/watch-new-sites.sh) ให้เอง
(`wpaa-newsite.path` ตื่นตอน panel เขียน vhost · `wpaa-newsite.timer` ยิงทุก 1 นาที)
รายละเอียดใน [05 §5.1c](05-operations.md)

### ทำไมข้อนี้ถึงสำคัญกว่าที่หน้าตามันดู

เอกสารรุ่นก่อนเขียนไว้ว่า "ทุกครั้งที่เพิ่มเว็บ ให้รัน `stamp-site.sh DOMAIN`"
**คำสั่งนั้นไม่เคยถูกรันจริง** เพราะทีมที่กด Add site ไม่ได้ใช้ cmd/ssh ผลที่ตามมา
วัดได้จากเครื่องจริง 2 เครื่องในวันเดียวกัน:

| เครื่อง | สภาพตอนเข้าไปดู |
|---|---|
| `187.52.125.203` | ลง `6.7.7` ตอน 00:04 · WordPress อัปตัวเองเป็น `7.1` ตอน **01:08** |
| `187.52.122.249` | เพิ่มเว็บ 26 ตัวตอนเช้า · **ทั้ง 26 ตัวขึ้น 7.1 หมด** ก่อน cron รอบ 23:00 จะมาถึง · `enable-php-83-wpfastcgi.conf` โดน WP Toolkit เขียนทับเป็นฉบับโรงงานไปด้วย |

ทางแก้ที่จบด้วยประโยค "แล้วให้รันคำสั่งนี้ด้วย" ไม่ใช่ทางแก้ — มันย้ายงานไปวางบนคนที่
ทำไม่ได้ แล้วรอให้หลุดอีกรอบ **ติดตั้ง watcher คือสิ่งที่ทำให้ประโยคนั้นไม่จำเป็น**

### `stamp-site.sh` ยังเรียกเองได้อยู่

```powershell
ssh root@SERVER_IP "/root/stamp-site.sh DOMAIN.TLD"
```

เก็บไว้ใช้ตอนไล่แก้ปัญหาเฉพาะหน้า และเป็นตัวงานที่ watcher เรียกใช้ —
แต่ไม่ใช่ขั้นตอนที่คนต้องทำประจำอีกแล้ว ([06 §6.1](06-new-site.md))

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

> อัปเดต 2026-08-23: FastCGI cache config (`apply-cache-config.sh`) และ Redis
> (`set-redis-limit.sh`) **ทำเสร็จบนเครื่องอ้างอิงแล้ว** — เครื่องใหม่ก็ยังต้องทำเองอยู่ดี
> เพราะเป็นค่าที่ผูกกับเครื่อง ไม่ได้ติดมากับ repo

- [ ] **เปลี่ยนพอร์ต panel + security entrance + password** ([02 §2.1](02-hardening.md))
- [ ] **ปิด SSH password login** หลังยืนยันว่า key ใช้ได้ ([02 §2.3](02-hardening.md))
- [ ] **Cloudflare SSL = Full (Strict)** ไม่ใช่ Full ธรรมดา — Full ธรรมดาไม่ตรวจว่า cert
      ตรงชื่อโดเมน จึงกลบอาการของรู default_server ไว้ ([04 §4.9](04-cache.md))
- [ ] **ติดตั้งเฉพาะ PHP 8.3** อย่าลง 8.0/8.1/8.2 ที่หมดอายุแล้วมาให้ต้องถอนทีหลัง
- [ ] **Backup + restore จริง 1 รอบ** ([05 §5.3](05-operations.md))

---

**ถัดไป:** [01-provisioning.md](01-provisioning.md)

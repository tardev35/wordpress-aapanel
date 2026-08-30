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

### 🔀 ก่อนอื่น — เครื่องนี้เป็นแบบไหน

| image ที่เลือกตอนเช่า | เริ่มตรงไหน |
|---|---|
| **template ชื่อ `aaPanel`** (Hostinger มีให้) | เริ่ม **ข้อ 1** ในตารางข้างล่างเลย |
| **Ubuntu 22.04 เปล่า** หรือเจ้าอื่นที่ไม่มี template | ทำ [10-bare-linux](10-bare-linux.md) จนจบก่อน → แล้วเข้าตารางนี้ที่ **ข้อ 3** |

**สองทางนี้ต่างกันแค่ข้อ 1–2 เท่านั้น** — พอ panel ขึ้นและถูกล็อกแล้ว ตั้งแต่ข้อ 3
เป็นต้นไปเหมือนกันทุกบรรทัด ใช้สคริปต์ชุดเดียวกัน ได้เครื่องที่หน้าตาเหมือนกัน

| | เครื่องที่มี template | เครื่องเปล่า |
|---|---|---|
| ข้อ 1 (เข้า panel ครั้งแรก) | `bt default` ได้เลย | [10 §10.2–10.6](10-bare-linux.md) — `apt upgrade`, UTC, swap, SSH key, ติดตั้ง panel |
| ข้อ 2 (ล็อก panel) | เหมือนกัน | เหมือนกัน |
| ข้อ 3 เป็นต้นไป | **เหมือนกันทั้งหมด** | **เหมือนกันทั้งหมด** |

> เครื่องเปล่าใช้เวลามากกว่าราว 20–30 นาที (รอ `apt upgrade` กับ installer ของ panel)
> แลกกับการเลือกผู้ให้บริการได้อิสระ และได้ตั้ง timezone/swap/sysctl ให้ถูกตั้งแต่ต้น
> ก่อนที่ panel จะเข้ามาเกี่ยวข้อง

| # | ทำอะไร | อ่าน | เวลา |
|---|---|---|---|
| 1 | เข้า aaPanel ครั้งแรก · เปิดพอร์ตที่ firewall ของผู้ให้บริการ | [01 §1.1–1.2](01-provisioning.md) | 15 นาที |
| 2 | 🔴 **ล็อก panel ทันที** — พอร์ต + entrance + รหัสผ่าน | [02 §2.1](02-hardening.md) | 10 นาที |
| 3 | ติดตั้ง stack (Nginx / MariaDB / PHP 8.3 / Redis) | [01 §1.4–1.7](01-provisioning.md) | 30 นาที |
| 4 | Swap + sysctl + BBR | [02 §2.2](02-hardening.md) · [03 §3.1](03-tuning.md) | 10 นาที |
| 5 | จูน PHP-FPM + OPcache | [03 §3.2–3.3](03-tuning.md) | 25 นาที |
| 6 | SSH key + ปิด password + Fail2ban | [02 §2.3–2.4](02-hardening.md) | 15 นาที |
| **7** | 🔴 **รันชุดสคริปต์ทั้งหมด** — 10 คำสั่งใน [§0.1b](#01b-สรุปคำสั่งทั้งหมด-ก๊อปวางได้) | ดูตารางถัดไป | **10 นาที** |
| 8 | ตั้ง cron รอบกลางคืน (**ในหน้า Cron ของ panel**) | [05 §5.1b](05-operations.md) | 3 นาที |
| 9 | 🔴 **Backup + ทดสอบ restore ให้สำเร็จ 1 ครั้ง** | [05 §5.3](05-operations.md) | 40 นาที |
| 10 | เว็บแรก | [06](06-new-site.md) (WordPress) · [09](09-static-sites.md) (static) | 10 นาที |

### ข้อ 7 ครอบอะไรบ้าง

ทั้งหมดเป็นของที่ repo นี้เตรียมไว้ให้ รันเรียงกันรวดเดียวใน [§0.1b](#01b-สรุปคำสั่งทั้งหมด-ก๊อปวางได้)
— แยกออกมาให้ดูตรงนี้เพราะแต่ละตัวมีเหตุผลของตัวเองที่ควรรู้

| ในชุด | สคริปต์ | ถ้าไม่รัน จะเจออะไร |
|---|---|---|
| 1 | `harden-nginx.sh` | โดเมนที่ชี้มาแต่ยังไม่ Add site ได้เว็บของลูกค้ารายอื่น ([02 §2.8](02-hardening.md)) |
| 2 | `apply-cache-config.sh` | FastCGI cache ฉบับโรงงาน — แคช 200 ไว้ **1 วัน** และสั่งเบราว์เซอร์ห้ามแคช ([04](04-cache.md)) |
| 3 | `set-redis-limit.sh` | Redis ไม่มีเพดาน RAM ([03 §3.5](03-tuning.md)) |
| 4 | `apply-mysql-config.sh --restart` | MariaDB วิ่งด้วยค่าโรงงาน — buffer pool 1 GB และ `join_buffer_size` จองเปล่า ~1.6 GB ([03 §3.4](03-tuning.md)) |
| 5 | `install-autoheal.sh --no-cron` | ไม่มีตัวซ่อมรอบกลางคืน (ข้อ 8 ต่อจากนี้) |
| 6 | `install-site-watcher.sh` | 🔴 ไซต์ใหม่เปิด auto-update ค้าง → WordPress อัปตัวเองภายใน 1 ชม. ([05 §5.1c](05-operations.md)) |
| 7 | `fix-cache-purge.sh` | 🔴 ปุ่ม Purge ในหน้า WP กดแล้วไม่มีอะไรเกิดขึ้น ([04 §4.7](04-cache.md)) |
| 8 | แก้ IP ที่หัว panel | หัว panel โชว์ IP ของเครื่องอื่น → ก๊อปไปรันคำสั่งผิดเครื่อง ([07 ข้อ 18](07-troubleshooting.md)) |
| 9 | `verify-config.sh` | ไม่รู้ว่าข้อ 1–8 ติดจริงหรือเปล่า — **ต้องขึ้น `ผ่านทั้งหมด`** |
| 10 | ทดสอบ 404 | ยืนยันว่ารู 443 ปิดจริง |

### ลำดับที่ห้ามสลับ

- **ข้อ 2 ก่อนทุกอย่าง** — บอทสแกนเจอเครื่องใหม่ภายในไม่กี่ชั่วโมง
- **ข้อ 6 ก่อนปิด password** — ทดสอบ SSH key ให้เข้าได้จริงก่อน ไม่งั้นล็อกตัวเองออก
- **ข้อ 7 ก่อนข้อ 10 ทั้งชุด** — โดยเฉพาะ `install-site-watcher.sh` กับ `fix-cache-purge.sh`
  เว็บแรกที่ขึ้นก่อนตั้ง watcher จะเปิด auto-update ค้าง แล้ว WordPress อัปตัวเอง
  ขึ้นตัวล่าสุดภายในชั่วโมงเดียว (วัดจากเครื่องจริง 2 เครื่อง) — **ปิดทีหลังไม่ย้อนเวอร์ชันกลับ**
- **`apply-mysql-config.sh` ทำตอนนี้ ไม่ใช่ทีหลัง** — มัน restart MariaDB ตอนเครื่องยังว่าง
  ทำได้ตามใจ พอมีเว็บลูกค้าแล้วต้องนัดเวลา
- **ข้อ 9 ก่อนรับงานลูกค้าจริง** — backup ที่ไม่เคย restore สำเร็จ ยังไม่นับว่าเป็น backup

### ถ้าตั้งหลายเครื่องพร้อมกัน

**ทำทีละเครื่องให้จบข้อ 10 ก่อน แล้วค่อยขึ้นเครื่องถัดไป** — เครื่องที่สองจะเร็วกว่ามาก
เพราะรู้แล้วว่าแต่ละขั้นหน้าตาเป็นยังไง และถ้าเจอปัญหาจะรู้ทันทีว่าเป็นเรื่องเฉพาะเครื่อง
หรือเป็นของที่คู่มือยังขาด

**ถ้าเช่ามาคนละแบบ (หนึ่งเครื่องมี template หนึ่งเครื่องเปล่า) ให้ทำเครื่องที่มี template ก่อน**
เพราะมันสั้นกว่า จะได้เห็นปลายทางว่าเครื่องที่เสร็จแล้วหน้าตาเป็นยังไง แล้วค่อยไปทำ
เครื่องเปล่าโดยมีของให้เทียบ

ตอนทำเครื่องเปล่า เทียบผลด้วยคำสั่งเดียวกันได้เลย — ทั้งสองเครื่องต้องได้เหมือนกัน:

```powershell
ssh root@เครื่องที่มี-template "bash /root/wpaa/scripts/verify-config.sh"
ssh root@เครื่องเปล่า          "bash /root/wpaa/scripts/verify-config.sh"
```

**ต้องขึ้น `ผ่านทั้งหมด` ทั้งคู่** ถ้าเครื่องเปล่าขาดข้อไหน แปลว่า [10-bare-linux](10-bare-linux.md)
ยังมีขั้นที่ตกหล่น — **แก้ที่เอกสาร ไม่ใช่แก้เฉพาะเครื่องนั้นแล้วผ่านไป**

จบแต่ละเครื่องแล้วอย่าลืม [§0.8](#08-อัปเดตเอกสารด้วย) — เติมแถวของเครื่องนั้นใน README
ด้วยค่าที่ `inventory.sh` อ่านมาจริง **อย่าคัดลอกค่าจากเครื่องอื่นมาเติมแทน**

---

## 0.1b สรุปคำสั่งทั้งหมด (ก๊อปวางได้)

นี่คือ **ข้อ 7** ในตารางข้างบน — ทำหลังจากติดตั้ง stack และจูนตามข้อ 1–6 แล้ว

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

# 4) ค่าจูน MariaDB ตาม 03 หัวข้อ 3.4  <-- ทำตอนนี้ เครื่องยังว่าง restart ได้ตามใจ
#    ตอนมีเว็บลูกค้าแล้วต้องนัดเวลา และ panel เขียนทับ my.cnf ได้เรื่อย ๆ
ssh root@NEW_IP "bash /tmp/wpaa/scripts/apply-mysql-config.sh --restart"

# 5) วางไฟล์ถาวรไว้ให้ cron ใช้ (ยังไม่แตะ crontab)
ssh root@NEW_IP "bash /tmp/wpaa/scripts/install-autoheal.sh --no-cron"

# 6) ให้เครื่อง stamp ไซต์ใหม่เอง  <-- ห้ามข้าม ดู 0.6
ssh root@NEW_IP "bash /tmp/wpaa/scripts/install-site-watcher.sh"

# 7) ให้ปุ่ม Purge ในหน้า WP ล้างแคชได้จริง (ดู 04 §4.7)
ssh root@NEW_IP "bash /tmp/wpaa/scripts/fix-cache-purge.sh"

# 8) แก้ IP ที่หัว panel ให้ตรงเครื่อง - image ของ Hostinger ติดค่าของเครื่องอื่นมา
#    ถ้าปล่อยไว้ คนจะก๊อป IP ผิดไปรันคำสั่งผิดเครื่อง (ดู 07 ข้อ 18)
ssh root@NEW_IP "F=/www/server/panel/data/iplist.txt; mkdir -p /root/wpaa/backups; cp -p \$F /root/wpaa/backups/ 2>/dev/null; printf '%s' \$(ip -4 addr show scope global | grep -oP 'inet \K[0-9.]+' | head -1) > \$F; cat \$F"

# 9) ยืนยัน - ต้องขึ้น "ผ่านทั้งหมด"
ssh root@NEW_IP "bash /tmp/wpaa/scripts/verify-config.sh"

# 10) ทดสอบว่ารูปิดจริง - ต้องได้ 404
curl -sk --resolve nosuch.invalid:443:NEW_IP https://nosuch.invalid/ -o /dev/null -w "%{http_code}"

# 11) หมุน log เว็บอัตโนมัติ (aaPanel ไม่ตั้งให้ log โตไม่หยุด) ดู 05 §5.8
ssh root@NEW_IP "bash -s -- --rotate-now" < scripts/setup-logrotate.sh
```

**ข้อ 5 ยังไม่จบ** — ไปตั้งงานใน **aaPanel → Cron Job → Add Task** ต่อ
(Daily · **16:00** เพราะเครื่องเป็น UTC · Script content = `/root/wpaa/scripts/nightly-check.sh`)
รายละเอียดและกับดักเรื่องเวลาอยู่ที่ [05 §5.1b](05-operations.md)

**หลังข้อ 6 กับ 7 ทีมงานกด Add site ในแผงได้เลย ไม่ต้องสั่งอะไรต่อ** — ดูเหตุผลใน 0.6

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

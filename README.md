# WordPress on aaPanel — Runbook

คู่มือติดตั้งและดูแลเซิร์ฟเวอร์ VPS สำหรับโฮสต์ WordPress หลายเว็บ (เป้าหมาย ~100 เว็บ)
บน **Ubuntu 22.04 LTS + aaPanel + LNMP** ปัจจุบันดูแลอยู่ **2 เครื่อง**

> ⚠️ **repo นี้ไม่เก็บความลับ** — ห้าม commit IP จริง, รหัสผ่าน, API key, หรือไฟล์ `.env`
> ดู [`.env.example`](.env.example) สำหรับค่าที่ต้องเติมเองในเครื่อง

> 📌 **repo นี้บรรยายสภาพจริง ไม่ใช่สเปกเป้าหมาย**
> ถ้าเครื่องยังไม่ได้ตั้งค่าตามที่ควรเป็น เอกสารจะเขียนว่า "ยังไม่ได้ทำ" ไม่ใช่เขียนเหมือนทำแล้ว
> ค่าทุกตัวในตารางด้านล่างมาจาก [`scripts/inventory.sh`](scripts/inventory.sh) ไม่ได้มาจากความจำ

---

## สารบัญ

| เอกสาร | เนื้อหา |
|---|---|
| [docs/01-provisioning.md](docs/01-provisioning.md) | เช่า VPS, เลือก OS, ติดตั้ง stack |
| [docs/02-hardening.md](docs/02-hardening.md) | ความปลอดภัย panel / SSH / firewall / **รู default_server 443** |
| [docs/03-tuning.md](docs/03-tuning.md) | จูน sysctl, PHP-FPM, OPcache, MySQL, Redis |
| [docs/04-cache.md](docs/04-cache.md) | FastCGI Cache + Cloudflare + **cache poisoning ข้ามเว็บ** |
| [docs/05-operations.md](docs/05-operations.md) | งานประจำวัน/สัปดาห์/เดือน, backup |
| [docs/06-new-site.md](docs/06-new-site.md) | ขั้นตอนเพิ่มเว็บ WordPress ใหม่ |
| [docs/07-troubleshooting.md](docs/07-troubleshooting.md) | ปัญหาที่เคยเจอจริงและวิธีแก้ |
| [docs/08-decisions.md](docs/08-decisions.md) | บันทึกการตัดสินใจ |
| [docs/09-static-sites.md](docs/09-static-sites.md) | โฮสต์เว็บ static (Astro) บนเครื่องเดียวกัน |

---

## เครื่องที่ดูแลอยู่

| | **เครื่อง A** | **เครื่อง B** |
|---|---|---|
| hostname | ดู `SERVER_A_HOSTNAME` ใน `.env` | ดู `SERVER_B_HOSTNAME` |
| ตัวแปรใน `.env` | `SERVER_A_*` | `SERVER_B_*` |
| OS | Ubuntu 22.04.5 LTS | *(ยังไม่ยืนยัน)* |
| CPU / RAM / Disk | 4 vCPU / 15 Gi / 194 G | *(ยังไม่ยืนยัน)* |
| Swap | 4 GB | *(ยังไม่ยืนยัน)* |
| aaPanel | 8.0.5 | 8.0.5 *(จากหน้าจอ)* |
| Nginx | 1.30.4 (Single WebServer model) | *(ยังไม่ยืนยัน)* |
| MariaDB | 10.11.10 | *(ยังไม่ยืนยัน)* |
| Redis | 8.0.5 | *(ยังไม่ยืนยัน)* |
| PHP ที่ติดตั้งจริง | **8.0, 8.1, 8.2, 8.3** | *(ยังไม่ยืนยัน)* |
| PHP ที่เว็บใช้จริง | 8.3 ทุกเว็บ (+ static 1 เว็บ) | *(ยังไม่ยืนยัน)* |
| จำนวนไซต์ | 13 (WordPress 12 + static 1) | 2 *(จากหน้าจอ)* |

> **เครื่อง B ยังไม่ได้เก็บข้อมูล** — พอร์ต 22 ไม่ตอบจากเครื่องที่ใช้ทำเอกสาร
> เติมช่องว่างด้วย: `ssh root@<B> "bash -s" < scripts/inventory.sh`
> **อย่าคัดลอกค่าจากเครื่อง A มาเติมแทน** สองเครื่องนี้ไม่ได้ตั้งค่าพร้อมกันและไม่ควรเดาว่าเหมือนกัน

### ⚠️ PHP 8.4 ไม่มีบนเครื่อง A

เอกสารรุ่นแรกเขียนว่า "8.3 หลัก + 8.4 สำรอง" แต่ของจริงคือ **ไม่มี 8.4 เลย**
และ **8.0 / 8.1 / 8.2 ที่หมดอายุแล้วยังไม่ได้ถอน** (ไม่มีเว็บไหนใช้ — ดูตาราง SITES ใน `inventory.sh`)

---

## งบประมาณ RAM (เครื่อง A)

รวมทั้งหมดต้องไม่เกิน ~12 GB จาก 15 GB เพื่อเหลือ headroom

| ส่วน | จอง |
|---|---|
| MariaDB (buffer pool 4G + per-connection) | ~4.5 GB |
| PHP-FPM 8.3 (35 × ~80 MB) | 2.8 GB |
| OPcache | 1.0 GB |
| Redis | *(ยังไม่จำกัด — ดูด้านล่าง)* |
| FastCGI Cache | 1.0 GB |
| Nginx + OS + aaPanel | 1.0 GB |
| **รวมที่ควบคุมได้** | **~10.3 GB** |

🔴 **Redis ยังไม่ได้ตั้ง `maxmemory`** แปลว่ามันโตได้ไม่จำกัดและจะไปแย่ง RAM กับ MariaDB
เป็นช่องโหว่ของงบ RAM ที่ยังเปิดอยู่จริง ๆ ไม่ใช่แค่ TODO บนกระดาษ (ดู [03-tuning §3.5](docs/03-tuning.md))

---

## ผลการวัด TTFB

| สถานะ | TTFB |
|---|---|
| Cache MISS (ผ่าน PHP + MySQL) | 35 ms |
| Cache HIT | 0.3 ms |

> ตัวเลขนี้วัดจากเครื่องที่ **ตั้ง FastCGI cache ตาม [`configs/enable-php-83-wpfastcgi.conf`](configs/enable-php-83-wpfastcgi.conf) แล้ว**
> **เครื่อง A ยังไม่ได้ตั้ง** (ไฟล์ยังเป็นฉบับโรงงานของ WP Toolkit) จึงยังไม่มีตัวเลข baseline ของตัวเอง
> ยืนยันสถานะได้ทุกเมื่อด้วย `bash scripts/verify-config.sh`

---

## 🔴 งานที่ยังค้าง (ยืนยันจากเครื่อง A เมื่อ 2026-08-23)

- [ ] **`enable-php-83-wpfastcgi.conf` ยังเป็นฉบับโรงงาน** — ยังมี `Cache-Control: max-age=0`, `Last-Modified`, `fastcgi_cache_valid 200 1d` และไม่มี `cache_lock`/`use_stale` (ดู [04-cache §4.2](docs/04-cache.md))
- [ ] **Redis ยังไม่ตั้ง `maxmemory`**
- [ ] **ล็อก panel** — ยังเป็นพอร์ต `8888` ต้องเปลี่ยนพอร์ต + security entrance + password
- [ ] **ตั้ง Backup + ทดสอบ restore** — ยังไม่มี backup เลยแม้แต่ชุดเดียว
- [ ] SSH: ปิด password login (คีย์ใช้ได้แล้ว แต่ password ยังเปิดอยู่)
- [ ] SMTP ภายนอก (Brevo / Amazon SES) — ห้ามส่งเมลจาก VPS ตรง
- [ ] ปลั๊กอิน Nginx Helper ทุกเว็บ (ล้าง cache อัตโนมัติ)
- [ ] ปิด `wp-cron` ในตัว → ใช้ system cron
- [ ] ถอน PHP 8.0 / 8.1 / 8.2 ที่ไม่มีเว็บไหนใช้
- [ ] Cloudflare WAF rules (บอทกำลังสแกนอยู่จริง)
- [ ] เก็บ inventory ของ **เครื่อง B**

### ✅ ทำแล้ว

- [x] Swap 4 GB
- [x] sysctl + BBR (`/etc/sysctl.d/99-tuning.conf`)
- [x] PHP-FPM 8.3 `ondemand` / 35 / 30s
- [x] OPcache 1 GB, `memory_limit 256M`
- [x] Fail2ban ติดตั้งแล้ว
- [x] **ปิดรู `default_server` พอร์ต 443** + www→non-www ที่ระดับ nginx (2026-08-23 — ดู [02-hardening §2.8](docs/02-hardening.md))

---

## กฎเหล็กของเซิร์ฟเวอร์นี้

1. **ใช้ `/etc/init.d/<service>` หรือ GUI ไม่ใช้ `systemctl`** — aaPanel รัน service ผ่าน init.d ทำให้ `systemctl` รายงานสถานะไม่ตรงความจริง (nginx, php-fpm, redis)
2. **ห้ามใช้ `sed -i` กับไฟล์ config** — เคยทำ php-fpm พังจนเว็บล่ม ใช้ aaPanel GUI แทน
3. **กฎ nginx ที่เราเขียนเอง ให้ไปอยู่ใน `extension/<domain>/`** ไม่ใช่แก้ vhost ตรง ๆ — vhost โดน panel เขียนทับได้ทุกครั้งที่ต่ออายุ SSL หรือเปลี่ยน setting แต่โฟลเดอร์ `extension/` ไม่โดน (ดู [08-decisions ADR-010](docs/08-decisions.md))
4. **หลังกด Add site ในแผง ต้องรัน `stamp-site.sh <domain>` เสมอ** — ไม่ใช่แค่ใส่กฎกลาง แต่ตัว reload คือสิ่งที่ปิดช่วงหน้าต่างที่โดเมนใหม่ไปหยิบเว็บของคนอื่นมาแสดง (ดู [07-troubleshooting ข้อ 10–11](docs/07-troubleshooting.md))
5. **ตรวจ syntax ก่อน start/reload ทุกครั้ง**
   ```bash
   /www/server/php/83/sbin/php-fpm -t -y /www/server/php/83/etc/php-fpm.conf
   /www/server/nginx/sbin/nginx -t
   ```
6. **สำรองไฟล์ก่อนแก้เสมอ** — `cp <file> <file>.bak-$(date +%F)`
7. **ทุกเว็บ WordPress ใช้ PHP 8.3 เหมือนกันหมด** — เพื่อให้มีจุดแก้ config จุดเดียว (เว็บ static ใช้ `enable-php-00` ไม่นับ)
8. **หลังอัปเดต aaPanel ต้องรัน `verify-config.sh`** — ดู [05-operations](docs/05-operations.md)

---

## Quick Reference

```bash
# เก็บสภาพจริงทั้งเครื่อง (อ่านอย่างเดียว)
ssh root@SERVER_IP "bash -s" < scripts/inventory.sh

# ตรวจว่าค่าที่เอกสารอ้างยังอยู่ไหม
ssh root@SERVER_IP "bash -s" < scripts/verify-config.sh

# สถานะ service - ยืนยันจากของจริง ไม่ใช่ systemctl (ดู docs/07 ข้อ 1)
curl -sI http://127.0.0.1 | head -3      # nginx ตอบ = ทำงาน
redis-cli ping                            # PONG = ทำงาน
ls -la /tmp/php-cgi-83.sock               # มีไฟล์ = php-fpm ทำงาน
free -h && uptime

# ทดสอบ cache
curl -sI http://127.0.0.1 -H "Host: DOMAIN.TLD" | grep -i x-cache

# ทดสอบว่าโดเมนแปลกหน้าไม่ไปหยิบเว็บคนอื่น (ต้องได้ 404)
curl -sk --resolve nosuch.invalid:443:SERVER_IP https://nosuch.invalid/ -o /dev/null -w '%{http_code}\n'

# reload หลังแก้ config
/www/server/nginx/sbin/nginx -t && /etc/init.d/nginx reload
```

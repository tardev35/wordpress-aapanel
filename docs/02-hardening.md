# 02 — Hardening

> 🔴 **ส่วนนี้ต้องทำก่อนเว็บ production ขึ้นเซิร์ฟเวอร์**
> เซิร์ฟเวอร์ใหม่จะถูกบอทสแกนภายในไม่กี่ชั่วโมง (ยืนยันจาก log จริง — ดูท้ายเอกสาร)

---

## 2.1 ล็อก aaPanel ⚠️ ทำเป็นอย่างแรก

ค่าเริ่มต้นคือ `https://<IP>:8888/aapadmin` ซึ่ง **พอร์ตและ path เป็นค่ามาตรฐานที่ทุกคนรู้**

```bash
bt
```

| เมนู | ทำอะไร | ตั้งเป็น |
|---|---|---|
| `8` | เปลี่ยนพอร์ต panel | เลขสุ่ม 5 หลัก เช่น `31847` |
| `29` | **Security entrance** (safe path) | path ที่เดาไม่ได้ เช่น `/x7k2m9p4` |
| `5` | เปลี่ยน password | ยาว ≥ 20 ตัวอักษร |
| `6` | เปลี่ยน username | ไม่ใช้ค่าเริ่มต้น |

**Security entrance เป็นฟีเจอร์ที่ดีมากของ aaPanel** — ถ้าไม่ใส่ path ลับต่อท้าย URL
จะเข้าหน้า login ไม่ได้เลย บอทสแกนพอร์ตจะเจอแต่หน้าว่าง

### อัปเดต Firewall

**hPanel → VPS → Security → Firewall**

| Port | เปิด? |
|---|---|
| 22 (SSH) | ✅ |
| 80, 443 | ✅ |
| **พอร์ต panel ใหม่** | ✅ (จำกัด IP ออฟฟิศได้ยิ่งดี) |
| **8888** | ❌ **ปิด** |
| 888 (phpMyAdmin) | จำกัด IP ออฟฟิศ |
| 21, 40110-40210 (FTP) | ❌ ไม่ใช้ |

### เพิ่มอีกชั้น

**aaPanel → Security → IP whitelist** — ให้เข้า panel ได้เฉพาะ IP ออฟฟิศ

---

## 2.2 Swap

ตรวจก่อนว่ามีหรือยัง — บาง template ให้มา 2 GB แล้ว

```bash
free -h
```

ถ้า `Swap: 0B`:

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

**ทำไมสำคัญ:** ถ้า RAM เต็มโดยไม่มี swap Linux จะฆ่า process ทิ้ง (MariaDB มักโดนก่อน)
= **เว็บล่มทั้ง 100 เว็บพร้อมกัน** Swap คือตาข่ายนิรภัย ไม่ใช่ที่ทำงานประจำ

---

## 2.3 SSH Hardening

> ⚠️ **ทำเป็นขั้นตอนสุดท้ายเสมอ** และเปิด SSH ไว้ 2 หน้าต่างพร้อมกัน
> หน้าต่างที่สองห้ามปิด — เป็นทางกลับถ้าตั้งค่าผิด

### ขั้น 1: ยืนยันว่า SSH key ใช้ได้จริง

```bash
cat ~/.ssh/authorized_keys
```

**เปิดหน้าต่าง SSH ใหม่แล้วล็อกอินด้วย key ให้สำเร็จ**
ถ้ายังต้องพิมพ์รหัสผ่าน **อย่าทำขั้นถัดไป**

### ขั้น 2: ปิด password login

```bash
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf > /dev/null <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

sudo sshd -t     # ต้องไม่แสดงอะไรเลย = ผ่าน
sudo systemctl restart ssh
```

**ทดสอบด้วยหน้าต่างใหม่ทันที** ถ้าเข้าไม่ได้ กลับหน้าต่างเดิมแล้ว:
```bash
sudo rm /etc/ssh/sshd_config.d/99-hardening.conf
sudo systemctl restart ssh
```

### ทางเข้าสำรอง

**hPanel → VPS → Browser terminal** — เข้าได้โดยไม่ผ่าน SSH
**ทดสอบให้เข้าได้สำเร็จ 1 ครั้งก่อนทำ SSH hardening**

---

## 2.4 Fail2ban

```bash
sudo apt update && sudo apt install fail2ban -y

sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled = true
EOF

sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

ดูอีกครั้งหลังผ่านไป 1 วัน จะเห็นจำนวน IP ที่ถูกแบน — นั่นคือหลักฐานว่าทำไมขั้นตอนนี้จำเป็น

---

## 2.5 Permission ของ WordPress

### ⚠️ `wp-config.php` ต้องไม่เป็น 666

aaPanel/WP installer บางครั้งตั้ง `666` ซึ่งแปลว่า **ทุก user ในระบบเขียนไฟล์นี้ได้**
และไฟล์นี้เก็บรหัสผ่านฐานข้อมูล

```bash
# ตรวจทุกเว็บ
find /www/wwwroot -name "wp-config.php" -exec ls -la {} \;

# แก้ทุกเว็บพร้อมกัน
find /www/wwwroot -name "wp-config.php" -exec chmod 640 {} \;
find /www/wwwroot -name "wp-config.php" -exec chown www:www {} \;
```

### Permission มาตรฐาน

| ประเภท | ค่า |
|---|---|
| โฟลเดอร์ | `755` |
| ไฟล์ทั่วไป | `644` |
| `wp-config.php` | **`640`** |

---

## 2.6 ความเสี่ยงเฉพาะของ aaPanel: shared user

**ทุกเว็บรันในนาม user `www` เดียวกัน** (ต่างจาก CyberPanel ที่แยก user ต่อเว็บ)
ถ้าเว็บหนึ่งถูกเจาะ ผู้โจมตีอาจอ่านไฟล์ของเว็บอื่นได้

### มาตรการลดความเสี่ยง

1. **เปิด `open_basedir` ต่อเว็บ** — aaPanel → Website → Settings → มีตัวเลือกให้
2. **แยก database user ต่อ 1 เว็บ** — ห้ามใช้ user เดียวกันข้ามเว็บ **(ข้อนี้ห้ามข้าม)**
3. **`disable_functions` ใน php.ini:**
   ```
   exec,passthru,shell_exec,system,proc_open,popen,parse_ini_file,show_source
   ```
   ⚠️ **อย่าใส่ `putenv` หรือ `getenv`** — ปลั๊กอิน WordPress บางตัวใช้และจะพังทันที

> **ถ้าเว็บทั้ง 100 เป็นของทีมเดียวกัน ความเสี่ยงนี้รับได้**
> แต่ถ้าเป็นเว็บลูกค้าคนละราย ควรพิจารณาแยกเป็น 2 เครื่อง

---

## 2.7 Cloudflare WAF

### หลักฐานว่าจำเป็น — log จริงจากเซิร์ฟเวอร์นี้

บอทเริ่มสแกนภายในชั่วโมงแรกที่เว็บขึ้นออนไลน์ ยิงเข้ามาทุก 1–2 วินาที:

```
GET /.env                        ← หาไฟล์ที่มีรหัส DB
GET /.git/HEAD                   ← หา source code
GET /.vscode/sftp.json           ← หารหัสผ่าน SFTP
GET /?rest_route=/wp/v2/users/   ← ดึงรายชื่อ user WordPress
GET /actuator/env
GET /telescope/requests
GET /info.php
```

### Custom Rules

**Security → WAF → Custom rules → Create rule**

```
URI Query String contains "rest_route=/wp/v2/users"
OR URI Path contains ".env"
OR URI Path contains ".git"
OR URI Path contains ".vscode"
OR URI Path contains "/actuator"
→ Action: Block
```

### Rate Limiting

**Security → WAF → Rate limiting rules**

```
URI Path equals /wp-login.php
> 5 requests / 1 minute
→ Block 10 minutes
```

### เปิด Bot Fight Mode

**Security → Settings → Bot Fight Mode** (ฟรี)

---

## 2.8 ปิดรู `default_server` พอร์ต 443 🔴

**นี่คือช่องโหว่ที่ทำให้เว็บของลูกค้ารายหนึ่งไปโผล่ใต้โดเมนของอีกราย** เกิดขึ้นจริงเมื่อ 2026-08-23

### อาการ

ทีมงานเปิดโดเมนตัวเอง แล้วเจอเว็บของลูกค้าคนอื่นเต็มหน้า โดย **URL ยังเป็นโดเมนตัวเองอยู่**
(ไม่ได้ redirect ไปไหน — nginx แค่หยิบไฟล์ผิดเว็บมาเสิร์ฟใต้ชื่อโดเมนนั้น)

### สาเหตุ

`0.default.conf` ที่ aaPanel สร้างให้มีแค่นี้:

```nginx
server {
    listen 80;
    server_name _;
    index index.html;
    root /www/server/nginx/html;
}
```

**มีแต่พอร์ต 80** และทั้งเครื่องไม่มีใครประกาศ `default_server` เลย

พอไม่มีใครประกาศ nginx จะเลือก **server block แรกที่ `listen 443` ตามลำดับการโหลด**
(= เรียงตามชื่อไฟล์ใน `/www/server/panel/vhost/nginx/`) มาเป็น default ของพอร์ตนั้น

ผลคือโดเมนที่ชี้ DNS มาที่เครื่องแล้วแต่ยังไม่ได้ Add site จะได้เว็บนั้นไปเต็ม ๆ
และเนื่องจากเรียงตามตัวอักษร **ไซต์ที่รับเคราะห์เปลี่ยนไปเรื่อย ๆ ทุกครั้งที่มีโดเมนใหม่ชื่อมาก่อน**

> Cloudflare ไม่ได้ช่วยจับ เพราะ SSL mode เป็น **Full ธรรมดา** ไม่ใช่ Full (Strict)
> มันจึงยอมรับ cert ที่ไม่ตรงชื่อโดเมนและส่งต่อเนื้อหามาให้ผู้ใช้ตามปกติ

### พิสูจน์ว่ามีรูหรือยัง

```bash
# ยิงชื่อโฮสต์ที่ไม่มีอยู่จริงตรงไปที่ IP - ต้องได้ 404
curl -sk --resolve nosuch.invalid:443:SERVER_IP https://nosuch.invalid/ \
     -o /dev/null -w '%{http_code}\n'

# ถ้าได้ 200 ให้ดูว่าไปหยิบเว็บไหนมา
curl -sk --resolve nosuch.invalid:443:SERVER_IP https://nosuch.invalid/ | grep -o '<title>[^<]*</title>'

# และดูว่ามันเสิร์ฟ cert ของใคร
echo | openssl s_client -connect SERVER_IP:443 -servername nosuch.invalid 2>/dev/null \
  | openssl x509 -noout -subject
```

### วิธีปิด

```bash
scp -r configs scripts root@SERVER_IP:/tmp/wpaa/
ssh root@SERVER_IP "bash /tmp/wpaa/scripts/harden-nginx.sh"
ssh root@SERVER_IP "/etc/init.d/nginx reload"
```

[`scripts/harden-nginx.sh`](../scripts/harden-nginx.sh) ติดตั้ง 3 อย่าง:

| ไฟล์ | หน้าที่ |
|---|---|
| [`configs/0.catchall_ssl.conf`](../configs/0.catchall_ssl.conf) | `listen 443 ssl default_server` — โดเมนแปลกหน้าได้ **404**, `www.*` ได้ **301 ไป apex** |
| [`configs/common-site.conf`](../configs/common-site.conf) | www → non-www ที่ระดับ nginx ใส่ให้ทุกไซต์ผ่าน symlink |
| [`scripts/stamp-site.sh`](../scripts/stamp-site.sh) | ใช้กับไซต์ใหม่ทุกครั้งหลัง Add site |

**สิ่งที่ตั้งใจไม่แตะ:**

- **พอร์ต 80** ปล่อยให้ `0.default.conf` ของ panel ดูแลต่อ — ทั้งเพื่อเก็บหน้า
  "Website not found" ที่อ่านรู้เรื่องไว้ และเพื่อให้ **Let's Encrypt แบบ HTTP-01
  ต่ออายุได้เหมือนเดิม** (validation วิ่งผ่านพอร์ต 80)
- **vhost ของไซต์ทุกตัว** ไม่ถูกแก้แม้แต่ไฟล์เดียว

cert ของ catch-all เป็น **self-signed ของตัวเอง ไม่ยืมของไซต์ไหน** — ถ้าไปยืม cert ของไซต์หนึ่ง
แล้ววันหนึ่งไซต์นั้นถูกลบ **nginx จะสตาร์ทไม่ขึ้นทั้งเครื่อง**

### ผลหลังปิด

```
โดเมนแปลกหน้าเข้า https        404
www.<โดเมนที่มีไซต์>            301 -> apex
www.<โดเมนที่ไม่มี www ใน server_name>   301 -> apex   (catch-all รับให้)
```

ข้อสุดท้ายคือกำไรที่ได้มาฟรี — ไซต์ที่ panel ไม่ได้ใส่ `www` ใน `server_name` ก็ได้ redirect ด้วย
โดยไม่ต้องไปตั้งอะไรเพิ่มต่อโดเมน

---

## Checklist

สถานะด้านล่างคือของ **เครื่อง A** ยืนยันเมื่อ 2026-08-23 (เครื่อง B ยังไม่ได้ตรวจ)

- [ ] เปลี่ยนพอร์ต panel — **ยังเป็น 8888**
- [ ] ตั้ง Security entrance
- [ ] เปลี่ยน username + password ของ panel
- [ ] ปิดพอร์ต 8888 ใน firewall
- [ ] ตั้ง IP whitelist ของ panel
- [x] Swap 4 GB
- [ ] ทดสอบ Browser terminal ได้สำเร็จ
- [ ] SSH key ใช้ได้ → ปิด password login — **คีย์ใช้ได้แล้ว แต่ password ยังเปิดอยู่**
- [x] Fail2ban ติดตั้งแล้ว
- [ ] `wp-config.php` = 640 ทุกเว็บ
- [ ] แยก DB user ต่อเว็บ
- [ ] Cloudflare WAF + rate limit
- [x] **ปิดรู `default_server` พอร์ต 443** (§2.8)
- [ ] Cloudflare SSL mode = Full (Strict) — **ยังเป็น Full ธรรมดา** ซึ่งเป็นเหตุผลหนึ่งที่ §2.8 ไม่ถูกจับได้เร็วกว่านี้

---

**ถัดไป:** [03-tuning.md](03-tuning.md)

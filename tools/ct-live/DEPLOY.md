# ct-live — deploy ขึ้น VPS + โดเมน (ล็อก IP + รหัสผ่าน, ไม่ต้อง certbot)

> ✅ **deploy จริงแล้ว** บน Astro VPS เมื่อ 2026-08-31 — Cloudflare (SSL Flexible) → nginx
> (realip + ล็อก IP + Basic Auth) → ct-live (systemd, 127.0.0.1:8765)

ct-live เป็น Python **stdlib ล้วน ไม่ต้อง pip** · bind `127.0.0.1:8765` · เก็บ log ใน SQLite

## สถาปัตยกรรม

```
Browser --HTTPS--> Cloudflare (SSL Flexible) --HTTP--> nginx :80 (origin)
                                                        ├─ realip: กู้ IP จริงจาก CF-Connecting-IP
                                                        ├─ ชั้น 1: allow <IP คุณ>; deny all;
                                                        ├─ ชั้น 2: auth_basic (รหัสผ่าน popup)
                                                        └─ proxy_pass 127.0.0.1:8765 (systemd)
```
**ทำไม Flexible:** ไม่ต้อง certbot — Cloudflare ทำ HTTPS ให้ browser, origin เสิร์ฟ HTTP 80 พอ
(ปลอดภัยกว่าถ้าใช้ **Cloudflare Origin CA cert** ฟรี 15 ปี → Full(strict) ก็ยังไม่ต้อง certbot)

---

## 0. ก่อนเริ่ม

- **VPS** ที่มี python3 + nginx + systemd (ไม่ต้อง aaPanel) — 🔴 ถ้าจะลง Playwright ควรแยกจากเว็บลูกค้า
- **ซับโดเมน** เช่น `ct-live.<yourdomain>` — ที่ Cloudflare ตั้ง A record → `VPS_IP`,
  **orange cloud (proxied)** และ **SSL/TLS = Flexible**
- **IP ของคุณ** สำหรับ allow — เช็คด้วย:
  ```bash
  curl -s https://api.ipify.org; echo            # Git Bash / Linux / mac
  ```
  ```powershell
  curl.exe -s https://api.ipify.org              # Windows PowerShell (curl = alias ต้องใช้ curl.exe)
  ```

---

## 1. ct-live + systemd

```bash
scp -r tools/ct-live root@VPS_IP:/opt/ct-live      # .env (key+model) + proxies ไปด้วย
ssh root@VPS_IP 'rm -rf /opt/ct-live/__pycache__ /opt/ct-live/data/hits.db*;
  chown -R www-data:www-data /opt/ct-live; chmod 600 /opt/ct-live/.env'
```

`/etc/systemd/system/ct-live.service`:
```ini
[Unit]
Description=ct-live — CT stream monitor
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/ct-live
ExecStart=/usr/bin/python3 server.py
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
```
```bash
systemctl daemon-reload && systemctl enable --now ct-live
sleep 9; systemctl is-active ct-live; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8765/
```

---

## 2. nginx — realip + ล็อก IP + รหัสผ่าน popup

```bash
# ก) Cloudflare ranges -> กู้ IP จริง (จำเป็น ไม่งั้น origin เห็นแต่ IP ของ CF)
{ for ip in $(curl -s https://www.cloudflare.com/ips-v4); do echo "set_real_ip_from $ip;"; done
  for ip in $(curl -s https://www.cloudflare.com/ips-v6); do echo "set_real_ip_from $ip;"; done
} > /etc/nginx/cloudflare-realip.conf

# ข) allowlist (แก้เพิ่มด้วย ct-allow.sh ทีหลัง)
printf 'allow <YOUR_IP>;\nallow 127.0.0.1;\n' > /etc/nginx/ct-live-allow.conf

# ค) รหัส popup (สุ่ม ไม่โชว์) - เปลี่ยนเองด้วย ct-passwd.sh
echo "admin:$(openssl passwd -apr1 "$(openssl rand -base64 18)")" > /etc/nginx/ct-live.htpasswd
chmod 640 /etc/nginx/ct-live.htpasswd; chown root:www-data /etc/nginx/ct-live.htpasswd
```

`/etc/nginx/sites-available/ct-live.<yourdomain>` (แล้ว `ln -s` เข้า `sites-enabled/`):
```nginx
server {
    listen 80;
    server_name ct-live.<yourdomain>;

    include /etc/nginx/cloudflare-realip.conf;
    real_ip_header CF-Connecting-IP;

    location / {
        include /etc/nginx/ct-live-allow.conf;   # ชั้น 1: ล็อก IP
        deny all;
        auth_basic "ct-live";                    # ชั้น 2: รหัสผ่าน popup
        auth_basic_user_file /etc/nginx/ct-live.htpasswd;

        proxy_pass http://127.0.0.1:8765;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 120s;
    }
}
```
```bash
nginx -t && systemctl reload nginx
```
> ล็อก 2 ชั้น (satisfy all): IP ไม่ใช่ของคุณ = 403 (ไม่เจอ popup) · IP ถูกแต่ไม่มีรหัส = 401 (popup) ·
> ครบทั้งคู่ = เข้าได้ · คนยิงตรง origin ข้าม CF (IP ไม่ใช่ CF) → header ปลอมไม่ถูกเชื่อ → 403

---

## 3. สคริปต์ช่วย (วางไว้ที่ /root บน VPS)

**`ct-allow.sh`** — จัดการ IP ที่เข้าได้:
```bash
bash /root/ct-allow.sh 1.2.3.4       # เพิ่ม IP + test + reload ให้เอง
bash /root/ct-allow.sh --list        # ดู IP ที่ allow อยู่
bash /root/ct-allow.sh --whoami      # โชว์ IP ปัจจุบันของคุณ (เผื่อ IP เปลี่ยน)
```
**`ct-passwd.sh`** — ตั้ง/เปลี่ยนรหัส popup (user: `admin`):
```bash
bash /root/ct-passwd.sh 'รหัสใหม่ของคุณ'
```

---

## 4. ตั้งค่า Cloudflare + เข้าใช้งาน

1. A record `ct-live.<yourdomain>` → `VPS_IP` · **orange cloud** · **SSL/TLS = Flexible**
2. **ตั้งรหัสของคุณเองก่อน** (ตอน deploy รหัสเป็นสุ่มที่ไม่มีใครรู้):
   `bash /root/ct-passwd.sh 'รหัสคุณ'`
3. เปิด `https://ct-live.<yourdomain>` → popup เด้ง → user `admin` + รหัสที่ตั้ง
4. IP เปลี่ยน (เน็ตบ้าน/VPN) เข้าไม่ได้ → เพิ่ม IP ใหม่: `bash /root/ct-allow.sh <ip>`

---

## กฎเหล็ก / งานเสริม

- `.env` `chmod 600` — มี API key
- ยิง probe **ผ่าน proxy** (มี `proxies-probe.txt` แล้ว) ไม่ให้ IP origin โผล่ไปหาเว็บพนัน
- 🔴 **อย่าลง Playwright บนเครื่องที่โฮสต์เว็บ static ของคุณ** — หนัก
- เสริมความแน่น: Cloudflare WAF allow เฉพาะ IP คุณ (ล็อกที่ขอบ) + ufw จำกัด port 80 เฉพาะช่วง CF
- Flexible = CF↔origin เป็น HTTP — อยากเข้ารหัสช่วงนี้โดยไม่ต้อง certbot ใช้ Cloudflare Origin CA cert
- แจ้งเตือน 24 ชม.: เพิ่มส่ง Telegram ฝั่ง server (ยังไม่ได้ทำ — งานเพิ่ม)

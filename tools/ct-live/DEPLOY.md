# ct-live — แผน deploy ขึ้น VPS + โดเมน (ล็อก IP ให้เข้าคนเดียว)

> สถานะ: **แผน** ยังไม่ได้ deploy จริง — ทำตามนี้เมื่อพร้อม
> ปรัชญา: มีโดเมนสวย ๆ ไว้เข้าเอง แต่ **nginx ล็อก IP** ให้เข้าได้แค่เครื่องคุณ คนอื่น 403

ct-live เป็น Python **stdlib ล้วน ไม่ต้อง pip อะไรเลย** · bind `127.0.0.1:8765` · เก็บ log ใน SQLite
เหมาะกับรันบน VPS ตลอด 24 ชม. (เฝ้าสตรีม CT ต่อเนื่อง ไม่ต้องเปิดคอมทิ้ง)

---

## 0. ก่อนเริ่ม — เตรียม 3 อย่าง

1. **VPS แยกตัวเล็ก ๆ** (1-2 GB พอ) — 🔴 **อย่าใช้เครื่อง WordPress ลูกค้า** โดยเฉพาะถ้าจะต่อ Playwright
2. **โดเมน/ซับโดเมน** เช่น `ct.example.com` ชี้ A record มาที่ IP VPS
3. **IP ของคุณ** — `curl -s https://api.ipify.org; echo` (IP บ้าน dynamic เผื่อทั้งวง เช่น `1.2.3.0/24`)

---

## 1. เอา ct-live ขึ้นเครื่อง + ตั้ง .env

```bash
# บนเครื่องคุณ
scp -r tools/ct-live root@VPS_IP:/www/wwwroot/ctlive
# บน VPS — สร้าง .env (ไม่ commit)
cat > /www/wwwroot/ctlive/.env <<'ENV'
OPENROUTER_API_KEY=sk-or-...
OPENROUTER_MODEL=google/gemini-3.5-flash-lite
ENV
chmod 600 /www/wwwroot/ctlive/.env
```

`data/` (SQLite) จะถูกสร้างเอง · proxy เปิดเว็บใส่ `proxies-probe.txt` ถ้าไม่อยากให้ IP VPS โผล่ไปหาเว็บพนัน

---

## 2. systemd — รันตลอด restart เอง

`/etc/systemd/system/ct-live.service`:

```ini
[Unit]
Description=ct-live — CT stream monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=www
WorkingDirectory=/www/wwwroot/ctlive
ExecStart=/usr/bin/python3 server.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now ct-live
systemctl status ct-live          # ต้องขึ้น active (running)
curl -s http://127.0.0.1:8765/ | head -c 80   # ต้องได้ HTML
```

server bind `127.0.0.1` อยู่แล้ว → เข้าจากข้างนอกตรง ๆ ไม่ได้ ต้องผ่าน nginx เท่านั้น

---

## 3. 🔴 nginx: โดเมน + SSL + ล็อก IP (หัวใจของแผนนี้)

สร้างไซต์ `ct.example.com` ใน aaPanel ตามปกติ แล้วขอ SSL (Let's Encrypt) จากนั้นแก้ config ของไซต์
ให้ **proxy ไป 127.0.0.1:8765 + allow เฉพาะ IP คุณ**:

```nginx
location / {
    allow 1.2.3.4;          # << IP คุณ (หรือ 1.2.3.0/24)
    allow 127.0.0.1;
    deny all;               # คนอื่นทั้งหมด 403

    proxy_pass http://127.0.0.1:8765;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_read_timeout 120s;    # /api/live, /api/probe ใช้เวลาบ้าง
}
```

```bash
nginx -t && nginx -s reload
```

> ถ้าไม่ใช้ aaPanel: ทำ server block + certbot เอง หลักการเดียวกัน

---

## 4. ยืนยันว่าล็อกได้ผล

```bash
# จากเครื่องคุณ (IP ที่ allow) — ต้องได้ 200
curl -sk https://ct.example.com/ -o /dev/null -w "%{http_code}\n"

# จากที่อื่น / มือถือปิด wifi (คนละ IP) — ต้องได้ 403
```

ได้ **200 จากคุณ + 403 จากคนอื่น** ถึงถือว่าปลอดภัยพอเปิดใช้

---

## 5. (ทางเลือก) เสริมความสามารถ

### 5a. Playwright — อ่านเว็บ JS ให้แม่นขึ้น
เว็บ SPA (เช่น london45) HTML ดิบมีข้อความไทยน้อย — Playwright render JS ให้ก่อนอ่าน
```bash
pip install playwright && playwright install-deps && playwright install chromium
```
🔴 หนัก — เปิดเบราว์เซอร์ต่อ 1 เว็บ · ใช้เฉพาะตัวที่ urllib อ่านไม่ได้ + จำกัด concurrency + ยิงผ่าน proxy
(ยังไม่ได้ทำในโค้ด — เป็นงานเพิ่มถ้าต้องการ)

### 5b. แจ้งเตือนฝั่ง server (Telegram/อีเมล)
browser Notification เตือนแค่ตอนเปิดหน้าเว็บค้างไว้ · ถ้าอยากเตือน 24 ชม. จริง
เพิ่มส่ง Telegram ตอนเจอเว็บพนันไทยเพิ่งจด (ยังไม่ได้ทำ — งานเพิ่ม)

---

## กฎเหล็กก่อนเปิดสาธารณะ

1. **ล็อก IP หรือใส่ Basic Auth เสมอ** — endpoint `/api/classify`,`/api/live` เผา credit ได้,
   `/api/probe` เปิด URL อะไรก็ได้ (open-proxy/SSRF) ถ้าเปิดโล่ง
2. `.env` `chmod 600` — มี API key อยู่ ห้ามหลุด
3. **แยกเครื่องจาก WordPress ลูกค้า** โดยเฉพาะถ้าใช้ Playwright
4. ยิง probe **ผ่าน proxy** ไม่ให้ IP VPS โผล่ไปหาเว็บพนันตรง ๆ

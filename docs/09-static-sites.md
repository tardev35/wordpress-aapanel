# 09 — เว็บ static บนเครื่องเดียวกัน

เครื่องอ้างอิง ไม่ได้มีแต่ WordPress — มีเว็บที่ build เป็น HTML ล้วน (Astro) อยู่ด้วย 1 เว็บ
เอกสารนี้คือวิธีทำให้เว็บแบบนั้นอยู่ร่วมกับ WP บน aaPanel ตัวเดียวกันได้

---

## 9.1 ต่างจากเว็บ WordPress ตรงไหน

| | WordPress | static (Astro) |
|---|---|---|
| PHP version ตอน Add site | **8.3** | **Static** (vhost ได้ `enable-php-00`) |
| Database | สร้าง | ไม่ต้อง |
| WP Toolkit | ใช้ | **ห้ามใช้** — มันจะลง WordPress ทับ |
| FastCGI cache | เปิด | ไม่เกี่ยว (ไม่มี PHP ให้ cache) |
| ไฟล์เว็บ | ติดตั้งโดย installer | deploy ขึ้นมาจากเครื่อง dev |

---

## 9.2 สร้างไซต์

**aaPanel → Website → Add site**

| ช่อง | ค่า |
|---|---|
| Domain | โดเมนจริง |
| **PHP Version** | **Static** |
| Database | ❌ |
| FTP | ❌ |

จากนั้นออก SSL ตามปกติ แล้ว **รัน `stamp-site.sh` เหมือนไซต์อื่นทุกประการ**

```bash
ssh root@SERVER_IP "/root/stamp-site.sh DOMAIN.TLD"
```

---

## 9.3 กฎ nginx เพิ่มเติม

เว็บ static ต้องการกฎที่เว็บ PHP ไม่ต้องการ — คัดลอก
[`configs/aapanel-astro.conf`](../configs/aapanel-astro.conf) ไปวางที่:

```
/www/server/panel/vhost/nginx/extension/<domain>/astro.conf
```

**สามข้อสำคัญในไฟล์นั้น:**

1. **`try_files $uri $uri/ $uri.html =404;`** — Astro สร้างหน้าเป็นโฟลเดอร์
   (`promotion/index.html`) ไม่ใช่ไฟล์เดี่ยว `/promotion` จึงต้องผ่าน `$uri/` ก่อน
   route ภาษาไทย (`/ทางเข้า/`) มาถึงในรูป percent-encoded และแมตช์โฟลเดอร์ UTF-8 ได้เอง

2. **`location ^~ /_astro/` และ `^~ /fonts/` ตั้ง `Cache-Control: immutable` 1 ปี** —
   ไฟล์พวกนี้มี content hash ในชื่ออยู่แล้ว
   `^~` เป็นตัวสำคัญ: มันหยุดไม่ให้ nginx ไปไล่ regex location ของ panel ต่อ
   ซึ่งตัวหนึ่ง (`location ~ .*\.(js|css)?$ { expires 12h; }`) จะกดไฟล์เหล่านี้เหลือ 12 ชั่วโมง

   > ⚠️ ไฟล์ `public/_headers` ในโปรเจกต์ Astro **Cloudflare อ่านเท่านั้น บน nginx ไม่มีผลเลย**
   > ถ้าไม่ใส่กฎนี้ ไฟล์ที่ตั้งใจให้แคชปีนึงจะโดน revalidate ทุกครั้ง

3. **`location ~ \.php$ { return 404; }`** — build ไม่มีไฟล์ PHP สักตัว อะไรที่ขอมาคือบอท

---

## 9.4 Deploy

ฝั่ง dev (โปรเจกต์ Astro) มีสคริปต์ `deploy-aapanel.ps1` ทำงานนี้:

```powershell
.\deploy-aapanel.ps1 -Domain DOMAIN.TLD
```

ขั้นตอนที่มันทำ: `npm run build` → `tar` → `scp` ไป `/tmp` → ssh เข้าไปแตกลง
`/www/wwwroot/<domain>` → ตั้ง owner/permission → ติดตั้ง `astro.conf` → `nginx -t` → reload

### ⚠️ `.user.ini` ถูกล็อกด้วย immutable flag

aaPanel วาง `.user.ini` ไว้ในทุก site root และตั้ง `chattr +i`

```
$ lsattr .user.ini
----i---------e------- .user.ini
```

**ไฟล์ที่ติด `+i` แม้แต่ root ก็ `chown` / `chmod` ไม่ได้** สคริปต์ deploy ที่ใช้
`chown -R` แล้วมี `set -e` จะตัดจบทั้งชุดตรงนี้ — โดยที่ `tar` แตกไฟล์ไปแล้ว
กลายเป็นเว็บขึ้นแต่ permission ยังไม่ถูกตั้ง และขั้นตอนหลังจากนั้นไม่ได้รัน

วิธีที่ใช้ได้: ข้ามไฟล์กลุ่มนี้ไปเลย

```bash
KEEP="! -name .user.ini ! -name .htaccess ! -name 502.html"
find "$WEBROOT" -mindepth 1 $KEEP -exec chown www:www {} +
find "$WEBROOT" -mindepth 1 $KEEP -type d -exec chmod 755 {} +
find "$WEBROOT" -mindepth 1 $KEEP -type f -exec chmod 644 {} +
```

---

## 9.5 ตรวจหลัง deploy

```bash
# หน้าแรกและหน้าลูกต้องได้ 200
curl -sk --resolve DOMAIN.TLD:443:SERVER_IP https://DOMAIN.TLD/ -o /dev/null -w '%{http_code}\n'

# ไฟล์ hash ต้องได้ immutable ไม่ใช่ max-age=43200
curl -sk --resolve DOMAIN.TLD:443:SERVER_IP -I https://DOMAIN.TLD/_astro/SOMEFILE.css | grep -i cache-control
```

---

**ก่อนหน้า:** [08-decisions.md](08-decisions.md)

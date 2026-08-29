#!/usr/bin/env bash
# harden-wp.sh [--check] [--remove] - ปิดทางเข้าที่ WordPress โดนบ่อยที่สุด ทุกไซต์บนเครื่อง
#
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/harden-wp.sh --check"   # ดูอย่างเดียว
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/harden-wp.sh"           # ติดตั้ง
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/harden-wp.sh --remove"  # ถอดออก
#
# ทำอะไร:
#   1. วาง configs/wp-hardening.conf ไว้ที่ /www/server/nginx/conf/
#   2. ประกาศ limit_req zone สำหรับ wp-login.php (ระดับ http)
#   3. symlink เข้า extension/<domain>/01-hardening.conf ให้ทุกไซต์
#   4. nginx -t แล้วค่อย reload - ถ้าไม่ผ่านจะถอนทุกอย่างกลับให้เอง
#
# 🔴 เขียนขึ้นหลังเหตุการณ์จริง 2026-08-29 บน bbc29pro.com (187.52.122.249)
#
# ไทม์ไลน์ที่ไล่ได้จาก mtime:
#   23 ส.ค. 14:36  ไซต์ถูกสร้าง (WordPress 6.5.10) มีปลั๊กอิน fileorganizer 1.2.0
#   25 ส.ค. 01:12  บัญชี admin ปลอมตัวแรก yukyequw
#   25 ส.ค. 03:18  บัญชี admin_backup
#   25 ส.ค. 06:15  บัญชี user
#   25 ส.ค. 22:16  เริ่มวางไฟล์ใน wp-content/themes/.well-known/.<md5>system/
#   27 ส.ค. 06:13  วางเว็บเชลล์ชุดใหญ่ + โปรย .htaccess ของตัวเอง 199 ไฟล์
#   29 ส.ค. 13:23  ยังมีการเขียนไฟล์อยู่ = แบ็คดอร์ถูกใช้งานจริงตอนที่เข้าไปดู
#
# สิ่งที่กฎชุดนี้จะกันได้ถ้ามีตั้งแต่แรก:
#   - เชลล์ที่ wp-includes/x9d5285/index.php  -> ข้อ 3 ห้ามเรียก PHP ใน wp-includes ตรง ๆ
#   - ของที่ซ่อนใน .well-known/.<md5>system/ -> ข้อ 4 บล็อกโฟลเดอร์ซ่อน
#   - เชลล์ที่อัปผ่านช่องโหว่ไปไว้ใน uploads  -> ข้อ 2 ห้ามรัน PHP ใน uploads
#   - xmlrpc 15,217 POST/ชม. ที่ทำ CPU เต็ม   -> ข้อ 1
#
# ⚠️ กฎพวกนี้ **ไม่ได้แทนการอัปเดตปลั๊กอิน** ทางเข้ายังเปิดอยู่ถ้าปลั๊กอินมีช่องโหว่
# มันแค่ทำให้ของที่เจาะเข้ามาแล้วเอาไปใช้ต่อไม่ได้ และซื้อเวลาให้คนมาแก้ทัน

set -u

CONF=/www/server/nginx/conf/wp-hardening.conf
SRC="$(cd "$(dirname "$0")/../configs" 2>/dev/null && pwd)/wp-hardening.conf"
[ -f "$SRC" ] || SRC=/root/wpaa/configs/wp-hardening.conf
VHOST=/www/server/panel/vhost/nginx
EXT="$VHOST/extension"
ZONE="$VHOST/0.fastcgi_cache.conf"
NGINX=/www/server/nginx/sbin/nginx
BK=/root/wpaa/backups
MODE=set

case "${1:-}" in
  --check)  MODE=check ;;
  --remove) MODE=remove ;;
  "") ;;
  *) echo "ไม่รู้จักตัวเลือก: $1"; exit 1 ;;
esac

if [ "$MODE" = "remove" ]; then
  find "$EXT" -name "01-hardening.conf" -delete 2>/dev/null
  rm -f "$CONF"
  if [ -f "$ZONE" ]; then
    grep -v "wplogin" "$ZONE" > "$ZONE.tmp" && mv "$ZONE.tmp" "$ZONE"
  fi
  "$NGINX" -t && /etc/init.d/nginx reload
  echo "ถอดกฎออกหมดแล้ว"
  exit 0
fi

echo "== 1. ไฟล์กฎ =="
if [ ! -f "$SRC" ]; then
  echo "  !! หา wp-hardening.conf ไม่เจอ ($SRC) - scp configs/ ขึ้นมาก่อน"; exit 1
fi
if [ "$MODE" = "check" ]; then
  [ -f "$CONF" ] && echo "  ติดตั้งแล้ว" || echo "  ยังไม่ได้ติดตั้ง"
else
  [ -f "$CONF" ] && cp -p "$CONF" "$BK/wp-hardening.conf.bak-$(date +%F-%H%M%S)" 2>/dev/null
  mkdir -p "$BK"
  install -m 644 "$SRC" "$CONF"
  echo "  ติดตั้ง $CONF"
fi

echo
echo "== 2. limit_req zone สำหรับ wp-login (ระดับ http) =="
# ต้องประกาศนอก server block - 0.fastcgi_cache.conf ถูก include ที่ระดับ http อยู่แล้ว
if grep -q "wplogin" "$ZONE" 2>/dev/null; then
  echo "  มีอยู่แล้ว"
elif [ "$MODE" = "check" ]; then
  echo "  ยังไม่มี"
else
  cp -p "$ZONE" "$BK/0.fastcgi_cache.conf.bak-$(date +%F-%H%M%S)"
  cat >> "$ZONE" <<'NGX'

# zone สำหรับจำกัดอัตรายิง wp-login.php - ใช้โดย wp-hardening.conf
# 5r/m ต่อ IP เผื่อ burst 3 คนพิมพ์รหัสผิดไม่กระทบ บอทยิงรัวโดนหมด
limit_req_zone $binary_remote_addr zone=wplogin:10m rate=5r/m;
NGX
  echo "  เพิ่ม limit_req_zone แล้ว"
fi

echo
echo "== 3. symlink เข้าทุกไซต์ =="
n=0; have=0
for f in "$VHOST"/*.conf; do
  b=$(basename "$f" .conf)
  case "$b" in 0.*|phpmyadmin|phpfpm_status|speed|waf2monitor_data) continue ;; esac
  [ -d "/www/wwwroot/$b" ] || continue
  if [ -e "$EXT/$b/01-hardening.conf" ]; then
    have=$((have+1))
  elif [ "$MODE" = "check" ]; then
    n=$((n+1))
  else
    mkdir -p "$EXT/$b"
    ln -sf "$CONF" "$EXT/$b/01-hardening.conf"
    n=$((n+1))
  fi
done
if [ "$MODE" = "check" ]; then
  echo "  มีแล้ว $have ไซต์ · ยังขาด $n ไซต์"
  echo
  echo "โหมด --check ไม่ได้แก้อะไร"
  exit 0
fi
echo "  มีอยู่แล้ว $have ไซต์ · เพิ่มใหม่ $n ไซต์"

echo
echo "== 4. nginx -t =="
# 🔴 ห้ามเขียน `if "$NGINX" -t | tail -2; then` - exit code ที่ได้จะเป็นของ tail (0 เสมอ)
# nginx ไม่ผ่านก็ยังเข้า then แล้วสั่ง reload ทั้งที่ config พัง (เจอจริงตอนติดตั้งครั้งแรก)
NGXOUT=$("$NGINX" -t 2>&1); NGXRC=$?
printf '%s
' "$NGXOUT" | tail -2
if [ "$NGXRC" = "0" ]; then
  /etc/init.d/nginx reload
  echo "  reload แล้ว"
else
  echo "  !! ไม่ผ่าน - ถอนกลับทั้งหมด"
  find "$EXT" -name "01-hardening.conf" -delete 2>/dev/null
  rm -f "$CONF"
  grep -v "wplogin" "$ZONE" > "$ZONE.tmp" && mv "$ZONE.tmp" "$ZONE"
  "$NGINX" -t && /etc/init.d/nginx reload
  exit 1
fi

echo
echo "== 5. ทดสอบว่ากฎทำงานจริง =="
D=$(ls -1 /www/wwwroot | grep '\.' | head -1)
R="--resolve $D:443:127.0.0.1"
t() { printf '  %-42s %s\n' "$2" "$(curl -sk $R "$1" -o /dev/null -w '%{http_code}' --max-time 10)"; }
t "https://$D/xmlrpc.php"                       "xmlrpc.php (ต้อง 403)"
t "https://$D/wp-includes/version.php"          "wp-includes/*.php (ต้อง 403)"
t "https://$D/wp-config.php"                    "wp-config.php (ต้อง 403)"
t "https://$D/.env"                             ".env (ต้อง 404)"
t "https://$D/"                                 "หน้าแรก (ต้อง 200)"
echo "  --- acme-challenge ต้องยังผ่าน ไม่งั้น SSL ต่ออายุไม่ได้ ---"
mkdir -p "/www/wwwroot/$D/.well-known/acme-challenge"
echo OK > "/www/wwwroot/$D/.well-known/acme-challenge/probe"
chown -R www:www "/www/wwwroot/$D/.well-known"
printf '  %-42s %s\n' "acme-challenge (ต้อง 200)" "$(curl -s --resolve $D:80:127.0.0.1 "http://$D/.well-known/acme-challenge/probe" -o /dev/null -w '%{http_code}')"
rm -f "/www/wwwroot/$D/.well-known/acme-challenge/probe"

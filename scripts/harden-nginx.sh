#!/usr/bin/env bash
# harden-nginx.sh - ติดตั้งกฎ nginx ระดับเครื่อง ทำครั้งเดียวต่อ VPS 1 เครื่อง
#
# แก้ 2 อย่างที่ aaPanel ไม่ได้ทำมาให้:
#   1. ปิดรู default_server พอร์ต 443 (โดเมนแปลกหน้าไปโผล่เว็บลูกค้าอีกราย)
#   2. www -> non-www ที่ระดับ nginx ไม่ใช่รอ WordPress
#
# วิธีใช้ - อัปทั้งโฟลเดอร์ขึ้นเครื่องก่อน เพราะสคริปต์อ่านไฟล์จาก ../configs/
#   scp -r configs scripts root@SERVER_IP:/tmp/wpaa/
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/harden-nginx.sh"
#
# สคริปต์นี้จบที่ nginx -t เท่านั้น ไม่ reload ให้เอง - ดูผลก่อนแล้วค่อยสั่ง:
#   /etc/init.d/nginx reload

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
CONFIGS="$HERE/../configs"
VHOST=/www/server/panel/vhost/nginx
NGXCONF=/www/server/nginx/conf

for f in 0.catchall_ssl.conf common-site.conf; do
  [ -f "$CONFIGS/$f" ] || { echo "หาไฟล์ไม่เจอ: $CONFIGS/$f - อัป configs/ ขึ้นมาด้วยหรือยัง?"; exit 1; }
done

echo "== 1. cert ของ catch-all =="
# self-signed ของตัวเอง ไม่ยืม cert ของไซต์ไหน - ถ้ายืมแล้วไซต์นั้นถูกลบ nginx จะไม่สตาร์ท
if [ -f "$NGXCONF/catchall.crt" ]; then
  echo "มีอยู่แล้ว ข้าม"
else
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$NGXCONF/catchall.key" -out "$NGXCONF/catchall.crt" \
    -subj "/CN=unmatched-host" >/dev/null 2>&1
  chmod 600 "$NGXCONF/catchall.key"
  echo "สร้างแล้ว"
fi

echo "== 2. กฎกลางที่ทุกไซต์ใช้ร่วมกัน =="
install -m 644 "$CONFIGS/common-site.conf" "$NGXCONF/common-site.conf"
echo "$NGXCONF/common-site.conf"

echo "== 3. catch-all พอร์ต 443 =="
install -m 644 "$CONFIGS/0.catchall_ssl.conf" "$VHOST/0.catchall_ssl.conf"
echo "$VHOST/0.catchall_ssl.conf"

echo "== 4. ตัวช่วยสำหรับไซต์ใหม่ =="
install -m 755 "$HERE/stamp-site.sh" /root/stamp-site.sh
echo "/root/stamp-site.sh"

echo "== 5. ใส่กฎกลางให้ไซต์ที่มีอยู่แล้วทุกตัว =="
for f in "$VHOST"/*.conf; do
  b=$(basename "$f" .conf)
  case "$b" in
    0.*|phpmyadmin|phpfpm_status|speed|waf2monitor_data) continue ;;
  esac
  [ -d "/www/wwwroot/$b" ] || continue
  mkdir -p "$VHOST/extension/$b"
  ln -sf "$NGXCONF/common-site.conf" "$VHOST/extension/$b/00-common.conf"
  echo "  $b"
done

echo "== 6. nginx -t =="
/www/server/nginx/sbin/nginx -t

echo
echo "ผ่านแล้วสั่ง reload ได้:  /etc/init.d/nginx reload"

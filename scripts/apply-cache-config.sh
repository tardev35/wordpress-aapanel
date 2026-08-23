#!/usr/bin/env bash
# apply-cache-config.sh - ติดตั้งไฟล์ FastCGI cache ฉบับที่จูนแล้วทับฉบับโรงงาน
#
#   scp -r configs scripts root@SERVER_IP:/tmp/wpaa/
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/apply-cache-config.sh"
#   ssh root@SERVER_IP "/etc/init.d/nginx reload"
#
# ⚠️ ไฟล์นี้ใช้ร่วมกันทุกเว็บ PHP 8.3 - แก้ครั้งเดียวมีผลทุกเว็บพร้อมกัน
#
# ⚠️ WP Toolkit เขียนทับไฟล์นี้ได้ ยืนยันแล้วบนเครื่องอ้างอิง: ไฟล์ถูกเขียนใหม่เป็นฉบับโรงงาน
# ตอน 06:34 ซึ่งเป็นเวลาเดียวกับที่มีการเพิ่มไซต์ใหม่ **หลังเพิ่มไซต์ทุกครั้งให้รัน
# verify-config.sh** ไม่ใช่แค่หลังอัปเดต panel
#
# ถ้า nginx -t ไม่ผ่าน สคริปต์จะกู้ไฟล์เดิมกลับให้อัตโนมัติ

set -e

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../configs/enable-php-83-wpfastcgi.conf"
DST=/www/server/nginx/conf/enable-php-83-wpfastcgi.conf
BAK="$DST.bak-$(date +%F-%H%M%S)"
NGINX=/www/server/nginx/sbin/nginx

[ -f "$SRC" ] || { echo "หาไฟล์ต้นทางไม่เจอ: $SRC - อัป configs/ ขึ้นมาด้วยหรือยัง?"; exit 1; }
[ -f "$DST" ] || { echo "ไม่มี $DST บนเครื่องนี้ - ยังไม่มีเว็บไหนเปิด FastCGI cache?"; exit 1; }

if diff -q "$SRC" "$DST" >/dev/null 2>&1; then
  echo "ไฟล์ตรงกันอยู่แล้ว ไม่ต้องทำอะไร"
  exit 0
fi

echo "== สำรองของเดิม =="
cp -p "$DST" "$BAK"
echo "$BAK"

echo "== ติดตั้งฉบับที่จูนแล้ว =="
install -m 644 "$SRC" "$DST"

echo "== nginx -t =="
if "$NGINX" -t; then
  echo
  echo "ผ่าน - สั่ง reload ได้:  /etc/init.d/nginx reload"
  echo
  echo "แล้วล้าง cache ด้วย เพราะของเก่าถูกเก็บตอนกฎยังเป็นอีกแบบ:"
  echo "  bash $HERE/clear-cache.sh"
else
  echo
  echo "!! nginx -t ไม่ผ่าน - กู้ไฟล์เดิมกลับแล้ว ไม่มีอะไรเปลี่ยน"
  cp -p "$BAK" "$DST"
  "$NGINX" -t
  exit 1
fi

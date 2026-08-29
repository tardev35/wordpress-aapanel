#!/usr/bin/env bash
# stamp-site.sh <domain> - รันทุกครั้งหลังกด Add site ในแผง
#
# ทำ 2 อย่าง:
#   1. ใส่กฎกลาง (www -> non-www) ให้ไซต์ใหม่
#   2. reload nginx
#
# ข้อ 2 สำคัญกว่าที่คิด: ระหว่างที่ panel สร้าง vhost เสร็จแต่ nginx ยังไม่ reload
# โดเมนใหม่จะยังไม่มี server block ของตัวเองในคอนฟิกที่รันอยู่ ทุก request จึงตกไปที่
# default server = ได้เว็บของไซต์อื่น และถ้าไซต์นั้นเปิด FastCGI cache ไว้ HTML ของ
# เว็บผิดจะถูกเก็บใต้คีย์ของโดเมนใหม่ ค้างข้ามวัน (ดู docs/07 ข้อ 11)
#
# หลัง harden-nginx.sh ติดตั้งแล้ว จะมีสำเนาอยู่ที่ /root/stamp-site.sh ด้วย
#   ssh root@SERVER_IP "/root/stamp-site.sh newdomain.com"

set -e

d="$1"
[ -n "$d" ] || { echo "ใช้: stamp-site.sh <domain>"; exit 1; }
[ -d "/www/wwwroot/$d" ] || { echo "ไม่มีไซต์ชื่อนี้บนเครื่อง: $d"; exit 1; }

COMMON=/www/server/nginx/conf/common-site.conf
[ -f "$COMMON" ] || { echo "ยังไม่มี $COMMON - รัน harden-nginx.sh ก่อน"; exit 1; }

dir="/www/server/panel/vhost/nginx/extension/$d"
mkdir -p "$dir"
ln -sf "$COMMON" "$dir/00-common.conf"

# กฎกันเว็บโดนแฮ็ก - ห้ามรัน PHP ใน uploads, ห้ามเรียก wp-includes ตรง ๆ,
# บล็อกโฟลเดอร์ซ่อน, จำกัดอัตรายิง wp-login (ดู configs/wp-hardening.conf)
#
# ไซต์ใหม่ต้องได้ตั้งแต่วินาทีแรก - bbc29pro.com ถูกเจาะภายใน 2 วันหลังสร้าง
# (สร้าง 23 ส.ค. 14:36 -> บัญชี admin ปลอมตัวแรก 25 ส.ค. 01:12)
HARDEN=/www/server/nginx/conf/wp-hardening.conf
[ -f "$HARDEN" ] && ln -sf "$HARDEN" "$dir/01-hardening.conf"

# ปิด auto-update ให้ไซต์ใหม่ตั้งแต่ตอนนี้ ไม่ต้องรอ cron รอบ 5 ทุ่ม
#
# ทำไมรอไม่ได้: ไซต์ที่สร้างตอนเช้าจะมี auto-update เปิดอยู่ทั้งวันจนกว่า cron จะมาถึง
# และ cron ของ WordPress เองอาจยิงอัปเวอร์ชันไปก่อนในช่วงนั้น (ดู docs/08 ADR-012)
# สคริปต์ที่เรียกเป็น idempotent อยู่แล้ว จึงเรียกซ้ำได้ไม่มีผลข้างเคียง
AUTOUPD=/root/wpaa/scripts/set-wp-autoupdate.sh
if [ -x "$AUTOUPD" ]; then
  "$AUTOUPD" | grep "ปิดแล้ว" || true
fi

/www/server/nginx/sbin/nginx -t
/etc/init.d/nginx reload
echo "stamped: $d"

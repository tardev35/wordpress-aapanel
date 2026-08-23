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

/www/server/nginx/sbin/nginx -t
/etc/init.d/nginx reload
echo "stamped: $d"

#!/usr/bin/env bash
# clear-cache.sh [DOMAIN] - ล้าง FastCGI cache
#
#   bash clear-cache.sh                  # ทุกไซต์บนเครื่อง
#   bash clear-cache.sh DOMAIN.TLD       # เฉพาะไซต์เดียว
#
# ต้องรันเมื่อไหร่:
#   - เปลี่ยน setting ใน WordPress ที่มีผลกับ HTML ทุกหน้า (เช่นปลด noindex)
#   - เปิดเว็บที่เคยอยู่สถานะ Stopped ไม่งั้น cache ค้างหน้า "website has been stopped"
#   - เปลี่ยนไฟล์ enable-php-83-wpfastcgi.conf (apply-cache-config.sh เตือนให้อยู่แล้ว)
#
# ⚠️ ปลั๊กอิน Nginx Helper ล้างให้เฉพาะตอน publish/edit โพสต์
# **ไม่ล้างตอนเปลี่ยน setting** จึงต้องมาสั่งเองในเคสพวกนั้น

CACHE_DIR=$(grep -oP 'fastcgi_cache_path\s+\K[^ ]+' \
  /www/server/panel/vhost/nginx/0.fastcgi_cache.conf 2>/dev/null)
CACHE_DIR=${CACHE_DIR:-/www/server/fastcgi_cache}
NGINX=/www/server/nginx/sbin/nginx

SITE="${1:-}"

[ -d "$CACHE_DIR" ] || { echo "ไม่พบโฟลเดอร์แคช: $CACHE_DIR"; exit 1; }
before=$(find "$CACHE_DIR" -type f 2>/dev/null | wc -l)
echo "cache dir: $CACHE_DIR  (มี $before ไฟล์)"

if [ -n "$SITE" ]; then
  # cache key คือ "$scheme$request_method$host$request_uri" ชื่อโฮสต์จึงอยู่ในไฟล์
  # เลือกลบเฉพาะไฟล์ที่ KEY ตรงกับโดเมนนี้ ไซต์อื่นไม่ถูกแตะ
  n=$(grep -rlaE "^KEY: https?GET${SITE}/" "$CACHE_DIR" 2>/dev/null | tee /tmp/cc.list | wc -l)
  if [ "$n" = "0" ]; then
    echo "ไม่มีไฟล์แคชของ $SITE อยู่แล้ว"
  else
    xargs -r rm -f < /tmp/cc.list
    echo "ลบแคชของ $SITE ไป $n ไฟล์"
  fi
  rm -f /tmp/cc.list
else
  rm -rf "${CACHE_DIR:?}"/*
  echo "ลบแคชทั้งหมด ($before ไฟล์)"
fi

"$NGINX" -t >/dev/null 2>&1 && /etc/init.d/nginx reload
echo "เหลือ $(find "$CACHE_DIR" -type f 2>/dev/null | wc -l) ไฟล์"

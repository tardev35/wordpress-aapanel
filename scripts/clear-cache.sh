#!/usr/bin/env bash
# clear-cache.sh - ล้าง FastCGI cache ทั้งหมด
#
# ต้องรันหลังเปิดเว็บที่เคยอยู่สถานะ Stopped
# ไม่งั้น cache จะค้างหน้า "The website has been stopped" ไว้ 1 ชั่วโมง

CACHE_DIR=$(grep -oP 'fastcgi_cache_path\s+\K[^ ]+' \
  /www/server/panel/vhost/nginx/0.fastcgi_cache.conf 2>/dev/null)
CACHE_DIR=${CACHE_DIR:-/www/server/fastcgi_cache}

echo "cache dir: $CACHE_DIR"
rm -rf "${CACHE_DIR:?}"/*

/www/server/nginx/sbin/nginx -t && /etc/init.d/nginx reload
echo "ล้าง cache เรียบร้อย"

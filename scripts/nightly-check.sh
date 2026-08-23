#!/usr/bin/env bash
# nightly-check.sh - ตรวจและ "ซ่อมเอง" ทุกคืน ติดตั้งด้วย install-autoheal.sh
#
# ทำไมต้องมี: WP Toolkit เขียนทับ enable-php-83-wpfastcgi.conf ทุกครั้งที่เพิ่มไซต์ใหม่
# ทีมงานเพิ่มเว็บกันวันละหลายตัว ค่าที่จูนไว้จึงหลุดได้ทุกวันโดยไม่มีใครรู้
# และไซต์ใหม่ที่ไม่ได้รัน stamp-site.sh ก็จะไม่มีกฎ www redirect
#
# สคริปต์นี้ "แก้ให้เลย" ไม่ใช่แค่รายงาน เพราะวิธีแก้เป็นการเอาไฟล์ที่รู้ว่าถูกไปทับ
# ซึ่งไม่ต้องใช้วิจารณญาณ - แต่จะแตะเฉพาะตอนที่ต่างจริงเท่านั้น
#
# ต้นฉบับที่ถือว่าถูกอยู่ที่ /root/wpaa/configs/ (ไม่ใช่ /tmp ซึ่งหายตอนรีบูต)
# log: /var/log/wpaa-nightly.log

set -u

ROOT=/root/wpaa
CONFIGS="$ROOT/configs"
VHOST=/www/server/panel/vhost/nginx
NGXCONF=/www/server/nginx/conf
NGINX=/www/server/nginx/sbin/nginx
LOG=/var/log/wpaa-nightly.log
LOG_KEEP=2000

CANON="$CONFIGS/enable-php-83-wpfastcgi.conf"
LIVE="$NGXCONF/enable-php-83-wpfastcgi.conf"

changed=0
restored_cache=0

log() { echo "$(date '+%F %T %Z') $*" >> "$LOG"; }

log "=== เริ่มตรวจ ==="

# ---------- 1. FastCGI cache config ----------
if [ -f "$CANON" ] && [ -f "$LIVE" ]; then
  if ! diff -q "$CANON" "$LIVE" >/dev/null 2>&1; then
    cp -p "$LIVE" "$LIVE.bak-auto-$(date +%F-%H%M%S)"
    install -m 644 "$CANON" "$LIVE"
    changed=1
    restored_cache=1
    log "[แก้] enable-php-83-wpfastcgi.conf ถูกเขียนทับ - กู้ฉบับที่จูนแล้วกลับ"
  fi
else
  log "[เตือน] หาไฟล์เทียบไม่เจอ: $CANON หรือ $LIVE"
fi

# ---------- 2. catch-all 443 ----------
if [ ! -f "$VHOST/0.catchall_ssl.conf" ]; then
  if [ -f "$CONFIGS/0.catchall_ssl.conf" ] && [ -f "$NGXCONF/catchall.crt" ]; then
    install -m 644 "$CONFIGS/0.catchall_ssl.conf" "$VHOST/0.catchall_ssl.conf"
    changed=1
    log "[แก้] 0.catchall_ssl.conf หายไป - ติดตั้งกลับ"
  else
    log "[เตือน] 0.catchall_ssl.conf หาย และสร้างกลับเองไม่ได้ (ไม่มี cert) - รัน harden-nginx.sh"
  fi
fi

# ---------- 3. กฎกลางของแต่ละไซต์ ----------
[ -f "$NGXCONF/common-site.conf" ] || {
  [ -f "$CONFIGS/common-site.conf" ] && install -m 644 "$CONFIGS/common-site.conf" "$NGXCONF/common-site.conf" && changed=1 && log "[แก้] common-site.conf หายไป - ติดตั้งกลับ"
}

for f in "$VHOST"/*.conf; do
  b=$(basename "$f" .conf)
  case "$b" in 0.*|phpmyadmin|phpfpm_status|speed|waf2monitor_data) continue ;; esac
  [ -d "/www/wwwroot/$b" ] || continue
  if [ ! -e "$VHOST/extension/$b/00-common.conf" ]; then
    mkdir -p "$VHOST/extension/$b"
    ln -sf "$NGXCONF/common-site.conf" "$VHOST/extension/$b/00-common.conf"
    changed=1
    log "[แก้] $b ยังไม่ได้ stamp - ใส่กฎกลางให้แล้ว"
  fi
done

# ---------- 4. reload เฉพาะตอนที่มีอะไรเปลี่ยน ----------
if [ "$changed" = "1" ]; then
  if "$NGINX" -t >/dev/null 2>&1; then
    /etc/init.d/nginx reload >/dev/null 2>&1
    log "[ok] nginx -t ผ่าน reload แล้ว"
    if [ "$restored_cache" = "1" ]; then
      CACHE=$(grep -oP 'fastcgi_cache_path\s+\K[^ ]+' "$VHOST/0.fastcgi_cache.conf" 2>/dev/null)
      CACHE=${CACHE:-/www/server/fastcgi_cache}
      rm -rf "${CACHE:?}"/* 2>/dev/null
      log "[ok] ล้าง FastCGI cache เพราะกฎ cache เปลี่ยน"
    fi
  else
    log "[ล้มเหลว] nginx -t ไม่ผ่านหลังแก้ - ดูรายละเอียด:"
    "$NGINX" -t >> "$LOG" 2>&1
    log "[ล้มเหลว] ไม่ได้ reload ของเดิมยังวิ่งอยู่ - ต้องเข้าไปดูด้วยมือ"
  fi
else
  log "[ok] ไม่มีอะไรเปลี่ยน"
fi

# ---------- 5. WordPress auto-update ----------
# ไซต์ที่สร้างใหม่จะมาพร้อม auto-update เปิดอยู่เสมอ (WordPress 5.6+ เปิด major ให้เอง)
# ถ้าไม่ไล่ปิด นโยบายที่ตั้งไว้จะรั่วทีละไซต์ทุกครั้งที่ทีมเพิ่มเว็บ
# เรียกสคริปต์ตัวเดิม ไม่เขียนตรรกะซ้ำ - มันข้ามไซต์ที่ตั้งไว้แล้วและตรวจ php -l ให้เอง
if [ -x "$ROOT/scripts/set-wp-autoupdate.sh" ]; then
  newly=$("$ROOT/scripts/set-wp-autoupdate.sh" 2>&1 | grep "ปิดแล้ว" || true)
  if [ -n "$newly" ]; then
    echo "$newly" | while IFS= read -r l; do
      log "[แก้] ปิด auto-update: $(echo "$l" | awk '{print $1}')"
    done
  fi
fi

# ---------- 5. ตัด log ไม่ให้โต ----------
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt "$LOG_KEEP" ]; then
  tail -n "$LOG_KEEP" "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

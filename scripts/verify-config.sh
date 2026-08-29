#!/usr/bin/env bash
# verify-config.sh - ตรวจว่าค่าที่เอกสารอ้างไว้ยังอยู่บนเครื่องจริงหรือไม่
#
# ใช้หลังอัปเดต aaPanel ทุกครั้ง และใช้ตอนรับเครื่องใหม่มาดูแล
#
# 2026-08-23: สคริปต์นี้จับ drift ได้จริง - เครื่อง 187 มี enable-php-83-wpfastcgi.conf
# เป็นฉบับโรงงานของ WP Toolkit ทั้งไฟล์ ทั้งที่ docs/04 เขียนว่าปรับไป 4 จุดแล้ว
# แปลว่า "เขียนไว้ในเอกสาร" กับ "ทำแล้วบนเครื่อง" เป็นคนละเรื่อง ต้องรันตัวนี้ถึงจะรู้

PHPV=83
VHOST=/www/server/panel/vhost/nginx
NGXCONF=/www/server/nginx/conf
WPFCGI="$NGXCONF/enable-php-$PHPV-wpfastcgi.conf"
FAIL=0

# ต้อง "มี" pattern นี้
check() {
  local label="$1" file="$2" pattern="$3"
  printf "%-34s : " "$label"
  if [ ! -f "$file" ]; then echo "ไฟล์หาย!"; FAIL=1; return; fi
  if grep -q "$pattern" "$file"; then echo "OK"; else echo "หายไป -> กู้จาก ${file}.bak-*"; FAIL=1; fi
}

# ต้อง "ไม่มี" pattern นี้
check_absent() {
  local label="$1" file="$2" pattern="$3"
  printf "%-34s : " "$label"
  if [ ! -f "$file" ]; then echo "ไฟล์หาย!"; FAIL=1; return; fi
  if grep -q "$pattern" "$file"; then echo "ยังมีอยู่ -> ไฟล์เป็นฉบับโรงงาน"; FAIL=1; else echo "OK"; fi
}

echo "=== ตรวจ config เทียบกับที่เอกสารอ้าง ==="
echo

echo "-- FastCGI cache (docs/04) --"
check        "cache_lock"              "$WPFCGI" "fastcgi_cache_lock"
check        "cache_use_stale"         "$WPFCGI" "fastcgi_cache_use_stale"
check        "cache_valid = 1h (ไม่ใช่ 1d)" "$WPFCGI" "fastcgi_cache_valid 200 301 302 1h"
check_absent "no Cache-Control max-age=0" "$WPFCGI" "Cache-Control  *max-age=0"
check_absent "no Last-Modified header" "$WPFCGI" "add_header Last-Modified"
check        "skip /wp-json/"          "$WPFCGI" "wp-json"

echo
echo "-- PHP (docs/03) --"
check "PHP-FPM ondemand"      "/www/server/php/$PHPV/etc/php-fpm.conf" "^pm = ondemand"
check "PHP-FPM max_children 35" "/www/server/php/$PHPV/etc/php-fpm.conf" "^pm.max_children = 35"
check "OPcache enabled"       "/www/server/php/$PHPV/etc/php.ini" "^opcache.enable = 1"
check "memory_limit 256M"     "/www/server/php/$PHPV/etc/php.ini" "^memory_limit = 256M"

echo
echo "-- MariaDB (docs/03 หัวข้อ 3.4) --"
MYCNF=/etc/my.cnf
# ค่าพวกนี้ผูกกับเครื่อง 4 vCPU / 16 GB - เครื่องขนาดอื่นดูตารางใน docs/10 หัวข้อ 10.8
# แล้วแก้ทั้งเอกสารและบรรทัดพวกนี้ให้ตรงกัน
mycheck() {
  local key="$1" want="$2"
  printf "%-34s : " "$key"
  if [ ! -f "$MYCNF" ]; then echo "ไม่มี $MYCNF"; FAIL=1; return; fi
  local cur
  cur=$(grep -E "^[[:space:]]*$key[[:space:]]*=" "$MYCNF" | tail -1 | sed 's/.*=[[:space:]]*//;s/[[:space:]]*$//')
  if [ -z "$cur" ]; then echo "ไม่ได้ตั้ง (ควรเป็น $want)"; FAIL=1
  elif [ "$cur" = "$want" ]; then echo "OK ($cur)"
  else echo "เป็น $cur ควรเป็น $want"; FAIL=1; fi
}
mycheck innodb_buffer_pool_size 4096M
mycheck max_connections 200
mycheck join_buffer_size 256K
mycheck table_open_cache 2048
mycheck query_cache_size 0M

echo
echo "-- ระบบ (docs/02, docs/03) --"
check "sysctl BBR"      "/etc/sysctl.d/99-tuning.conf" "tcp_congestion_control = bbr"
check "Redis maxmemory" "/www/server/redis/redis.conf" "^maxmemory"

echo
echo "-- nginx ระดับเครื่อง (docs/02 หัวข้อ 2.8) --"
check "catch-all 443"   "$VHOST/0.catchall_ssl.conf" "listen 443 ssl default_server"
check "common-site.conf" "$NGXCONF/common-site.conf" "www"

printf "%-34s : " "all sites stamped"
MISSING=""
for f in "$VHOST"/*.conf; do
  b=$(basename "$f" .conf)
  case "$b" in 0.*|phpmyadmin|phpfpm_status|speed|waf2monitor_data) continue ;; esac
  [ -d "/www/wwwroot/$b" ] || continue
  [ -e "$VHOST/extension/$b/00-common.conf" ] || MISSING="$MISSING $b"
done
if [ -z "$MISSING" ]; then echo "OK"; else echo "ขาด ->$MISSING (รัน stamp-site.sh)"; FAIL=1; fi

printf "%-34s : " "กฎกันแฮ็ก (01-hardening)"
HMISS=""
for f in "$VHOST"/*.conf; do
  b=$(basename "$f" .conf)
  case "$b" in 0.*|phpmyadmin|phpfpm_status|speed|waf2monitor_data) continue ;; esac
  [ -d "/www/wwwroot/$b" ] || continue
  [ -e "$VHOST/extension/$b/01-hardening.conf" ] || HMISS="$HMISS $b"
done
if [ ! -f /www/server/nginx/conf/wp-hardening.conf ]; then
  echo "ยังไม่ได้ติดตั้ง -> รัน harden-wp.sh"; FAIL=1
elif [ -z "$HMISS" ]; then echo "OK"
else echo "ขาด ->$HMISS (รัน harden-wp.sh)"; FAIL=1; fi

printf "%-34s : " "WP auto-update ปิดหมด"
WPMISS=""
for c in /www/wwwroot/*/wp-config.php; do
  [ -f "$c" ] || continue
  grep -q AUTOMATIC_UPDATER_DISABLED "$c" || WPMISS="$WPMISS $(basename "$(dirname "$c")")"
done
if [ -z "$WPMISS" ]; then echo "OK"; else echo "ยังเปิดอยู่ ->$WPMISS (รัน set-wp-autoupdate.sh)"; FAIL=1; fi

echo
echo "-- งานอัตโนมัติ (docs/05) --"

# ตรวจว่า "มีอยู่และยังเป็นอยู่" ไม่ใช่แค่ "เคยติดตั้ง" - unit ที่ถูก disable ไว้
# จะเงียบเหมือนตอนทำงานปกติทุกอย่าง เพราะสคริปต์มันไม่เขียน log ตอนไม่มีอะไรทำ
for u in wpaa-newsite.path wpaa-newsite.timer; do
  printf "%-34s : " "$u"
  if ! systemctl list-unit-files "$u" >/dev/null 2>&1 || [ -z "$(systemctl list-unit-files "$u" --no-legend 2>/dev/null)" ]; then
    echo "ยังไม่ได้ติดตั้ง -> รัน install-site-watcher.sh"; FAIL=1
  elif [ "$(systemctl is-active "$u" 2>/dev/null)" = "active" ]; then
    echo "OK"
  else
    echo "ติดตั้งแล้วแต่ไม่ทำงาน -> systemctl enable --now $u"; FAIL=1
  fi
done

# ไม่ใช่เรื่องความสวยงาม - หัวหน้า panel เป็นที่แรกที่คนมองเวลาจะยืนยันว่า
# "กำลังอยู่บนเครื่องไหน" ถ้ามันโชว์ IP ของเครื่องอื่น คนจะก๊อป IP นั้นไปรันคำสั่งผิดเครื่อง
printf "%-34s : " "IP ที่หัว panel"
PIP=$(cat /www/server/panel/data/iplist.txt 2>/dev/null | tr -d '[:space:]')
RIP=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
if [ -z "$PIP" ]; then
  echo "ว่าง - panel จะไปถาม ifconfig.me เอง"
elif [ "$PIP" = "$RIP" ]; then
  echo "OK ($RIP)"
else
  echo "ไม่ตรง: panel=$PIP เครื่องจริง=$RIP -> ดู 07 ข้อ 18"; FAIL=1
fi

# ปุ่ม Purge ต้องครบ 3 ข้อที่ตรวจจากไฟล์ได้ (อีก 2 ข้ออยู่ในฐานข้อมูล - ดู fix-cache-purge.sh --check)
# ขาดข้อเดียวก็เงียบสนิท ไม่มี error ให้เห็น จึงต้องมีคนตรวจแทน
CACHEDIR=$(grep -oP 'fastcgi_cache_path \K[^ ]+' /www/server/panel/vhost/nginx/0.fastcgi_cache.conf 2>/dev/null)
CACHEDIR=${CACHEDIR:-/www/server/fastcgi_cache}

printf "%-34s : " "purge: open_basedir"
PURGEMISS=""
for c in /www/wwwroot/*/wp-config.php; do
  [ -f "$c" ] || continue
  sd=$(dirname "$c"); sb=$(basename "$sd"); ini="$sd/.user.ini"
  [ -f "$ini" ] || continue
  grep -q "$CACHEDIR" "$ini" || PURGEMISS="$PURGEMISS $sb"
done
if [ -z "$PURGEMISS" ]; then echo "OK"; else echo "ขาด ->$PURGEMISS (รัน fix-cache-purge.sh)"; FAIL=1; fi

# ข้อที่ทำให้ "เปิดปลั๊กอินแล้วยังไม่หาย" - ปลั๊กอินถูกชี้ไปลบผิดโฟลเดอร์
printf "%-34s : " "purge: cache path ใน wp-config"
PATHMISS=""
for c in /www/wwwroot/*/wp-config.php; do
  [ -f "$c" ] || continue
  sb=$(basename "$(dirname "$c")")
  p=$(grep -m1 RT_WP_NGINX_HELPER_CACHE_PATH "$c" | sed "s/.*, *'//;s/' *).*//")
  [ "$p" = "$CACHEDIR" ] || PATHMISS="$PATHMISS $sb(${p:-ไม่ได้ตั้ง})"
done
if [ -z "$PATHMISS" ]; then echo "OK ($CACHEDIR)"; else echo "ชี้ผิด ->$PATHMISS"; FAIL=1; fi

printf "%-34s : " "purge: ไฟล์ปลั๊กอิน nginx-helper"
FILEMISS=""
for c in /www/wwwroot/*/wp-config.php; do
  [ -f "$c" ] || continue
  sd=$(dirname "$c")
  [ -f "$sd/wp-content/plugins/nginx-helper/nginx-helper.php" ] || FILEMISS="$FILEMISS $(basename "$sd")"
done
if [ -z "$FILEMISS" ]; then echo "OK"; else echo "ไม่มี ->$FILEMISS"; FAIL=1; fi

printf "%-34s : " "nightly-check ตั้ง cron ไว้"
NCRON=$( { crontab -l 2>/dev/null; cat /www/server/cron/* 2>/dev/null; } | grep -c "nightly-check.sh" )
if [ "$NCRON" = "0" ]; then
  echo "ไม่มีเลย -> ดู 05 §5.1b"; FAIL=1
else
  echo "OK ($NCRON จุด)"
fi

echo
if [ "$FAIL" = "0" ]; then
  echo "ผ่านทั้งหมด"
else
  echo "!! มีค่าไม่ตรง - ดู docs ที่วงเล็บไว้ในแต่ละหมวด"
  echo "   แก้แล้วอย่าลืม /www/server/nginx/sbin/nginx -t ก่อน reload"
fi

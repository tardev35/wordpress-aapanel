#!/usr/bin/env bash
# inventory.sh - เก็บค่าจริงจากเครื่อง "อ่านอย่างเดียว" ไม่แก้อะไรทั้งสิ้น
#
# จุดประสงค์: เอาผลลัพธ์ไปเติมตาราง inventory ใน README แทนการเดา
# repo นี้ยึดหลัก "บรรยายสภาพจริง" ไม่ใช่สเปกเป้าหมาย ค่าทุกตัวจึงต้องมาจากไฟล์นี้
#
#   ssh root@SERVER_IP "bash -s" < scripts/inventory.sh
#
# ไม่แตะ MySQL เพราะต้องใส่รหัส root - ตรวจแยกด้วย docs/03 หัวข้อ "ตรวจผล"

PHPV=83
VHOST=/www/server/panel/vhost/nginx
NGXCONF=/www/server/nginx/conf
WPFCGI="$NGXCONF/enable-php-$PHPV-wpfastcgi.conf"

line() { printf '\n=== %s ===\n' "$1"; }

line "IDENTITY"
hostname
lsb_release -d 2>/dev/null | sed 's/Description:\s*//'
ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}'

line "HARDWARE"
echo "vCPU   : $(nproc)"
free -h | awk '/^Mem:/{print "RAM    : " $2 " total, " $7 " available"} /^Swap:/{print "Swap   : " $2}'
df -h / | awk 'NR==2{print "Disk   : " $2 " total, " $4 " free"}'

line "VERSIONS"
printf 'aaPanel : %s\n' "$(grep -m1 -oP "version\s*=\s*'\K[^']+" /www/server/panel/class/common.py 2>/dev/null)"
printf 'nginx   : %s\n' "$(/www/server/nginx/sbin/nginx -v 2>&1 | sed 's|.*/||')"
printf 'PHP     : %s\n' "$(ls /www/server/php/ 2>/dev/null | tr '\n' ' ')"
printf 'MariaDB : %s\n' "$(mysql --version 2>/dev/null | grep -oP 'Distrib \K[^,]+')"
printf 'Redis   : %s\n' "$(redis-cli --version 2>/dev/null | awk '{print $2}')"

line "PHP-FPM $PHPV"
grep -E '^pm |^pm\.max_children|^pm\.process_idle_timeout|^pm\.max_requests' \
  /www/server/php/$PHPV/etc/php-fpm.conf 2>/dev/null || echo "อ่านไฟล์ไม่ได้"
echo "master  : $(pgrep -cf 'php-fpm: master' 2>/dev/null || echo 0)"
echo "worker  : $(pgrep -cf 'php-fpm: pool' 2>/dev/null || echo 0)   (ondemand: ตอนว่างควรเป็น 0)"

line "PHP.INI $PHPV"
# ตั้งใจ grep แบบเห็นทุกบรรทัดที่ซ้ำ - php.ini ของเครื่องนี้มี opcache สองชุด
# (ของ aaPanel + ที่เติมทีหลัง) ค่าท้ายสุดชนะ แต่ต้องเห็นว่ามันซ้ำ
grep -nE '^(memory_limit|expose_php|opcache\.(enable|memory_consumption|max_accelerated_files))' \
  /www/server/php/$PHPV/etc/php.ini 2>/dev/null || echo "อ่านไฟล์ไม่ได้"

line "SYSCTL"
echo "bbr        : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
echo "swappiness : $(sysctl -n vm.swappiness 2>/dev/null)"
echo "99-tuning  : $([ -f /etc/sysctl.d/99-tuning.conf ] && echo present || echo MISSING)"

line "REDIS"
grep -E '^maxmemory' /www/server/redis/redis.conf 2>/dev/null || echo "maxmemory: ยังไม่ได้ตั้ง"

line "FASTCGI CACHE"
if [ -f "$WPFCGI" ]; then
  echo "cache_valid       : $(grep -oP 'fastcgi_cache_valid \K.*' "$WPFCGI" | tr -d ';')"
  echo "cache_lock        : $(grep -c 'fastcgi_cache_lock' "$WPFCGI")"
  echo "use_stale         : $(grep -c 'fastcgi_cache_use_stale' "$WPFCGI")"
  echo "max-age=0 (ควร 0) : $(grep -c 'Cache-Control  *max-age=0' "$WPFCGI")"
  echo "Last-Modified (ควร 0): $(grep -c 'add_header Last-Modified' "$WPFCGI")"
else
  echo "ไม่มีไฟล์ $WPFCGI"
fi
echo "cache on disk     : $(du -sh /www/server/fastcgi_cache 2>/dev/null | cut -f1) / $(find /www/server/fastcgi_cache -type f 2>/dev/null | wc -l) ไฟล์"

line "NGINX DEFAULT SERVER"
echo "default_server 443 : $(grep -rl 'listen 443 ssl default_server' $VHOST/*.conf 2>/dev/null | head -1 || echo 'ไม่มี -> มีรู ดู docs/02 หัวข้อ 2.8')"
echo "common-site.conf   : $([ -f $NGXCONF/common-site.conf ] && echo present || echo MISSING)"

line "SITES"
printf '%-26s %-7s %-9s %-6s %s\n' DOMAIN SSL PHP CACHE STAMPED
for f in "$VHOST"/*.conf; do
  b=$(basename "$f" .conf)
  case "$b" in 0.*|phpmyadmin|phpfpm_status|speed|waf2monitor_data) continue ;; esac
  [ -d "/www/wwwroot/$b" ] || continue
  ssl=$(grep -qE '^\s*listen 443 ssl' "$f" && echo yes || echo no)
  php=$(grep -oP 'enable-php-\K[0-9]+' "$f" | head -1)
  [ "$php" = "00" ] && php="static"
  cache=$(grep -q 'wpfastcgi' "$f" && echo yes || echo no)
  stamp=$([ -e "$VHOST/extension/$b/00-common.conf" ] && echo yes || echo NO)
  printf '%-26s %-7s %-9s %-6s %s\n' "$b" "$ssl" "$php" "$cache" "$stamp"
done

line "SECURITY"
echo "panel port : $(cat /www/server/panel/data/port.pl 2>/dev/null)"
echo "fail2ban   : $(command -v fail2ban-client >/dev/null && echo installed || echo 'not installed')"

echo
echo "เอาผลนี้ไปเทียบกับตาราง inventory ใน README.md ทีละแถว"

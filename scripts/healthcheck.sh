#!/usr/bin/env bash
# healthcheck.sh - ตรวจสถานะเซิร์ฟเวอร์
# ใช้: bash scripts/healthcheck.sh
#
# หมายเหตุ: systemctl บน aaPanel รายงานไม่ตรงความจริง
# สคริปต์นี้จึงยืนยันด้วยวิธีอื่นควบคู่ไปด้วย

PHPV=83

echo "=========================================="
echo " SYSTEM"
echo "=========================================="
lsb_release -d 2>/dev/null
uptime
echo
free -h | head -3
echo
df -h / | tail -1

echo
echo "=========================================="
echo " SERVICES (ยืนยันจากของจริง ไม่เชื่อ systemctl)"
echo "=========================================="

printf "%-14s : " "nginx"
if curl -sI http://127.0.0.1 --max-time 3 2>/dev/null | grep -q "HTTP/"; then
  echo "OK (ตอบ HTTP)"
else
  echo "FAIL"
fi

printf "%-14s : " "php-fpm-$PHPV"
if [ -S "/tmp/php-cgi-$PHPV.sock" ] && pgrep -f "php/$PHPV/etc/php-fpm.conf" >/dev/null; then
  echo "OK (socket + master process)"
else
  echo "FAIL (socket หรือ process หาย)"
fi

printf "%-14s : " "mysqld"
echo "$(systemctl is-active mysqld 2>/dev/null)"

printf "%-14s : " "redis"
echo "$(redis-cli ping 2>/dev/null || echo FAIL)"

echo
echo "=========================================="
echo " PHP-FPM (ondemand ต้องเห็นแค่ master ตอนว่าง)"
echo "=========================================="
echo "master  : $(pgrep -cf 'php-fpm: master' 2>/dev/null || echo 0)"
echo "worker  : $(pgrep -cf 'php-fpm: pool' 2>/dev/null || echo 0)"
echo "RAM     : $(ps aux | grep php-fpm | grep -v grep | awk '{sum+=$6} END {printf "%.1f MB", sum/1024}')"
echo
grep -E "^pm |^pm\.max_children|^pm\.process_idle_timeout" /www/server/php/$PHPV/etc/php-fpm.conf 2>/dev/null

echo
echo "=========================================="
echo " TUNING (ค่าที่ต้องตรวจหลังอัปเดต aaPanel)"
echo "=========================================="
echo -n "BBR             : "; sysctl -n net.ipv4.tcp_congestion_control
echo -n "swappiness      : "; cat /proc/sys/vm/swappiness
echo -n "cache_lock      : "; grep -c "fastcgi_cache_lock" /www/server/nginx/conf/enable-php-$PHPV-wpfastcgi.conf 2>/dev/null || echo "ไฟล์หาย!"
echo -n "opcache         : "; grep -c "^opcache.enable = 1" /www/server/php/$PHPV/etc/php.ini 2>/dev/null

echo
echo "หมายเหตุ: cache_lock ต้อง >= 1  (ได้ 0 = โดนเขียนทับ กู้จาก .bak-*)"
echo
echo "ตรวจ MySQL (ต้องใส่รหัสผ่าน):"
echo "  mysql -uroot -p -e \"SHOW VARIABLES LIKE 'innodb_buffer_pool_size';\""
echo "  ค่าที่ถูกต้อง: 4294967296"

#!/usr/bin/env bash
# apply-php-config.sh [PHPV] - วาง php-fpm.conf (ondemand, max_children 35) + php.ini (memory 256M + opcache)
#   จูนตาม docs/03 §3.2 (PHP-FPM) และ §3.3 (OPcache/php.ini)
#
# อ่านไฟล์จาก ../configs/ จึงต้องอัปทั้งโฟลเดอร์ก่อน:
#   scp -r configs scripts root@SERVER_IP:/tmp/wpaa/
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/apply-php-config.sh"       # PHP 8.3 (ค่าเริ่ม)
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/apply-php-config.sh 84"    # เวอร์ชันอื่น
#
# ปลอดภัย: back up ของเดิม, validate ด้วย php-fpm -t ก่อน restart, ไม่ผ่าน = ถอนกลับให้
# 🔴 ondemand คือหัวใจ - worker เกิดเมื่อมี request ตายเมื่อว่าง เว็บที่ไม่มีคนเข้ากิน RAM = 0

set -u
PHPV="${1:-83}"
HERE=$(cd "$(dirname "$0")" && pwd)
CONFIGS="$HERE/../configs"
ETC="/www/server/php/$PHPV/etc"
FPM="$ETC/php-fpm.conf"
INI="$ETC/php.ini"
SRC_FPM="$CONFIGS/php-fpm-$PHPV.conf"
SRC_INI="$CONFIGS/php-ini-$PHPV.ini"
BIN="/www/server/php/$PHPV/sbin/php-fpm"
TS=$(date +%Y%m%d-%H%M%S)

[ -d "$ETC" ] || { echo "🔴 ไม่พบ PHP $PHPV ที่ $ETC"; exit 1; }
[ -f "$SRC_FPM" ] || { echo "🔴 ไม่พบ $SRC_FPM (อัป configs/ ขึ้นมาด้วยหรือยัง?)"; exit 1; }
[ -f "$SRC_INI" ] || { echo "🔴 ไม่พบ $SRC_INI"; exit 1; }

echo "== 1. back up ของเดิม =="
cp -p "$FPM" "$FPM.bak-$TS" 2>/dev/null && echo "  $FPM.bak-$TS"
cp -p "$INI" "$INI.bak-$TS" 2>/dev/null && echo "  $INI.bak-$TS"

echo "== 2. วาง config ใหม่ =="
install -m 644 "$SRC_FPM" "$FPM"; echo "  $FPM (ondemand · max_children 35)"
install -m 644 "$SRC_INI" "$INI"; echo "  $INI (memory 256M · opcache)"

echo "== 3. validate php-fpm -t =="
if ! "$BIN" -t -y "$FPM" 2>&1 | grep -q "test is successful"; then
  echo "🔴 php-fpm -t ไม่ผ่าน — ถอนกลับของเดิม:"
  "$BIN" -t -y "$FPM"
  [ -f "$FPM.bak-$TS" ] && cp -p "$FPM.bak-$TS" "$FPM"
  [ -f "$INI.bak-$TS" ] && cp -p "$INI.bak-$TS" "$INI"
  exit 1
fi
echo "  test is successful ✅"

echo "== 4. restart php-fpm-$PHPV =="
/etc/init.d/php-fpm-$PHPV stop  >/dev/null 2>&1
sleep 2
/etc/init.d/php-fpm-$PHPV start >/dev/null 2>&1
sleep 1
[ -S "/tmp/php-cgi-$PHPV.sock" ] && echo "  socket /tmp/php-cgi-$PHPV.sock ✅" || echo "  ⚠️ ไม่พบ socket /tmp/php-cgi-$PHPV.sock"

echo
echo "== ยืนยันจากไฟล์จริง =="
grep -E "^pm =|^pm\.max_children" "$FPM" | sed 's/^/  /'
grep -E "^memory_limit" "$INI" | head -1 | sed 's/^/  /'
w=$(ps aux | grep "php-fpm: pool" | grep -v grep | wc -l)
echo "  worker ตอนนี้: $w  (ondemand: ตอนไม่มีทราฟฟิกควรเป็น 0 เห็นแต่ master)"

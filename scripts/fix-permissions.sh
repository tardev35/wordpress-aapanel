#!/usr/bin/env bash
# fix-permissions.sh - แก้ permission ของ WordPress ทุกเว็บ
#
# ปัญหาที่เคยเจอ: installer ตั้ง wp-config.php เป็น 666
# ซึ่งแปลว่าทุก user เขียนไฟล์ที่เก็บรหัสผ่าน DB ได้

echo "=== wp-config.php ก่อนแก้ ==="
find /www/wwwroot -maxdepth 2 -name "wp-config.php" -exec ls -la {} \;

read -rp "แก้เป็น 640 ทั้งหมด? (yes/no) " ans
[ "$ans" = "yes" ] || { echo "ยกเลิก"; exit 0; }

find /www/wwwroot -maxdepth 2 -name "wp-config.php" -exec chmod 640 {} \;
find /www/wwwroot -maxdepth 2 -name "wp-config.php" -exec chown www:www {} \;

echo
echo "=== หลังแก้ ==="
find /www/wwwroot -maxdepth 2 -name "wp-config.php" -exec ls -la {} \;

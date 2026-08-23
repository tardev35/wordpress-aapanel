#!/usr/bin/env bash
# check-wp-versions.sh - ดูว่าแต่ละไซต์ได้ WordPress เวอร์ชันอะไร และมาจากแพ็กเกจไหน
#
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/check-wp-versions.sh"
#
# ทำไมต้องมี: ฟอร์ม Add WordPress ของ WP Toolkit ไม่ได้ติดตั้งตามเวอร์ชันที่เลือกเสมอไป
# และ panel **ไม่ได้บันทึกว่าตอนสร้างเลือกเวอร์ชันอะไรไว้** (ตาราง wordpress_onekey
# มีแค่ prefix/user/pass/site_type) จึงตรวจย้อนหลังจากบันทึกไม่ได้ ต้องดูจากไฟล์จริง
#
# คอลัมน์ "มาจาก" อ่านแบบนี้:
#   ชื่อ .zip = แตกจากแพ็กเกจที่ panel เก็บไว้ (วันที่ไฟล์ตรงกับวันที่ข้างใน zip)
#   "โหลดสด"  = ไฟล์ถูกเขียนตอนติดตั้ง ไม่ตรงกับ zip ตัวไหน = ไปดึงตัวล่าสุดมา

PKG=/www/server/panel/data/wp_packages

declare -A ZIPDATE
for z in "$PKG"/*.zip; do
  [ -f "$z" ] || continue
  d=$(unzip -l "$z" 2>/dev/null | grep -m1 "wordpress/wp-settings.php" | awk '{print $2, $3}')
  [ -n "$d" ] && ZIPDATE["$d"]=$(basename "$z")
done

printf '%-26s %-9s %s\n' DOMAIN WP "มาจาก"
printf '%-26s %-9s %s\n' "--------------------------" "--------" "--------------------"

for d in /www/wwwroot/*/; do
  b=$(basename "$d")
  f="$d/wp-includes/version.php"
  [ -f "$f" ] || continue
  v=$(grep -m1 "wp_version =" "$f" | sed "s/.*= *.//;s/.;.*//")
  s="$d/wp-settings.php"
  sd=$(stat -c '%y' "$s" 2>/dev/null | cut -c1-16 | sed 's/ / /')
  src="${ZIPDATE[$sd]:-โหลดสด ($sd)}"
  printf '%-26s %-9s %s\n' "$b" "$v" "$src"
done

echo
echo "แพ็กเกจที่ panel เก็บไว้:"
for z in "$PKG"/*.zip; do
  [ -f "$z" ] || continue
  printf '  %-24s %s\n' "$(basename "$z")" "$(unzip -l "$z" 2>/dev/null | grep -m1 'wordpress/wp-settings.php' | awk '{print $2, $3}')"
done

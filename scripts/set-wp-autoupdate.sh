#!/usr/bin/env bash
# set-wp-autoupdate.sh [--revert] - ปิด auto-update ของ WordPress ทุกไซต์บนเครื่อง
#
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/set-wp-autoupdate.sh"
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/set-wp-autoupdate.sh --revert"
#
# ทำไมต้องมี: ตั้งแต่ WordPress 5.6 การติดตั้งใหม่จะ "เปิด auto-update ระดับ major"
# ให้เองโดยอัตโนมัติ aaPanel จึงติดตั้งเวอร์ชันที่เลือกจริง แต่ WordPress อัปตัวเองขึ้น
# ตัวล่าสุดภายในไม่กี่ชั่วโมง (ยืนยันแล้ว: เลือก 6.5.10 ตอนติดตั้ง แต่กลับมาดูเป็น 7.1 ทุกไซต์)
#
# ค่าที่ใส่คือ AUTOMATIC_UPDATER_DISABLED ซึ่งเป็นสวิตช์ใหญ่ตัวเดียว ปิดทั้ง core,
# ปลั๊กอิน, ธีม และ translation
#
# 🔴 ผลที่ตามมาที่ต้องรับให้ได้: จะไม่ได้ security patch อัตโนมัติอีกเลย
# งาน "อัปเดต WP ทุกสัปดาห์ผ่าน WP Toolkit" ใน docs/05 จึงเปลี่ยนจาก "ควรทำ" เป็น "ห้ามพลาด"
#
# สำรอง wp-config.php ทุกไฟล์ก่อนแก้เสมอ และข้ามไซต์ที่ตั้งไว้อยู่แล้ว

set -u

MODE="${1:-set}"
CONST=AUTOMATIC_UPDATER_DISABLED
PHP=/www/server/php/83/bin/php
LINE="define( '$CONST', true );"
changed=0
skipped=0

for cfg in /www/wwwroot/*/wp-config.php; do
  [ -f "$cfg" ] || continue
  site=$(basename "$(dirname "$cfg")")

  if [ "$MODE" = "--revert" ]; then
    if grep -q "$CONST" "$cfg"; then
      cp -p "$cfg" "$cfg.bak-autoupd-$(date +%F-%H%M%S)"
      grep -v "$CONST" "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
      chown www:www "$cfg"; chmod 640 "$cfg"
      printf '%-24s ถอดออกแล้ว\n' "$site"; changed=$((changed+1))
    else
      printf '%-24s ไม่มีอยู่แล้ว\n' "$site"; skipped=$((skipped+1))
    fi
    continue
  fi

  if grep -q "$CONST" "$cfg"; then
    printf '%-24s ตั้งไว้แล้ว ข้าม\n' "$site"; skipped=$((skipped+1))
    continue
  fi

  cp -p "$cfg" "$cfg.bak-autoupd-$(date +%F-%H%M%S)"

  # แทรกก่อนบรรทัดปิดท้ายมาตรฐานของ wp-config.php ไล่ลำดับจากที่เจาะจงที่สุด
  awk -v line="$LINE" '
    !done && (/That.s all, stop editing/ || /Absolute path to the WordPress directory/ || /wp-settings\.php/) {
      print "/* ปิด auto-update - ตั้งโดย scripts/set-wp-autoupdate.sh */"
      print line
      print ""
      done=1
    }
    { print }
  ' "$cfg" > "$cfg.tmp"

  # wp-config.php พังคือเว็บดับสนิท จึงตรวจ syntax ก่อนเอาไปทับของจริงเสมอ
  if grep -q "$CONST" "$cfg.tmp" && ! "$PHP" -l "$cfg.tmp" >/dev/null 2>&1; then
    rm -f "$cfg.tmp"
    printf '%-24s !! php -l ไม่ผ่าน - ไม่แตะไฟล์จริง\n' "$site"
    continue
  fi

  if grep -q "$CONST" "$cfg.tmp"; then
    mv "$cfg.tmp" "$cfg"
    chown www:www "$cfg"; chmod 640 "$cfg"
    printf '%-24s ปิดแล้ว\n' "$site"; changed=$((changed+1))
  else
    rm -f "$cfg.tmp"
    printf '%-24s !! หาจุดแทรกไม่เจอ - ต้องแก้เอง\n' "$site"
  fi
done

echo
echo "เปลี่ยน $changed ไซต์ · ข้าม $skipped ไซต์"

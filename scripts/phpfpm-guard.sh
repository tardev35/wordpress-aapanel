#!/usr/bin/env bash
# phpfpm-guard.sh - เฝ้า php-fpm ให้เว็บไม่ 502: จัดการ 3 อาการที่ aaPanel ก่อ
#   (1) config พัง  - aaPanel เขียนทับ pm.max_children เป็น non-number (เช่น "200pm...")
#   (2) master ตาย  - reload ด้วย config พังแล้ว php-fpm ดับ
#   (3) socket หาย  - restart ซ้ำ ๆ จน master ซ้อน/orphan ไม่มีตัวสร้าง socket (502 ค้าง)
#
#   bash phpfpm-guard.sh          # รันเดี่ยว (ปกติ systemd timer เรียกทุก 1 นาที)
#
# 🔴 เคสจริง 2026-08-31 ถึง 09-01 บนฟลีต aaPanel — ดู docs/07 ข้อ 3
#
# ปลอดภัย:
#   - แตะ config เฉพาะตอน php-fpm -t "ไม่ผ่าน" (backup ก่อน)
#   - ซ่อม config แล้วถ้า master+socket ยังดี = ไม่ restart (เว็บไม่สะดุด)
#   - ตอนต้อง clean restart: ฆ่า php-fpm ด้วย PID ที่ยืนยัน comm=php-fpm เท่านั้น
#     (ไม่ใช้ pkill -f ที่อาจไปแมตช์ cmdline ของ shell/สคริปต์ตัวเองแล้วฆ่าตัวเอง)
set -u
LOG=/var/log/wpaa-phpfpm-guard.log
say(){ echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; logger -t phpfpm-guard "$*" 2>/dev/null || true; }
fixed=0

for PHPV in 83 84 82 81 74; do
  F=/www/server/php/$PHPV/etc/php-fpm.conf
  BIN=/www/server/php/$PHPV/sbin/php-fpm
  SOCK=/tmp/php-cgi-$PHPV.sock
  [ -f "$F" ] && [ -x "$BIN" ] || continue
  cfg_ok(){ "$BIN" -t -y "$F" >/dev/null 2>&1; }
  master_ok(){ pgrep -f "php/$PHPV/etc/php-fpm.conf" >/dev/null 2>&1; }
  healthy(){ master_ok && [ -S "$SOCK" ]; }   # ondemand: master ต้อง listen socket เสมอ

  # 1) config พัง -> ซ่อม max_children ให้เหลือเลขล้วน (ตัด garbage ที่ merge มา)
  if ! cfg_ok; then
    cp -p "$F" "$F.guard-bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
    sed -i -E "s/^(pm\.max_children[[:space:]]*=[[:space:]]*[0-9]+).*/\1/" "$F"
    if ! cfg_ok; then say "🔴 php-fpm-$PHPV: config ยังพังหลังซ่อม max_children - ต้องดูมือ"; continue; fi
    say "php-fpm-$PHPV: config ถูกเขียนพัง (max_children) - ซ่อมไฟล์แล้ว"
    fixed=1
  fi

  # 2) สุขภาพดีอยู่ (master + socket ครบ) = จบ ไม่ต้อง restart แม้เพิ่งซ่อมไฟล์ (master ยังเสิร์ฟด้วย config เก่าในแรม)
  healthy && continue

  # 3) ไม่ดี (master ตาย / socket หาย=orphan) -> clean restart
  #    ฆ่า php-fpm ของเวอร์ชันนี้เฉพาะ PID ที่ comm=php-fpm จริง (กันฆ่า shell/สคริปต์ตัวเอง)
  for pid in $(pgrep -f "php/$PHPV/etc/php-fpm.conf" 2>/dev/null); do
    [ "$(cat /proc/$pid/comm 2>/dev/null)" = "php-fpm" ] && kill -9 "$pid" 2>/dev/null
  done
  sleep 1
  rm -f "$SOCK"                                  # ล้าง socket ค้าง กัน "Another FPM instance seems to already listen"
  /etc/init.d/php-fpm-$PHPV start >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8; do healthy && break; sleep 1; done   # master+socket ขึ้นช้าได้หลายวิ
  if healthy; then
    say "php-fpm-$PHPV: เก็บกวาด (config พัง/master ตาย/orphan socket หาย) -> clean restart คืนแล้ว"
    fixed=1
  else
    say "🔴 php-fpm-$PHPV: clean restart แล้วยังไม่มา - ต้องดูมือ"
  fi
done

[ -t 1 ] && { [ "$fixed" = 1 ] && echo "phpfpm-guard: เก็บกวาด/ซ่อมแล้ว (ดู $LOG)" || echo "phpfpm-guard: ปกติ ไม่ต้องแตะ"; }
exit 0

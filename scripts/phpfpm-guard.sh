#!/usr/bin/env bash
# phpfpm-guard.sh - เฝ้า php-fpm: ถ้า config พัง (max_children เพี้ยนเป็น non-number เพราะ
#   aaPanel เขียนทับ) หรือ master ดับ -> ซ่อม + ปลุกกลับ กันเว็บ 502 ทั้งเครื่อง
#
#   bash phpfpm-guard.sh            # ตรวจ+ซ่อมรอบเดียว (ปกติ systemd timer เรียกทุก 1 นาที)
#
# 🔴 เคสจริง 2026-08-31: aaPanel เขียนทับ php-fpm.conf ทีละเครื่อง (06:34/06:39/06:49) ทำ
#   pm.max_children กลายเป็น "200pm.process_idle_timeout = 30s" (บรรทัดติดกัน newline หาย) ->
#   php-fpm -t ไม่ผ่าน -> ดับตอน reload -> 502 ยกเครื่อง (ดู docs/07 ข้อ 3)
#
# ปลอดภัย: แตะไฟล์เฉพาะตอน php-fpm -t "ไม่ผ่าน" เท่านั้น · backup ก่อนแก้ · validate ก่อน restart
#   ถ้า master ยังรันอยู่ = แก้แค่ไฟล์ ไม่ restart (รอ reload ครั้งหน้าไม่ตาย) = ไม่ทำ 502 เอง
set -u
LOG=/var/log/wpaa-phpfpm-guard.log
say(){ echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; logger -t phpfpm-guard "$*" 2>/dev/null || true; }

fixed=0
for PHPV in 83 84 82 81 74; do
  F=/www/server/php/$PHPV/etc/php-fpm.conf
  BIN=/www/server/php/$PHPV/sbin/php-fpm
  [ -f "$F" ] && [ -x "$BIN" ] || continue
  alive(){ pgrep -f "php/$PHPV/etc/php-fpm.conf" >/dev/null 2>&1; }
  wait_alive(){ for _ in 1 2 3 4 5 6; do alive && return 0; sleep 1; done; return 1; }  # master ขึ้นช้าได้ ~ไม่กี่วิ

  if "$BIN" -t -y "$F" >/dev/null 2>&1; then
    # config ผ่าน - เหลือเช็คแค่ว่า master ยังอยู่ไหม (ondemand: ต้องเห็น master เสมอ)
    if ! alive; then
      /etc/init.d/php-fpm-$PHPV start >/dev/null 2>&1
      wait_alive && { say "php-fpm-$PHPV: master หายทั้งที่ config ดี -> start คืนแล้ว"; fixed=1; } \
                 || say "🔴 php-fpm-$PHPV: master หาย + start ไม่ขึ้น - ต้องดูมือ"
    fi
    continue
  fi

  # config พัง -> backup แล้วซ่อม pm.max_children ให้เหลือ "เลขล้วน" (ตัด garbage ที่ merge ต่อท้าย)
  cp -p "$F" "$F.guard-bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
  sed -i -E "s/^(pm\.max_children[[:space:]]*=[[:space:]]*[0-9]+).*/\1/" "$F"

  if ! "$BIN" -t -y "$F" >/dev/null 2>&1; then
    say "🔴 php-fpm-$PHPV: config ยังพังหลังซ่อม max_children - ต้องแก้มือ (docs/07 ข้อ 3)"
    continue
  fi

  if alive; then
    # master ยังรันบน config เก่าในหน่วยความจำ (ยังเสิร์ฟได้) - ทำไฟล์ให้ดีไว้ รอ reload ครั้งหน้า
    # ไม่ restart = ไม่มีช่วง 502 ระหว่างซ่อม
    say "php-fpm-$PHPV: ไฟล์ config ถูกเขียนพัง (max_children) - ซ่อมไฟล์แล้ว master ยังรัน ไม่ restart"
    fixed=1
  else
    /etc/init.d/php-fpm-$PHPV restart >/dev/null 2>&1
    wait_alive && { say "php-fpm-$PHPV: config พัง+master ดับ -> ซ่อม+restart คืนแล้ว ($(grep -m1 '^pm.max_children' "$F"))"; fixed=1; } \
               || say "🔴 php-fpm-$PHPV: ซ่อม config แล้วแต่ start ไม่ขึ้น - ต้องดูมือ"
  fi
done

# รันมือจะได้เห็นผล (ตอน timer เรียกไม่มี TTY ก็ไม่เป็นไร)
[ -t 1 ] && { [ "$fixed" = 1 ] && echo "phpfpm-guard: ซ่อม/ปลุกแล้ว (ดู $LOG)" || echo "phpfpm-guard: ทุกเวอร์ชันปกติ ไม่ต้องแตะ"; }
exit 0

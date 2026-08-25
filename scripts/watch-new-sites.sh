#!/usr/bin/env bash
# watch-new-sites.sh - stamp ไซต์ใหม่ให้เอง ไม่ต้องมีใครสั่ง
#
# ติดตั้งด้วย install-site-watcher.sh ซึ่งตั้ง systemd ให้เรียกตัวนี้ 2 ทาง:
#   wpaa-newsite.path   ตื่นทันทีที่ panel เขียน vhost = วินาทีที่กด Add site
#   wpaa-newsite.timer  ยิงทุก 1 นาที เป็นตาข่าย และเป็นตัวที่ทัน wp-config.php ซึ่งโผล่ทีหลัง
#
# เรียกมือก็ได้ ปลอดภัย เพราะมันไม่แตะอะไรถ้าไม่มีอะไรต้องแก้:
#
#   ssh root@SERVER_IP "/root/wpaa/scripts/watch-new-sites.sh"
#
# ทำไมต้องมี: ขั้นตอน "รัน stamp-site.sh หลัง Add site" ใน docs/06 เป็นขั้นที่คนลืมได้
# และลืมทีเดียวก็สาย - login-edo89.com สร้าง 00:04 ลง 6.7.7 ถูกต้อง แต่ auto-update
# ของ WordPress ยิงตัวเองขึ้น 7.1 ตอน 01:08 คือ **ห่างกันแค่ 1 ชั่วโมง**
# ส่วน nightly-check.sh ซึ่งเป็นตาข่ายอีกชั้นเพิ่งจะมาถึงตอน 23:00 ของวันนั้น = สายไป 22 ชม.
#
# ตัวนี้จึงมาปิดช่องว่างระหว่าง "กด Add site" กับ "รอบกลางคืน" - วัดจริงบนเครื่องได้
# 37 มิลลิวินาทีสำหรับ nginx reload และไม่เกิน 1 นาทีสำหรับปิด auto-update
#
# ที่ต้องเป็นเครื่องทำเอง ไม่ใช่เขียนคู่มือให้คนรัน: ทีมที่กด Add site ไม่ได้ใช้ cmd/ssh
# ทางแก้ที่จบด้วย "แล้วให้รันคำสั่งนี้ด้วย" คือการย้ายงานไปวางบนคนที่ทำไม่ได้
#
# ไม่ต้องมีไฟล์จำสถานะ - มันอ่านจากของจริงว่าไซต์ไหน "ยังขาด" อยู่ จึงกู้ตัวเองได้
# ถ้า panel เขียนทับ หรือถ้าเครื่องดับไปตอนกลางคัน

set -u

VHOST=/www/server/panel/vhost/nginx
EXT="$VHOST/extension"
STAMP=/root/stamp-site.sh
AUTOUPD=/root/wpaa/scripts/set-wp-autoupdate.sh
CLEARCACHE=/root/wpaa/scripts/clear-cache.sh
CONST=AUTOMATIC_UPDATER_DISABLED
LOG=/var/log/wpaa-newsite.log
LOG_KEEP=2000

log() { echo "$(date '+%F %T %Z') $*" >> "$LOG"; }

# ยิงบ่อยมาก จึง "เงียบเมื่อไม่มีอะไรทำ" เสมอ ไม่งั้น log จะโตวันละ 1440 บรรทัด
# โดยไม่มีข้อมูลอะไรเลย - log ว่างแปลว่าไม่มีไซต์ไหนหลุด ไม่ใช่ว่ามันไม่ทำงาน
acted=0

[ -x "$STAMP" ] || { log "!! ไม่มี $STAMP - รัน harden-nginx.sh ก่อน"; exit 1; }

for dir in /www/wwwroot/*/; do
  d=$(basename "$dir")
  [ "$d" = "default" ] && continue

  # เงื่อนไขว่า "เป็นไซต์จริงที่ panel สร้างเสร็จแล้ว" ไม่ใช่โฟลเดอร์ที่ใครมาวางไว้เอง
  # ถ้าไม่กันตรงนี้ stamp-site.sh จะไป ln โฟลเดอร์มั่ว ๆ เข้า vhost
  [ -f "$VHOST/$d.conf" ] || continue

  # ---------- ยังไม่เคย stamp เลย ----------
  # stamp-site.sh ทำทั้งกฎ www, ปิด auto-update และ reload ให้ในตัว จึงจบในรอบเดียว
  if [ ! -e "$EXT/$d/00-common.conf" ]; then
    acted=1
    log "ไซต์ใหม่ $d - ยังไม่มี 00-common.conf จึง stamp ให้"
    if out=$("$STAMP" "$d" 2>&1); then
      log "  สำเร็จ | $(echo "$out" | tr '\n' '|')"
      # ล้างแคชของโดเมนนี้ทิ้งเป็นประกัน ลบเฉพาะไฟล์ที่ KEY ตรงโดเมนนี้ ไซต์อื่นไม่ถูกแตะ
      #
      # ปกติไม่มีอะไรให้ล้าง เพราะคนที่เปิดโดเมนก่อน nginx reload จะไปโดน catch-all
      # ซึ่ง return 404 ตรง ๆ ไม่มี fastcgi_pass จึงป้อนแคชไม่ได้ (08 ADR-011)
      # บรรทัดนี้คือชั้นที่กันไว้เผื่อวันที่ catch-all หลุด ซึ่งขยะจะค้างตาม
      # fastcgi_cache_valid = 1 วัน (ดู 07 ข้อ 11)
      [ -x "$CLEARCACHE" ] && log "  $("$CLEARCACHE" "$d" 2>&1 | tail -2 | tr '\n' '|')"
    else
      log "  !! ไม่สำเร็จ | $(echo "$out" | tr '\n' '|')"
    fi
    continue
  fi

  # ---------- stamp แล้ว แต่ WordPress เพิ่งมาลงทีหลัง ----------
  # เคสจริง: สร้างไซต์เปล่าก่อน (ยังไม่มี wp-config.php) แล้วค่อยลง WP ทีหลัง
  # รอบแรก stamp ไปตอนที่ยังไม่มี WordPress ให้ปิด จึงต้องมาปิดตอนนี้
  # เรียก set-wp-autoupdate.sh ตรง ๆ ไม่ผ่าน stamp-site.sh เพราะไม่ต้อง reload nginx ซ้ำ
  cfg="$dir/wp-config.php"
  if [ -f "$cfg" ] && ! grep -q "$CONST" "$cfg"; then
    acted=1
    log "ไซต์ $d - เพิ่งมี wp-config.php และ auto-update ยังเปิดอยู่ จึงปิดให้"
    out=$("$AUTOUPD" 2>&1)
    log "  $(echo "$out" | grep -- "$d" || echo "$out" | tr '\n' '|')"
  fi
done

if [ "$acted" = 1 ] && [ -f "$LOG" ]; then
  tail -n "$LOG_KEEP" "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

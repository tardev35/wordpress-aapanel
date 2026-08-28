#!/usr/bin/env bash
# watch-new-sites.sh - stamp ไซต์ใหม่ให้เอง ไม่ต้องมีใครสั่ง
#
# ติดตั้งด้วย install-site-watcher.sh ซึ่งตั้ง systemd ให้เรียกตัวนี้ 2 ทาง:
#   wpaa-newsite.path   ตื่นทันทีที่ panel เขียน vhost = วินาทีที่กด Add site
#   wpaa-newsite.timer  ยิงทุก 1 นาที เป็นตาข่าย และเป็นตัวที่ทัน wp-config.php ซึ่งโผล่ทีหลัง
#
# ซ่อม 3 อย่าง ทั้งหมดคือของที่ WP Toolkit ทำพังตอนเพิ่มไซต์:
#   0. enable-php-83-wpfastcgi.conf ถูกเขียนทับเป็นฉบับโรงงาน
#   1. ไซต์ใหม่ยังไม่มีกฎกลาง (00-common.conf) และ nginx ยังไม่ reload
#   2. ไซต์ใหม่เปิด auto-update ของ WordPress ค้างไว้
#   3. ไซต์ใหม่ล้างแคชจากหน้า WP ไม่ได้ เพราะ open_basedir กั้น PHP ไว้ (fix-cache-purge.sh)
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
FIXPURGE=/root/wpaa/scripts/fix-cache-purge.sh
CACHEDIR=/www/server/fastcgi_cache
CONST=AUTOMATIC_UPDATER_DISABLED
CANON=/root/wpaa/configs/enable-php-83-wpfastcgi.conf
LIVE=/www/server/nginx/conf/enable-php-83-wpfastcgi.conf
NGINX=/www/server/nginx/sbin/nginx
LOG=/var/log/wpaa-newsite.log
LOG_KEEP=2000

log() { echo "$(date '+%F %T %Z') $*" >> "$LOG"; }

# ยิงบ่อยมาก จึง "เงียบเมื่อไม่มีอะไรทำ" เสมอ ไม่งั้น log จะโตวันละ 1440 บรรทัด
# โดยไม่มีข้อมูลอะไรเลย - log ว่างแปลว่าไม่มีไซต์ไหนหลุด ไม่ใช่ว่ามันไม่ทำงาน
acted=0

[ -x "$STAMP" ] || { log "!! ไม่มี $STAMP - รัน harden-nginx.sh ก่อน"; exit 1; }

# ---------- 0. คอนฟิก FastCGI cache ที่ WP Toolkit เขียนทับทุกครั้งที่เพิ่มไซต์ ----------
#
# ตรรกะเดียวกับ nightly-check.sh ข้อ 1 แต่มาอยู่ตรงนี้เพราะ path unit ตื่นตอน panel
# เขียน vhost ซึ่งเป็น "จังหวะเดียวกัน" กับที่ WP Toolkit ทับไฟล์นี้พอดี รอถึงรอบกลางคืน
# แปลว่าเว็บทั้งเครื่องวิ่งด้วยฉบับโรงงานได้นานสุด 23 ชั่วโมง (เกิดจริงบน 187.52.122.249
# เมื่อ 2026-08-25: เพิ่มเว็บชุดใหญ่ตอนเช้า ไฟล์เป็นฉบับโรงงานยาวถึงเที่ยง)
#
# ต่างจาก nightly-check.sh ตรงที่ **ถ้า nginx -t ไม่ผ่านจะเอาของเดิมกลับ** ไม่ใช่แค่ไม่ reload
# เพราะตัวนี้ยิงทุกนาที ถ้าปล่อยไฟล์ที่ nginx -t ไม่ผ่านค้างไว้ reload ครั้งถัดไป
# ไม่ว่าจะมาจากใคร (panel ต่ออายุ SSL, stamp-site.sh) จะพังตามไปด้วย
if [ -f "$CANON" ] && [ -f "$LIVE" ] && ! diff -q "$CANON" "$LIVE" >/dev/null 2>&1; then
  acted=1
  bak="$LIVE.bak-auto-$(date +%F-%H%M%S)"
  # เวลาที่ WP Toolkit เขียนทับไฟล์ = จุดเริ่มของช่วงที่กฎ cache ผิด
  # ไฟล์แคชที่เกิดหลังจากนี้เท่านั้นที่ถูกเก็บด้วยกฎโรงงาน ที่เก่ากว่านั้นยังถูกต้อง
  drift_ts=$(stat -c %Y "$LIVE" 2>/dev/null || echo 0)
  cp -p "$LIVE" "$bak"
  install -m 644 "$CANON" "$LIVE"
  if "$NGINX" -t >/dev/null 2>&1; then
    /etc/init.d/nginx reload >/dev/null 2>&1
    # ต้องล้างแคชด้วย เพราะของที่ค้างอยู่ถูกเก็บตอนกฎยังเป็นอีกแบบ
    # (ฉบับโรงงานเก็บ 200 ไว้ 1 วัน และแนบ Cache-Control: max-age=0 ไปให้เบราว์เซอร์)
    # ล้างเฉพาะไฟล์ที่เกิดระหว่างที่กฎยังผิด ไม่ล้างทั้งเครื่อง
    #
    # 🔴 เคยล้างทั้งเครื่องแล้วเจอของจริง 2026-08-28 00:55 UTC: ทีมเพิ่มไซต์ตอนที่มี
    # ทราฟฟิก ~50,000 request/ชม. แคชของ 145 ไซต์หายพร้อมกัน ทุก request จึงวิ่งเข้า PHP
    # PHP-FPM เต็ม 35 worker แล้ว load พุ่งเป็น 11.95 บนเครื่อง 4 cores
    #
    # ช่วงที่กฎผิดจริง ๆ สั้นมาก (ไม่กี่วินาทีถึงหนึ่งนาที) จำนวนไฟล์ที่ต้องล้างจึงน้อย
    CACHE=$(grep -oP 'fastcgi_cache_path\s+\K[^ ]+' "$VHOST/0.fastcgi_cache.conf" 2>/dev/null)
    CACHE=${CACHE:-/www/server/fastcgi_cache}
    if [ "$drift_ts" -gt 0 ]; then
      n=$(find "$CACHE" -type f -newermt "@$drift_ts" 2>/dev/null | wc -l)
      find "$CACHE" -type f -newermt "@$drift_ts" -delete 2>/dev/null
      log "[แก้] enable-php-83-wpfastcgi.conf ถูกเขียนทับ - กู้กลับ reload แล้ว ล้างแคชเฉพาะช่วงที่กฎผิด $n ไฟล์ (เหลือ $(find "$CACHE" -type f 2>/dev/null | wc -l))"
    else
      log "[แก้] enable-php-83-wpfastcgi.conf ถูกเขียนทับ - กู้กลับ reload แล้ว (หาเวลาอ้างอิงไม่ได้ ไม่ล้างแคช)"
    fi
  else
    cp -p "$bak" "$LIVE"
    log "[ล้มเหลว] กู้ config แล้ว nginx -t ไม่ผ่าน - เอาของเดิมกลับ ไม่ได้ reload"
    "$NGINX" -t >> "$LOG" 2>&1
  fi
fi

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

  # ---------- ปุ่ม Purge ในหน้า WP ต้องล้างแคชได้จริง ----------
  #
  # aaPanel ใส่ .user.ini ล็อก open_basedir ให้ PHP อยู่แต่ในโฟลเดอร์ไซต์ตัวเอง
  # ปลั๊กอิน Nginx Helper จึงลบไฟล์ใน /www/server/fastcgi_cache ไม่ได้ ปุ่มกดแล้วเงียบ
  # ไม่มี error ให้เห็น ทีมจึงกดซ้ำแล้วสรุปว่า "แคชมันดื้อ" (เจอจริง 2026-08-25)
  #
  # เช็คถูก ๆ ตรงนี้ก่อน แล้วค่อยเรียกสคริปต์เต็มเฉพาะไซต์ที่ยังขาด เพราะตัวนั้น
  # ต้องต่อ MySQL ทีละไซต์ ไม่คุ้มจะเรียกทุกนาที
  # ต้องมี wp-config.php ด้วย - ไซต์ static (docs/09) ไม่มีปลั๊กอินให้ล้างแคช
  # และ fix-cache-purge.sh ก็ข้ามมันอยู่แล้ว ถ้าไม่กันตรงนี้จะวนเรียกทุกนาทีไม่จบ
  # (เจอจริงกับ sclass88-member.com ซึ่งเป็นเว็บ Astro)
  # เช็ค 2 อย่างที่ดูจากไฟล์ได้เร็ว ๆ ก่อน แล้วค่อยเรียกสคริปต์เต็มซึ่งต้องต่อ MySQL
  #
  # ที่ต้องดูไฟล์ปลั๊กอินด้วย: ทีมใช้ all-in-one-wp-migration import ไซต์ทับกันบ่อย
  # ซึ่งเขียนทับทั้ง wp-content และฐานข้อมูล = ปลั๊กอินหายและค่าที่ตั้งไว้หายไปพร้อมกัน
  # ส่วน .user.ini อยู่นอก wp-content จึงรอดทุกครั้ง ถ้าดูแค่ตัวนั้นจะไม่มีวันเจอ
  # (เจอจริง 2026-08-27: ไซต์เสียปลั๊กอินเพิ่มทีละ 1-3 ตัวระหว่างวัน)
  ini="$dir/.user.ini"
  need_purgefix=0
  [ -f "$ini" ] && ! grep -q "$CACHEDIR" "$ini" && need_purgefix=1
  [ -f "$dir/wp-content/plugins/nginx-helper/nginx-helper.php" ] || need_purgefix=1
  if [ -x "$FIXPURGE" ] && [ -f "$dir/wp-config.php" ] && [ "$need_purgefix" = 1 ]; then
    acted=1
    log "ไซต์ $d - ปุ่ม Purge ยังใช้ไม่ได้ (open_basedir หรือไฟล์ปลั๊กอินหาย)"
    log "  $("$FIXPURGE" "$d" 2>&1 | grep -- "$d" || echo '(ไม่มีผลลัพธ์)')"
  fi

  # ---------- ปุ่ม Purge ถูกตั้งกลับเป็น get_request ----------
  #
  # ค่าที่ตั้งไว้ถอยกลับได้ ถ้ามีคนเปิดหน้า Settings ของ Nginx Helper แล้วกด Save
  # (ฟอร์มส่งค่า default ซึ่งคือ get_request) หรือถ้าไซต์ถูก import ทับ
  # เจอจริง 2026-08-28: 7 จาก 200 ไซต์ถอยกลับ ยิง /purge/ ออกไปรวมกันเกือบหมื่นครั้ง
  #
  # ไม่เช็คค่าในฐานข้อมูลทุกนาที เพราะต้องต่อ MySQL ทีละไซต์ - ใช้ "เสียงร้อง" แทน:
  # get_request จะยิง /purge/... ซึ่ง nginx ปฏิเสธแล้วเขียนลง error log ทันที
  # จับจากตรงนั้นถูกกว่ามาก และเลิกเองเมื่อค่าถูกแก้แล้ว
  elog="/www/wwwlogs/$d.error.log"
  if [ -x "$FIXPURGE" ] && [ -f "$elog" ] && [ -n "$(find "$elog" -mmin -2 2>/dev/null)" ]      && tail -50 "$elog" 2>/dev/null | grep -q 'access forbidden by rule.*GET /purge/'; then
    acted=1
    log "ไซต์ $d - ยิง /purge/ แล้วโดนปฏิเสธ = purge_method ถอยกลับเป็น get_request"
    log "  $("$FIXPURGE" "$d" 2>&1 | grep -- "$d" || echo '(ไม่มีผลลัพธ์)')"
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

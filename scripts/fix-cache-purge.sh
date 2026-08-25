#!/usr/bin/env bash
# fix-cache-purge.sh [--check] [DOMAIN] - ทำให้ปุ่ม Purge ในหน้า WP ล้างแคชได้จริง
#
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/fix-cache-purge.sh"          # ทุกไซต์
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/fix-cache-purge.sh --check"  # ดูอย่างเดียว
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/fix-cache-purge.sh DOMAIN"   # ไซต์เดียว
#
# ทำไมต้องมี: ปลั๊กอิน Nginx Helper มีทางล้างแคชให้เลือก 2 ทาง และบนเครื่องที่ตั้งตาม
# คู่มือนี้ **ตันทั้งสองทาง** ปุ่มจึงกดได้ ไม่มี error แต่ไม่มีอะไรถูกลบ
#
#   1. "Using a GET request to PURGE/URL" - PHP ยิง HTTP ไปที่ตัวเอง แล้ว nginx ลบให้
#      ตัน: location /purge ตั้ง `allow 127.0.0.1; deny all;` แต่ไซต์อยู่หลัง Cloudflare
#      PHP จึง resolve ได้ IP ของ Cloudflare คำขอวิ่งออกนอกเครื่องแล้ววนกลับ
#      ต้นทางไม่ใช่ 127.0.0.1 อีกต่อไป -> โดน deny (Cloudflare ตอบ 403 ให้ด้วยซ้ำ)
#
#   2. "Delete local server cache files" - PHP ลบไฟล์ตรง ๆ
#      ตัน: aaPanel ใส่ .user.ini ล็อก open_basedir ให้ PHP อยู่แต่ในโฟลเดอร์ไซต์ตัวเอง
#      -> "open_basedir restriction in effect. File(/www/server/fastcgi_cache/...)"
#
# สคริปต์นี้เปิดทาง 2 ให้ใช้ได้ โดยเติม path ของโฟลเดอร์แคชเข้า open_basedir
# แล้วตั้ง purge_method ของปลั๊กอินให้เป็น unlink_files
#
# ⚠️ ผลข้างเคียงที่ต้องรับ: PHP ของไซต์หนึ่งอ่าน/ลบไฟล์แคชของไซต์อื่นบนเครื่องเดียวกันได้
# เพราะทุกไซต์ใช้โฟลเดอร์แคชร่วมกัน - รับได้เมื่อทุกเว็บเป็นของเจ้าของเดียวกัน
# ถ้าวันหนึ่งเครื่องนี้ขายพื้นที่ให้คนนอก ต้องกลับมาทบทวนข้อนี้
#
# .user.ini ถูก aaPanel ตั้ง chattr +i ไว้ ต้องถอดก่อนแก้แล้วใส่กลับ (ดู docs/07 ข้อ 12)

set -u

CACHE=/www/server/fastcgi_cache
BK=/root/wpaa/backups
PHP=/www/server/php/83/bin/php
TS=$(date +%F-%H%M%S)
MODE=set
ONLY=""

for a in "$@"; do
  case "$a" in
    --check) MODE=check ;;
    -*) echo "ไม่รู้จักตัวเลือก: $a"; exit 1 ;;
    *) ONLY="$a" ;;
  esac
done

[ -d "$CACHE" ] || { echo "ไม่มีโฟลเดอร์แคช $CACHE - ไซต์ยังไม่ได้เปิด FastCGI cache?"; exit 1; }
mkdir -p "$BK"

ini_changed=0
db_changed=0

for d in /www/wwwroot/*/; do
  b=$(basename "$d")
  [ "$b" = "default" ] && continue
  [ -n "$ONLY" ] && [ "$b" != "$ONLY" ] && continue
  [ -f "$d/wp-config.php" ] || continue

  printf '%-24s ' "$b"
  msg=""

  # ---------- 1. open_basedir ----------
  ini="$d/.user.ini"
  if [ ! -f "$ini" ]; then
    msg="$msg ไม่มี.user.ini"
  elif grep -q "$CACHE" "$ini"; then
    msg="$msg ini:มีแล้ว"
  elif [ "$MODE" = "check" ]; then
    msg="$msg ini:ยังขาด"
  else
    cur=$(cat "$ini")
    cp -p "$ini" "$BK/$b.user.ini.bak-$TS"   # สำรองนอก web root เสมอ
    chattr -i "$ini" 2>/dev/null
    # ไม่ใช้ sed -i กับไฟล์ config (กฎข้อ 2 ใน README) เขียนทับทั้งไฟล์แทน
    printf '%s\n' "${cur%$'\n'}:$CACHE/" > "$ini"
    chown www:www "$ini"; chmod 644 "$ini"
    chattr +i "$ini" 2>/dev/null
    ini_changed=$((ini_changed+1))
    msg="$msg ini:เติมให้แล้ว"
  fi

  # ---------- 2. purge_method ของปลั๊กอิน ----------
  DB=$(grep -m1 "DB_NAME"     "$d/wp-config.php" | sed "s/.*'DB_NAME', *'//;s/'.*//")
  DU=$(grep -m1 "DB_USER"     "$d/wp-config.php" | sed "s/.*'DB_USER', *'//;s/'.*//")
  DP=$(grep -m1 "DB_PASSWORD" "$d/wp-config.php" | sed "s/.*'DB_PASSWORD', *'//;s/'.*//")
  PFX=$(grep -m1 'table_prefix' "$d/wp-config.php" | sed "s/.*= *'//;s/'.*//")
  q() { mysql -u"$DU" -p"$DP" "$DB" -Nse "$1" 2>/dev/null; }

  OPT=$(q "select option_value from ${PFX}options where option_name='rt_wp_nginx_helper_options';")
  if [ -z "$OPT" ]; then
    msg="$msg | db:ไม่มี nginx-helper"
  else
    case "$OPT" in
      *'"purge_method";s:12:"unlink_files"'*) msg="$msg | db:ตั้งแล้ว" ;;
      *)
        if [ "$MODE" = "check" ]; then
          msg="$msg | db:ยังเป็น get_request"
        else
          # แก้ผ่าน PHP เพราะเป็น serialized array - แก้ด้วย sed จะทำให้ตัวเลขความยาวเพี้ยน
          # แล้ว unserialize ไม่ออก = ปลั๊กอินกลับไปใช้ค่า default เงียบ ๆ
          NEW=$(OPT="$OPT" "$PHP" -r '
            $a = @unserialize(getenv("OPT"));
            if (!is_array($a)) { exit(1); }
            $a["enable_purge"]  = "1";
            $a["cache_method"]  = "enable_fastcgi";
            $a["purge_method"]  = "unlink_files";
            echo base64_encode(serialize($a));
          ' 2>/dev/null)
          if [ -z "$NEW" ]; then
            msg="$msg | db:!! unserialize ไม่ผ่าน ไม่แตะ"
          else
            q "update ${PFX}options set option_value=FROM_BASE64('$NEW') where option_name='rt_wp_nginx_helper_options';"
            # WordPress อ่าน option จาก cache ของตัวเองด้วย ล้าง transient ที่ค้างทิ้ง
            q "delete from ${PFX}options where option_name like '_transient_%rt_wp_nginx%';"
            db_changed=$((db_changed+1))
            msg="$msg | db:เปลี่ยนเป็น unlink_files"
          fi
        fi
        ;;
    esac
  fi

  echo "$msg"
done

echo
if [ "$MODE" = "check" ]; then
  echo "โหมด --check ไม่ได้แก้อะไร"
  exit 0
fi

echo "แก้ .user.ini $ini_changed ไซต์ · แก้ค่าปลั๊กอิน $db_changed ไซต์"

if [ "$ini_changed" != "0" ]; then
  # .user.ini ถูก PHP cache ไว้ตาม user_ini.cache_ttl (default 300 วิ) reload ให้มีผลทันที
  echo "== reload php-fpm =="
  /etc/init.d/php-fpm-83 reload
fi

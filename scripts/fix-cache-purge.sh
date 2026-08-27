#!/usr/bin/env bash
# fix-cache-purge.sh [--check] [DOMAIN] - ทำให้ปุ่ม Purge ในหน้า WP ล้างแคชได้จริง
#
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/fix-cache-purge.sh --check"     # ดูอย่างเดียว
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/fix-cache-purge.sh"             # แก้จริงทุกไซต์
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/fix-cache-purge.sh DOMAIN"      # ไซต์เดียว
#
# ต้องครบ 5 ข้อ ปุ่มถึงจะล้างแคชได้จริง ขาดข้อเดียวก็เงียบสนิทไม่มี error ให้เห็น:
#
#   1. wp-config มี RT_WP_NGINX_HELPER_CACHE_PATH ชี้ไป **โฟลเดอร์ที่ nginx ใช้จริง**
#   2. .user.ini เปิด open_basedir ให้ PHP แตะโฟลเดอร์นั้นได้
#   3. ไฟล์ปลั๊กอิน nginx-helper อยู่ในไซต์
#   4. ปลั๊กอินถูก activate
#   5. purge_method = unlink_files (ไม่ใช่ get_request)
#
# ทำไมต้องมีทั้ง 5: เจอมาแล้วทีละข้อบนเครื่องจริง (2026-08-25 ถึง 2026-08-27)
#
#   ข้อ 5 - get_request ยิง HTTP ไปหาตัวเอง แต่ location /purge ตั้ง allow 127.0.0.1
#           ไซต์อยู่หลัง Cloudflare คำขอจึงวนออกไปกลับมาด้วย IP อื่น -> โดน deny
#   ข้อ 2 - aaPanel ล็อก open_basedir ไว้ที่โฟลเดอร์ไซต์ PHP จึง unlink ไม่ได้
#           -> "open_basedir restriction in effect"
#   ข้อ 1 - 97 จาก 136 ไซต์บน 187.52.122.249 ชี้ไป /dev/shm/nginx-cache/wp
#           ซึ่ง **ว่างเปล่า** ส่วน nginx เก็บจริงที่ /www/server/fastcgi_cache
#           ปลั๊กอินจึงลบไฟล์ในโฟลเดอร์ที่ไม่มีอะไรอยู่ สำเร็จทุกครั้ง แต่ไม่มีผล
#   ข้อ 3-4 - 60 ไซต์ปิดปลั๊กอินไว้ ใน 60 นั้น 48 ไซต์ไม่มีไฟล์ปลั๊กอินด้วยซ้ำ
#             (หลายไซต์เปิด litespeed-cache แทน ซึ่งไม่แคชอะไรเลยบนเครื่องที่ใช้ nginx)
#
# ⚠️ ผลข้างเคียงของข้อ 2: ทุกไซต์ใช้โฟลเดอร์แคชร่วมกัน การเปิด open_basedir แปลว่า
# PHP ของไซต์หนึ่งอ่าน/ลบไฟล์แคชของไซต์อื่นได้ - รับได้เมื่อทุกเว็บเป็นของเจ้าของเดียวกัน
# ถ้าวันหนึ่งเครื่องนี้ขายพื้นที่ให้คนนอก ต้องกลับมาทบทวนข้อนี้
#
# .user.ini ถูก aaPanel ตั้ง chattr +i ไว้ ต้องถอดก่อนแก้แล้วใส่กลับ (ดู docs/07 ข้อ 12)

set -u

BK=/root/wpaa/backups
PHP=/www/server/php/83/bin/php
PLUG=nginx-helper/nginx-helper.php
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

# ถามจาก nginx เองว่าเก็บแคชที่ไหน ไม่ใช่เขียนตายตัว - ถ้าวันหนึ่งย้ายไป RAM (docs/04 4.6)
# สคริปต์นี้จะตามไปเอง
CACHE=$(grep -oP 'fastcgi_cache_path \K[^ ]+' /www/server/panel/vhost/nginx/0.fastcgi_cache.conf 2>/dev/null)
CACHE=${CACHE:-/www/server/fastcgi_cache}
[ -d "$CACHE" ] || { echo "ไม่มีโฟลเดอร์แคช $CACHE"; exit 1; }
echo "โฟลเดอร์แคชที่ nginx ใช้จริง: $CACHE"
echo

mkdir -p "$BK"

# หาไซต์ที่มีไฟล์ปลั๊กอินอยู่แล้ว ไว้ใช้เป็นต้นแบบคัดลอกให้ไซต์ที่ยังไม่มี
DONOR=""
for f in /www/wwwroot/*/wp-content/plugins/nginx-helper/nginx-helper.php; do
  [ -f "$f" ] && { DONOR=$(dirname "$f"); break; }
done

n_path=0; n_ini=0; n_files=0; n_act=0; n_opt=0

for d in /www/wwwroot/*/; do
  b=$(basename "$d")
  [ "$b" = "default" ] && continue
  [ -n "$ONLY" ] && [ "$b" != "$ONLY" ] && continue
  [ -f "$d/wp-config.php" ] || continue

  printf '%-26s' "$b"
  msg=""

  # ---------- 1. RT_WP_NGINX_HELPER_CACHE_PATH ----------
  cfg="$d/wp-config.php"
  curpath=$(grep -m1 RT_WP_NGINX_HELPER_CACHE_PATH "$cfg" | sed "s/.*, *'//;s/' *).*//")
  if [ "$curpath" = "$CACHE" ]; then
    msg="$msg path:OK"
  elif [ "$MODE" = "check" ]; then
    msg="$msg path:${curpath:-ไม่ได้ตั้ง}"
  else
    cp -p "$cfg" "$BK/$b.wp-config.bak-$TS"
    tmp="$cfg.tmp"
    if [ -n "$curpath" ]; then
      awk -v c="$CACHE" '
        /RT_WP_NGINX_HELPER_CACHE_PATH/ { print "define( \047RT_WP_NGINX_HELPER_CACHE_PATH\047, \047" c "\047 );"; next }
        { print }' "$cfg" > "$tmp"
    else
      awk -v c="$CACHE" '
        !done && (/That.s all, stop editing/ || /wp-settings\.php/) {
          print "define( \047RT_WP_NGINX_HELPER_CACHE_PATH\047, \047" c "\047 );"; done=1 }
        { print }' "$cfg" > "$tmp"
    fi
    # wp-config พังคือเว็บดับสนิท ตรวจ php -l ก่อนเอาไปทับเสมอ
    if grep -q "$CACHE" "$tmp" && "$PHP" -l "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$cfg"; chown www:www "$cfg"; chmod 640 "$cfg"
      n_path=$((n_path+1)); msg="$msg path:แก้แล้ว"
    else
      rm -f "$tmp"; msg="$msg path:!!ไม่ผ่าน php -l ไม่แตะ"
    fi
  fi

  # ---------- 2. open_basedir ----------
  ini="$d/.user.ini"
  if [ ! -f "$ini" ]; then
    msg="$msg ini:ไม่มีไฟล์"
  elif grep -q "$CACHE" "$ini"; then
    msg="$msg ini:OK"
  elif [ "$MODE" = "check" ]; then
    msg="$msg ini:ขาด"
  else
    cur=$(cat "$ini")
    cp -p "$ini" "$BK/$b.user.ini.bak-$TS"
    chattr -i "$ini" 2>/dev/null
    printf '%s\n' "${cur%$'\n'}:$CACHE/" > "$ini"
    chown www:www "$ini"; chmod 644 "$ini"
    chattr +i "$ini" 2>/dev/null
    n_ini=$((n_ini+1)); msg="$msg ini:เติมแล้ว"
  fi

  # ---------- 3. ไฟล์ปลั๊กอิน ----------
  if [ -f "$d/wp-content/plugins/$PLUG" ]; then
    msg="$msg file:OK"
  elif [ "$MODE" = "check" ]; then
    msg="$msg file:ไม่มี"
  elif [ -n "$DONOR" ]; then
    cp -a "$DONOR" "$d/wp-content/plugins/"
    chown -R www:www "$d/wp-content/plugins/nginx-helper"
    n_files=$((n_files+1)); msg="$msg file:คัดลอกแล้ว"
  else
    msg="$msg file:!!ไม่มีต้นแบบให้คัดลอก"
  fi

  # ---------- 4-5. active_plugins + ค่าในฐานข้อมูล ----------
  DB=$(grep -m1 "DB_NAME"     "$cfg" | sed "s/.*'DB_NAME', *'//;s/'.*//")
  DU=$(grep -m1 "DB_USER"     "$cfg" | sed "s/.*'DB_USER', *'//;s/'.*//")
  DP=$(grep -m1 "DB_PASSWORD" "$cfg" | sed "s/.*'DB_PASSWORD', *'//;s/'.*//")
  PFX=$(grep -m1 'table_prefix' "$cfg" | sed "s/.*= *'//;s/'.*//")
  q() { mysql -u"$DU" -p"$DP" "$DB" -Nse "$1" 2>/dev/null; }

  AP=$(q "select option_value from ${PFX}options where option_name='active_plugins';")
  if [ -z "$AP" ]; then
    msg="$msg db:ต่อไม่ได้"
  else
    case "$AP" in
      *nginx-helper*) msg="$msg active:OK" ;;
      *)
        if [ "$MODE" = "check" ]; then
          msg="$msg active:ปิดอยู่"
        else
          # active_plugins เป็น serialized array - แก้ด้วย sed จะทำให้ตัวเลขความยาวเพี้ยน
          NEW=$(AP="$AP" P="$PLUG" "$PHP" -r '
            $a = @unserialize(getenv("AP"));
            if (!is_array($a)) exit(1);
            if (!in_array(getenv("P"), $a, true)) { $a[] = getenv("P"); sort($a); }
            echo base64_encode(serialize(array_values($a)));' 2>/dev/null)
          if [ -n "$NEW" ]; then
            q "update ${PFX}options set option_value=FROM_BASE64('$NEW') where option_name='active_plugins';"
            n_act=$((n_act+1)); msg="$msg active:เปิดแล้ว"
          else
            msg="$msg active:!!unserialize ไม่ผ่าน"
          fi
        fi
        ;;
    esac

    OPT=$(q "select option_value from ${PFX}options where option_name='rt_wp_nginx_helper_options';")
    case "${OPT:-}" in
      "") if [ "$MODE" = "check" ]; then msg="$msg opt:ยังไม่มี"
          else
            NEW=$("$PHP" -r 'echo base64_encode(serialize([
              "enable_purge"=>"1","cache_method"=>"enable_fastcgi","purge_method"=>"unlink_files",
              "purge_homepage_on_edit"=>"1","purge_homepage_on_del"=>"1",
              "purge_page_on_mod"=>"1","purge_archive_on_edit"=>"1"]));')
            q "insert into ${PFX}options (option_name,option_value,autoload) values ('rt_wp_nginx_helper_options',FROM_BASE64('$NEW'),'yes');"
            n_opt=$((n_opt+1)); msg="$msg opt:สร้างแล้ว"
          fi ;;
      *'"purge_method";s:12:"unlink_files"'*) msg="$msg opt:OK" ;;
      *)  if [ "$MODE" = "check" ]; then msg="$msg opt:ยังไม่ถูก"
          else
            NEW=$(OPT="$OPT" "$PHP" -r '
              $a = @unserialize(getenv("OPT"));
              if (!is_array($a)) exit(1);
              $a["enable_purge"]="1"; $a["cache_method"]="enable_fastcgi"; $a["purge_method"]="unlink_files";
              echo base64_encode(serialize($a));' 2>/dev/null)
            if [ -n "$NEW" ]; then
              q "update ${PFX}options set option_value=FROM_BASE64('$NEW') where option_name='rt_wp_nginx_helper_options';"
              n_opt=$((n_opt+1)); msg="$msg opt:แก้แล้ว"
            else
              msg="$msg opt:!!unserialize ไม่ผ่าน"
            fi
          fi ;;
    esac
  fi

  echo " $msg"
done

echo
if [ "$MODE" = "check" ]; then
  echo "โหมด --check ไม่ได้แก้อะไร"
  exit 0
fi
echo "แก้ path $n_path · open_basedir $n_ini · คัดลอกปลั๊กอิน $n_files · เปิดปลั๊กอิน $n_act · ค่าปลั๊กอิน $n_opt"

# ต้อง reload ทั้งกรณีแก้ .user.ini และกรณีแก้ wp-config
#   .user.ini  ถูก PHP cache ไว้ตาม user_ini.cache_ttl (ค่าเริ่มต้น 300 วิ)
#   wp-config  ถูก OPcache เก็บ bytecode ไว้ ค่าคงที่เดิมจึงยังถูกใช้ต่อทั้งที่ไฟล์เปลี่ยนแล้ว
#
# เจอจริง 2026-08-27: แก้ RT_WP_NGINX_HELPER_CACHE_PATH ครบ 97 ไซต์แล้ว แต่ปลั๊กอิน
# ยังรายงาน path เก่าอยู่ เพราะรอบนั้น n_ini = 0 เลยไม่ได้ reload
if [ "$n_ini" != "0" ] || [ "$n_path" != "0" ]; then
  echo "== reload php-fpm ให้ค่าใหม่มีผลทันที (ล้าง OPcache + user.ini cache) =="
  /etc/init.d/php-fpm-83 reload
fi

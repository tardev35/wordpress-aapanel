#!/usr/bin/env bash
# fix-noindex.sh [--apply] - หาไซต์ที่ตั้ง "ห้าม search engine เก็บข้อมูล" ไว้ แล้วปลดให้
#
#   bash fix-noindex.sh                        # ดูอย่างเดียว ทุกไซต์ (ค่าเริ่มต้น)
#   bash fix-noindex.sh --apply                # แก้จริง ทุกไซต์
#   bash fix-noindex.sh --apply DOMAIN.TLD     # แก้เฉพาะไซต์เดียว
#
# ตัวที่ทำให้ติดคือ WordPress → Settings → Reading → "Discourage search engines
# from indexing this site" ซึ่งเก็บเป็น option `blog_public = 0` ในฐานข้อมูลของแต่ละไซต์
# ผลคือ WordPress ใส่ <meta name='robots' content='noindex, nofollow'> ให้ทุกหน้า
# และ Google จะไม่เก็บเข้าดัชนีเลย
#
# มักติดจากตอนสร้างเว็บ/ติดตั้งธีม แล้วลืมปลดก่อนเปิดใช้จริง
#
# สคริปต์นี้อ่าน/เขียนผ่าน wp-load.php ของไซต์เอง จึงไม่ต้องดึงรหัสผ่านฐานข้อมูลออกมา
# และใช้ค่า config เดียวกับที่เว็บใช้จริง

APPLY=0
ONLY=""
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -*)      ;;
    *)       ONLY="$a" ;;
  esac
done

PHP=/www/server/php/83/bin/php
n=0; fixed=0

[ -x "$PHP" ] || { echo "ไม่พบ $PHP"; exit 1; }

for d in /www/wwwroot/*/; do
  b=$(basename "$d")
  [ -f "$d/wp-load.php" ] || continue
  [ -n "$ONLY" ] && [ "$b" != "$ONLY" ] && continue

  cur=$("$PHP" -r '
    define("WP_USE_THEMES", false);
    error_reporting(0);
    require $argv[1]."/wp-load.php";
    echo get_option("blog_public");
  ' "$d" 2>/dev/null)

  if [ "$cur" = "0" ]; then
    n=$((n+1))
    if [ "$APPLY" = "1" ]; then
      "$PHP" -r '
        define("WP_USE_THEMES", false);
        error_reporting(0);
        require $argv[1]."/wp-load.php";
        update_option("blog_public", "1");
      ' "$d" 2>/dev/null
      new=$("$PHP" -r '
        define("WP_USE_THEMES", false);
        error_reporting(0);
        require $argv[1]."/wp-load.php";
        echo get_option("blog_public");
      ' "$d" 2>/dev/null)
      if [ "$new" = "1" ]; then
        printf '%-26s แก้แล้ว\n' "$b"; fixed=$((fixed+1))
      else
        printf '%-26s !! แก้ไม่สำเร็จ\n' "$b"
      fi
    else
      printf '%-26s 🔴 ติด noindex\n' "$b"
    fi
  fi
done

# ล้าง FastCGI cache หลังแก้ ไม่งั้นหน้าเก่าที่มี noindex จะถูกเสิร์ฟต่ออีกเป็นชั่วโมง
# ตาม fastcgi_cache_valid และ Googlebot อาจมาเจอพอดี = แก้แล้วเหมือนไม่ได้แก้
# ปลั๊กอิน Nginx Helper ล้างให้เฉพาะตอน publish/edit โพสต์ ไม่ล้างตอนเปลี่ยน setting
if [ "$APPLY" = "1" ] && [ "$fixed" -gt 0 ]; then
  CACHE=$(grep -oP 'fastcgi_cache_path\s+\K[^ ]+' /www/server/panel/vhost/nginx/0.fastcgi_cache.conf 2>/dev/null)
  CACHE=${CACHE:-/www/server/fastcgi_cache}
  rm -rf "${CACHE:?}"/* 2>/dev/null
  /www/server/nginx/sbin/nginx -t >/dev/null 2>&1 && /etc/init.d/nginx reload >/dev/null 2>&1
  echo
  echo "ล้าง FastCGI cache แล้ว (จำเป็น ไม่งั้นหน้าเก่าที่มี noindex ยังถูกเสิร์ฟต่อ)"
fi

echo
if [ "$APPLY" = "1" ]; then
  echo "แก้ไปแล้ว $fixed จาก $n ไซต์"
  echo "ถ้าเว็บใช้ปลั๊กอิน SEO (Yoast/Rank Math) ให้เช็คในปลั๊กอินด้วย เพราะมันตั้ง noindex ซ้อนได้อีกชั้น"
else
  echo "เจอ $n ไซต์ที่ติด noindex — รันซ้ำด้วย --apply เพื่อแก้"
fi

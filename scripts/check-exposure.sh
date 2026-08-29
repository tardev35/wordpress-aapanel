#!/usr/bin/env bash
# check-exposure.sh [DOMAIN] - ดูว่าเว็บเราเปิดเผยอะไรให้บอทบ้าง
#
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/check-exposure.sh"             # ทุกไซต์บนเครื่อง
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/check-exposure.sh DOMAIN.TLD"  # ไซต์เดียว
#   bash check-exposure.sh example.com                                          # เว็บที่ไหนก็ได้
#
# ตัวนี้ **ไม่ได้เจาะอะไรทั้งนั้น** มันแค่เปิดหน้าเว็บสาธารณะแล้วดูว่าตอบอะไรกลับมา
# เหมือนที่เบราว์เซอร์ทำ - ใช้ตรวจเว็บตัวเองและเว็บเพื่อนได้อย่างปลอดภัย
#
# ทำไมต้องมี: บอทที่เจาะ bbc29pro.com ไม่ได้ทำอะไรซับซ้อนกว่านี้เลย มันแค่
#   1. อ่าน Certificate Transparency log สาธารณะ -> ได้รายชื่อโดเมนใหม่ทั้งโลก
#   2. ยิง path มาตรฐานชุดหนึ่ง -> ดูว่าอันไหนตอบ 200
#   3. อันที่ตอบ = ช่องที่ใช้ต่อได้
#
# วัดจริงบนเครื่อง 2026-08-29: cert ออก -> บอทมาถึงใน **58 นาที** เท่ากันทั้ง 3 ไซต์
# ที่สร้างเช้านั้น
#
# ดู docs/11-security.md สำหรับเคสเต็ม

set -u

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36"
ONLY="${1:-}"

# ยิงผ่าน 127.0.0.1 ถ้าไซต์อยู่บนเครื่องนี้ (เลี่ยง Cloudflare บังผล)
# ถ้าไม่ใช่ ก็ยิงตรงออกอินเทอร์เน็ตตามปกติ
probe() {
  local d="$1" path="$2"
  if [ -d "/www/wwwroot/$d" ]; then
    curl -sk --resolve "$d:443:127.0.0.1" -A "$UA" "https://$d$path" -o /tmp/ce.out -w '%{http_code}' --max-time 8 2>/dev/null
  else
    curl -sk -A "$UA" "https://$d$path" -o /tmp/ce.out -w '%{http_code}' --max-time 12 2>/dev/null
  fi
}

# 200 = เปิดให้เข้าถึง (ไม่ดี) · 401/403/404 = ปิดแล้ว (ดี)
verdict() {
  case "$1" in
    200|301|302) echo "เปิดอยู่" ;;
    401|403)     echo "ปิดแล้ว" ;;
    404)         echo "ไม่มี/ปิด" ;;
    *)           echo "$1" ;;
  esac
}

check_site() {
  local d="$1" bad=0
  echo "=============================================================="
  echo "  $d"
  echo "=============================================================="
  printf '  %-34s %-6s %-10s %s\n' "สิ่งที่บอทลอง" "CODE" "สถานะ" "ได้อะไรไปถ้าเปิด"
  printf '  %-34s %-6s %-10s %s\n' "----------------------------------" "-----" "---------" "--------------------"

  one() {
    local path="$1" why="$2" c v
    c=$(probe "$d" "$path"); v=$(verdict "$c")
    [ "$v" = "เปิดอยู่" ] && bad=$((bad+1))
    printf '  %-34s %-6s %-10s %s\n' "$path" "$c" "$v" "$why"
  }

  one /xmlrpc.php                  "เดารหัสผ่านรัว ๆ ทีละหลายร้อยครั้ง"
  one /wp-json/wp/v2/users         "แจกชื่อผู้ใช้ให้เอาไปเดารหัส"
  one "/?author=1"                 "ทางเก่าที่ให้ชื่อผู้ใช้เหมือนกัน"
  one /wp-includes/wlwmanifest.xml "ยืนยันว่าเป็น WordPress"
  one /readme.html                 "บอกเวอร์ชัน WordPress"
  one /wp-config.php               "รหัสผ่านฐานข้อมูล"
  one /wp-config.php.bak           "ไฟล์ config ที่คนลืมลบ"
  one /.env                        "คีย์และรหัสผ่านต่าง ๆ"
  one /.git/config                 "ซอร์สโค้ดทั้งโปรเจกต์"
  one /wp-content/debug.log        "path จริงของเครื่อง + error"
  one /wp-admin/setup-config.php   "ไซต์ที่ติดตั้งค้าง = ยึดได้ทันที"
  one /wp-content/uploads/         "ดูรายชื่อไฟล์ทั้งหมด"

  # เวอร์ชันหลุดทาง meta generator ไหม
  probe "$d" "/" >/dev/null
  local gen
  gen=$(grep -o '<meta name="generator" content="[^"]*"' /tmp/ce.out 2>/dev/null | head -1 | sed 's/.*content="//;s/"//')
  printf '  %-34s %-6s %-10s %s\n' "meta generator" "-" \
    "$([ -n "$gen" ] && echo 'เปิดอยู่' || echo 'ปิดแล้ว')" "${gen:-ไม่หลุด}"
  [ -n "$gen" ] && bad=$((bad+1))

  echo
  if [ "$bad" = "0" ]; then
    echo "  ✅ ไม่มีช่องที่เปิดอยู่"
  else
    echo "  ⚠️  มี $bad รายการที่ยังเปิดอยู่ - ดู docs/11-security.md"
  fi
  echo
}

if [ -n "$ONLY" ]; then
  check_site "$ONLY"
else
  for x in /www/wwwroot/*/; do
    b=$(basename "$x")
    [ "$b" = "default" ] && continue
    [ -f "$x/wp-config.php" ] || continue
    check_site "$b"
  done
fi

#!/usr/bin/env bash
# cpu-load-demo.sh — พิสูจน์ว่า "request รัว ๆ ที่ทะลุแคชไปรัน PHP เต็มรูป" ทำ CPU พุ่งจริง
#
#   bash cpu-load-demo.sh              # ยิง 8 พร้อมกัน 15 วินาที
#   bash cpu-load-demo.sh 20 30        # ยิง 20 พร้อมกัน 30 วินาที
#
# ทำไมต้องมี: อยากเห็นกับตาว่าทำไมเราถึงปิด xmlrpc และใช้ FastCGI cache
# xmlrpc ทุก POST ข้ามแคชไปรัน WordPress เต็มรูป + system.multicall ยัดหลายพัน
# การเดารหัสใน request เดียว -> นี่คือตัวที่ทำ CPU 92% บน bbc29pro.com
#
# 🔒 ปลอดภัยโดยออกแบบ:
#   - ยิงแค่ 127.0.0.1 ของเครื่องตัวเอง ไม่เปิดอะไรออกเน็ต ไม่แตะเว็บจริง
#   - สร้าง endpoint ชั่วคราวบนพอร์ตสูง (18099) แล้วลบทิ้งเองเมื่อจบ
#   - ปฏิเสธที่จะรันถ้าเจอเว็บจริงบนเครื่อง (กันเผลอรันบนเครื่อง production)
#   - งานต่อ request มีเพดาน จบเองใน ~40ms ยิงนานแค่ไหนก็ไม่ค้าง
#
# ⚠️ รันบน "เครื่องเปล่าที่ไม่มีเว็บจริง" เท่านั้น เช่น 72.62.127.10
#    ห้ามรันบนเครื่องที่มีลูกค้าจริง แม้จะยิง localhost ก็ยังกิน CPU ของเครื่องนั้น

set -u
CONC=${1:-8}
DUR=${2:-15}
PORT=18099
PHPV=83
SOCK="/tmp/php-cgi-${PHPV}.sock"
ROOT="/tmp/cpu-load-demo.$$"
VHOST="/www/server/panel/vhost/nginx/zz-cpu-load-demo.conf"
NGINX="/www/server/nginx/sbin/nginx"

# เพดานกันยิงหนักเกิน
[ "$CONC" -gt 32 ] && CONC=32
[ "$DUR"  -gt 60 ] && DUR=60

echo "=================================================================="
echo "  สาธิตภาระ CPU จาก request ที่รัน PHP เต็มรูป"
echo "  ยิง $CONC พร้อมกัน นาน $DUR วินาที ที่ http://127.0.0.1:$PORT/"
echo "=================================================================="

# ---------- 0. ตรวจความปลอดภัยก่อนทำอะไร ----------
REAL=$(ls /www/server/panel/vhost/nginx/*.conf 2>/dev/null \
       | grep -vcE "/0\.|phpfpm_status|waf2monitor|zz-cpu-load-demo")
if [ "$REAL" -gt 0 ]; then
  echo "🔴 หยุด: เครื่องนี้มีเว็บจริง $REAL ไซต์"
  echo "   สคริปต์นี้รันได้เฉพาะเครื่องเปล่า จะได้ไม่กระทบลูกค้าจริง"
  echo "   ถ้าตั้งใจจริง ๆ ให้แก้ตัวแปร REAL ออกเอง (ไม่แนะนำ)"
  exit 1
fi
[ -S "$SOCK" ] || { echo "🔴 ไม่พบ php-fpm socket $SOCK"; exit 1; }
command -v curl >/dev/null || { echo "🔴 ต้องมี curl"; exit 1; }

cleanup() {
  echo
  echo "--- เก็บกวาด ---"
  rm -f "$VHOST"
  rm -rf "$ROOT"
  "$NGINX" -s reload 2>/dev/null
  echo "  ลบ endpoint ชั่วคราวและ reload nginx แล้ว — ไม่เหลืออะไรบนเครื่อง"
}
trap cleanup EXIT INT TERM

# ---------- 1. สร้าง endpoint ชั่วคราว ----------
mkdir -p "$ROOT"
cat > "$ROOT/index.php" <<'PHP'
<?php
// จำลองภาระต่อ 1 request แบบเว็บ WordPress ทั่วไป (~30-40ms งาน CPU จริง)
// มีเพดานเวลา จบเองเสมอ ไม่ใช่ลูปไม่รู้จบ
$t = microtime(true);
$x = 0.0;
while (microtime(true) - $t < 0.035) {      // ทำงาน 35ms แล้วหยุด
    $x += sqrt(mt_rand(1, 1000000)) * sin($x + 1.234);
}
echo "ok ", number_format($x, 2);
PHP

cat > "$VHOST" <<EOF
server {
    listen $PORT;
    server_name _;
    root $ROOT;
    index index.php;
    location ~ \.php\$ {
        fastcgi_pass unix:$SOCK;
        fastcgi_index index.php;
        include fastcgi.conf;
    }
}
EOF

if ! "$NGINX" -t 2>/dev/null; then
  echo "🔴 nginx config ไม่ผ่าน — ยกเลิก"
  "$NGINX" -t
  exit 1
fi
"$NGINX" -s reload 2>/dev/null
sleep 1
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:$PORT/")
[ "$code" = "200" ] || { echo "🔴 endpoint ตอบ $code ไม่ใช่ 200 — ยกเลิก"; exit 1; }
echo "  endpoint ชั่วคราวพร้อม (ตอบ 200)"

# ---------- 2. วัด CPU ก่อนยิง ----------
cpu_now() {   # คืน %CPU ที่ไม่ว่าง (100 - idle) อ่านจาก /proc/stat 1 วินาที
  read _ a b c d _ < /proc/stat
  local i1=$d t1=$((a+b+c+d)); sleep 1
  read _ a b c d _ < /proc/stat
  local i2=$d t2=$((a+b+c+d))
  awk "BEGIN{printf \"%.0f\", 100-($i2-$i1)*100/($t2-$t1)}"
}
echo
echo "--- ก่อนยิง ---"
echo "  CPU ใช้ไป $(cpu_now)%   |   load: $(cut -d' ' -f1-3 /proc/loadavg)"

# ---------- 3. ยิงรัว ๆ ----------
echo
echo "--- กำลังยิง $CONC พร้อมกัน นาน $DUR วินาที (ดู CPU ในหน้า aapanel ตอนนี้) ---"
END=$(( $(date +%s) + DUR ))
for i in $(seq 1 "$CONC"); do
  ( while [ "$(date +%s)" -lt "$END" ]; do
      curl -s -o /dev/null -m 5 "http://127.0.0.1:$PORT/"
    done ) &
done
# วัด CPU ระหว่างยิง 3 ครั้ง
for s in 1 2 3; do
  echo "  ระหว่างยิง #$s:  CPU ใช้ไป $(cpu_now)%   |   load: $(cut -d' ' -f1-3 /proc/loadavg)"
done
wait

# ---------- 4. วัด CPU หลังหยุด ----------
echo
echo "--- หลังหยุด 3 วินาที ---"
sleep 3
echo "  CPU ใช้ไป $(cpu_now)%   |   load: $(cut -d' ' -f1-3 /proc/loadavg)"

echo
echo "=================================================================="
echo "  จบ — CPU กลับสู่ปกติเมื่อหยุดยิง"
echo "  ของจริง xmlrpc แย่กว่านี้: ทุก POST ข้ามแคช + multicall ยัดหลายพัน"
echo "  การเดารหัสใน request เดียว บอทยิงจากหลายพัน IP พร้อมกัน CPU ไม่มีวันลง"
echo "  กฎที่กันไว้: xmlrpc ปิดใน common-site.conf + FastCGI cache (ดู docs/04, 12)"
echo "=================================================================="

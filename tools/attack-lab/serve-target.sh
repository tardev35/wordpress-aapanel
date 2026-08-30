#!/usr/bin/env bash
# serve-target.sh — เปิด "เป้าซ้อมโหลด" สาธารณะบน VPS เปล่า เพื่อให้ยิงจากเครื่องอื่นได้
#
#   bash serve-target.sh              # เปิดเป้าบนพอร์ต 18099 พิมพ์ URL ออกมา
#   (กด Ctrl+C เพื่อปิดและลบทิ้ง)
#
# ใช้คู่กับ hammer.py ที่รันบนเครื่องคุณ:
#   python tools/attack-lab/hammer.py --url http://<ไอพี VPS>:18099/
#
# 🔒 ปลอดภัยโดยออกแบบ:
#   - รันได้เฉพาะ "เครื่องที่ไม่มีเว็บจริง" เท่านั้น (ปฏิเสธถ้าเจอเว็บจริง)
#   - endpoint ตอบ header X-Load-Demo:1 เพื่อให้ hammer รู้ว่าเป็นเป้าซ้อม
#   - งานต่อ request มีเพดาน จบเองใน 35ms
#   - กด Ctrl+C แล้วลบ endpoint + reload nginx ทิ้งเอง ไม่เหลืออะไร
#
# ⚠️ พอร์ต 18099 ต้องเปิดใน aapanel -> Security ก่อน ไม่งั้นยิงจากข้างนอกไม่ถึง
#    เปิดเสร็จใช้แล้วปิดพอร์ตด้วย

set -u
PORT=18099
PHPV=83
SOCK="/tmp/php-cgi-${PHPV}.sock"
ROOT="/tmp/serve-target.$$"
VHOST="/www/server/panel/vhost/nginx/zz-serve-target.conf"
NGINX="/www/server/nginx/sbin/nginx"

echo "=================================================================="
echo "  เปิดเป้าซ้อมโหลดสาธารณะบนพอร์ต $PORT"
echo "=================================================================="

# ---------- กันรันบนเครื่องที่มีเว็บจริง ----------
REAL=$(ls /www/server/panel/vhost/nginx/*.conf 2>/dev/null \
       | grep -vcE "/0\.|phpfpm_status|waf2monitor|zz-serve-target")
if [ "$REAL" -gt 0 ]; then
  echo "🔴 หยุด: เครื่องนี้มีเว็บจริง $REAL ไซต์ — เปิดเป้าซ้อมได้เฉพาะเครื่องเปล่า"
  exit 1
fi
[ -S "$SOCK" ] || { echo "🔴 ไม่พบ php-fpm socket $SOCK"; exit 1; }

cleanup() {
  echo; echo "--- ปิดเป้าและเก็บกวาด ---"
  rm -f "$VHOST"; rm -rf "$ROOT"
  "$NGINX" -s reload 2>/dev/null
  echo "  ลบ endpoint และ reload nginx แล้ว — อย่าลืมปิดพอร์ต $PORT ใน aapanel Security"
}
trap cleanup EXIT INT TERM

# ---------- สร้าง endpoint ----------
mkdir -p "$ROOT"
cat > "$ROOT/index.php" <<'PHP'
<?php
header('Content-Type: text/plain');
header('X-Load-Demo: 1');
$t = microtime(true); $x = 0.0;
while (microtime(true) - $t < 0.035) {      // งาน CPU 35ms/request เท่าเว็บ WP ทั่วไป
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
    location = / { rewrite ^ /index.php last; }
}
EOF

if ! "$NGINX" -t 2>/dev/null; then
  echo "🔴 nginx config ไม่ผ่าน — ยกเลิก"; "$NGINX" -t; exit 1
fi
"$NGINX" -s reload 2>/dev/null
sleep 1
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:$PORT/")
[ "$code" = "200" ] || { echo "🔴 endpoint ตอบ $code — ยกเลิก"; exit 1; }

IP=$(curl -s -m 5 https://api.ipify.org 2>/dev/null || echo "<ไอพี VPS>")
echo
echo "  ✅ เป้าพร้อม — ยิงจากเครื่องคุณด้วย:"
echo
echo "     python tools/attack-lab/hammer.py --url http://$IP:$PORT/ --conc 32 --dur 30"
echo
echo "  เปิดหน้า aapanel ของ VPS ดู CPU ตอนยิง"
echo "  ยังไม่ถึงต้องเปิดพอร์ต $PORT ใน aapanel -> Security ก่อน"
echo
echo "  (ค้างไว้แบบนี้ กด Ctrl+C เพื่อปิดและลบทิ้ง)"
# ค้างรอจนกด Ctrl+C
while :; do sleep 3600; done

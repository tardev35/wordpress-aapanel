#!/usr/bin/env bash
# testsite-guard.sh — ล็อกเว็บทดสอบให้เข้าได้แค่ IP เรา ก่อนปลดเกราะ xmlrpc
#
#   bash testsite-guard.sh <domain> lock <ip|cidr>   # ใส่ allow <ip>; deny all;
#   bash testsite-guard.sh <domain> status           # เช็คว่าล็อก/ปลดเกราะอยู่ไหม
#   bash testsite-guard.sh <domain> open-xmlrpc       # ปลดเกราะ (ต้องล็อกก่อน)
#   bash testsite-guard.sh <domain> close-xmlrpc      # คืนเกราะ
#   bash testsite-guard.sh <domain> unlock            # เอา allow/deny ออก (ต้องคืนเกราะก่อน)
#
# กฎเหล็ก: จะ open-xmlrpc ได้ต่อเมื่อ "ล็อก IP แล้ว" เท่านั้น สคริปต์บังคับให้
# ดู docs/13-safe-vuln-testing.md
#
# ⚠️ รันบนเครื่องทดสอบที่ไม่มีเว็บลูกค้าจริง

set -u
DOMAIN="${1:-}"
ACTION="${2:-status}"
ARG="${3:-}"
VHOST="/www/server/panel/vhost/nginx/${DOMAIN}.conf"
LOCKINC="/www/server/panel/vhost/nginx/extension/${DOMAIN}/00-iplock.conf"
HARDLINK="/www/server/panel/vhost/nginx/extension/${DOMAIN}/01-hardening.conf"
NGINX="/www/server/nginx/sbin/nginx"

[ -n "$DOMAIN" ] || { echo "ใช้: bash testsite-guard.sh <domain> <lock|status|open-xmlrpc|close-xmlrpc|unlock> [ip]"; exit 1; }
[ -f "$VHOST" ] || { echo "🔴 ไม่พบไซต์ $DOMAIN ($VHOST)"; exit 1; }

# ---------- กันรันบนเครื่องที่มีเว็บจริงหลายไซต์ ----------
REAL=$(ls /www/server/panel/vhost/nginx/*.conf 2>/dev/null \
       | grep -vcE "/0\.|phpfpm_status|waf2monitor")
if [ "$REAL" -gt 1 ]; then
  echo "⚠️ เครื่องนี้มี $REAL ไซต์ — ควรทดสอบบนเครื่องเปล่าที่มีแค่ไซต์ทดสอบ"
  echo "   ถ้าแน่ใจว่าไซต์อื่นไม่ใช่ลูกค้าจริง กด Enter เพื่อไปต่อ หรือ Ctrl+C ยกเลิก"
  read -r _
fi

is_locked() { [ -f "$LOCKINC" ] && grep -q "deny all" "$LOCKINC"; }
is_open()   { [ ! -e "$HARDLINK" ]; }   # ไม่มี symlink hardening = เกราะถูกปลด

reload() {
  if "$NGINX" -t 2>/dev/null; then "$NGINX" -s reload 2>/dev/null; return 0
  else echo "🔴 nginx -t ไม่ผ่าน:"; "$NGINX" -t; return 1; fi
}

case "$ACTION" in
  lock)
    [ -n "$ARG" ] || { echo "🔴 ต้องระบุ IP: bash testsite-guard.sh $DOMAIN lock 1.2.3.4"; exit 1; }
    mkdir -p "$(dirname "$LOCKINC")"
    { echo "# ล็อกเว็บทดสอบให้เข้าได้แค่ IP นี้ - สร้างโดย testsite-guard.sh"
      echo "allow $ARG;"
      echo "allow 127.0.0.1;"
      echo "deny all;"
    } > "$LOCKINC"
    reload || { rm -f "$LOCKINC"; exit 1; }
    echo "✅ ล็อกแล้ว — เข้าได้แค่ $ARG (และ localhost)"
    echo "   ตรวจซ้ำด้วย: bash testsite-guard.sh $DOMAIN status"
    ;;

  open-xmlrpc)
    if ! is_locked; then
      echo "🔴 ยังไม่ได้ล็อก IP — ปลดเกราะไม่ได้"
      echo "   ล็อกก่อน: bash testsite-guard.sh $DOMAIN lock <ไอพีคุณ>"
      echo "   (docs/13 กฎเหล็กข้อ 1: xmlrpc เปิด → IP ต้องล็อก)"
      exit 1
    fi
    if [ -e "$HARDLINK" ]; then
      rm -f "$HARDLINK"
      reload || exit 1
      echo "✅ ปลดเกราะแล้ว (ถอด hardening ของไซต์นี้) — xmlrpc เปิด"
    else
      echo "ℹ️ ไซต์นี้ไม่มี hardening อยู่แล้ว (xmlrpc เปิดโดยปริยาย)"
    fi
    echo "   ⚠️ ล็อก IP ต้องอยู่ตลอด ห้าม unlock จนกว่าจะ close-xmlrpc"
    ;;

  close-xmlrpc)
    if [ -x /www/wwwroot/../../scripts/harden-wp.sh ] 2>/dev/null; then :; fi
    echo "คืนเกราะให้ $DOMAIN — รัน harden-wp.sh กับไซต์นี้:"
    echo "   bash scripts/harden-wp.sh $DOMAIN"
    echo "(หรือ deploy hardening ผ่านวิธีปกติ) แล้วรัน status ตรวจอีกที"
    ;;

  unlock)
    if is_open; then
      echo "🔴 xmlrpc ยังเปิดอยู่ (ไม่มี hardening) — ปลดล็อก IP ไม่ได้"
      echo "   คืนเกราะก่อน: bash testsite-guard.sh $DOMAIN close-xmlrpc"
      exit 1
    fi
    rm -f "$LOCKINC"
    reload || exit 1
    echo "✅ ปลดล็อก IP แล้ว — เว็บเปิดให้ทุกคนเข้า (เกราะยังอยู่)"
    ;;

  status|*)
    echo "===== สถานะ $DOMAIN ====="
    if is_locked; then
      echo "  ล็อก IP    : ✅ ล็อกแล้ว"
      grep -E "^allow" "$LOCKINC" | sed 's/^/               /'
    else
      echo "  ล็อก IP    : ❌ ยังไม่ล็อก (คนนอกเข้าได้)"
    fi
    if is_open; then
      echo "  เกราะ      : ⚠️ ปลดแล้ว (xmlrpc เปิด)"
    else
      echo "  เกราะ      : ✅ มี hardening อยู่"
    fi
    # ทดสอบจริงว่าคนนอกโดนบล็อกไหม (ยิงจาก localhost โดยปลอม IP ไม่ได้ แค่เตือน)
    if is_open && ! is_locked; then
      echo
      echo "  🔴 อันตราย: เกราะปลด แต่ไม่ได้ล็อก IP — บอทข้างนอกเข้ายิงได้"
      echo "     ล็อกทันที: bash testsite-guard.sh $DOMAIN lock <ไอพีคุณ>"
    fi
    ;;
esac

#!/usr/bin/env bash
# setup-logrotate.sh [--check|--remove|--rotate-now] - หมุน log เว็บ /www/wwwlogs อัตโนมัติทุก 7 วัน
#
# aaPanel ไม่ตั้ง logrotate ให้ /www/wwwlogs เอง log จึงโตไม่หยุด (เจอก้อน 162 MB)
# ตัวนี้วาง /etc/logrotate.d/aapanel-wwwlogs หมุน "สัปดาห์ละครั้ง เก็บ 2 สัปดาห์ บีบอัด"
# — คุมพื้นที่ได้เหมือนกดปุ่ม Log cleanup แต่ยังเหลือ log เก่าไว้สืบสวนความปลอดภัย
#   (สำคัญ: เราใช้ log จับการโจมตี เช่นเคส xmlrpc ยิง bbc29pro การล้างเกลี้ยงจะทำหลักฐานหาย)
#
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/setup-logrotate.sh"              # ติดตั้ง
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/setup-logrotate.sh --rotate-now" # ติดตั้ง + หมุนทันที (คืนพื้นที่เลย)
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/setup-logrotate.sh --check"      # ดูสถานะ
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/setup-logrotate.sh --remove"     # ถอดออก (log เดิมไม่ลบ)
#
# ปลอดภัย: เขียน config ไฟล์เดียว ไม่แตะ service; postrotate ส่งสัญญาณ USR1 ให้ nginx เปิด log ใหม่
#          ตรวจ syntax ด้วย logrotate --debug (dry-run ไม่แตะไฟล์) ก่อนเสมอ ไม่ผ่านจะถอน config กลับ
#
# ปรับจำนวนสัปดาห์ที่เก็บได้: KEEP=4 bash setup-logrotate.sh

set -u
CONF=/etc/logrotate.d/aapanel-wwwlogs
LOGDIR=/www/wwwlogs
NGINX_PID=/www/server/nginx/logs/nginx.pid
KEEP="${KEEP:-2}"                       # เก็บกี่รอบ (สัปดาห์)
ACTION="${1:-install}"

sizes() { du -sh "$LOGDIR" 2>/dev/null | cut -f1; }

case "$ACTION" in
  --check)
    echo "== สถานะ logrotate ของ $LOGDIR =="
    if [ -f "$CONF" ]; then echo "  config      : ✅ ติดตั้งแล้ว ($CONF)"
    else echo "  config      : ❌ ยังไม่ติดตั้ง"; fi
    echo "  ขนาด log รวม : $(sizes)"
    if systemctl is-active --quiet logrotate.timer 2>/dev/null; then
      echo "  scheduler   : ✅ logrotate.timer (systemd) ทำงานอยู่"
    elif [ -f /etc/cron.daily/logrotate ]; then
      echo "  scheduler   : ✅ /etc/cron.daily/logrotate"
    elif [ -f /etc/cron.d/aapanel-logrotate ]; then
      echo "  scheduler   : ✅ /etc/cron.d/aapanel-logrotate (สำรอง)"
    else
      echo "  scheduler   : ⚠️ ไม่พบ - รัน setup ใหม่เพื่อให้ตั้ง cron สำรอง"
    fi
    if [ -f "$CONF" ]; then
      echo "  ตรวจ syntax :"
      logrotate --debug "$CONF" 2>&1 | grep -iE "error|rotating pattern|considering" | head -3 | sed 's/^/    /'
    fi
    exit 0 ;;
  --remove)
    rm -f "$CONF" /etc/cron.d/aapanel-logrotate
    echo "ถอด logrotate config แล้ว (log เดิมยังอยู่ ไม่ได้ลบ)"; exit 0 ;;
esac

# ---------- ติดตั้ง ----------
command -v logrotate >/dev/null || {
  echo "== ติดตั้ง logrotate =="; apt-get update -qq && apt-get install -y -qq logrotate; }
[ -d "$LOGDIR" ] || { echo "🔴 ไม่พบ $LOGDIR — เครื่องนี้เป็น aaPanel LNMP หรือเปล่า?"; exit 1; }

echo "== 1. เขียน config =="
cat > "$CONF" <<EOF
# หมุน log เว็บ aaPanel ทุก 7 วัน เก็บ $KEEP สัปดาห์ บีบอัด — ติดตั้งโดย scripts/setup-logrotate.sh
$LOGDIR/*.log {
    su root root
    weekly
    rotate $KEEP
    missingok
    notifempty
    compress
    delaycompress
    create 0644 root root
    sharedscripts
    postrotate
        if [ -f $NGINX_PID ]; then
            kill -USR1 \$(cat $NGINX_PID) 2>/dev/null || true
        fi
    endscript
}
EOF
chmod 644 "$CONF"
echo "  $CONF (เก็บ $KEEP สัปดาห์)"

echo "== 2. ตรวจ syntax (dry-run ไม่แตะไฟล์จริง) =="
if ! logrotate --debug "$CONF" >/tmp/lr-check.out 2>&1; then
  echo "🔴 config ไม่ผ่าน — ถอนกลับ:"; cat /tmp/lr-check.out; rm -f "$CONF"; exit 1
fi
if grep -qiE "^error:" /tmp/lr-check.out; then
  echo "🔴 พบ error — ถอนกลับ:"; grep -i "error" /tmp/lr-check.out; rm -f "$CONF"; exit 1
fi
echo "  ผ่าน"

echo "== 3. scheduler ที่จะรัน config นี้ =="
if systemctl is-active --quiet logrotate.timer 2>/dev/null; then
  echo "  ✅ logrotate.timer ทำงานอยู่ (รันทุกวัน หมุนเฉพาะตัวที่ครบ 7 วัน)"
elif [ -f /etc/cron.daily/logrotate ]; then
  echo "  ✅ /etc/cron.daily/logrotate มีอยู่แล้ว"
else
  echo "  ⚠️ ไม่พบ scheduler ของ logrotate — ตั้ง cron สำรองให้"
  echo '0 3 * * 0 root /usr/sbin/logrotate /etc/logrotate.conf' > /etc/cron.d/aapanel-logrotate
  chmod 644 /etc/cron.d/aapanel-logrotate
  echo "    เพิ่ม /etc/cron.d/aapanel-logrotate (อาทิตย์ 03:00)"
fi

BEFORE=$(sizes)
if [ "$ACTION" = "--rotate-now" ]; then
  echo "== 4. หมุนทันที (คืนพื้นที่เลย) =="
  logrotate --force "$CONF"
  echo "  ขนาด $LOGDIR : $BEFORE → $(sizes)"
else
  echo "== 4. เสร็จ =="
  echo "  ขนาด $LOGDIR ตอนนี้ : $BEFORE (จะหมุนรอบแรกเมื่อ scheduler รันครั้งถัดไป)"
  echo "  อยากคืนพื้นที่เดี๋ยวนี้: รันซ้ำด้วยอาร์กิวเมนต์ --rotate-now"
fi
echo
echo "ตรวจซ้ำ: รันสคริปต์นี้ด้วยอาร์กิวเมนต์ --check"

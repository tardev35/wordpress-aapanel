#!/usr/bin/env bash
# install-phpfpm-guard.sh [--remove] - ตั้ง phpfpm-guard.sh ให้ยิงทุก 1 นาที กัน php-fpm พัง -> 502
#
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/install-phpfpm-guard.sh"
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/install-phpfpm-guard.sh --remove"
#
# ทำไมต้องมี: aaPanel เขียนทับ /www/server/php/*/etc/php-fpm.conf เป็นระยะ แล้วทำ pm.max_children
#   เพี้ยนเป็น non-number (เช่น "200pm.process_idle_timeout = 30s" — newline หาย) -> php-fpm ดับ
#   ตอน reload -> 502 ทุกเว็บ. เกิดซ้ำหลายรอบ 2026-08-31 (4 เครื่อง ทีละตัว 06:34-06:49)
#   แก้มืออย่างเดียวไม่ทัน จึงต้องมีตัวเฝ้าซ่อมเอง (ดู docs/07 ข้อ 3)
#
# ใช้ systemd timer ไม่ใช่หน้า Cron ของ aaPanel เพราะยิงทุกนาที (panel จะเขียน log ท่วม)
# Type=oneshot กันรันซ้อนในตัว · phpfpm-guard.sh แตะไฟล์เฉพาะตอน config พังเท่านั้น (ปลอดภัย)
#
# ดูสถานะ:  systemctl list-timers wpaa-phpfpm-guard.timer
#           journalctl -u wpaa-phpfpm-guard.service -n 30
#           tail -f /var/log/wpaa-phpfpm-guard.log
set -u

ROOT=/root/wpaa
SCRIPT="$ROOT/scripts/phpfpm-guard.sh"
UNIT=wpaa-phpfpm-guard
SVC=/etc/systemd/system/$UNIT.service
TMR=/etc/systemd/system/$UNIT.timer
SRC="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "--remove" ]; then
  systemctl disable --now "$UNIT.timer" 2>/dev/null || true
  rm -f "$SVC" "$TMR"
  systemctl daemon-reload
  echo "ถอด $UNIT ออกแล้ว (ไฟล์สคริปต์ยังอยู่)"
  exit 0
fi

echo "== 1. คัดลอกสคริปต์ไป $ROOT/scripts =="
mkdir -p "$ROOT/scripts"
# ไม่รันจาก /tmp ตรง ๆ เพราะ /tmp หายตอนรีบูต แล้ว timer จะพังเงียบ (เหมือน install-site-watcher)
if [ "$SRC" != "$ROOT/scripts" ]; then
  install -m 755 "$SRC/phpfpm-guard.sh" "$SCRIPT"
fi
chmod +x "$SCRIPT"
echo "  $SCRIPT"

echo "== 2. เขียน systemd unit =="
cat > "$SVC" <<EOF
[Unit]
Description=wpaa - เฝ้า php-fpm ซ่อม config ที่ aaPanel เขียนพัง กัน 502
Documentation=file://$SCRIPT
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=$SCRIPT
EOF

cat > "$TMR" <<EOF
[Unit]
Description=wpaa - ตรวจ php-fpm ทุก 1 นาที (ซ่อม config พัง/ปลุก master)

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=$UNIT.service

[Install]
WantedBy=timers.target
EOF
echo "  $SVC"
echo "  $TMR"

echo "== 3. เปิดใช้ + รันทันที 1 รอบ =="
systemctl daemon-reload
systemctl enable --now "$UNIT.timer"
systemctl start "$UNIT.service"

echo
systemctl list-timers "$UNIT.timer" --no-pager | head -3
echo
echo "log: /var/log/wpaa-phpfpm-guard.log (เขียนเฉพาะรอบที่ต้องซ่อมจริง)"

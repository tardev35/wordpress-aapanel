#!/usr/bin/env bash
# install-site-watcher.sh [--remove] - ตั้ง watch-new-sites.sh ให้ยิงทุก 1 นาที
#
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/install-site-watcher.sh"
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/install-site-watcher.sh --remove"
#
# ติดตั้งสองตัวคู่กัน:
#   wpaa-newsite.path   ตื่น **ทันที** ที่ panel เขียนไฟล์ลง vhost/nginx/ = ตอนกด Add site
#   wpaa-newsite.timer  ยิงทุก 1 นาที เป็นตาข่ายรับกรณีที่ inotify พลาดหรือ path unit ถูกปิด
#
# ต้องมีทั้งคู่: path unit ตื่นตอน "vhost ถูกเขียน" ซึ่งเร็วพอสำหรับ nginx reload
# แต่ wp-config.php ของ WordPress โผล่มา **ข้างใน** /www/wwwroot/<domain>/ ทีหลัง
# ซึ่ง path unit ตัวนี้มองไม่เห็น timer จึงเป็นตัวที่ไปปิด auto-update ให้
#
# ใช้ systemd timer ไม่ใช่หน้า Cron ของ aaPanel ทั้งที่ docs/05 บอกให้ใช้ panel
# เพราะงานนี้ยิง **ทุกนาที** ซึ่ง panel จะเขียน log + เรียก log_task_analyzer.py
# ทุกรอบ = 1440 entry ต่อวันในหน้า Cron จนงานอื่นจมหาย ส่วน timer ของ systemd
# ไม่มีต้นทุนนั้น และ Type=oneshot กันรันซ้อนให้ในตัว ไม่ต้องพึ่ง flock
#
# ดูสถานะ:  systemctl status wpaa-newsite.path
#           systemctl list-timers wpaa-newsite.timer
#           journalctl -u wpaa-newsite.service -n 50
#           tail -f /var/log/wpaa-newsite.log

set -u

ROOT=/root/wpaa
SCRIPT="$ROOT/scripts/watch-new-sites.sh"
UNIT=wpaa-newsite
SVC=/etc/systemd/system/$UNIT.service
TMR=/etc/systemd/system/$UNIT.timer
PTH=/etc/systemd/system/$UNIT.path
VHOSTDIR=/www/server/panel/vhost/nginx
SRC="$(cd "$(dirname "$0")" && pwd)"

if [ "${1:-}" = "--remove" ]; then
  systemctl disable --now "$UNIT.path" 2>/dev/null || true
  systemctl disable --now "$UNIT.timer" 2>/dev/null || true
  rm -f "$SVC" "$TMR" "$PTH"
  systemctl daemon-reload
  echo "ถอด $UNIT ออกแล้ว (ไฟล์สคริปต์ยังอยู่)"
  exit 0
fi

echo "== 1. คัดลอกสคริปต์ไป $ROOT/scripts =="
mkdir -p "$ROOT/scripts"
# ตั้งใจไม่คัดลอกจาก /tmp มาใช้รันตรง ๆ เพราะ /tmp หายตอนรีบูตแล้ว timer จะพังเงียบ
if [ "$SRC" != "$ROOT/scripts" ]; then
  install -m 755 "$SRC/watch-new-sites.sh" "$ROOT/scripts/watch-new-sites.sh"
  [ -f "$SRC/set-wp-autoupdate.sh" ] && install -m 755 "$SRC/set-wp-autoupdate.sh" "$ROOT/scripts/set-wp-autoupdate.sh"
fi
chmod +x "$SCRIPT"
echo "  $SCRIPT"

echo "== 2. เขียน systemd unit =="
cat > "$SVC" <<EOF
[Unit]
Description=wpaa - stamp ไซต์ใหม่ที่เพิ่งสร้างใน aaPanel
Documentation=file://$ROOT/scripts/watch-new-sites.sh

[Service]
Type=oneshot
ExecStart=$SCRIPT
EOF

cat > "$TMR" <<EOF
[Unit]
Description=wpaa - ตรวจหาไซต์ใหม่ทุก 1 นาที

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=$UNIT.service

[Install]
WantedBy=timers.target
EOF
cat > "$PTH" <<EOF
[Unit]
Description=wpaa - ตื่นทันทีเมื่อ panel เขียน vhost ของไซต์ใหม่

[Path]
PathChanged=$VHOSTDIR
Unit=$UNIT.service

[Install]
WantedBy=paths.target
EOF
echo "  $SVC"
echo "  $TMR"
echo "  $PTH"

echo "== 3. เปิดใช้ =="
systemctl daemon-reload
systemctl enable --now "$UNIT.timer"
systemctl enable --now "$UNIT.path"

echo
systemctl list-timers "$UNIT.timer" --no-pager
systemctl status "$UNIT.path" --no-pager -n 0 | head -4
echo
echo "log: /var/log/wpaa-newsite.log (เขียนเฉพาะรอบที่มีอะไรให้แก้จริง)"

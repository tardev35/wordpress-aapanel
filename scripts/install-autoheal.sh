#!/usr/bin/env bash
# install-autoheal.sh - ติดตั้ง nightly-check.sh เข้า crontab ให้รันทุกคืน
#
#   scp -r configs scripts root@SERVER_IP:/tmp/wpaa/
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/install-autoheal.sh"
#
# ตัวเลือก:
#   --no-cron       คัดลอกไฟล์อย่างเดียว ไม่แตะ crontab (ใช้เมื่อจะไปตั้งใน
#                   หน้า Cron ของ aaPanel แทน ซึ่งทีมมองเห็นและกดดูได้)
#   --remove-cron   ถอดบรรทัด cron ที่สคริปต์นี้เคยใส่ไว้ออก
#
# ทำอะไร:
#   1. คัดลอก configs/ + scripts/ ไป /root/wpaa/  (ไม่ใช่ /tmp ซึ่งหายตอนรีบูต)
#   2. เพิ่มบรรทัดใน crontab ให้รัน nightly-check.sh ทุกวัน 23:00 เวลาไทย
#
# ⚠️ เรื่องเวลา: เครื่องนี้ตั้ง timezone เป็น UTC (ตรวจด้วย `timedatectl`)
# 23:00 ไทย = 16:00 UTC จึงเขียนเป็น "0 16 * * *"
#
# ⚠️ ตั้งใจไม่ใช้ CRON_TZ=Asia/Bangkok ถึงแม้จะอ่านง่ายกว่า เพราะ CRON_TZ มีผลกับ
# ทุกบรรทัดที่อยู่ถัดจากมันในไฟล์เดียวกัน - งาน cron ของ aaPanel ที่อยู่ในไฟล์นี้อยู่แล้ว
# จะโดนเลื่อนเวลาไปด้วยโดยไม่ตั้งใจ
#
# ⚠️ บรรทัดนี้ไม่โผล่ในหน้า Cron ของ aaPanel เพราะ panel อ่านจากฐานข้อมูลของตัวเอง
# ไม่ได้อ่าน crontab ตรง ๆ - ดูด้วย `crontab -l`

set -e

SRC=$(cd "$(dirname "$0")/.." && pwd)
DEST=/root/wpaa
MARK="# wpaa-nightly"
CRON_LINE="0 16 * * * /usr/bin/flock -n /tmp/wpaa-nightly.lock /root/wpaa/scripts/nightly-check.sh $MARK"

MODE="${1:-install}"

if [ "$MODE" = "--remove-cron" ]; then
  CUR=$(crontab -l 2>/dev/null || true)
  if echo "$CUR" | grep -qF "$MARK"; then
    echo "$CUR" | grep -vF "$MARK" | crontab -
    echo "ถอดบรรทัด cron ออกแล้ว - ไฟล์ใน $DEST ยังอยู่ครบ"
  else
    echo "ไม่มีบรรทัด cron ของสคริปต์นี้อยู่แล้ว"
  fi
  crontab -l 2>/dev/null | grep -v '^$' || true
  exit 0
fi

[ -d "$SRC/configs" ] || { echo "ไม่เจอ $SRC/configs - อัปทั้งโฟลเดอร์ configs/ และ scripts/ ขึ้นมาด้วย"; exit 1; }

echo "== 1. คัดลอกไป $DEST =="
mkdir -p "$DEST"
cp -r "$SRC/configs" "$DEST/"
cp -r "$SRC/scripts" "$DEST/"
chmod +x "$DEST/scripts/"*.sh
echo "$DEST/configs  ($(ls "$DEST/configs" | wc -l) ไฟล์)"
echo "$DEST/scripts  ($(ls "$DEST/scripts" | wc -l) ไฟล์)"

if [ "$MODE" = "--no-cron" ]; then
  echo
  echo "== ข้าม crontab (--no-cron) =="
  echo "ไปตั้งในหน้า Cron ของ aaPanel แทน:"
  echo "  Task type     : Shell Script"
  echo "  Task name     : wpaa nightly check"
  echo "  Execute cycle : Daily  16 : 00     <-- 16:00 UTC = 23:00 เวลาไทย"
  echo "  Execute user  : root"
  echo "  Script content: /root/wpaa/scripts/nightly-check.sh"
  echo
  echo "หน้า Cron ของ panel ใช้ 'เวลาเครื่อง' ซึ่งเครื่องนี้เป็น UTC"
  echo "ใส่ 23:00 ตรง ๆ จะไปรัน 6 โมงเช้าของวันถัดไปตามเวลาไทย"
  exit 0
fi

echo "== 2. crontab =="
CUR=$(crontab -l 2>/dev/null || true)
if echo "$CUR" | grep -qF "$MARK"; then
  echo "มีอยู่แล้ว - อัปเดตบรรทัดเดิม"
  echo "$CUR" | grep -vF "$MARK" > /tmp/wpaa-cron.tmp
else
  echo "$CUR" > /tmp/wpaa-cron.tmp
fi
echo "$CRON_LINE" >> /tmp/wpaa-cron.tmp
crontab /tmp/wpaa-cron.tmp
rm -f /tmp/wpaa-cron.tmp

echo
crontab -l | grep -F "$MARK"
echo
echo "23:00 เวลาไทย = 16:00 UTC (เครื่องนี้เป็น UTC)"
echo "log: /var/log/wpaa-nightly.log"
echo
echo "ทดสอบเลยได้โดยไม่ต้องรอ:"
echo "  /root/wpaa/scripts/nightly-check.sh && tail -20 /var/log/wpaa-nightly.log"

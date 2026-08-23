#!/usr/bin/env bash
# set-redis-limit.sh [ขนาด] - จำกัด RAM ของ Redis พร้อมตั้ง policy ให้ถูกต้อง
#
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/set-redis-limit.sh"       # 1gb
#   ssh root@SERVER_IP "bash /tmp/wpaa/scripts/set-redis-limit.sh 512mb"
#
# ⚠️ ทำไมไม่ใช้ช่อง maxmemory ในหน้า Redis ของ aaPanel:
# ช่องนั้นรับ "ตัวเลขหน่วย MB" (พิมพ์ 1gb ไม่ได้ ต้องพิมพ์ 1024) และที่สำคัญกว่าคือ
# มันตั้งให้แค่ maxmemory ไม่ได้ตั้ง maxmemory-policy ซึ่งค่าเริ่มต้นคือ noeviction
#
# noeviction = พอเต็มเพดาน Redis จะ "ปฏิเสธคำสั่งเขียน" ไม่ใช่ทิ้งคีย์เก่า
# สำหรับ object cache นี่แย่กว่าไม่จำกัดเลย เพราะ WordPress จะเริ่มได้ error ตอนเขียน cache
# แทนที่จะแค่ใช้ RAM เยอะ -> ต้องตั้งคู่กับ allkeys-lru เสมอ

set -e

SIZE="${1:-1gb}"
CONF=/www/server/redis/redis.conf
BAK="$CONF.bak-$(date +%F-%H%M%S)"

[ -f "$CONF" ] || { echo "ไม่พบ $CONF"; exit 1; }

if grep -qE '^\s*maxmemory\s' "$CONF"; then
  echo "redis.conf มี maxmemory อยู่แล้ว - แก้เองในไฟล์ ไม่เขียนซ้ำให้"
  grep -nE '^\s*maxmemory' "$CONF"
  exit 0
fi

echo "== สำรอง redis.conf =="
cp -p "$CONF" "$BAK"
echo "$BAK"

echo "== เพิ่มค่า =="
{
  echo ""
  echo "# ตั้งโดย scripts/set-redis-limit.sh - ต้องมีคู่กันเสมอ"
  echo "# ไม่มี policy = noeviction = ปฏิเสธการเขียนเมื่อเต็ม ซึ่งพัง object cache"
  echo "maxmemory $SIZE"
  echo "maxmemory-policy allkeys-lru"
} >> "$CONF"
tail -4 "$CONF"

echo "== restart redis (reload ไม่พอ) =="
/etc/init.d/redis restart

sleep 2
echo "== ยืนยัน =="
printf 'maxmemory        : %s\n' "$(redis-cli config get maxmemory | tail -1)"
printf 'maxmemory-policy : %s\n' "$(redis-cli config get maxmemory-policy | tail -1)"
redis-cli ping

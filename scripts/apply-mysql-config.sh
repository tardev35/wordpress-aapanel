#!/usr/bin/env bash
# apply-mysql-config.sh [--check] [--restart] - ตั้งค่า MariaDB ตาม docs/03 หัวข้อ 3.4
#
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/apply-mysql-config.sh --check"     # ดูอย่างเดียว
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/apply-mysql-config.sh"             # แก้ไฟล์ ยังไม่ restart
#   ssh root@SERVER_IP "bash /root/wpaa/scripts/apply-mysql-config.sh --restart"   # แก้แล้ว restart เลย
#
# ทำไมต้องมี: ค่าจูน MariaDB ใน docs/03 หัวข้อ 3.4 **ไม่เคยถูกตั้งจริงบนเครื่องไหนเลย**
# (ตรวจเมื่อ 2026-08-25 ทั้ง 2 เครื่องเหมือนกันเป๊ะ: buffer pool 1024M แทน 4096M,
# max_connections 400 แทน 200, join_buffer_size 4096K แทน 256K)
#
# join_buffer_size จองแยกต่อ connection - 4096K x 400 conn = จองไว้ได้ถึง ~1.6 GB
# โดยที่ WordPress แทบไม่ได้ใช้ join ใหญ่ขนาดนั้นเลย
#
# 🔴 ค่าพวกนี้มีผลก็ต่อเมื่อ restart MariaDB เท่านั้น - เปลี่ยนขณะรันไม่ได้
# ระหว่าง restart หน้าที่อยู่ใน FastCGI cache ยังเสิร์ฟได้ปกติ (ไม่แตะ PHP/MySQL)
# ส่วน request ที่ต้องผ่าน PHP จะพลาดช่วงสั้น ๆ
#
# ความปลอดภัยที่ใส่ไว้:
#   1. ตรวจก่อนว่าทุก option ที่จะเขียน มีอยู่จริงใน mysqld รุ่นนี้
#      (`mysqld --verbose --help` - ทดสอบแล้วว่ามันปฏิเสธชื่อมั่ว ๆ จริง)
#   2. สำรอง /etc/my.cnf ไว้ก่อนเสมอ
#   3. ถ้า restart แล้ว MariaDB ไม่กลับมาภายใน 60 วินาที **กู้ไฟล์เดิมแล้ว restart ใหม่ให้เอง**
#
# ⚠️ ไม่มีตัวตรวจ syntax แบบ `nginx -t` ให้ใช้ - `mysqld --verbose --help` ผ่านแม้ใส่
# option มั่ว และ `--validate-config` รันเป็น root ไม่ได้ จึงต้องใช้วิธีข้อ 1 แทน
#
# ค่าเหล่านี้ผูกกับเครื่อง 4 vCPU / 16 GB - เครื่องขนาดอื่นดู docs/10 หัวข้อ 10.8
# แล้วแก้ทั้งเอกสาร สคริปต์นี้ และ verify-config.sh ให้ตรงกัน

set -u

CNF=/etc/my.cnf
BK=/root/wpaa/backups
BIN=$(command -v mariadbd 2>/dev/null || echo /www/server/mysql/bin/mysqld)
MODE=set
DORESTART=0

for a in "$@"; do
  case "$a" in
    --check)   MODE=check ;;
    --restart) DORESTART=1 ;;
    *) echo "ไม่รู้จักตัวเลือก: $a"; exit 1 ;;
  esac
done

# คีย์กับค่าที่ docs/03 หัวข้อ 3.4 ระบุ - ลำดับในนี้คือลำดับที่จะถูกเติมถ้ายังไม่มี
TARGETS="
innodb_buffer_pool_size=4096M
max_connections=200
join_buffer_size=256K
read_rnd_buffer_size=256K
table_open_cache=2048
query_cache_size=0M
innodb_flush_log_at_trx_commit=2
innodb_flush_method=O_DIRECT
innodb_io_capacity=2000
innodb_io_capacity_max=4000
table_definition_cache=2000
long_query_time=2
"

[ -f "$CNF" ] || { echo "ไม่มี $CNF"; exit 1; }
[ -x "$BIN" ] || { echo "หา mysqld ไม่เจอ: $BIN"; exit 1; }

echo "== 1. ตรวจว่า option ทุกตัวมีอยู่จริงใน mysqld รุ่นนี้ =="
HELP=$("$BIN" --verbose --help 2>/dev/null)
bad=0
for kv in $TARGETS; do
  k="${kv%%=*}"
  # ในหน้า help ชื่อ option ใช้ขีดกลางแทนขีดล่าง และตามด้วย " ", "=", หรือ "[=#]"
  if ! printf '%s' "$HELP" | grep -qE "^  --$(printf '%s' "$k" | tr _ -)( |=|\[|$)"; then
    echo "  !! ไม่มี option ชื่อ $k ในรุ่นนี้ - ยกเลิกทั้งหมด"
    bad=1
  fi
done
[ "$bad" = "0" ] || exit 1
echo "  ผ่านทุกตัว"

echo
echo "== 2. เทียบค่าปัจจุบันกับที่ควรเป็น =="
need=0
for kv in $TARGETS; do
  k="${kv%%=*}"; want="${kv#*=}"
  cur=$(grep -E "^[[:space:]]*$k[[:space:]]*=" "$CNF" | tail -1 | sed 's/.*=[[:space:]]*//;s/[[:space:]]*$//')
  if [ "$cur" = "$want" ]; then
    printf '  %-32s OK (%s)\n' "$k" "$cur"
  else
    printf '  %-32s %s -> %s\n' "$k" "${cur:-ไม่ได้ตั้ง}" "$want"
    need=$((need+1))
  fi
done

if [ "$need" = "0" ]; then
  echo
  echo "ตรงตามเอกสารอยู่แล้วทุกค่า ไม่ต้องทำอะไร"
  exit 0
fi

if [ "$MODE" = "check" ]; then
  echo
  echo "โหมด --check ไม่ได้แก้อะไร ($need ค่าต้องแก้)"
  exit 0
fi

echo
echo "== 3. สำรองของเดิม =="
mkdir -p "$BK"
BAKFILE="$BK/my.cnf.bak-$(date +%F-%H%M%S)"
cp -p "$CNF" "$BAKFILE"
echo "  $BAKFILE"

echo
echo "== 4. เขียนไฟล์ใหม่ =="
# แก้เฉพาะบรรทัดที่ตรงคีย์ใน [mysqld] และเติมตัวที่ยังไม่มีก่อนจบ section
# ไม่ใช้ sed -i กับไฟล์ config (กฎข้อ 2 ใน README) - สร้างไฟล์ใหม่แล้วค่อยเอาไปทับ
TMP=$(mktemp)
printf '%s' "$TARGETS" | grep -v '^$' > /tmp/wpaa-mysql-targets

awk '
BEGIN {
  while ((getline line < "/tmp/wpaa-mysql-targets") > 0) {
    split(line, a, "=")
    want[a[1]] = substr(line, index(line, "=") + 1)
  }
  insec = 0
}
/^\[/ {
  if (insec) { flush() }        # ออกจาก [mysqld] แล้ว - เติมตัวที่ยังไม่ได้เขียน
  insec = ($0 == "[mysqld]")
  print; next
}
{
  if (insec) {
    line = $0
    for (k in want) {
      if (line ~ "^[ \t]*" k "[ \t]*=") {
        if (!(k in done)) { print k " = " want[k]; done[k] = 1 }
        next
      }
    }
  }
  print
}
END { if (insec) flush() }
function flush(  k) {
  for (k in want) if (!(k in done)) { print k " = " want[k]; done[k] = 1 }
}
' "$CNF" > "$TMP"

rm -f /tmp/wpaa-mysql-targets

# กันเหนียว: ไฟล์ใหม่ต้องไม่สั้นผิดปกติ และต้องยังมี datadir อยู่
if [ "$(wc -l < "$TMP")" -lt 20 ] || ! grep -q "^datadir" "$TMP"; then
  echo "  !! ไฟล์ใหม่ดูผิดปกติ ไม่เอาไปทับ - ของเดิมยังอยู่ครบ"
  rm -f "$TMP"; exit 1
fi

install -m 644 -o root -g root "$TMP" "$CNF"
rm -f "$TMP"
echo "  เขียน $CNF แล้ว"

for kv in $TARGETS; do
  k="${kv%%=*}"
  printf '  %-32s %s\n' "$k" "$(grep -E "^[[:space:]]*$k[[:space:]]*=" "$CNF" | tail -1 | sed 's/.*=[[:space:]]*//')"
done

if [ "$DORESTART" = "0" ]; then
  echo
  echo "🔴 ค่ายังไม่มีผลจนกว่าจะ restart:  /etc/init.d/mysqld restart"
  echo "   หรือรันสคริปต์นี้ใหม่ด้วย --restart"
  exit 0
fi

echo
echo "== 5. restart MariaDB =="
T0=$(date +%s)
/etc/init.d/mysqld restart >/dev/null 2>&1

ok=0
for i in $(seq 1 60); do
  if mysqladmin ping >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
T1=$(date +%s)

if [ "$ok" = "1" ]; then
  echo "  กลับมาแล้วใน $((T1-T0)) วินาที"
else
  echo "  !! ไม่กลับมาภายใน 60 วินาที - กู้ไฟล์เดิมแล้ว restart ใหม่"
  install -m 644 -o root -g root "$BAKFILE" "$CNF"
  /etc/init.d/mysqld restart >/dev/null 2>&1
  for i in $(seq 1 60); do mysqladmin ping >/dev/null 2>&1 && break; sleep 1; done
  if mysqladmin ping >/dev/null 2>&1; then
    echo "  กู้สำเร็จ MariaDB กลับมาด้วยคอนฟิกเดิม - ดู error log ก่อนลองใหม่:"
  else
    echo "  🔴 กู้แล้วยังไม่ขึ้น - ต้องเข้าไปดูด้วยมือทันที:"
  fi
  echo "     tail -50 /www/server/data/*.err"
  exit 1
fi

echo
echo "== 6. ยืนยันจากตัว MariaDB เอง (ไม่ใช่จากไฟล์) =="
mysql -Nse "SHOW VARIABLES WHERE Variable_name IN (
 'innodb_buffer_pool_size','max_connections','join_buffer_size',
 'read_rnd_buffer_size','table_open_cache','query_cache_size',
 'innodb_flush_log_at_trx_commit','innodb_flush_method',
 'innodb_io_capacity','table_definition_cache','long_query_time');" 2>/dev/null \
 | awk '{printf "  %-32s %s\n", $1, $2}'

#!/usr/bin/env bash
# set-wp-admin.sh [--check] [--pass 'PASS'] [--user USER] [DOMAIN]
#   ทำให้รหัส admin จริงของทุกเว็บ "ตรงกับที่ตั้งไว้" หลังลง WordPress แบบ batch
#
#   ssh root@IP "bash /root/wpaa/scripts/set-wp-admin.sh --check"          # ดูว่ารหัสไหนเพี้ยน (ไม่แก้)
#   ssh root@IP "bash /root/wpaa/scripts/set-wp-admin.sh"                  # ตั้งให้ตรงกับที่ panel เก็บ (onekey)
#   ssh root@IP "bash /root/wpaa/scripts/set-wp-admin.sh --pass 'Abc+123'" # บังคับรหัสเดียวกันทุกเว็บ
#   ssh root@IP "bash /root/wpaa/scripts/set-wp-admin.sh ceo89x.com"       # เว็บเดียว
#
# ปัญหาที่แก้: aaPanel WP Toolkit (one-key) ลง WP แบบ batch แล้วรหัส admin จริง "ไม่ตรง" กับที่กรอก
#   ในฟอร์ม โดยเฉพาะรหัสมีอักขระพิเศษ (+ = & % ฯลฯ) ที่โดน escape เพี้ยนตอน install ต้องมานั่ง
#   รีเซ็ตทีละเว็บ เสียเวลา
#
# วิธีทำงาน: อ่าน user/pass ที่ "ตั้งใจ" จากตาราง wordpress_onekey ของ panel (จับคู่ด้วย table_prefix
#   ของแต่ละเว็บ) แล้วบังคับรหัส admin จริงให้ตรง ด้วย wp_set_password() ของ WordPress เอง — hash ถูก
#   เสมอ ทุกเวอร์ชัน (phpass/bcrypt). --pass บังคับรหัสที่กำหนดเองแทนค่าใน onekey
#
# ปลอดภัย: เช็คก่อนเสมอ ตรงอยู่แล้ว = ไม่แตะ (ไม่เตะ session ทิ้งฟรี ๆ) · แก้เฉพาะตัวที่เพี้ยน
#   --check = ดูอย่างเดียวไม่แก้ · ตั้งรหัสด้วย wp_set_password (ล้าง session เก่าให้อัตโนมัติ)
set -u

ODB=/www/server/panel/data/default.db
CRED=/tmp/.wpadmincred.$$
PHPF=/tmp/.wpadminchk.$$.php
MODE=apply
ONLY=""
OV_PASS=""
OV_USER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE=check ;;
    --pass) shift; OV_PASS="${1:-}" ;;
    --user) shift; OV_USER="${1:-}" ;;
    --*) echo "ไม่รู้จักตัวเลือก: $1"; exit 1 ;;
    *) ONLY="$1" ;;
  esac
  shift
done

[ -f "$ODB" ] || { echo "🔴 ไม่พบ $ODB (เครื่องนี้ใช่ aaPanel ไหม?)"; exit 1; }
command -v sqlite3 >/dev/null || { echo "🔴 ไม่มี sqlite3"; exit 1; }

# หา PHP binary ของ panel (เลี่ยง php -t เปล่า ๆ ที่อาจชี้ผิดเวอร์ชัน)
PHP=""
for v in 83 84 82 81; do [ -x "/www/server/php/$v/bin/php" ] && { PHP="/www/server/php/$v/bin/php"; break; }; done
[ -n "$PHP" ] || { echo "🔴 ไม่พบ php binary ใน /www/server/php/*/bin"; exit 1; }

# สคริปต์ PHP: โหลด WP ของเว็บนั้น -> เช็ค/ตั้งรหัส admin (อ่าน cred จากไฟล์ กันอักขระพิเศษเพี้ยน)
cat > "$PHPF" <<'PHP'
<?php
define('WP_USE_THEMES', false);
error_reporting(0);
$creds = @file(getenv('WPCRED'), FILE_IGNORE_NEW_LINES);
if ($creds === false || count($creds) < 2) { echo "RESULT|ERR|อ่าน cred ไม่ได้\n"; exit; }
list($intended_user, $intended_pass) = $creds;
$_SERVER['HTTP_HOST'] = getenv('WPHOST') ?: 'localhost';
$_SERVER['REQUEST_URI'] = '/';
$_SERVER['REQUEST_METHOD'] = 'GET';
require getenv('WPROOT') . '/wp-load.php';
$u = $intended_user ? get_user_by('login', $intended_user) : false;
if (!$u) { $a = get_users(['role' => 'administrator', 'number' => 1, 'orderby' => 'ID', 'order' => 'ASC']); $u = $a[0] ?? null; }
if (!$u) { echo "RESULT|NOADMIN|\n"; exit; }
$match = wp_check_password($intended_pass, $u->user_pass, $u->ID);
if ($match) { echo "RESULT|OK|{$u->user_login}\n"; exit; }
if (getenv('WPMODE') === 'apply') {
    wp_set_password($intended_pass, $u->ID);
    echo "RESULT|FIXED|{$u->user_login}\n";
} else {
    echo "RESULT|DRIFT|{$u->user_login}\n";
}
PHP

n_ok=0; n_fix=0; n_drift=0; n_skip=0
echo "โหมด: $([ "$MODE" = check ] && echo 'เช็คอย่างเดียว (--check)' || echo 'แก้จริง') · รหัสที่ใช้: $([ -n "$OV_PASS" ] && echo '--pass ที่กำหนด' || echo 'ค่าใน wordpress_onekey')"
echo

for d in /www/wwwroot/*/; do
  b=$(basename "$d")
  [ "$b" = "default" ] && continue
  [ -n "$ONLY" ] && [ "$b" != "$ONLY" ] && continue
  [ -f "$d/wp-config.php" ] || continue

  pfx=$(grep -m1 'table_prefix' "$d/wp-config.php" | sed "s/.*= *'//;s/'.*//")
  ok=$(sqlite3 -separator '|' "$ODB" "SELECT user,pass FROM wordpress_onekey WHERE prefix='$pfx' LIMIT 1;" 2>/dev/null)
  U="${OV_USER:-${ok%%|*}}"
  P="${OV_PASS:-${ok#*|}}"

  if [ -z "$OV_PASS" ] && [ -z "$ok" ]; then
    printf '%-26s ข้าม: prefix=%s ไม่มีใน onekey (ใส่ --pass เพื่อบังคับ)\n' "$b" "$pfx"
    n_skip=$((n_skip+1)); continue
  fi
  if [ -z "$P" ]; then
    printf '%-26s ข้าม: ไม่รู้รหัสที่ตั้งใจ\n' "$b"; n_skip=$((n_skip+1)); continue
  fi

  printf '%s\n%s\n' "$U" "$P" > "$CRED"; chmod 640 "$CRED"; chown root:www "$CRED" 2>/dev/null
  res=$(WPMODE="$MODE" WPHOST="$b" WPROOT="$d" WPCRED="$CRED" \
        su -s /bin/bash www -c "WPMODE='$MODE' WPHOST='$b' WPROOT='$d' WPCRED='$CRED' '$PHP' '$PHPF'" 2>/dev/null | grep '^RESULT|')
  st="${res#RESULT|}"; tag="${st%%|*}"; login="${st#*|}"
  case "$tag" in
    OK)      printf '%-26s ✅ ตรงอยู่แล้ว (admin=%s)\n' "$b" "$login"; n_ok=$((n_ok+1)) ;;
    FIXED)   printf '%-26s 🔧 ตั้งรหัสใหม่แล้ว (admin=%s)\n' "$b" "$login"; n_fix=$((n_fix+1)) ;;
    DRIFT)   printf '%-26s ⚠️  รหัสเพี้ยน! (admin=%s) — รันโหมดแก้เพื่อตั้งให้ตรง\n' "$b" "$login"; n_drift=$((n_drift+1)) ;;
    NOADMIN) printf '%-26s 🔴 หา admin ไม่เจอในเว็บ\n' "$b"; n_skip=$((n_skip+1)) ;;
    *)       printf '%-26s 🔴 เช็คไม่สำเร็จ (%s)\n' "$b" "${st:-ไม่มีผลลัพธ์}"; n_skip=$((n_skip+1)) ;;
  esac
done

rm -f "$CRED" "$PHPF"
echo
echo "สรุป: ตรงอยู่แล้ว $n_ok · แก้แล้ว $n_fix · เพี้ยน(ยังไม่แก้) $n_drift · ข้าม $n_skip"
[ "$MODE" = check ] && [ "$n_drift" -gt 0 ] && echo "-> รันซ้ำแบบไม่ใส่ --check เพื่อตั้งรหัสให้ตรง"
exit 0

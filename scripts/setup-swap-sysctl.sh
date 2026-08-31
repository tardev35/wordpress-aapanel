#!/usr/bin/env bash
# setup-swap-sysctl.sh [--check] - swap + sysctl tuning + BBR (ตาม docs/02 §2.2 · docs/03 §3.1)
#
# สคริปต์เดี่ยว ไม่อ่าน configs/ จึง pipe ผ่าน bash -s ได้เลย ไม่ต้องอัป repo ขึ้นเครื่อง
#   ssh root@SERVER_IP "bash -s"            < scripts/setup-swap-sysctl.sh   # ติดตั้ง
#   ssh root@SERVER_IP "bash -s -- --check" < scripts/setup-swap-sysctl.sh   # ดูสถานะ
#   ssh root@SERVER_IP "SWAP_GB=8 bash -s"  < scripts/setup-swap-sysctl.sh   # เปลี่ยนขนาด swap
#
# idempotent - รันซ้ำได้ · ถ้ามี swap อยู่แล้วข้ามการสร้าง (ไม่ลบ/ไม่ทับ swap เดิม)
# ⚠️ ทำตอนเครื่องยังว่าง (ก่อนเอาเว็บขึ้น) จะได้ไม่กระทบใคร

set -u
SWAP_GB="${SWAP_GB:-4}"
SWAPFILE=/swapfile
SYSCTL=/etc/sysctl.d/99-tuning.conf
ACTION="${1:-install}"

if [ "$ACTION" = "--check" ]; then
  echo "== สถานะ =="
  echo "  swap:"; swapon --show 2>/dev/null | sed 's/^/    /' || echo "    ไม่มี"
  free -h | awk 'NR==1 || /Swap/' | sed 's/^/  /'
  echo "  tcp_congestion_control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo "  swappiness            : $(cat /proc/sys/vm/swappiness 2>/dev/null)"
  echo "  sysctl file           : $([ -f "$SYSCTL" ] && echo 'มี' || echo 'ยังไม่มี')"
  exit 0
fi

echo "== 1. swap =="
if swapon --show 2>/dev/null | grep -q .; then
  echo "  มี swap อยู่แล้ว ข้าม ($(swapon --show=NAME --noheadings 2>/dev/null | tr '\n' ' '))"
else
  echo "  สร้าง swap ${SWAP_GB}G ที่ $SWAPFILE"
  if ! fallocate -l "${SWAP_GB}G" "$SWAPFILE" 2>/dev/null; then
    echo "  (fallocate ไม่ได้ ใช้ dd แทน อาจช้าหน่อย)"
    dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SWAP_GB * 1024)) status=none
  fi
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE" >/dev/null
  swapon "$SWAPFILE"
  grep -q "^$SWAPFILE " /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
  echo "  เปิด swap แล้ว + ใส่ /etc/fstab (ติดถาวรหลัง reboot)"
fi

echo "== 2. BBR module =="
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
modprobe tcp_bbr 2>/dev/null || true

echo "== 3. sysctl tuning =="
cat > "$SYSCTL" <<'SYS'
# ใช้ RAM ให้เต็มที่ก่อนแตะ swap
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# รองรับ connection จำนวนมาก
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65535

# BBR - อัลกอริทึมควบคุมความแออัดของ Google (ลดเวลาส่งข้ามทวีป 10-25%)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

fs.file-max = 2097152
SYS
sysctl --system >/dev/null 2>&1
echo "  วาง $SYSCTL + sysctl --system แล้ว"

echo
echo "== ตรวจผล =="
cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
sw=$(cat /proc/sys/vm/swappiness 2>/dev/null)
echo "  tcp_congestion_control : $cc  $([ "$cc" = bbr ] && echo '✅' || echo '⚠️ ไม่ใช่ bbr (บาง kernel ไม่มี module)')"
echo "  swappiness             : $sw  $([ "$sw" = 10 ] && echo '✅' || echo '⚠️')"
echo "  swap                   : $(free -h | awk '/Swap/{print $2}')  ✅"
echo
echo "ตรวจซ้ำ: bash setup-swap-sysctl.sh --check"

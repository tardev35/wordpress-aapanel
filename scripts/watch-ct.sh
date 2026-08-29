#!/usr/bin/env bash
# watch-ct.sh - ดูสตรีมใบรับรองสด ๆ จาก Certificate Transparency log ทุกตัวที่ใช้งานได้
#
#   bash watch-ct.sh                 # ดึงรอบเดียว ทุก log แล้วจบ
#   bash watch-ct.sh --follow        # วนดูเรื่อย ๆ (Ctrl-C เพื่อออก)
#   bash watch-ct.sh --logs          # แค่ดูว่าตอนนี้มี log ไหนใช้ได้บ้าง
#   bash watch-ct.sh --mine          # ไฮไลต์เฉพาะโดเมนที่อยู่บนเครื่องนี้
#   bash watch-ct.sh --grep bank     # ไฮไลต์โดเมนที่มีคำนี้
#   bash watch-ct.sh --n 40          # จำนวน entry ที่ดึงต่อ log ต่อรอบ (ค่าเริ่มต้น 20)
#
# ทำไมต้องมี: บอทที่เจาะ bbc29pro.com หาเว็บเจอจากที่นี่ ไม่ใช่จาก Google
# (ดู docs/11-security.md) - หน้านี้ทำให้เห็นท่อนั้นด้วยตาตัวเอง
#
# มันทำอะไร - ไม่มีอะไรมากกว่า 3 ขั้น:
#   1. โหลดรายชื่อ log ทางการจาก Google (log_list.json) แล้วคัดเฉพาะตัวที่
#      สถานะ usable/qualified และยังอยู่ในช่วงเวลาที่รับ cert
#   2. ถาม ct/v1/get-sth ว่าตอนนี้เก็บไปกี่ใบ
#   3. ขอ ct/v1/get-entries ใบท้าย ๆ มาแกะด้วย openssl x509 เอาชื่อโดเมนออกมา
#
# ⚠️ นี่คือ **การสุ่มดู** ไม่ใช่การรับครบทุกใบ
# วัดจริงบน Nimbus 2026 ได้ 118 ใบ/วินาที ต่อ log เดียว x 11 log = เกิน 1,000 ใบ/วินาที
# การรับให้ครบต้องไล่ทุก index ต่อเนื่อง ซึ่งกินแบนด์วิดท์มหาศาล
#
# ⏱️ เวลาที่เห็นจากแต่ละ log ไม่เท่ากัน เป็นเรื่องปกติ
# get-sth คืน tree_size ที่ log เซ็นไว้เป็นรอบ ไม่ใช่ค่าล่าสุดวินาทีต่อวินาที
# วัดจริง 2026-08-29 14:49 UTC:  Google argon = 14:48 (ช้า 1 นาที)
#                                 Cloudflare nimbus = 14:00 (ช้า 49 นาที)
# เวลาที่แสดงเป็นเวลาที่ cert ถูกบันทึกจริง จึงย้อนหลังตามรอบเซ็นของแต่ละ log
#
# 🔴 ถ้าเป้าหมายคือ "รู้ทันทีที่มีใครออก cert ให้โดเมนเรา" **อย่าใช้สคริปต์นี้**
# เพราะสุ่มดูแล้วจะพลาด ให้ใช้ทางที่ออกแบบมาเพื่อการนั้นแทน:
#   - Cloudflare -> SSL/TLS -> Certificate Transparency Monitoring (ต่อ zone)
#   - crt.sh มี RSS ต่อโดเมน
#   - หรือ query crt.sh เป็นรอบ:  curl -s "https://crt.sh/?q=DOMAIN&output=json"

set -u

LIST_URL=https://www.gstatic.com/ct/log_list/v3/log_list.json
CACHE=/tmp/wpaa-ct-loglist.json
N=20
MODE=once
HILITE=""
MINE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --follow) MODE=follow ;;
    --logs)   MODE=logs ;;
    --mine)   MINE=1 ;;
    --grep)   shift; HILITE="${1:-}" ;;
    --n)      shift; N="${1:-20}" ;;
    *) echo "ไม่รู้จักตัวเลือก: $1"; exit 1 ;;
  esac
  shift
done

command -v openssl >/dev/null || { echo "ต้องมี openssl"; exit 1; }
command -v python3 >/dev/null || { echo "ต้องมี python3"; exit 1; }

# ---------- รายชื่อ log ----------
# ดึงใหม่ถ้าไฟล์เก่าเกิน 12 ชั่วโมง - Google อัปเดตรายการนี้เรื่อย ๆ
# log หมดอายุตามช่วงเวลา (shard ปีละ 2 ครั้ง) เขียน URL ตายตัวไว้จะพังทุกครึ่งปี
if [ ! -f "$CACHE" ] || [ -n "$(find "$CACHE" -mmin +720 2>/dev/null)" ]; then
  curl -s --max-time 30 "$LIST_URL" -o "$CACHE" || { echo "โหลดรายชื่อ log ไม่ได้"; exit 1; }
fi

LOGS=$(python3 - "$CACHE" <<'PY'
import json,sys,datetime
d=json.load(open(sys.argv[1]))
today=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
for op in d["operators"]:
    for log in op.get("logs",[]):
        st=log.get("state",{})
        if not any(k in st for k in ("usable","qualified")): continue
        iv=log.get("temporal_interval",{})
        s=iv.get("start_inclusive","")[:10]; e=iv.get("end_exclusive","")[:10]
        if e and e<=today: continue
        if s and s>today:  continue
        print("%s|%s" % (op["name"], log["url"].rstrip("/")))
PY
)

if [ "$MODE" = "logs" ]; then
  echo "CT log ที่ใช้งานได้ตอนนี้ (จาก log_list.json ของ Google):"
  printf '%s\n' "$LOGS" | while IFS='|' read -r name url; do
    printf '  %-14s %s\n' "$name" "$url"
  done
  echo
  echo "  รวม $(printf '%s\n' "$LOGS" | grep -c .) log"
  exit 0
fi

# ---------- รายชื่อโดเมนของเราเอง ----------
MYDOMAINS=/tmp/wpaa-ct-mine.txt
: > "$MYDOMAINS"
if [ "$MINE" = "1" ] && [ -d /www/wwwroot ]; then
  ls -1 /www/wwwroot 2>/dev/null | grep '\.' > "$MYDOMAINS"
  echo "เฝ้าโดเมนบนเครื่องนี้ $(wc -l < "$MYDOMAINS") รายการ"
fi

fetch_log() {
  local name="$1" url="$2"
  local sth size
  sth=$(curl -s --max-time 12 "$url/ct/v1/get-sth" 2>/dev/null) || return
  size=$(printf '%s' "$sth" | grep -oE '"tree_size":[0-9]+' | cut -d: -f2)
  [ -n "$size" ] || return
  local start=$(( size - N )) end=$(( size - 1 ))
  [ "$start" -lt 0 ] && start=0
  curl -s --max-time 25 "$url/ct/v1/get-entries?start=$start&end=$end" 2>/dev/null \
    | NAME="$name" SIZE="$size" HILITE="$HILITE" MINEF="$MYDOMAINS" python3 -c '
import json,sys,os,base64,struct,subprocess,re,datetime
name=os.environ["NAME"]; hil=os.environ.get("HILITE","").lower()
mine=set()
try:
    mine={l.strip().lower() for l in open(os.environ["MINEF"]) if l.strip()}
except Exception: pass
try: d=json.load(sys.stdin)
except Exception: sys.exit()
G="\033[38;5;244m"; Y="\033[38;5;214m"; R="\033[38;5;203m"; N0="\033[0m"
for e in d.get("entries",[]):
    try:
        leaf=base64.b64decode(e["leaf_input"])
        ts=struct.unpack(">Q",leaf[2:10])[0]/1000
        et=struct.unpack(">H",leaf[10:12])[0]
        if et==0:
            ln=int.from_bytes(leaf[12:15],"big"); der=leaf[15:15+ln]
        else:
            ex=base64.b64decode(e["extra_data"]); ln=int.from_bytes(ex[3:6],"big"); der=ex[6:6+ln]
        o=subprocess.run(["openssl","x509","-inform","DER","-noout","-issuer","-ext","subjectAltName"],
                         input=der,capture_output=True).stdout.decode("utf8","ignore")
        names=re.findall(r"DNS:([^,\s]+)",o)
        m=re.search(r"issuer=.*?O\s*=\s*([^,\n]+)",o); iss=(m.group(1).strip() if m else "?")[:18]
    except Exception:
        continue
    if not names: continue
    dom=names[0]; extra=(" +%d"%(len(names)-1)) if len(names)>1 else ""
    low=dom.lower().lstrip("*.")
    mark=""
    if low in mine or any(low.endswith("."+x) for x in mine): mark=R+"  <== โดเมนของเรา"+N0
    elif hil and hil in dom.lower():                          mark=Y+"  <== ตรงคำค้น"+N0
    t=datetime.datetime.utcfromtimestamp(ts).strftime("%H:%M:%S")
    print("%s%s  %-13s%s %-44s %s%-18s%s%s" % (G,t,name[:13],N0,dom[:44],G,iss,N0,mark))
'
}

run_once() {
  printf '%s\n' "$LOGS" | while IFS='|' read -r name url; do
    [ -n "$url" ] && fetch_log "$name" "$url"
  done
}

echo "ดึง $N ใบล่าสุดจากทุก log · $(printf '%s\n' "$LOGS" | grep -c .) log"
echo "เวลา(UTC)  log            โดเมน                                        ผู้ออก cert"
echo "---------------------------------------------------------------------------------------"

if [ "$MODE" = "follow" ]; then
  trap 'echo; echo "หยุดแล้ว"; exit 0' INT
  while :; do
    run_once
    echo "$(date -u '+%H:%M:%S') --- รอ 20 วินาที ---"
    sleep 20
  done
else
  run_once
fi

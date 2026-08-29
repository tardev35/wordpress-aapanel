#!/usr/bin/env python3
"""
ct-live — ดูสตรีมใบรับรองสดจาก Certificate Transparency log ผ่านหน้าเว็บบนเครื่องตัวเอง

    python tools/ct-live/server.py
    เปิด http://localhost:8765

ทำไมต้องมี server ไม่เขียนเป็น JS ล้วน:
  CT log ไม่ส่ง header CORS ให้ เบราว์เซอร์จึงเรียกตรงไม่ได้ ต้องมีตัวกลางฝั่งเครื่องเรา
  และการแกะ certificate ต้องอ่าน DER ซึ่งทำฝั่ง Python สะดวกกว่า

ใช้ไลบรารีมาตรฐานของ Python ล้วน ไม่ต้อง pip install อะไรเลย
เทสแล้วบน Python 3.13 (Windows) และ 3.10 (Ubuntu)

ดู docs/11-security.md สำหรับเหตุผลว่าทำไมต้องสนใจท่อนี้
"""

import base64
import gzip
import json
import re
import struct
import sys
import threading
import time
import ssl
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 8765
OR_URL = "https://openrouter.ai/api/v1/chat/completions"
LOG_LIST = "https://www.gstatic.com/ct/log_list/v3/log_list.json"
HERE = Path(__file__).parent
UA = {"User-Agent": "ct-live/1.0 (+local viewer)"}

def load_env():
    """อ่านคีย์จาก environment หรือไฟล์ .env ข้าง ๆ - ไม่ hardcode ลงโค้ด

    .env อยู่ใน .gitignore ของ repo แล้ว จึงไม่ถูก commit ขึ้นไป
    ถ้าไม่มีคีย์ ระบบยังทำงานปกติ แค่ปิดส่วนคัดกรองด้วย AI
    """
    import os
    cfg = {"key": os.environ.get("OPENROUTER_API_KEY", ""),
           "model": os.environ.get("OPENROUTER_MODEL", "google/gemini-3.1-flash-lite")}
    f = HERE / ".env"
    if f.exists():
        for line in f.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip().strip('"').strip("'")
            if k == "OPENROUTER_API_KEY" and not cfg["key"]:
                cfg["key"] = v
            elif k == "OPENROUTER_MODEL":
                cfg["model"] = v
    return cfg


ENV = load_env()
_logs_cache = {"at": 0.0, "logs": []}
_seen = set()          # กันไม่ให้โดเมนเดิมโผล่ซ้ำเวลา log ยังไม่ขยับ
_seen_order = []
_sth = {}              # สถานะล่าสุดของแต่ละ log ไว้แสดงในหน้า "ล็อก"


def http_json(url, timeout=25):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", "ignore"))


# ---------------------------------------------------------------- DER
def _der_len(b, i):
    """อ่านความยาวแบบ DER คืน (ความยาว, ตำแหน่งถัดไป)"""
    n = b[i]
    i += 1
    if n < 0x80:
        return n, i
    k = n & 0x7F
    return int.from_bytes(b[i:i + k], "big"), i + k


SAN_OID = bytes([0x06, 0x03, 0x55, 0x1D, 0x11])   # 2.5.29.17 subjectAltName


def punydecode(name):
    """xn--12c4cl3b5a4bq.com -> ไทยพนัน.com  (ถอดทีละ label ตัวที่พังก็ปล่อยไว้เดิม)"""
    if "xn--" not in name:
        return name
    out = []
    for lab in name.split("."):
        if lab.startswith("xn--"):
            try:
                lab = lab.encode("ascii").decode("idna")
            except Exception:
                pass
        out.append(lab)
    return ".".join(out)


def dns_names(der):
    """ดึงชื่อโดเมนจาก subjectAltName ของ certificate โดยไม่ง้อ openssl

    เดินหา OID ของ subjectAltName แล้วอ่าน OCTET STRING ที่ตามมา
    ข้างในเป็น SEQUENCE ของ GeneralName - ตัวที่เป็น dNSName ใช้ tag 0x82
    """
    out = []
    pos = 0
    while True:
        j = der.find(SAN_OID, pos)
        if j < 0:
            break
        pos = j + len(SAN_OID)
        k = pos
        if k < len(der) and der[k] == 0x01:          # BOOLEAN critical (ข้าม)
            ln, k = _der_len(der, k + 1)
            k += ln
        if k >= len(der) or der[k] != 0x04:          # ต้องเป็น OCTET STRING
            continue
        ln, k = _der_len(der, k + 1)
        blob = der[k:k + ln]
        if not blob or blob[0] != 0x30:              # ข้างในเป็น SEQUENCE
            continue
        ln2, m = _der_len(blob, 1)
        end = min(m + ln2, len(blob))
        while m < end:
            tag = blob[m]
            ln3, m = _der_len(blob, m + 1)
            if tag == 0x82:                          # dNSName
                try:
                    out.append(blob[m:m + ln3].decode("ascii"))
                except Exception:
                    pass
            m += ln3
        if out:
            break
    return out


ISSUER_RE = re.compile(rb"\x13.|\x0c.", re.S)


CA_NAMES = (b"Let's Encrypt", b"Google Trust Services", b"DigiCert", b"Sectigo",
            b"ZeroSSL", b"GlobalSign", b"Amazon", b"Actalis", b"Certum",
            b"Buypass", b"SSL.com", b"WoTrus", b"Entrust", b"IdenTrust")


def issuer_org(der):
    """เดาชื่อผู้ออก cert จากตำแหน่งที่ปรากฏเร็วที่สุดใน DER

    ใน X.509 ฟิลด์ issuer มาก่อน subject ชื่อ CA ที่โผล่ก่อนจึงมักเป็นผู้ออกจริง
    เป็นการเดา ไม่ได้ parse RDN เต็มรูป - พอสำหรับแสดงผล ไม่ควรเอาไปตัดสินใจอะไร
    """
    best, at = "—", len(der) + 1
    for name in CA_NAMES:
        i = der.find(name)
        if 0 <= i < at:
            best, at = name.decode(), i
    return best


def decode_entry(e):
    leaf = base64.b64decode(e["leaf_input"])
    if len(leaf) < 12:
        return None
    ts = struct.unpack(">Q", leaf[2:10])[0] / 1000
    etype = struct.unpack(">H", leaf[10:12])[0]
    try:
        if etype == 0:                                # x509_entry
            ln = int.from_bytes(leaf[12:15], "big")
            der = leaf[15:15 + ln]
        else:                                         # precert_entry
            ex = base64.b64decode(e.get("extra_data", ""))
            ln = int.from_bytes(ex[3:6], "big")
            der = ex[6:6 + ln]
    except Exception:
        return None
    names = dns_names(der)
    if not names:
        return None
    row = {
        "t": datetime.fromtimestamp(ts, timezone.utc).strftime("%H:%M:%S"),
        "d": names[0],
        "extra": len(names) - 1,
        "ca": issuer_org(der),
    }
    u = punydecode(names[0])
    if u != names[0]:
        row["u"] = u            # โดเมนไทยจดเป็น xn-- ต้องถอดถึงจะอ่านออก
    return row


# ---------------------------------------------------------------- ตรวจหน้าเว็บ
# ดูจากชื่อโดเมนเดาได้แค่ไหนก็เดา สู้เปิดดูหน้าเว็บจริงไม่ได้
# <html lang="th"> คือคำตอบจากตัวเว็บเอง ไม่ใช่การเดา
BROWSER_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")
RE_LANG = re.compile(rb"<html[^>]*\slang\s*=\s*[\"']?([a-zA-Z\-]{2,10})", re.I)
RE_TITLE = re.compile(rb"<title[^>]*>(.{0,200}?)</title>", re.I | re.S)
RE_OGLOC = re.compile(rb"og:locale[\"'][^>]*content=[\"']([a-zA-Z_\-]{2,10})", re.I)
RE_THAI = re.compile(r"[฀-๿]")

_NOVERIFY = ssl.create_default_context()
_NOVERIFY.check_hostname = False
_NOVERIFY.verify_mode = ssl.CERT_NONE


def _get(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": BROWSER_UA,
        "Accept": "text/html,application/xhtml+xml",
        "Accept-Language": "th,en;q=0.8",
        "Accept-Encoding": "gzip",
    })
    with urllib.request.urlopen(req, timeout=9, context=_NOVERIFY) as r:
        raw = r.read(200000)
        if r.headers.get("Content-Encoding") == "gzip":
            try:
                raw = gzip.decompress(raw)
            except Exception:
                pass
        return r.status, raw, r.geturl()


def probe_site(dom):
    """เปิดหน้าเว็บอ่านแค่ lang กับ title - ไม่รันสคริปต์ ไม่ตามลิงก์ต่อ"""
    host = str(dom)[:120].lstrip("*.")
    out = {"d": dom, "lang": "", "th": False, "title": "", "err": ""}
    for scheme in ("https://", "http://"):
        try:
            st, raw, final = _get(scheme + host)
        except Exception as ex:
            out["err"] = type(ex).__name__
            continue
        m = RE_LANG.search(raw) or RE_OGLOC.search(raw)
        if m:
            out["lang"] = m.group(1).decode("ascii", "ignore").lower().replace("_", "-")
        mt = RE_TITLE.search(raw)
        if mt:
            try:
                out["title"] = re.sub(r"\s+", " ", mt.group(1).decode(
                    "utf-8", "ignore")).strip()[:90]
            except Exception:
                pass
        body = raw.decode("utf-8", "ignore")
        # นับตัวอักษรไทยในหน้า - เยอะพอถึงนับว่าเป็นเนื้อหาไทย ไม่ใช่แค่คำเดียวหลุดมา
        out["thai_chars"] = len(RE_THAI.findall(body))
        out["th"] = out["lang"].startswith("th") or out["thai_chars"] >= 40
        out["status"] = st
        out["err"] = ""
        if final.split("/")[2].lstrip("www.") != host.lstrip("www."):
            out["to"] = final.split("/")[2]      # เด้งไปโดเมนอื่น
        return out
    return out


def probe_many(doms, workers=6):
    with ThreadPoolExecutor(max_workers=workers) as ex:
        return list(ex.map(probe_site, doms))



# ---------------------------------------------------------------- logs
SHARD_RE = re.compile(r"^20\d\dh[12]$")


def log_id(url):
    """ตั้งชื่อสั้นให้ log ไว้ทำแท็บ ต้องไม่ซ้ำกัน

    DigiCert ใช้ path เป็น /2026h2 เหมือนกันทั้ง wyvern และ sphinx
    ถ้าเอา path อย่างเดียวจะชนกัน จึงต้องเอาชื่อโฮสต์มาผสม
    """
    body = url.split("//", 1)[-1]
    host = body.split("/", 1)[0].split(".")[0]
    parts = [p for p in body.split("/")[1:] if p]
    last = parts[-1] if parts else ""
    if last and not SHARD_RE.match(last):
        return last                     # argon2026h2 · nimbus2026 · log2026a
    if last:
        return host + last              # wyvern2026h2 · sphinx2026h2
    return host                         # elephant2026h2 · tiger2026h2


def usable_logs(force=False):
    if not force and _logs_cache["logs"] and time.time() - _logs_cache["at"] < 43200:
        return _logs_cache["logs"]
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    out = []
    try:
        d = http_json(LOG_LIST, timeout=30)
    except Exception as ex:
        print("โหลดรายชื่อ log ไม่ได้:", ex)
        return _logs_cache["logs"]
    for op in d.get("operators", []):
        for log in op.get("logs", []):
            st = log.get("state", {})
            if not any(k in st for k in ("usable", "qualified")):
                continue
            iv = log.get("temporal_interval", {})
            s, e = iv.get("start_inclusive", "")[:10], iv.get("end_exclusive", "")[:10]
            if e and e <= today:
                continue
            if s and s > today:
                continue
            url = log["url"].rstrip("/")
            out.append({"op": op["name"], "url": url, "id": log_id(url),
                        "label": f"{op['name']} · {log_id(url)}"})
    _logs_cache.update(at=time.time(), logs=out)
    return out


def pull(log, n=12):
    """ดึง entry ท้าย ๆ ของ log หนึ่งตัว แล้วแกะเป็นรายการโดเมน"""
    try:
        sth = http_json(log["url"] + "/ct/v1/get-sth", timeout=12)
        size = int(sth["tree_size"])
        _sth[log["id"]] = {"size": size, "ts": int(sth.get("timestamp", 0)) // 1000,
                           "at": int(time.time())}
    except Exception:
        return []
    start, end = max(0, size - n), size - 1
    try:
        data = http_json(f"{log['url']}/ct/v1/get-entries?start={start}&end={end}", timeout=25)
    except Exception:
        return []
    rows = []
    for e in data.get("entries", []):
        r = decode_entry(e)
        if not r:
            continue
        key = (r["d"], r["t"])
        if key in _seen:
            continue
        _seen.add(key)
        _seen_order.append(key)
        if len(_seen_order) > 4000:                   # กันหน่วยความจำโต
            _seen.discard(_seen_order.pop(0))
        r["log"] = log["op"]
        r["id"] = log["id"]
        rows.append(r)
    return rows


def sweep(n=12):
    rows = []
    threads = []
    lock = threading.Lock()

    def worker(lg):
        got = pull(lg, n)
        with lock:
            rows.extend(got)

    for lg in usable_logs():
        t = threading.Thread(target=worker, args=(lg,), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join(timeout=30)
    rows.sort(key=lambda r: r["t"])
    return rows


# ---------------------------------------------------------------- AI
PROMPT = """คุณคือตัวคัดกรองชื่อโดเมน ดูจาก "ชื่อโดเมน" อย่างเดียว ห้ามเปิดเว็บ

งาน: บอกว่าโดเมนไหนน่าจะเป็นเว็บพนันออนไลน์ (คาสิโน สล็อต บาคาร่า แทงบอล หวย)

สัญญาณที่มักพบในโดเมนพนันภาษาไทย:
- คำ: slot, casino, bet, bacara/baccarat, huay/lotto, pg, joker, sexy, ufa, sbo, 888, 168, 789, 99, vip, auto, wallet, true wallet
- รูปแบบ: คำมั่ว + ตัวเลข เช่น xyz888.com, abc168pro.net
- ลงท้าย: -game, -play, -win, -club, -bet, -vip, -pro, -auto

ระวัง: เว็บทั่วไปก็มีตัวเลขได้ อย่าตัดสินจากตัวเลขอย่างเดียว
ถ้าไม่แน่ใจให้ตอบ no

ต้องบอก "ตลาด" ที่เว็บนั้นเล็งไว้ด้วย (m):
- th = ตลาดไทย รูปแบบเด่นคือ <คำ><เลขมงคล>-<คำลงท้าย>.com
  ตัวอย่างจริง: aha789-vip, bbc29-play, xo789-club, betdee168-club, maha289-play,
  duangpang168-game, win3333-vvip, luck44-home, betrich88-th, bplay444-new
  คำลงท้ายที่พบบ่อย: vip vvip pro play club win game bet auto slot new home th thai
  เลขที่พบบ่อย: 168 88 888 789 1688 99 89 98 55 44 289 333 444
  คำไทยสะกดอังกฤษ: duangpang, hongtae, meephooh, bunmak, laobunrod, ruay, huay
  แบรนด์: ufa/ufabet, amb/ambbet, g2g, pg/pgslot, xo/slotxo, betflix, joox, sagame
  หรือชื่อเป็นอักษรไทยตรง ๆ เช่น เว็บฟิน20.com
- cn = ตลาดจีน สัญญาณ: ชื่อเป็นตัวเลขล้วน (858002.com), นำหน้าด้วย m./ww/wap,
  ag, bc, hg, 6688, 365, พินอิน, .cc .top ที่ตามด้วยอักษรมั่ว
- other = อื่น ๆ หรือดูไม่ออก

เลขมงคล 88/168/888 ใช้กันทั่วเอเชีย ไม่ได้แปลว่าไทยเสมอ
ถ้าชื่อระบุที่อื่นชัดเจน (taipei, tokyo, manila, hanoi, jakarta, saigon)
หรือเป็นพินอิน ให้ตอบ cn หรือ other ไม่ใช่ th

ตอบเป็น JSON array เท่านั้น ไม่ต้องมีข้อความอื่น:
[{"d":"ชื่อโดเมน","v":"yes|maybe|no","m":"th|cn|other","w":"เหตุผลสั้นไม่เกิน 8 คำ"}]
ต้องมีครบทุกโดเมนที่ให้มา"""


def classify(domains):
    """ส่งชื่อโดเมนไปให้โมเดลคัดกรอง - ส่งไปแค่ "ชื่อ" ไม่ได้เปิดเว็บ ไม่ได้ส่งข้อมูลอื่น"""
    if not ENV["key"]:
        return {"error": "ยังไม่ได้ตั้ง OPENROUTER_API_KEY - ดู tools/ct-live/.env"}
    body = json.dumps({
        "model": ENV["model"],
        "temperature": 0,
        "messages": [{"role": "system", "content": PROMPT},
                     {"role": "user", "content": chr(10).join(domains)}],
    }).encode()
    req = urllib.request.Request(OR_URL, data=body, headers={
        "Authorization": "Bearer " + ENV["key"],
        "Content-Type": "application/json",
        "HTTP-Referer": "http://localhost:8765",
        "X-Title": "ct-live",
    })
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            out = json.loads(r.read().decode("utf-8", "ignore"))
    except urllib.error.HTTPError as ex:
        return {"error": "OpenRouter ตอบ %s: %s" % (ex.code, ex.read()[:180].decode("utf8", "ignore"))}
    except Exception as ex:
        return {"error": "เรียก OpenRouter ไม่ได้: %s" % ex}
    txt = out.get("choices", [{}])[0].get("message", {}).get("content", "")
    m = re.search(r"\[.*\]", txt, re.S)          # โมเดลชอบห่อด้วย ```json
    if not m:
        return {"error": "โมเดลตอบมาไม่ใช่ JSON", "raw": txt[:200]}
    try:
        rows = json.loads(m.group(0))
    except Exception:
        return {"error": "อ่าน JSON จากโมเดลไม่ได้", "raw": txt[:200]}
    usage = out.get("usage", {})
    return {"rows": rows, "model": out.get("model", ENV["model"]),
            "in": usage.get("prompt_tokens"), "out": usage.get("completion_tokens")}


# ---------------------------------------------------------------- http
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass                                          # เงียบไว้ ไม่งั้น console รก

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index"):
            try:
                html = (HERE / "index.html").read_bytes()
            except FileNotFoundError:
                self._send(500, "text/plain; charset=utf-8",
                           "หา index.html ไม่เจอ - ต้องอยู่โฟลเดอร์เดียวกับ server.py".encode())
                return
            self._send(200, "text/html; charset=utf-8", html)

        elif self.path == "/api/logs":
            lg = [dict(x) for x in usable_logs()]
            now = int(time.time())
            for x in lg:
                s = _sth.get(x["id"])
                if s:
                    x["size"] = s["size"]
                    x["sth_age"] = now - s["ts"]      # STH เก่ากี่วินาที
                    x["seen_at"] = s["at"]
            self._send(200, "application/json; charset=utf-8",
                       json.dumps(lg, ensure_ascii=False).encode())

        elif self.path.startswith("/api/entries"):
            m = re.search(r"[?&]n=(\d+)", self.path)
            n = min(int(m.group(1)), 40) if m else 12
            try:
                rows = sweep(n)
            except Exception as ex:
                rows = []
                print("sweep error:", ex)
            self._send(200, "application/json; charset=utf-8",
                       json.dumps(rows, ensure_ascii=False).encode())
        elif self.path == "/api/vocab":
            # คำที่ถอดจากโดเมนจริงด้วย tune.py - ไม่มีไฟล์ก็ใช้กฎโครงสร้างอย่างเดียว
            # vocab.json = ตัวเต็ม มีชื่อแบรนด์ อยู่แค่ในเครื่อง
            # vocab-generic.json = ตัวที่ commit ไว้ ใครโคลนไปก็ใช้ได้
            body = b'{"min":2.0,"vocab":{}}'
            for name in ("vocab.json", "vocab-generic.json"):
                f = HERE / name
                if f.exists():
                    body = f.read_bytes()
                    break
            self._send(200, "application/json; charset=utf-8", body)

        elif self.path == "/api/ai-status":
            self._send(200, "application/json; charset=utf-8", json.dumps({
                "ready": bool(ENV["key"]), "model": ENV["model"]}).encode())
        else:
            self._send(404, "text/plain; charset=utf-8", b"not found")

    def do_POST(self):
        if self.path not in ("/api/classify", "/api/probe"):
            self._send(404, "text/plain; charset=utf-8", b"not found")
            return
        n = int(self.headers.get("Content-Length", 0))
        try:
            doms = json.loads(self.rfile.read(n).decode("utf-8"))[:60]
        except Exception:
            self._send(400, "application/json; charset=utf-8",
                       json.dumps({"error": "payload ไม่ถูกต้อง"}, ensure_ascii=False).encode())
            return
        if self.path == "/api/probe":
            rows = probe_many([str(d)[:120] for d in doms if d][:24])
            self._send(200, "application/json; charset=utf-8",
                       json.dumps({"rows": rows}, ensure_ascii=False).encode())
            return
        res = classify([str(d)[:120] for d in doms if d])
        self._send(200, "application/json; charset=utf-8",
                   json.dumps(res, ensure_ascii=False).encode())


def main():
    print("ct-live — ดูสตรีมใบรับรองสดจาก Certificate Transparency")
    print("กำลังโหลดรายชื่อ log จาก Google ...")
    lg = usable_logs(force=True)
    if not lg:
        print("โหลดรายชื่อ log ไม่ได้ — ตรวจการเชื่อมต่ออินเทอร์เน็ตแล้วลองใหม่")
        sys.exit(1)
    for x in lg:
        print(f"   {x['op']:<12} {x['url']}")
    print(f"\nใช้ได้ {len(lg)} log")
    print(f"\n  เปิดเบราว์เซอร์ที่  ->  http://localhost:{PORT}")
    print("  หยุดด้วย Ctrl-C\n")
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nหยุดแล้ว")


if __name__ == "__main__":
    main()

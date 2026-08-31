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
import os
import re
import socket
import sqlite3
import struct
import sys
import threading
import time
import ssl
import urllib.parse
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
           "proxy": os.environ.get("PROXY_URL", ""),
           "collect": os.environ.get("COLLECTOR", ""),
           "collect_cycle": os.environ.get("COLLECT_CYCLE", ""),
        "model": os.environ.get("OPENROUTER_MODEL", "google/gemini-3.5-flash-lite")}
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
            elif k == "COLLECTOR":
                cfg["collect"] = v
            elif k == "COLLECT_CYCLE":
                cfg["collect_cycle"] = v
            elif k in ("PROXY_URL", "HTTPS_PROXY", "HTTP_PROXY") and not cfg["proxy"]:
                cfg["proxy"] = v
    return cfg


ENV = load_env()

# ---------------------------------------------------------------- ฐานข้อมูล SQLite
# เก็บ log เว็บพนันไทยที่เจอ แบบหมุน 3 วัน (วันนี้ + 2 วันก่อน) เกินนั้นลบทิ้ง
# เช่น วันนี้ 30 ส.ค. -> พอถึง 2 ก.ย. ของวันที่ 30 จะถูกลบ
DB_PATH = HERE / "data" / "hits.db"
_db_lock = threading.Lock()


def _db():
    (HERE / "data").mkdir(exist_ok=True)
    con = sqlite3.connect(str(DB_PATH), timeout=10)
    con.execute("""CREATE TABLE IF NOT EXISTS hits(
        d TEXT PRIMARY KEY, v TEXT, m TEXT, w TEXT,
        lang TEXT, chars INTEGER, title TEXT,
        th TEXT, age_days INTEGER, via TEXT,
        first_seen INTEGER, day TEXT, parked TEXT DEFAULT '', live TEXT DEFAULT '')""")
    # เพิ่มคอลัมน์ที่ยังไม่มีให้ DB เก่าที่สร้างก่อนมีฟีเจอร์นี้
    have = [c[1] for c in con.execute("PRAGMA table_info(hits)")]
    if "parked" not in have:
        con.execute("ALTER TABLE hits ADD COLUMN parked TEXT DEFAULT ''")
    if "live" not in have:
        con.execute("ALTER TABLE hits ADD COLUMN live TEXT DEFAULT ''")
    return con


def _db_purge(con):
    # เก็บ 3 วันปฏิทินล่าสุด ลบของที่เก่ากว่านั้น
    con.execute("DELETE FROM hits WHERE day <= date('now','localtime','-3 days')")


# โดเมนต้องหน้าตาเป็นโดเมนจริง (ตัวอักษรโดเมนล้วน + มีจุด) กัน key ขยะลง DB ถาวร
_DOM_RE = re.compile(r"^[a-z0-9._-]{1,120}$")


def _clip(v, n=200):
    return str(v if v is not None else "")[:n]


def _to_int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def db_add(rows):
    with _db_lock:
        con = _db()
        now = int(time.time())
        today = datetime.now().strftime("%Y-%m-%d")
        for r in rows[:150]:               # จำกัดจำนวนต่อรอบ เท่า endpoint อื่น
            if not isinstance(r, dict):
                continue
            d = str(r.get("d", "")).strip().lower()[:120]
            if "." not in d or not _DOM_RE.match(d):
                continue                   # ไม่ใช่โดเมน -> ข้าม (ไม่ให้ลง PRIMARY KEY)
            con.execute(
                """INSERT INTO hits
                   (d,v,m,w,lang,chars,title,th,age_days,via,first_seen,day,parked,live)
                   VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                   ON CONFLICT(d) DO UPDATE SET
                     v=excluded.v, m=excluded.m, w=excluded.w,
                     th=excluded.th, age_days=excluded.age_days, via=excluded.via,
                     parked=excluded.parked, live=excluded.live""",
                (d, _clip(r.get("v"), 8), _clip(r.get("m"), 300), _clip(r.get("w"), 120),
                 _clip(r.get("lang"), 40), _to_int(r.get("chars")) or 0,
                 _clip(r.get("title"), 300),
                 _clip(r.get("th"), 40), _to_int(r.get("days")), _clip(r.get("via"), 40),
                 now, today, _clip(r.get("parked"), 40), _clip(r.get("live"), 8)))
        _db_purge(con)
        con.commit()
        n = con.execute("SELECT COUNT(*) FROM hits").fetchone()[0]
        con.close()
        return n


def db_recent(limit=2000):
    with _db_lock:
        con = _db()
        _db_purge(con)
        con.commit()
        cur = con.execute(
            "SELECT d,v,m,w,lang,chars,title,th,age_days,via,first_seen,day,parked,live "
            "FROM hits ORDER BY first_seen DESC LIMIT ?", (limit,))
        cols = [c[0] for c in cur.description]
        out = [dict(zip(cols, row)) for row in cur.fetchall()]
        con.close()
        return out


# คำ/สัญญาณที่พบบ่อยในชื่อเว็บพนันไทย - ใช้แค่ "นับความถี่" ในแผงสถิติ (descriptive)
_STAT_WORDS = ["slot", "casino", "baccarat", "bacara", "bet", "pg", "ufa", "amb", "joker",
               "sexy", "sbo", "sagame", "huay", "lotto", "lucky", "king", "gold", "rich",
               "win", "vip", "pro", "auto", "wallet", "game", "play", "club", "zeed",
               "fun", "hub", "thai", "789bet", "689", "auto"]


def _age_bucket(d):
    if d is None:
        return "?"
    d = int(d)
    return ("0-7" if d <= 7 else "8-30" if d <= 30 else "31-90" if d <= 90
            else "91-180" if d <= 180 else "180+")


def stats():
    """สรุปสถิติจากโดเมนที่เก็บใน hits.db - นับล้วน ๆ ไม่มีการตีความ"""
    from collections import Counter
    with _db_lock:
        con = _db()
        _db_purge(con)
        con.commit()
        rows = con.execute("SELECT d, age_days, live, day FROM hits").fetchall()
        con.close()
    words, nums, tlds, perday = Counter(), Counter(), Counter(), Counter()
    ages = {b: [0, 0] for b in ("0-7", "8-30", "31-90", "91-180", "180+", "?")}
    for d, age, live, day in rows:
        name = str(d or "").lstrip("*.").lower()
        sld, tld = (name.rsplit(".", 1) + [""])[:2] if "." in name else (name, "")
        if tld:
            tlds[tld] += 1
        for w in _STAT_WORDS:
            if w in sld:
                words[w] += 1
        for n in re.findall(r"\d+", sld):
            nums[n] += 1
        if day:
            perday[day] += 1
        b = _age_bucket(age)
        ages[b][0] += 1
        if live == "yes":
            ages[b][1] += 1
    order = ("0-7", "8-30", "31-90", "91-180", "180+", "?")
    return {
        "total": len(rows),
        "words": words.most_common(16),
        "nums": nums.most_common(12),
        "tlds": tlds.most_common(12),
        "perday": sorted(perday.items(), reverse=True)[:14],
        "age": [{"b": b, "tot": ages[b][0], "live": ages[b][1]}
                for b in order if ages[b][0]],
    }
_proxies = []          # เติมจริงตอน main() หลังนิยาม load_proxies
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
# meta description / og:description - คำโปรยของหน้า ใช้ช่วย Gemini ตัดสินว่า "เว็บขึ้นจริง" ไหม
RE_DESC = re.compile(rb"name=[\"']description[\"'][^>]*content=[\"']([^\"']{0,300})", re.I)
RE_OGDESC = re.compile(rb"og:description[\"'][^>]*content=[\"']([^\"']{0,300})", re.I)

_NOVERIFY = ssl.create_default_context()
_NOVERIFY.check_hostname = False
_NOVERIFY.verify_mode = ssl.CERT_NONE


def _get(url):
    """เปิดหน้าเว็บ - ลอง proxy ต่างประเทศก่อน ล้มเหลวค่อยยิงตรง

    วัดจริง 2026-08-30 ลองซ้ำ 4 รอบต่อโดเมน:
        โดเมน               มาเลเซีย  ไทย   ยิงตรง
        sumo69.info         403x4     403x4  OK      <- bestproxy บล็อกเอง
        heng35vip.co        403x4     TLSx4  OK      <- bestproxy บล็อกเอง
        ufafuture-thai.com  OKx4      TLSx4  OK
        moodeng9999.com     OKx4      TLSx4  OK
    403 = ตัว proxy ปฏิเสธ CONNECT เอง เหมือนกันทุกประเทศ
    TLS ขาดกลางคัน = ISP ไทยบล็อก เจอเฉพาะขาออกไทย
    มาเลเซียจึงใช้เปิดเว็บได้ 4/6 ส่วนไทยได้ 0-1/6 แต่ยิงตรงได้ 6/6 เสมอ
    """
    global _ppx_i
    hdrs = {
        "User-Agent": BROWSER_UA,
        "Accept": "text/html,application/xhtml+xml",
        "Accept-Language": "th,en;q=0.8",
        "Accept-Encoding": "gzip",
    }
    # ลอง proxy ต่างประเทศก่อน ถ้าไม่ผ่านค่อยยิงตรง - ดูเหตุผลที่หัวข้อ proxy pool
    tries = []
    if _probe_px:
        with _px_lock:
            for _ in range(2):              # พลาดราว 2/10 ครั้ง ลองตัวใหม่ก็ผ่าน
                tries.append(_probe_px[_ppx_i % len(_probe_px)])
                _ppx_i += 1
    tries.append(None)                      # ยิงตรงเป็นทางสุดท้ายเสมอ
    last, r = None, None
    for px in tries:
        # ต้องสร้าง Request ใหม่ทุกครั้ง - ProxyHandler เรียก req.set_proxy() ซึ่ง
        # แก้ตัว Request ถาวร ถ้าเอาตัวเดิมไปยิงตรงต่อ มันจะยังวิ่งเข้า proxy เดิม
        try:
            r = build_opener(px, _NOVERIFY).open(
                urllib.request.Request(url, headers=hdrs), timeout=5)
            break
        except Exception as ex:
            last, r = ex, None
    if r is None:
        raise last
    with r:
        raw = r.read(65536)
        if r.headers.get("Content-Encoding") == "gzip":
            try:
                raw = gzip.decompress(raw)
            except Exception:
                pass
        return r.status, raw, r.geturl()


_probe_cache = {}
_probe_lock = threading.Lock()


# ---------- ตรวจหน้า "จอดโดเมน" (registrar/parking) ----------
# โดเมนที่จดแล้วยังไม่ทำเว็บ จะโชว์หน้าของผู้ให้บริการ (Dynadot ฯลฯ) หรือหน้าประกาศขาย
# ถ้าชื่อเข้าเค้าพนันไทยแต่ยังจอดอยู่ = เพิ่งจด ยังไม่ขึ้นเว็บ -> ควรอยู่กลุ่ม "จดใหม่"
_PARK_HOSTS = ("dynadot", "sedo", "afternic", "godaddy", "parkingcrew",
               "bodis", "above.com", "hugedomains", "dan.com", "uniregistry",
               "namesilo", "porkbun", "sav.com", "cashparking", "parklogic",
               "voodoo.com", "fabulous.com")
_PARK_MARK = ("domain is for sale", "buy this domain", "this domain is for sale",
              "domain for sale", "is for sale", "domain parking", "parked free",
              "future home of", "domain has expired", "dynadot", "sedo",
              "afternic", "hugedomains", "godaddy")
_PARK_BODY = ("domain is for sale", "buy this domain", "this domain is for sale",
              "future home of", "domain has expired", "dynadot.com",
              "sedoparking", "hugedomains.com", "afternic.com")


def _park_hit(text, keys):
    t = (text or "").lower()
    for k in keys:
        if k in t:
            return k
    return ""


def _is_parked(title, body, to):
    # 1) เด้งไปโฮสต์ของผู้ให้บริการโดเมน/รับจอด  2) title มีคำหน้าจอด/ประกาศขาย
    # 3) เนื้อหาส่วนต้นมีวลีขายโดเมนชัด ๆ (จำกัดช่วงกันจับผิด)
    return (_park_hit(to, _PARK_HOSTS) or _park_hit(title, _PARK_MARK)
            or _park_hit((body or "")[:4000], _PARK_BODY))


def probe_site(dom):
    """เปิดหน้าเว็บอ่านแค่ lang กับ title - ไม่รันสคริปต์ ไม่ตามลิงก์ต่อ"""
    host = str(dom)[:120].lstrip("*.")
    with _probe_lock:
        hit = _probe_cache.get(host)
    if hit is not None:
        # ผลสำเร็จจำไว้ตลอด แต่ความล้มเหลวจำแค่ 15 นาที
        # เว็บล่มชั่วคราวหรือเน็ตสะดุด ไม่ควรถูกตราหน้าว่าเปิดไม่ได้ตลอดไป
        if not hit.get("err") or time.time() - hit.get("_at", 0) < 900:
            return dict(hit, d=dom)
    out = {"d": dom, "lang": "", "th": False, "title": "", "desc": "", "err": ""}
    for scheme in ("https://", "http://"):
        try:
            st, raw, final = _get(scheme + host)
        except Exception as ex:
            out["err"] = type(ex).__name__
            # https หมดเวลา แปลว่าเครื่องปลายทางไม่ตอบ ลอง http ต่อก็รออีก 5 วิเปล่า ๆ
            if "timed out" in str(ex).lower() or isinstance(ex, TimeoutError):
                break
            continue
        m = RE_LANG.search(raw) or RE_OGLOC.search(raw)
        if m:
            out["lang"] = m.group(1).decode("ascii", "ignore").lower().replace("_", "-")
        mt = RE_TITLE.search(raw)
        if mt:
            try:
                out["title"] = re.sub(r"\s+", " ", mt.group(1).decode(
                    "utf-8", "ignore")).strip()[:120]
            except Exception:
                pass
        md = RE_DESC.search(raw) or RE_OGDESC.search(raw)
        if md:
            try:
                out["desc"] = re.sub(r"\s+", " ", md.group(1).decode(
                    "utf-8", "ignore")).strip()[:200]
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
        # หน้าจอดโดเมน = ยังไม่ทำเว็บจริง (สัญญาณว่าเพิ่งจด) เก็บชื่อผู้ให้บริการที่เจอ
        out["parked"] = _is_parked(out["title"], body, out.get("to", ""))
        out["_at"] = time.time()
        with _probe_lock:
            _probe_cache[host] = out
        return out
    # เปิดไม่ได้ก็จำไว้ ไม่งั้นรอ timeout ซ้ำทุกรอบ - แต่หมดอายุใน 15 นาที
    out["_at"] = time.time()
    with _probe_lock:
        if len(_probe_cache) < 20000:
            _probe_cache[host] = out
    return out


def probe_many(doms, workers=32):
    with ThreadPoolExecutor(max_workers=workers) as ex:
        return list(ex.map(probe_site, doms))



# ---------------------------------------------------------------- proxy pool
# มี 2 ชุด: proxies.txt ใช้กับ RDAP · proxies-probe.txt ใช้เปิดหน้าเว็บ
#
# ⚠️ คุณภาพต่างกันมากระหว่างผู้ให้บริการ วัด 2026-08-30 ด้วย IP ไทยทั้งคู่
#    จาก ISP ชุดเดียวกัน (3BB, True, AIS, CAT) ยิงเว็บพนันไทยชุดเดียวกัน:
#
#      bestproxy  ผ่าน  3/18
#      webshare   ผ่าน 28/30   (เว็บทั่วไปเป็นตัวควบคุม 20/20)
#
#    ตอนแรกสรุปว่า "ISP ไทยบล็อกเว็บพนัน" เพราะเห็น TLS ถูกตัดที่ 5.2 วินาที
#    เป๊ะ ๆ ทุกครั้ง แต่พอเปลี่ยนผู้ให้บริการแล้วผ่าน แปลว่าตัวที่ตัดคือ
#    เครือข่ายของ bestproxy เอง ไม่ใช่ ISP ไทย - ข้อสรุปเดิมผิด
#
#    บทเรียน: อาการที่ "สม่ำเสมอเกินไป" ชี้ว่ามีคนตั้งใจตัด แต่ไม่ได้บอกว่า
#    ใครตัด ต้องเปลี่ยนตัวแปรทีละตัวถึงจะรู้ - ที่นี่คือเปลี่ยนผู้ให้บริการ
#    โดยคุมประเทศและ ISP ไว้เหมือนเดิม
#
# ไฟล์ proxies.txt อยู่ใน .gitignore - มีรหัสผ่าน ห้าม commit
_proxies = []          # ใช้กับ RDAP
_probe_px = []         # ใช้กับการเปิดหน้าเว็บ (คนละชุด คนละประเทศ)
_px_i = 0
_ppx_i = 0
_px_lock = threading.Lock()


def load_proxies(name="proxies.txt"):
    """อ่านไฟล์ proxy - รองรับ 2 รูปแบบที่ผู้ให้บริการใช้กัน

        host:port@user:pass     (bestproxy)
        host:port:user:pass     (webshare)
    """
    out = []
    f = HERE / name
    if f.exists():
        for line in f.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                if "@" in line:
                    hp, cred = line.split("@", 1)
                    user, pw = cred.rsplit(":", 1)
                else:
                    host, port, user, pw = line.split(":")
                    hp = "%s:%s" % (host, port)
                out.append("http://%s:%s@%s" % (
                    urllib.parse.quote(user, safe=""),
                    urllib.parse.quote(pw, safe=""), hp))
            except Exception:
                continue
    if not out and name == "proxies.txt" and ENV.get("proxy"):
        out.append(ENV["proxy"])
    return out


def next_proxy(pool=None):
    """หมุนไปทีละตัว งานพร้อมกันหลายเส้นจะได้กระจาย IP ไม่กระจุกที่ตัวเดียว"""
    global _px_i
    pool = _proxies if pool is None else pool
    if not pool:
        return None
    with _px_lock:
        px = pool[_px_i % len(pool)]
        _px_i += 1
    return px


def build_opener(px=None, ctx=None):
    hs = []
    if px:
        hs.append(urllib.request.ProxyHandler({"http": px, "https": px}))
    if ctx is not None:
        hs.append(urllib.request.HTTPSHandler(context=ctx))
    return urllib.request.build_opener(*hs)


def proxy_opener(ctx=None):
    """สร้าง opener ใหม่ทุกครั้ง - handler ต้องประกอบพร้อมกันตอนสร้าง
    ถ้าไป add_handler ทีหลัง urllib จะไม่ใช้ตัวที่เพิ่มกับ https ที่ผ่าน proxy"""
    return build_opener(next_proxy(), ctx)



# ---------------------------------------------------------------- วันจดโดเมน
# ใช้ RDAP ไม่ใช่ WHOIS - RDAP คืน JSON มีมาตรฐาน ไม่ต้องเดาว่าแต่ละ registry
# จัดหน้าข้อความยังไง (WHOIS แต่ละเจ้าเขียนคนละแบบหมด)
# ทะเบียนจำกัดจำนวนคำขอต่อ IP หนัก ถ้าตั้ง PROXY_URL ใน .env จะยิงผ่าน proxy ให้
RDAP_BOOT = "https://data.iana.org/rdap/dns.json"
_rdap_srv = {}
_rdap_cache = {}
_rdap_lock = threading.Lock()

TH_MON = ["", "ม.ค.", "ก.พ.", "มี.ค.", "เม.ย.", "พ.ค.", "มิ.ย.",
          "ก.ค.", "ส.ค.", "ก.ย.", "ต.ค.", "พ.ย.", "ธ.ค."]


def _iso_dt(iso):
    """parse ISO ให้ทนฟอร์แมต - Python 3.10 fromisoformat เข้มงวด (fractional ต้อง 3/6 หลัก)
    RDAP บางเจ้าให้ .79 / .0 หลักเดียว จึงตัด fractional ทิ้งก่อน (เราเอาแค่วัน)"""
    iso = re.sub(r"\.\d+", "", str(iso).replace("Z", "+00:00"))
    return datetime.fromisoformat(iso)


def thai_date(iso):
    """2026-08-12T04:11:22Z -> 12 ส.ค. 2569  (พ.ศ. = ค.ศ. + 543)"""
    try:
        d = _iso_dt(iso)
    except Exception:
        return ""
    return "%d %s %d" % (d.day, TH_MON[d.month], d.year + 543)


def rdap_servers():
    with _rdap_lock:
        if _rdap_srv:
            return _rdap_srv
    try:
        d = http_json(RDAP_BOOT, timeout=20)
    except Exception:
        return {}
    m = {}
    for tlds, urls in d.get("services", []):
        for tld in tlds:
            if urls:
                m[tld.lower()] = urls[0].rstrip("/")
    with _rdap_lock:
        _rdap_srv.update(m)
    return m


# ccTLD หลายเจ้ายังไม่ทำ RDAP - IANA มี 1200 TLD แต่ไม่มี .me .co
# พวกนี้ต้องถอยไปถาม WHOIS พอร์ต 43 แบบเดิม ซึ่งคืนมาเป็นข้อความล้วน
# ขั้นแรกถาม whois.iana.org ว่า TLD นี้ใครดูแล แล้วค่อยไปถามเจ้านั้นอีกที
_whois_srv = {}
RE_CREATED = re.compile(
    r"(?im)^\s*(?:creation date|created(?:\s+on)?|registered(?:\s+on)?|"
    r"domain_dateregistered|registration time)\s*:\s*(\S+)")


def whois_ask(server, query, timeout=10):
    with socket.create_connection((server, 43), timeout=timeout) as s:
        s.sendall((query + "\r\n").encode())
        buf = b""
        while len(buf) < 200000:
            b = s.recv(8192)
            if not b:
                break
            buf += b
    return buf.decode("utf-8", "ignore")


def whois_server_for(tld):
    with _rdap_lock:
        if tld in _whois_srv:
            return _whois_srv[tld]
    srv = ""
    try:
        for line in whois_ask("whois.iana.org", tld).splitlines():
            if line.lower().startswith("whois:"):
                srv = line.split(":", 1)[1].strip()
                break
    except Exception:
        pass
    if not srv:
        srv = "whois.nic." + tld          # เจ้าใหม่ ๆ ใช้รูปแบบนี้เกือบหมด
    with _rdap_lock:
        _whois_srv[tld] = srv
    return srv


def whois_created(domain):
    """คืนวันจดจาก WHOIS - ไม่ผ่าน proxy เพราะพอร์ต 43 ไม่ใช่ HTTP"""
    tld = domain.rsplit(".", 1)[-1]
    srv = whois_server_for(tld)
    if not srv:
        return ""
    try:
        txt = whois_ask(srv, domain)
    except Exception:
        return ""
    m = RE_CREATED.search(txt)
    if not m:
        return ""
    v = m.group(1).strip().rstrip(",")
    if len(v) == 8 and v.isdigit():       # 20250725
        v = "%s-%s-%sT00:00:00Z" % (v[:4], v[4:6], v[6:])
    elif len(v) == 10:                    # 2025-07-25
        v = v + "T00:00:00Z"
    return v



def domain_age(name):
    """คืนวันจดโดเมน - เอาเฉพาะ registrable domain ไม่ใช่ subdomain"""
    host = str(name)[:120].lower().lstrip("*.").rstrip(".")
    parts = host.split(".")
    srv = rdap_servers()
    reg = ""
    for i in range(len(parts) - 2, -1, -1):       # ลองจากยาวไปสั้น หา TLD ที่รู้จัก
        cand = ".".join(parts[i:])
        tld = ".".join(parts[i + 1:])
        if tld in srv:
            reg = cand
            break
    if not reg:
        reg = ".".join(parts[-2:])
    with _rdap_lock:
        hit = _rdap_cache.get(reg)
    if hit is not None:
        # ได้วันจด = เก็บถาวร · ว่าง (proxy พังชั่วคราว) = เก็บแค่ 30 นาที แล้ว retry ใหม่
        if hit.get("created") or time.time() - hit.get("_at", 0) < 1800:
            return dict(hit, d=name)

    out = {"d": name, "reg": reg, "created": "", "th": "", "days": None, "err": ""}
    base = srv.get(".".join(reg.split(".")[1:]))
    urls = ([base + "/domain/" + reg] if base else []) + ["https://rdap.org/domain/" + reg]
    direct = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for u in urls:
        req = urllib.request.Request(u, headers={"Accept": "application/rdap+json",
                                                 "User-Agent": BROWSER_UA})
        for opener in (proxy_opener(), direct):     # proxy ก่อน · พัง/ไม่ใช่ RDAP ค่อยยิงตรง
            try:
                with opener.open(req, timeout=12) as r:
                    d = json.loads(r.read(400000).decode("utf-8", "ignore"))
            except Exception as ex:
                out["err"] = type(ex).__name__
                continue
            for ev in d.get("events", []):
                if ev.get("eventAction") == "registration" and not out["created"]:
                    out["created"] = ev.get("eventDate", "")
            if out["created"]:
                break
        if out["created"]:
            out["th"] = thai_date(out["created"])
            try:
                born = _iso_dt(out["created"])
                out["days"] = (datetime.now(timezone.utc) - born).days
            except Exception:
                pass
            out["err"] = ""
            break
    if not out["created"]:
        # RDAP ไม่ได้ผล ลอง WHOIS ต่อ - ccTLD อย่าง .me .co ยังไม่มี RDAP
        try:
            c = whois_created(reg)
        except Exception:
            c = ""
        if c:
            out["created"], out["err"], out["via"] = c, "", "whois"
            out["th"] = thai_date(c)
            try:
                born = _iso_dt(c)
                out["days"] = (datetime.now(timezone.utc) - born).days
            except Exception:
                pass
    out["_at"] = time.time()
    with _rdap_lock:
        if len(_rdap_cache) < 20000:
            _rdap_cache[reg] = out
    return out


def ages_many(doms, workers=8):
    with ThreadPoolExecutor(max_workers=workers) as ex:
        return list(ex.map(domain_age, doms))



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


# ตำแหน่งที่อ่านค้างไว้ของแต่ละ log - หัวใจของ follow mode
# แบบเดิมดึงแค่ n ใบท้ายสุดทุกรอบ ระหว่างรอบมีใบไหลผ่านไปหลายพันใบโดยไม่เห็น
# แบบนี้จำไว้ว่าอ่านถึงไหน แล้วอ่านต่อจากตรงนั้น ไม่ข้ามภายในกำลังที่ไหว
_cursor = {}
_stat = {}
_cur_lock = threading.Lock()
_yield = {}          # log นี้ให้กี่ใบต่อคำขอ วัดจากของจริง
PAR_RANGES = 8       # ยิงกี่ช่วงพร้อมกันต่อ log


def pull(log, budget=200, deadline=None, cursor=None, seen=None, seen_order=None):
    """ไล่อ่าน entry ต่อจากที่ค้างไว้ ไม่เกิน budget ใบ และไม่เกินเวลาที่กำหนด

    เพดานเวลาสำคัญกว่าเพดานจำนวน - log ที่ให้ทีละ 9 ใบจะลากรอบยาวมาก
    ถ้าไม่ตัด หน้าเว็บจะค้างรอ log ที่ช้าที่สุดเสมอ

    cursor/seen แยกได้ - browser (จาก /api/entries) กับ collector อ่านคนละ cursor
    จะได้ไม่แย่งกัน (ต่างคนต่างเห็นสตรีมเต็ม)"""
    if cursor is None:
        cursor = _cursor
    if seen is None:
        seen = _seen
    if seen_order is None:
        seen_order = _seen_order
    lid = log["id"]
    try:
        sth = http_json(log["url"] + "/ct/v1/get-sth", timeout=12)
        size = int(sth["tree_size"])
        _sth[lid] = {"size": size, "ts": int(sth.get("timestamp", 0)) // 1000,
                     "at": int(time.time())}
    except Exception:
        return []

    with _cur_lock:
        cur = cursor.get(lid)
        if cur is None or cur > size:
            cur = max(0, size - budget)          # รอบแรกเริ่มใกล้ปลาย
        st = _stat.setdefault(lid, {"got": 0, "grew": 0, "last_size": size})
        st["grew"] += max(0, size - st["last_size"])
        st["last_size"] = size

    # แต่ละ log ยอมให้กี่ใบต่อคำขอไม่เท่ากัน (argon 9, nimbus 256) เพราะจำกัดที่
    # ขนาดไบต์ ไม่ใช่จำนวน ถ้ายิงทีละคำขอเรียงกัน log ที่ให้น้อยจะช้ามาก
    # จึงจำค่าที่ได้จริงไว้ แล้วยิงหลายช่วงพร้อมกันโดยใช้ค่านั้นเป็นขนาดหน้าต่าง
    step = _yield.get(lid, 256)
    rows, got = [], 0
    while got < budget and cur < size:
        if deadline and time.time() > deadline:
            break
        wins, s = [], cur
        for _ in range(PAR_RANGES):
            if s >= size or len(wins) * step >= budget - got:
                break
            wins.append((s, min(s + step - 1, size - 1)))
            s += step
        if not wins:
            break

        def fetch(w):
            try:
                return w, http_json(
                    f"{log['url']}/ct/v1/get-entries?start={w[0]}&end={w[1]}", timeout=25)
            except Exception:
                return w, None

        with ThreadPoolExecutor(max_workers=len(wins)) as ex:
            parts = dict(ex.map(fetch, wins))

        ents, advanced = [], 0
        for w in wins:                        # เรียงตามลำดับ หยุดที่ช่วงแรกที่ไม่เต็ม
            d = parts.get(w)
            got_w = d.get("entries", []) if d else []
            ents.extend(got_w)
            advanced += len(got_w)
            if len(got_w) < (w[1] - w[0] + 1):
                break                         # ขาดตรงนี้ รอบหน้าค่อยมาต่อ ไม่ข้าม
        if not ents:
            break
        if ents:
            _yield[lid] = max(1, len(parts.get(wins[0], {}).get("entries", [])) or step)
        for e in ents:
            r = decode_entry(e)
            if not r:
                continue
            key = (r["d"], r["t"])
            if key in seen:
                continue
            seen.add(key)
            seen_order.append(key)
            if len(seen_order) > 20000:
                seen.discard(seen_order.pop(0))
            r["log"] = log["op"]
            r["id"] = lid
            rows.append(r)
        cur += advanced
        got += advanced

    with _cur_lock:
        cursor[lid] = cur
        _stat[lid]["got"] += got
        _stat[lid]["behind"] = max(0, size - cur)
    return rows


def sweep(budget=200, seconds=20, cursor=None, seen=None, seen_order=None):
    rows = []
    lock = threading.Lock()
    deadline = time.time() + seconds

    def worker(lg):
        got = pull(lg, budget, deadline, cursor, seen, seen_order)
        with lock:
            rows.extend(got)

    threads = [threading.Thread(target=worker, args=(lg,), daemon=True)
               for lg in usable_logs()]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=seconds + 15)
    rows.sort(key=lambda r: r["t"])
    return rows


def coverage():
    """อ่านไปได้กี่ % ของที่ log เพิ่มขึ้นจริง - ตัวเลขนี้บอกความจริงว่าตกไปเท่าไร"""
    out = []
    with _cur_lock:
        for lid, s in _stat.items():
            grew = s.get("grew", 0)
            out.append({"id": lid, "got": s["got"], "grew": grew,
                        "behind": s.get("behind", 0),
                        "pct": round(100.0 * s["got"] / grew, 1) if grew else None})
    return sorted(out, key=lambda x: -(x["behind"] or 0))


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


LIVE_PROMPT = """แต่ละบรรทัดคือ 1 เว็บ รูปแบบ: โดเมน<TAB>title<TAB>description (description อาจว่าง)
อ่าน title + description บอกว่าเว็บนั้นเป็นเว็บพนันออนไลน์ที่ "เปิดให้บริการจริงแล้ว" หรือยัง
ดูเนื้อหาใน title/description เป็นหลัก ไม่ใช่ชื่อโดเมน

live = yes ถ้า title/description สื่อชัดว่าเป็นเว็บพนัน/คาสิโน/สล็อต/แทงบอล/หวย ที่ทำเสร็จเปิดจริง
  สัญญาณ: มีคำโปรย/บริการ เช่น "ศูนย์รวมสล็อต", "คาสิโนออนไลน์", "สมัครสมาชิก", "เว็บตรง",
  "ฝากถอนออโต้", "ทางเข้าเล่น", "อันดับ 1", "เว็บพนันออนไลน์"
  ⭐ แม้เนื้อหาในหน้าจะน้อย แต่ถ้า title/description บอกชัดว่าเป็นเว็บพนันที่เปิดแล้ว = yes
     (เว็บ JS จำนวนมากมีข้อความไทยในหน้าน้อย แต่ title โปรยชัด)
live = no ถ้าเป็น: parking / ประกาศขายโดเมน (for sale) / coming soon / under construction /
  หน้า default ของโฮสต์ / ไม่เกี่ยวกับพนัน / title ว่างหรือเป็นแค่ชื่อโดเมน-แบรนด์ลอย ๆ ไม่มีคำโปรย
  ดูไม่ออกว่าเปิดจริง ให้ตอบ no

ตอบ JSON array เท่านั้น ไม่ต้องมีข้อความอื่น:
[{"d":"ชื่อโดเมน","live":"yes|no","w":"เหตุผลสั้นไม่เกิน 8 คำ"}]
ต้องมีครบทุกโดเมนที่ให้มา"""


def _ask_model(system, user_content):
    """เรียกโมเดล 1 ครั้งด้วย system+user - คืน {'rows':...,'usage':...} หรือ {'error':...}"""
    if not ENV["key"]:
        return {"error": "ยังไม่ได้ตั้ง OPENROUTER_API_KEY - ดู tools/ct-live/.env"}
    body = json.dumps({
        "model": ENV["model"],
        "temperature": 0,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user_content}],
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
    return {"rows": rows, "model": out.get("model", ENV["model"]),
            "usage": out.get("usage", {})}


def classify(domains):
    """ส่งชื่อโดเมนไปให้โมเดลคัดกรอง - ส่งไปแค่ "ชื่อ" ไม่ได้เปิดเว็บ ไม่ได้ส่งข้อมูลอื่น"""
    res = _ask_model(PROMPT, chr(10).join(str(d) for d in domains))
    if "error" in res:
        return res
    u = res["usage"]
    return {"rows": res["rows"], "model": res["model"],
            "in": u.get("prompt_tokens"), "out": u.get("completion_tokens")}


def live_check(items):
    """อ่าน title ของหน้าเว็บ (ที่ probe มาแล้ว) บอกว่าเป็นเว็บพนันที่ 'เปิดจริง' หรือยัง
    - items = [{"d":..,"title":..}] ส่งเฉพาะ title ไม่ได้เปิดเว็บซ้ำ"""
    lines = []
    for it in items:
        if isinstance(it, dict):
            d = str(it.get("d", ""))[:120]
            t = str(it.get("title", ""))[:200]
            ds = str(it.get("desc", ""))[:200]
        else:
            d, t, ds = str(it)[:120], "", ""
        lines.append(d + "\t" + t + "\t" + ds)
    res = _ask_model(LIVE_PROMPT, chr(10).join(lines))
    if "error" in res:
        return res
    u = res["usage"]
    return {"rows": res["rows"], "model": res["model"],
            "in": u.get("prompt_tokens"), "out": u.get("completion_tokens")}


# ---------------------------------------------------------------- http
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass                                          # เงียบไว้ ไม่งั้น console รก

    def _send(self, code, ctype, body):
        try:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (ConnectionAbortedError, ConnectionResetError, BrokenPipeError):
            # เบราว์เซอร์ตัด connection กลางคัน (สลับแท็บ/รีเฟรช/ยกเลิก request) — ไม่ใช่ error จริง
            pass

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
            n = min(int(m.group(1)), 5000) if m else 400
            ms = re.search(r"[?&]s=(\d+)", self.path)
            secs = min(int(ms.group(1)), 120) if ms else 20
            try:
                rows = sweep(n, secs)
            except Exception as ex:
                rows = []
                print("sweep error:", ex)
            self._send(200, "application/json; charset=utf-8",
                       json.dumps(rows, ensure_ascii=False).encode())
        elif self.path == "/api/proxy-status":
            self._send(200, "application/json; charset=utf-8", json.dumps({
                "rdap": len(_proxies),
                "probe": len(_probe_px),
                "note": "RDAP ใช้ชุดไทย · เปิดเว็บใช้ชุดต่างประเทศ ล้มเหลวแล้วยิงตรง",
            }, ensure_ascii=False).encode())

        elif self.path == "/api/coverage":
            self._send(200, "application/json; charset=utf-8",
                       json.dumps(coverage(), ensure_ascii=False).encode())

        elif self.path == "/api/hits":
            try:
                rows = db_recent()
            except Exception as ex:
                rows = []
                print("db_recent error:", ex)
            self._send(200, "application/json; charset=utf-8",
                       json.dumps({"rows": rows}, ensure_ascii=False).encode())

        elif self.path == "/api/stats":
            try:
                s = stats()
            except Exception as ex:
                s = {"error": str(ex)}
                print("stats error:", ex)
            self._send(200, "application/json; charset=utf-8",
                       json.dumps(s, ensure_ascii=False).encode())

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
                "ready": bool(ENV["key"]), "model": ENV["model"],
                "collector": (ENV.get("collect") or os.environ.get("COLLECTOR")) == "1"}).encode())
        else:
            self._send(404, "text/plain; charset=utf-8", b"not found")

    def do_POST(self):
        if self.path not in ("/api/classify", "/api/probe", "/api/age", "/api/hit", "/api/live"):
            self._send(404, "text/plain; charset=utf-8", b"not found")
            return
        n = int(self.headers.get("Content-Length", 0))
        try:
            doms = json.loads(self.rfile.read(n).decode("utf-8"))[:150]
        except Exception:
            self._send(400, "application/json; charset=utf-8",
                       json.dumps({"error": "payload ไม่ถูกต้อง"}, ensure_ascii=False).encode())
            return
        if self.path == "/api/hit":
            # doms ในที่นี้คือลิสต์ของ object ผลคัดกรอง ไม่ใช่ชื่อโดเมน
            # db_add กรอง/จำกัดขนาดเอง (ข้ามตัวที่ไม่ใช่ dict / ไม่ใช่โดเมน)
            try:
                total = db_add(doms if isinstance(doms, list) else [])
            except Exception as ex:
                self._send(500, "application/json; charset=utf-8",
                           json.dumps({"error": str(ex)}).encode())
                return
            self._send(200, "application/json; charset=utf-8",
                       json.dumps({"ok": True, "total": total}).encode())
            return
        if self.path == "/api/age":
            rows = ages_many([str(d)[:120] for d in doms if d][:60])
            self._send(200, "application/json; charset=utf-8",
                       json.dumps({"rows": rows}, ensure_ascii=False).encode())
            return
        if self.path == "/api/live":
            # อ่าน title ที่ probe มาแล้ว บอกว่า "เปิดเว็บจริง" หรือยัง
            res = live_check([r for r in doms if isinstance(r, dict)][:60])
            self._send(200, "application/json; charset=utf-8",
                       json.dumps(res, ensure_ascii=False).encode())
            return
        if self.path == "/api/probe":
            rows = probe_many([str(d)[:120] for d in doms if d][:150])
            self._send(200, "application/json; charset=utf-8",
                       json.dumps({"rows": rows}, ensure_ascii=False).encode())
            return
        res = classify([str(d)[:120] for d in doms if d][:60])
        self._send(200, "application/json; charset=utf-8",
                   json.dumps(res, ensure_ascii=False).encode())


# ---------------------------------------------------------------- collector (ฝั่ง server)
# เดิน pipeline เอง (สตรีม -> กรองชื่อ -> probe -> classify -> live -> age -> เก็บ)
# ไม่ต้องเปิดแท็บ browser — เปิดด้วย COLLECTOR=1 ใน .env (ใช้บน VPS)
# กรองชื่อ (thScore) พอร์ตจาก index.html ให้เหมือนกัน จะได้ funnel ประหยัด token เท่ากัน
_RE_TLD = re.compile(r"\.(com|net|org|info|co|io|vip|xyz|club|online|site|live|bet|win|me|"
                     r"cc|top|pro|asia|biz|shop|fun|app|link|store|games?|casino|th)(\.[a-z]{2})?$")
_TH_SUF = (r"(vvip|vip|pro|play|club|wins|win|games|game|bets|bet|betting|casino|auto|"
           r"slots|slot|new|home|hub|max|one|plus|live|member|official|money|rich|lucky|luck|"
           r"king|gold|asia|online|fun|joy|top|best|real|mex|link|lotto|login|brand|zz)")
_RE_SUF = re.compile(_TH_SUF + r"[a-z]{0,3}$")
_RE_ANY = re.compile(_TH_SUF)
_RE_DSUF = re.compile("-" + _TH_SUF)
_RE_PRE = re.compile(r"^(play|bet|win|slot|game|casino)-")
_RE_THN = re.compile(r"(^|[-\d])(th|thai)$|thai")
_RE_LUCK = re.compile(r"(1688|8888|168|888|889|789|999|989|555|456|678|365|356|369|808|855|"
                      r"878|868|88|89|98|99|66|77|55|44|33|22|69|36|24|29|123|289|333|444|666|777)")
_RE_WD = re.compile(r"[a-z]{2,}\d{2,}")
_RE_DW = re.compile(r"^\d{1,4}[a-z]{2,}")
_RE_DUP = re.compile(r"([a-z])\1$")
_RE_TAIL = re.compile(r"[a-z]{3,}[xzkvsr]$")
_TH_VOCAB = {}
_TH_MIN = 2.0


def _th_core(d):
    lab = _RE_TLD.sub("", str(d or "").lower().lstrip("*.")).split(".")
    return lab[-1] if lab else ""


def _th_struct(c):
    flat = c.replace("-", "").replace("_", "")
    s = 0.0
    if _RE_THN.search(flat): s += 2.0
    if _RE_SUF.search(flat): s += 1.5
    elif _RE_ANY.search(flat): s += 1.0
    if _RE_DSUF.search(c): s += 0.5
    if _RE_PRE.search(c): s += 1.5
    if _RE_LUCK.search(flat): s += 1.5
    if _RE_WD.search(flat): s += 1.5
    if _RE_DW.search(flat): s += 0.5
    if _RE_DUP.search(flat): s += 0.5
    if _RE_TAIL.search(flat): s += 0.5
    return s


def _th_tokens(d):
    c = _th_core(d)
    t = set()
    for w in re.findall(r"[a-z]{2,12}", c):
        t.add("w:" + w)
    for n in re.findall(r"\d{2,4}", c):
        t.add("n:" + n)
    p = re.split(r"[-_]", c)
    t.add("end:" + re.sub(r"\d+$", "", p[-1])[:12])
    return t


def _load_vocab():
    global _TH_VOCAB, _TH_MIN
    for name in ("vocab.json", "vocab-generic.json"):
        f = HERE / name
        if f.exists():
            try:
                v = json.loads(f.read_text(encoding="utf-8"))
                _TH_VOCAB, _TH_MIN = v.get("vocab", {}), v.get("min", 2.0)
                return
            except Exception:
                pass


def th_hint(d):
    d = str(d or "").lower().lstrip("*.")
    if RE_THAI.search(d):
        return True
    s = _th_struct(_th_core(d))
    for k in _th_tokens(d):
        s += _TH_VOCAB.get(k, 0)
    return s >= _TH_MIN


def _collect_process(cands):
    pr = {}
    for p in probe_many(cands):
        pr[p.get("d")] = p
    cls = [d for d in cands
           if not pr.get(d, {}).get("err") and (pr[d].get("th") or pr[d].get("parked"))][:60]
    if not cls:
        return
    res = classify(cls)
    if "error" in res:
        print("collector classify:", str(res["error"])[:80])
        return
    recs, liveitems, ageneed = [], [], []
    for cr in res.get("rows", []):
        d = str(cr.get("d", "")).lower().lstrip("*.")
        if not d:
            continue
        v = str(cr.get("v", "no")).lower()
        v = v if v in ("yes", "maybe", "no") else "no"
        p = pr.get(d, {})
        recs.append({"d": d, "v": v, "m": cr.get("m", ""), "w": cr.get("w", ""),
                     "lang": p.get("lang", ""), "chars": p.get("thai_chars", 0),
                     "title": p.get("title", ""), "parked": p.get("parked", ""),
                     "live": "", "th": "", "days": None, "via": ""})
        if v != "no" and not p.get("parked") and (p.get("title") or p.get("desc")):
            liveitems.append({"d": d, "title": p.get("title", ""), "desc": p.get("desc", "")})
        if v != "no":
            ageneed.append(d)
    byd = {r["d"]: r for r in recs}
    if liveitems:
        lr = live_check(liveitems[:60])
        if "error" not in lr:
            for x in lr.get("rows", []):
                d = str(x.get("d", "")).lower().lstrip("*.")
                if d in byd:
                    byd[d]["live"] = "yes" if str(x.get("live", "")).lower() == "yes" else "no"
    if ageneed:
        for a in ages_many(ageneed[:60]):
            d = str(a.get("d", "")).lower().lstrip("*.")
            if d in byd:
                byd[d].update(th=a.get("th", ""), days=a.get("days"), via=a.get("via", ""))
    total = db_add(recs)
    gamb = sum(1 for r in recs if r["v"] != "no")
    print("collector: คัด %d เว็บ -> เก็บ %d (พนัน %d) · DB รวม %d"
          % (len(cls), len(recs), gamb, total))


def collector_loop():
    _load_vocab()
    cycle = int(os.environ.get("COLLECT_CYCLE") or ENV.get("collect_cycle") or 90)
    print("collector: เปิด — vocab %d คำ · min %.1f · รอบละ %ds (ไม่ต้องเปิดแท็บ)"
          % (len(_TH_VOCAB), _TH_MIN, cycle))
    seen = set()
    # cursor/seen แยกของ collector - ไม่แย่งกับ browser (/api/entries) ต่างคนต่างเห็นสตรีมเต็ม
    c_cursor, c_seen, c_seen_order = {}, set(), []
    try:                       # โหลดโดเมนที่มีใน DB แล้วเข้า seen - ไม่ probe/AI ซ้ำของเดิม
        for h in db_recent(50000):
            seen.add(str(h.get("d", "")).lower().lstrip("*."))
        print("collector: รู้จักจาก DB แล้ว %d โดเมน (จะไม่ทำซ้ำ)" % len(seen))
    except Exception:
        pass
    while True:
        try:
            rows = sweep(200, 20, c_cursor, c_seen, c_seen_order)
            cands = []
            for r in rows:
                d = str(r.get("d", "")).lower().lstrip("*.")
                if not d or d in seen:
                    continue
                if th_hint(r.get("u") or d):
                    seen.add(d)
                    cands.append(d)
            if len(seen) > 300000:
                seen = set(list(seen)[-150000:])
            if cands:
                _collect_process(cands[:120])
        except Exception as ex:
            print("collector loop:", type(ex).__name__, ex)
        time.sleep(cycle)


def main():
    global _proxies
    global _probe_px
    _proxies = load_proxies("proxies.txt")
    _probe_px = load_proxies("proxies-probe.txt")
    print("ct-live — ดูสตรีมใบรับรองสดจาก Certificate Transparency")
    print("proxy RDAP    : %s" % ("%d ตัว หมุนสลับ" % len(_proxies) if _proxies else "ไม่มี — ยิงตรง"))
    print("proxy เปิดเว็บ : %s" % ("%d ตัว ล้มเหลวแล้วยิงตรง" % len(_probe_px)
                                    if _probe_px else "ไม่มี — ยิงตรง"))
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
    if (ENV.get("collect") or os.environ.get("COLLECTOR")) == "1":
        threading.Thread(target=collector_loop, daemon=True).start()
    else:
        print("collector: ปิด (ตั้ง COLLECTOR=1 ใน .env ให้ server เก็บข้อมูลเองไม่ต้องเปิดแท็บ)")
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nหยุดแล้ว")


if __name__ == "__main__":
    main()

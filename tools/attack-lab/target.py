#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""target.py — เว็บ WordPress "จำลอง" ไว้ให้ซ้อมโจมตี รันบน localhost เท่านั้น

    python target.py                 # โหมดไม่มีการป้องกัน (เหมือนเว็บที่เพิ่งลงเสร็จ)
    python target.py --hardened      # เปิดกฎ hardening ชุดเดียวกับ configs/wp-hardening.conf

⚠️ นี่ไม่ใช่ WordPress จริง ไม่มีการรันโค้ดจริง เว็บเชลล์ที่ "อัปโหลด" เป็นไฟล์เปล่า
   ทุกอย่างอยู่ในหน่วยความจำ ปิดโปรแกรมแล้วหายหมด มีไว้ให้ "เห็นภาพ" ลำดับการเจาะ
   ว่าถ้าไม่มีการป้องกัน บอทเดินจากขั้นไหนไปขั้นไหน และกฎของเราตัดขั้นไหนทิ้ง

เทียบกับของจริง: โหมด --hardened ใช้ตรรกะเดียวกับกฎ nginx ใน
configs/wp-hardening.conf + common-site.conf ที่ deploy อยู่บนเครื่องจริง
"""
import argparse
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---- สถานะจำลองของ "เว็บ" ตัวนี้ ทุกอย่างอยู่ในแรม ----
STATE = {
    "wp_version": "6.4.2",                 # เวอร์ชันที่รู้ช่องโหว่ - meta generator แจกฟรี
    "users": {"admin": "รหัสอ่อน"},         # ชื่อผู้ใช้ที่ REST API จะแจก
    "valid_login": ("admin", "P@ssw0rd123"),
    "login_attempts": {},                  # ip -> [เวลาที่ลอง]
    "uploaded": {},                        # path -> เนื้อไฟล์ (เว็บเชลล์ที่ถูกวาง)
    "planted_admin": [],                   # ผู้ใช้ที่ถูกสร้างเพิ่มหลังยึดเว็บได้
}

HARDENED = False
RL_WINDOW = 60
RL_MAX = 5                                 # กฎจริง: limit_req zone wp-login 5 ครั้ง/นาที

# ---- กฎ hardening จริง แปลจาก configs/wp-hardening.conf เป็นเงื่อนไข path ----
def blocked_by_rule(method, path):
    """คืน (ชื่อกฎ, รหัสตอบกลับ) ถ้ากฎ hardening ตัวใดตัวหนึ่งบล็อก ไม่งั้นคืน None
    ทำงานเฉพาะตอน --hardened เท่านั้น"""
    if not HARDENED:
        return None
    p = path.split("?", 1)[0]

    # กฎ 1 (common-site.conf) — xmlrpc ปิดตาย
    if p == "/xmlrpc.php":
        return ("xmlrpc.php ถูกปิด (common-site.conf)", 403)
    # กฎ 2 — ห้ามรัน .php ใน uploads
    if re.match(r"^/wp-content/uploads/.*\.(php|phtml|php\d|phps|pht|shtml)$", p, re.I):
        return ("ห้ามรัน PHP ใน uploads (wp-hardening #2)", 403)
    # กฎ 3 — ห้ามเรียก .php ใน wp-includes ตรง ๆ
    if re.match(r"^/wp-includes/.*\.php$", p, re.I) and p not in (
            "/wp-includes/js/tinymce/wp-tinymce.php", "/wp-includes/ms-files.php"):
        return ("ห้ามเรียก PHP ใน wp-includes (wp-hardening #3)", 403)
    # กฎ 4 — โฟลเดอร์/ไฟล์ซ่อน (ยกเว้น acme-challenge)
    if "/." in p and "/.well-known/acme-challenge/" not in p:
        return ("บล็อกไฟล์/โฟลเดอร์ซ่อน (wp-hardening #4)", 404)
    # กฎ 5 — ไฟล์ที่ไม่ควรหลุด
    if re.match(r"^/(wp-config\.php|readme\.html|license\.txt)$", p, re.I):
        return ("บล็อกไฟล์ที่ไม่ควรหลุด (wp-hardening #5)", 403)
    if re.search(r"\.(sql|bak|old|env|ini|sh|zip|tar|gz)$", p, re.I):
        return ("บล็อกนามสกุลไฟล์อันตราย (wp-hardening #5)", 403)
    # กฎ 6 — ปิดการดึงรายชื่อผู้ใช้
    if re.match(r"^/wp-json/wp/v\d+/users", p):
        return ("ปิด REST users enumeration (wp-hardening #6)", 401)
    if re.match(r"^/(index\.php)?/?$", p) and "author=" in path:
        return ("ปิด ?author= enumeration (wp-hardening #6)", 403)
    return None


class Target(BaseHTTPRequestHandler):
    server_version = "Apache/2.4"          # ไม่โฆษณาว่าเป็น sim

    def log_message(self, *a):             # เงียบไว้ ให้ attacker.py เป็นคนเล่า
        pass

    def _send(self, code, body="", ctype="text/html; charset=utf-8", headers=None):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(b)

    # ---------------------------------------------------------------- GET
    def do_GET(self):
        rule = blocked_by_rule("GET", self.path)
        if rule:
            return self._send(rule[1], "blocked: %s" % rule[0],
                              headers={"X-Blocked-By": rule[0]})
        p = self.path.split("?", 1)[0]

        # หน้าแรก - meta generator แจกเวอร์ชัน (ช่องโหว่ข้อมูลรั่ว)
        if p == "/" and "author=" not in self.path:
            return self._send(200,
                '<!doctype html><html lang="th"><head>'
                '<meta name="generator" content="WordPress %s">'
                '<title>เว็บทดสอบ</title></head><body>สวัสดี</body></html>'
                % STATE["wp_version"])

        # /?author=1 -> เปิดเผยชื่อผู้ใช้จริงผ่าน redirect
        if "author=" in self.path:
            name = list(STATE["users"])[0]
            return self._send(301, "", headers={"Location": "/author/%s/" % name})

        # REST API แจกรายชื่อผู้ใช้แบบไม่ต้องล็อกอิน
        if re.match(r"^/wp-json/wp/v\d+/users", p):
            users = "".join('{"id":%d,"name":"%s","slug":"%s"}'
                            % (i + 1, u, u) for i, u in enumerate(STATE["users"]))
            return self._send(200, "[" + users.replace("}{", "},{") + "]",
                              ctype="application/json")

        # เรียกเว็บเชลล์ที่วางไว้ (จำลอง - ไม่รันโค้ดจริง)
        if p in STATE["uploaded"]:
            return self._webshell(p)

        # readme.html บอกเวอร์ชันอีกทาง
        if p == "/readme.html":
            return self._send(200, "<h1>WordPress %s</h1>" % STATE["wp_version"])

        return self._send(404, "not found")

    # ---------------------------------------------------------------- POST
    def do_POST(self):
        rule = blocked_by_rule("POST", self.path)
        if rule:
            return self._send(rule[1], "blocked: %s" % rule[0],
                              headers={"X-Blocked-By": rule[0]})
        p = self.path.split("?", 1)[0]
        n = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(n).decode("utf-8", "ignore") if n else ""

        if p == "/xmlrpc.php":
            return self._xmlrpc(body)
        if p == "/wp-login.php":
            return self._login(body)
        # อัปโหลดผ่านช่องโหว่ปลั๊กอิน -> วางไฟล์ลง uploads
        if p.startswith("/wp-admin/admin-ajax.php") or "upload" in p:
            return self._upload(body)
        # เรียกเว็บเชลล์ด้วย POST (สั่งงาน)
        if p in STATE["uploaded"]:
            return self._webshell(p, body)
        return self._send(404, "not found")

    # ---------------------------------------------------------------- ชิ้นส่วน
    def _xmlrpc(self, body):
        # system.multicall = ลองรหัสหลายพันครั้งใน request เดียว (ขยายกำลังบรูต)
        tries = body.count("<value>")
        if "wp.getUsersBlogs" in body or "system.multicall" in body:
            return self._send(200,
                "<methodResponse><params><param><value><array><data>"
                "<!-- ประมวลผล %d การเดารหัสใน request เดียว -->"
                "</data></array></value></param></params></methodResponse>" % max(tries, 1))
        return self._send(200, "<methodResponse/>")

    def _login(self, body):
        ip = self.client_address[0]
        now = time.time()
        hist = [t for t in STATE["login_attempts"].get(ip, []) if now - t < RL_WINDOW]
        # กฎ rate limit จริง (limit_req) - โหมด hardened เท่านั้น
        if HARDENED and len(hist) >= RL_MAX:
            return self._send(429, "429 too many requests",
                              headers={"X-Blocked-By": "rate limit wp-login 5r/m"})
        hist.append(now)
        STATE["login_attempts"][ip] = hist
        m = re.search(r"log=([^&]*)&pwd=([^&]*)", body)
        if m:
            import urllib.parse
            user = urllib.parse.unquote_plus(m.group(1))
            pw = urllib.parse.unquote_plus(m.group(2))
            if (user, pw) == STATE["valid_login"]:
                return self._send(302, "", headers={
                    "Location": "/wp-admin/",
                    "Set-Cookie": "wordpress_logged_in=SIM-ยึดเว็บสำเร็จ"})
        return self._send(200, "<div id='login_error'>รหัสผ่านไม่ถูกต้อง</div>")

    def _upload(self, body):
        # ช่องโหว่ upload: ปล่อยให้วาง .php ลง uploads ได้
        m = re.search(r'filename="([^"]+\.(?:php|phtml|pht))"', body, re.I)
        if not m:
            return self._send(200, '{"success":true}', ctype="application/json")
        fname = m.group(1)
        path = "/wp-content/uploads/2026/08/" + fname
        STATE["uploaded"][path] = body
        return self._send(200, '{"url":"%s"}' % path, ctype="application/json")

    def _webshell(self, path, body=""):
        # จำลองการทำงานของเว็บเชลล์ - ไม่รันคำสั่งจริง แค่แสดงว่าถ้ารันได้จะทำอะไรได้
        cmd = ""
        m = re.search(r"cmd=([^&]*)", self.path + "&" + body)
        if m:
            import urllib.parse
            cmd = urllib.parse.unquote_plus(m.group(1))
        if cmd == "id":
            return self._send(200, "uid=1000(www) gid=1000(www) groups=1000(www)")
        if cmd == "whoami":
            return self._send(200, "www")
        if "create_admin" in (self.path + body):
            STATE["users"]["hacker_bkp"] = "x"
            STATE["planted_admin"].append("hacker_bkp")
            return self._send(200, "สร้างผู้ใช้ระดับ admin 'hacker_bkp' สำเร็จ (จำลอง)")
        return self._send(200,
            "[เว็บเชลล์จำลองทำงานที่ %s] — ของจริงตรงนี้จะรันคำสั่งอะไรก็ได้ในสิทธิ์ www"
            % path)


def main():
    global HARDENED
    ap = argparse.ArgumentParser()
    ap.add_argument("--hardened", action="store_true",
                    help="เปิดกฎป้องกันชุดเดียวกับ configs/wp-hardening.conf")
    ap.add_argument("--port", type=int, default=8099)
    a = ap.parse_args()
    HARDENED = a.hardened
    mode = "เปิดกฎป้องกัน (hardened)" if HARDENED else "ไม่มีการป้องกันเลย (vulnerable)"
    print("=" * 60)
    print("  เป้าจำลอง WordPress — localhost:%d" % a.port)
    print("  โหมด: %s" % mode)
    print("  ⚠️ เป้าปลอม ไม่มีการรันโค้ดจริง ปิดโปรแกรมแล้วหายหมด")
    print("=" * 60)
    try:
        ThreadingHTTPServer(("127.0.0.1", a.port), Target).serve_forever()
    except KeyboardInterrupt:
        print("\nปิดเป้าจำลองแล้ว")


if __name__ == "__main__":
    main()

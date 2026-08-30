#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""hammer.py — ยิง request รัว ๆ ใส่เป้าซ้อมโหลด เพื่อดูภาระ CPU ของเป้า

    # ยิงเป้าบนเครื่องตัวเอง
    php -S 127.0.0.1:8099 tools/attack-lab/load-target.php   # เปิดเป้าอีกหน้าต่าง
    python tools/attack-lab/hammer.py

    # ยิงเป้าบน VPS เปล่าของเราเอง (ดู CPU ในหน้า aapanel ของ VPS)
    #   บน VPS:  bash serve-target.sh            # เปิดเป้าสาธารณะ พิมพ์ URL ออกมา
    #   บน PC :  python hammer.py --url http://72.62.127.10:18099/

🔒 ยิงเป้าที่ไม่ใช่ localhost ได้ "เฉพาะเป้าที่ตั้ง demo endpoint ไว้เอง" เท่านั้น
   ก่อนยิง จะเช็ค header X-Load-Demo:1 ก่อน ถ้าไม่มีจะปฏิเสธ
   จึงเอาไปยิงเว็บจริงของใคร (ที่ไม่มี header นี้) ไม่ได้ — วัดได้แค่เครื่องที่เราคุมเอง
"""
import argparse
import threading
import time
import urllib.request

STOP = False
COUNT = [0]
LOCK = threading.Lock()


def worker(url):
    global STOP
    while not STOP:
        try:
            urllib.request.urlopen(url, timeout=5).read()
            with LOCK:
                COUNT[0] += 1
        except Exception:
            pass


def main():
    global STOP
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8099/",
                    help="URL ของเป้า (เครื่องตัวเองหรือ VPS เปล่าของเราเอง)")
    ap.add_argument("--conc", type=int, default=8, help="ยิงพร้อมกันกี่ตัว")
    ap.add_argument("--dur", type=int, default=15, help="ยิงนานกี่วินาที")
    a = ap.parse_args()
    a.conc = min(a.conc, 64)
    a.dur = min(a.dur, 120)
    url = a.url

    import urllib.parse
    host = urllib.parse.urlparse(url).hostname or ""
    is_local = host in ("127.0.0.1", "localhost", "::1")

    # เช็คว่าเป้าเปิดอยู่ + ยืนยันว่าเป็น demo endpoint ที่เราตั้งเอง
    try:
        resp = urllib.request.urlopen(url, timeout=5)
        marker = resp.headers.get("X-Load-Demo", "")
        resp.read()
    except Exception:
        print("🔴 ต่อเป้าไม่ได้ที่ %s" % url)
        print("   เครื่องตัวเอง:  php -S 127.0.0.1:8099 tools/attack-lab/load-target.php")
        print("   VPS เปล่า   :  bash tools/attack-lab/serve-target.sh")
        return 1

    # เป้าที่ไม่ใช่ localhost ต้องมีเครื่องหมาย demo - กันเอาไปยิงเว็บจริงของใคร
    if not is_local and marker != "1":
        print("🔴 เป้า %s ไม่ใช่ demo endpoint (ไม่มี header X-Load-Demo:1)" % host)
        print("   เครื่องมือนี้ยิงได้เฉพาะเป้าซ้อมโหลดที่เราตั้งเองด้วย serve-target.sh")
        print("   ยิงเว็บจริงของใครไม่ได้")
        return 1
    if not is_local:
        print("  ⚠️ กำลังจะยิงเครื่องปลายทางจริง (%s) — ต้องเป็น VPS ของเราเองที่ไม่มีเว็บจริง"
              % host)

    print("=" * 58)
    print("  ยิง %d พร้อมกัน นาน %d วินาที ที่ %s" % (a.conc, a.dur, url))
    if is_local:
        print("  เปิด Task Manager ดู CPU ของ php.exe ตอนนี้")
    else:
        print("  เปิดหน้า aapanel ของ %s ดู CPU ตอนนี้" % host)
    print("=" * 58)

    threads = [threading.Thread(target=worker, args=(url,), daemon=True)
               for _ in range(a.conc)]
    t0 = time.time()
    for t in threads:
        t.start()
    while time.time() - t0 < a.dur:
        time.sleep(2)
        with LOCK:
            n = COUNT[0]
        el = time.time() - t0
        where = "php.exe" if is_local else ("CPU ของ " + host)
        print("  ยิงไปแล้ว %6d request  |  %5.0f req/วินาที  |  %s ควรพุ่งอยู่ตอนนี้"
              % (n, n / el if el else 0, where))
    STOP = True
    time.sleep(0.5)
    el = time.time() - t0
    print("-" * 58)
    print("  จบ — ยิงรวม %d request ใน %.0f วินาที (%.0f req/วินาที)"
          % (COUNT[0], el, COUNT[0] / el if el else 0))
    print("  ดู CPU ตกกลับสู่ปกติทันทีที่หยุด")
    print()
    if is_local:
        print("  หมายเหตุ: php -S เป็น single-thread จึงเห็นแค่ 1 core เต็ม")
        print("  ยิง VPS เปล่าที่มี php-fpm หลาย worker จะเห็นเต็มทั้งเครื่องเหมือน bbc29pro")
    else:
        print("  ของจริง xmlrpc แย่กว่านี้: ทุก POST ข้ามแคช + multicall ยัดหลายพันต่อ request")
        print("  บอทยิงจากหลายพัน IP พร้อมกัน CPU ไม่มีวันลง (ดู docs/12)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

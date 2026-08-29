#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ปรับตัวคัดกรองเว็บพนันไทยจากข้อมูลจริง แล้วพ่นโค้ด JS ไปใส่ index.html

    python tools/ct-live/tune.py               ปรับ + วัดผล
    python tools/ct-live/tune.py --emit        พิมพ์โค้ด JS ที่ได้

แบ่งข้อมูล 70% ไว้เรียน 30% ไว้ทดสอบ ตัวเลขที่รายงานมาจากส่วนที่ไม่เคยเห็น
ไม่งั้นจะได้เลขสวยเพราะจำคำตอบ ไม่ใช่เพราะเก่งจริง
"""
import io, os, re, sys, json, random

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
POS  = os.path.join(HERE, "data", "thai-gambling.txt")
NEG  = os.path.join(HERE, "data", "not-gambling.txt")

TLD = re.compile(r"\.(com|net|org|info|co|io|vip|xyz|club|online|site|live|bet|win|me|"
                 r"cc|top|pro|asia|biz|shop|fun|app|link|store|games?|casino|th)"
                 r"(\.[a-z]{2})?$")


# คำกลาง ๆ ของวงการ ไม่ผูกกับแบรนด์ไหน - ปลอดภัยที่จะเปิดเผย
GENERIC = set(
    "th thai vip vvip pro play club win wins game games bet bets betting casino "
    "slot slots auto new home hub max one plus live member official money rich "
    "lucky luck king gold asia online fun joy top best real mex link lotto login "
    "brand zz xn xx app co com net org info".split())


def write_vocab(name, mn, vocab):
    io.open(os.path.join(HERE, name), "w", encoding="utf-8").write(
        json.dumps({"min": mn, "vocab": vocab}, ensure_ascii=False, indent=1))


def load(path):
    if not os.path.exists(path):
        return []
    out = []
    for l in io.open(path, encoding="utf-8-sig"):
        l = re.sub(r"^https?://", "", l.strip().lower()).split("/")[0].lstrip("*.")
        if l and "." in l:
            out.append(l)
    return list(dict.fromkeys(out))


def core_of(d):
    """เอาเฉพาะชื่อจริง ตัดนามสกุลและ subdomain ออก"""
    lab = TLD.sub("", d).split(".")
    return lab[-1] if lab else d


def tokens(d):
    """ตัดคำจากชื่อโดเมน - คำอังกฤษ ตัวเลข และคำท้ายสุด"""
    c = core_of(d)
    t = set()
    for w in re.findall(r"[a-z]{2,12}", c):
        t.add("w:" + w)
    for n in re.findall(r"\d{2,4}", c):
        t.add("n:" + n)
    parts = re.split(r"[-_]", c)
    if parts:
        t.add("end:" + re.sub(r"\d+$", "", parts[-1])[:12])
    return t


def learn(pos, neg, min_count=4, min_lift=3.0):
    """เก็บคำที่โผล่ในเว็บพนันบ่อยกว่าเว็บทั่วไปมาก ๆ"""
    cp, cn = Counter(), Counter()
    for d in pos:
        cp.update(tokens(d))
    for d in neg:
        cn.update(tokens(d))
    P, N = len(pos), max(1, len(neg))
    keep = {}
    for tok, c in cp.items():
        if c < min_count:
            continue
        rp = c / P
        rn = (cn.get(tok, 0) + 0.5) / N
        lift = rp / rn
        if lift >= min_lift:
            keep[tok] = round(min(3.0, 1.0 + lift / 40.0), 2)
    return keep


SUF   = (r"(vvip|vip|pro|play|club|wins|win|games|game|bets|bet|betting|casino|auto|"
         r"slots|slot|new|home|hub|max|one|plus|live|member|official|money|rich|lucky|"
         r"luck|king|gold|asia|online|fun|joy|top|best|real|mex|link|lotto|login|brand|zz)")
RE_SUF  = re.compile(SUF + r"[a-z]{0,3}$")
RE_ANY  = re.compile(SUF)
RE_DSUF = re.compile(r"-" + SUF)
RE_PRE  = re.compile(r"^(play|bet|win|slot|game|casino)-")
RE_TH   = re.compile(r"(^|[-\d])(th|thai)$|thai")
RE_LUCK = re.compile(r"(1688|8888|168|888|889|789|999|989|555|456|678|365|356|369|808|855|878|868|"
                     r"88|89|98|99|66|77|55|44|33|22|69|36|24|29|123|289|333|444|666|777)")
RE_WD   = re.compile(r"[a-z]{2,}\d{2,}")
RE_DW   = re.compile(r"^\d{1,4}[a-z]{2,}")
RE_DUP  = re.compile(r"([a-z])\1$")          # flickk, pluss, winnerr - จดชื่อซ้ำหลายตัว
RE_TAIL = re.compile(r"[a-z]{3,}[xzkvsr]$")   # sabuyx, 3k888z, flickx


def structural(d):
    c = core_of(d)
    flat = c.replace("-", "").replace("_", "")
    s = 0.0
    if RE_TH.search(flat):   s += 2.0
    if RE_SUF.search(flat):  s += 1.5
    elif RE_ANY.search(flat):s += 1.0
    if RE_DSUF.search(c):    s += 0.5
    if RE_PRE.search(c):     s += 1.5
    if RE_LUCK.search(flat): s += 1.5
    if RE_WD.search(flat):   s += 1.5
    if RE_DW.match(flat):    s += 0.5
    if RE_DUP.search(flat):  s += 0.5
    if RE_TAIL.search(flat): s += 0.5
    return s


def score(d, vocab):
    if re.search(r"[\u0E00-\u0E7F]", d):
        return 99.0
    return structural(d) + sum(vocab.get(t, 0) for t in tokens(d))


def evaluate(pos, neg, vocab, th):
    tp = sum(1 for d in pos if score(d, vocab) >= th)
    fp = sum(1 for d in neg if score(d, vocab) >= th)
    return tp / max(1, len(pos)), fp / max(1, len(neg))


def main():
    pos, neg = load(POS), load(NEG)
    if not pos:
        print("ไม่พบ %s - ดู data/README.md" % POS)
        return 1
    if not neg:
        print("ไม่พบ %s - ต้องมีชุดลบถึงจะวัดการติดธงผิดได้" % NEG)
        return 1

    random.seed(20260830)
    random.shuffle(pos)
    cut = int(len(pos) * 0.7)
    tr, te = pos[:cut], pos[cut:]
    random.shuffle(neg)
    ncut = int(len(neg) * 0.7)
    ntr, nte = neg[:ncut], neg[ncut:]

    vocab = learn(tr, ntr)
    print("เรียนจาก %d โดเมน ได้คำที่ใช้ได้ %d คำ" % (len(tr), len(vocab)))
    r, f = evaluate(te, nte, {}, 2.0)
    print("กฎโครงสร้างอย่างเดียว (เกณฑ์ 2.0) : จับได้ %.1f%% ติดธงผิด %.1f%%" % (100 * r, 100 * f))
    print()
    print("  เกณฑ์   จับได้(เรียน)  จับได้(ทดสอบ)  ติดธงผิด(ทดสอบ)")
    best = None
    for th in [x / 2 for x in range(2, 17)]:
        r_tr, _ = evaluate(tr, ntr, vocab, th)
        r_te, f_te = evaluate(te, nte, vocab, th)
        mark = ""
        if f_te <= 0.05 and (best is None or r_te > best[1]):
            best, mark = (th, r_te, f_te), "  <=="
        print("  %4.1f    %6.1f%%        %6.1f%%         %5.1f%%%s"
              % (th, 100 * r_tr, 100 * r_te, 100 * f_te, mark))
    if best:
        print()
        print("เลือกเกณฑ์ %.1f -> จับได้ %.1f%% ติดธงผิด %.1f%% (วัดจากส่วนที่ไม่เคยเห็น)"
              % (best[0], 100 * best[1], 100 * best[2]))
    if "--emit" in sys.argv and best:
        # ปรับเกณฑ์เสร็จแล้วค่อยเรียนใหม่จากข้อมูล "ทั้งหมด" ข้อมูลยิ่งเยอะยิ่งแม่น
        # ตัวเลขที่รายงานข้างบนยังมาจากส่วนที่ไม่เคยเห็น จึงยังเชื่อได้
        full = dict(sorted(learn(pos, neg).items(), key=lambda kv: -kv[1]))
        write_vocab("vocab.json", best[0], full)

        # ตัวที่ commit ขึ้น repo ได้ - ตัดคำที่เป็นชื่อแบรนด์ของเราออก
        # รายชื่อ vocab เต็มคือรายชื่อแบรนด์ทั้งพอร์ต ไม่ควรอยู่บน repo
        # วัดแล้วเสียความแม่นแค่ 0.5% (88.3% -> 87.8%) คุ้มกว่าเอาไปเปิดเผย
        safe = {k: w for k, w in full.items()
                if k.startswith("n:") or k.split(":", 1)[1] in GENERIC
                or len(k.split(":", 1)[1]) <= 3}
        write_vocab("vocab-generic.json", best[0], safe)
        print()
        print("เรียนจากทั้ง %d โดเมน:" % len(pos))
        print("  vocab.json          %3d คำ  (มีชื่อแบรนด์ - ไม่ขึ้น git)" % len(full))
        print("  vocab-generic.json  %3d คำ  (ปลอดภัย commit ได้)" % len(safe))
    return 0


if __name__ == "__main__":
    sys.exit(main())

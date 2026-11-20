"""Minimal Hunspell expander (SFX/PFX, single-char flags, cross-product). Usage: unmunch.py dic aff > words"""
import re, sys
dic, aff = sys.argv[1], sys.argv[2]
rules = {}  # flag -> (kind, cross, [(strip, add, regex)])
lines = open(aff, encoding="utf-8", errors="replace").read().splitlines()
for ln in lines:
    p = ln.split()
    if len(p) >= 4 and p[0] in ("SFX", "PFX"):
        kind, flag = p[0], p[1]
        if flag not in rules and p[2] in "YN" and p[3].isdigit():
            rules[flag] = (kind, p[2] == "Y", []); continue
        if flag in rules and len(p) >= 4:
            strip = "" if p[2] == "0" else p[2]
            add = "" if p[3] == "0" else p[3].split("/")[0]
            cond = p[4] if len(p) > 4 else "."
            rx = re.compile(("^" + cond) if kind == "PFX" else (cond + "$"))
            rules[flag][2].append((strip, add, rx))
out = set()
def sfx(w, flags):
    res = []
    for f in flags:
        r = rules.get(f)
        if not r or r[0] != "SFX": continue
        for strip, add, rx in r[2]:
            if rx.search(w) and w.endswith(strip):
                res.append((w[:len(w) - len(strip)] + add, r[1]))
    return res
for i, ln in enumerate(open(dic, encoding="utf-8", errors="replace")):
    if i == 0 or not ln.strip(): continue
    ln = ln.split("\t")[0].strip()
    w, _, flags = ln.partition("/")
    out.add(w)
    s = sfx(w, flags)
    out.update(x for x, _ in s)
    for f in flags:
        r = rules.get(f)
        if not r or r[0] != "PFX": continue
        for strip, add, rx in r[2]:
            if rx.search(w) and w.startswith(strip):
                out.add(add + w[len(strip):])
                if r[1]:
                    out.update(add + x[len(strip):] for x, c in s if c)
for w in sorted(out): print(w)

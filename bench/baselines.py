"""Dictionary baselines that mimic how existing layout switchers decide."""
import re
from pathlib import Path

from core import EN, BG, Tool, render, render_one

DATA = Path(__file__).resolve().parent.parent / "data"
_strip = re.compile(r"^[^\w]+|[^\w]+$")


def load_dicts(with_freq=True):
    d = [set(), set()]
    for L, f in ((EN, "en_words.txt"), (BG, "bg_words.txt")):
        d[L] = {w.strip() for w in open(DATA / f, encoding="utf-8") if w.strip()}
    freq = [{}, {}]
    for L, f, ok in ((EN, "en_50k.txt", lambda w: w.isascii()), (BG, "bg_50k.txt", lambda w: not w.isascii())):
        for line in open(DATA / "raw" / f, encoding="utf-8"):
            w, _, n = line.rstrip().partition(" ")
            if w.isalpha() and ok(w):
                freq[L][w] = int(n)
    hun = [set(d[EN]), set(d[BG])]
    if with_freq:
        for L in (EN, BG):
            d[L] |= {w for w, n in freq[L].items() if n >= 50}
    # single letters: only real one-letter words count
    one = [{"a", "A", "I", "i"}, set("авеиосуяѝАВЕИОСУЯ")]
    for L in (EN, BG):
        d[L] = {w for w in d[L] if len(w) > 1 or w in one[L]}
    return d, freq, hun


def _prefixes(words, maxlen=12):
    p = set()
    for w in words:
        w = w.lower()
        for i in range(1, min(len(w), maxlen) + 1):
            p.add(w[:i])
    return p


class DictBaseline(Tool):
    """At a word boundary: if the typed word isn't valid in the active layout's language
    but its remap is valid in the other language, fix it. Optional frequency tie-break
    and optional prefix-based early detection."""

    def __init__(self, dicts, freq, use_freq=False, prefix_min=0, ratio=100.0):
        self.d, self.freq = dicts, freq
        self.use_freq, self.prefix_min, self.ratio = use_freq, prefix_min, ratio
        self.pre = [_prefixes(dicts[EN]), _prefixes(dicts[BG])] if prefix_min else None
        self.name = "dict" + ("+freq" if use_freq else "") + (f"+prefix{prefix_min}" if prefix_min else "")

    def valid(self, w, L):
        if not w:
            return False
        parts = [p for p in w.split("-") if p]
        return bool(parts) and all(p in self.d[L] or p.lower() in self.d[L] for p in parts)

    def on_key(self, i, key, active, tok_keys, tok_lays, boundary):
        other = 1 - active
        t = _strip.sub("", render(tok_keys, tok_lays))
        c = _strip.sub("", render_one(tok_keys, other))
        if not c or not any(ch.isalpha() for ch in c) or not any(ch.isalpha() for ch in t):
            return False
        if not boundary:
            if not self.prefix_min:
                return False
            n = sum(ch.isalpha() for ch in t)
            if n < self.prefix_min or not t.isalpha() or not c.isalpha():
                return False
            return t.lower() not in self.pre[active] and c.lower() in self.pre[other]
        tv, cv = self.valid(t, active), self.valid(c, other)
        if not cv:
            return False
        if not tv:
            return True
        if self.use_freq:
            ft = self.freq[active].get(t.lower(), 0)
            fc = self.freq[other].get(c.lower(), 0)
            return fc > self.ratio * max(ft, 1) and fc > 1000
        return False

"""Core of the wrong-layout benchmark: key maps, episode generation, simulation, scoring.

Layouts: EN = 0 (macOS "U.S."), BG = 1 (macOS "Bulgarian", BDS typewriter).
A keystroke is a physical key + shift, encoded as an int id. The key stream is
layout independent; what appears on screen depends on the active layout.
"""
from __future__ import annotations

import json
import random
import re
from dataclasses import dataclass, field
from pathlib import Path

EN, BG = 0, 1
HERE = Path(__file__).resolve().parent
_km = json.load(open(HERE / "keymap.json", encoding="utf-8"))
KEYS = list(_km["us"].keys())  # 47 physical keys, named by their unshifted US char
SPACE_KEY = len(KEYS)
SPACE_ID = SPACE_KEY * 2
VOCAB = SPACE_ID + 2

# RENDER[layout][key_id] -> char ('' if the key produces nothing)
RENDER = [[""] * VOCAB, [""] * VOCAB]
for k, name in enumerate(KEYS):
    for s in (0, 1):
        RENDER[EN][k * 2 + s] = _km["us"][name][s]
        RENDER[BG][k * 2 + s] = _km["bg"][name][s]
for L in (EN, BG):
    RENDER[L][SPACE_ID] = " "

CHAR2KEY = [{}, {}]
for L in (EN, BG):
    for kid in range(VOCAB):
        c = RENDER[L][kid]
        if c and c not in CHAR2KEY[L]:
            CHAR2KEY[L][c] = kid

# a key is neutral if it renders identically in both layouts (space, digits, ...)
NEUTRAL = [RENDER[EN][k] == RENDER[BG][k] for k in range(VOCAB)]


def render(keys, lays):
    return "".join(RENDER[l][k] for k, l in zip(keys, lays))


def render_one(keys, L):
    return "".join(RENDER[L][k] for k in keys)


def is_cyr(c):
    return "Ѐ" <= c <= "ӿ"


def is_lat(c):
    return ("a" <= c <= "z") or ("A" <= c <= "Z")


_NORM = str.maketrans({
    "„": '"', "“": '"', "”": '"', "«": '"', "»": '"', "″": '"',
    "’": "'", "‘": "'", "‚": "'", "′": "'", "´": "'", "`": "'",
    "–": "-", "—": "-", "−": "-", "‐": "-", "‑": "-",
    " ": " ", "\t": " ", "ѐ": "е", "Ѐ": "Е", "…": "...",
})


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.translate(_NORM)).strip()


def encode(text: str):
    """text -> (keys, intended layout per key) or None if not typeable."""
    cur = None
    for c in text:
        if is_cyr(c):
            cur = BG; break
        if is_lat(c):
            cur = EN; break
    if cur is None:
        cur = BG
    keys, lays = [], []
    for c in text:
        if c == " ":
            keys.append(SPACE_ID); lays.append(cur); continue
        if is_cyr(c):
            L = BG
        elif is_lat(c):
            L = EN
        elif c in CHAR2KEY[cur]:
            L = cur
        elif c in CHAR2KEY[1 - cur]:
            L = 1 - cur
        else:
            return None
        if c not in CHAR2KEY[L]:
            return None
        cur = L
        keys.append(CHAR2KEY[L][c]); lays.append(L)
    return keys, lays


# ---------------------------------------------------------------- episodes
@dataclass
class Episode:
    text: str
    keys: list
    intended: list          # per key, EN/BG
    init_active: int
    user_sel: dict          # key index -> layout the user explicitly selects before that key
    tok_tags: list          # per token (space separated), set of tags
    source: str = ""
    kind: str = ""


def tokens_of(keys):
    """list of (start, end_exclusive) key ranges for space-separated tokens."""
    out, s = [], 0
    for i, k in enumerate(keys):
        if k == SPACE_ID:
            if i > s:
                out.append((s, i))
            s = i + 1
    if len(keys) > s:
        out.append((s, len(keys)))
    return out


NEIGHBORS = {}
_rows = ["qwertyuiop[", "asdfghjkl;'", "zxcvbnm,./"]
for r in _rows:
    for i, c in enumerate(r):
        NEIGHBORS[c] = [r[j] for j in (i - 1, i + 1) if 0 <= j < len(r)]


def typo(word: str, rng: random.Random) -> str:
    """Typo applied in key space: swap, delete, double or neighbor-key substitution."""
    if len(word) < 3:
        return word
    i = rng.randrange(len(word) - 1)
    op = rng.random()
    if op < 0.3:
        return word[:i] + word[i + 1] + word[i] + word[i + 2:]
    if op < 0.55:
        return word[:i] + word[i + 1:]
    if op < 0.75:
        return word[:i] + word[i] + word[i:]
    # neighbor key substitution, done in key space so it works for both scripts
    c = word[i]
    for L in (EN, BG):
        if c in CHAR2KEY[L]:
            kid = CHAR2KEY[L][c]
            name = KEYS[kid // 2] if kid != SPACE_ID else " "
            nb = NEIGHBORS.get(name)
            if nb:
                k2 = KEYS.index(rng.choice(nb)) * 2 + (kid % 2)
                r = RENDER[L][k2]
                if r and (r.isalpha() == c.isalpha()):
                    return word[:i] + r + word[i + 1:]
    return word


def chatify(s: str, rng: random.Random) -> str:
    if rng.random() < 0.5 and s:
        s = s[0].lower() + s[1:]
    if rng.random() < 0.5:
        s = s.rstrip(".")
    if rng.random() < 0.25:
        s = s.replace(",", "")
    return s


def make_episode(rng, bg_lines, en_lines, terms, source, p_start=0.3, p_forget=0.35,
                 p_typo=0.04, chat=0.5, banned=None):
    """banned: if given, half of the inserted terms are random English words/bigrams from
    en_lines (excluding banned held-out terms), so a model can't just memorize a term list."""
    """Build one typing episode. Returns Episode or None."""
    r = rng.random()
    tags_extra = {}
    if r < 0.40:
        kind = "bg"
        parts = [rng.choice(bg_lines) for _ in range(rng.choice((1, 1, 2)))]
    elif r < 0.60:
        kind = "en"
        parts = [rng.choice(en_lines) for _ in range(rng.choice((1, 1, 2)))]
    elif r < 0.85:
        kind = "bg+terms"
        parts = [rng.choice(bg_lines)]
    else:
        kind = "bg|en"
        parts = [rng.choice(bg_lines), rng.choice(en_lines)]
        if rng.random() < 0.5:
            parts.reverse()
    parts = [chatify(p, rng) if rng.random() < chat else p for p in parts]
    words = " ".join(parts).split(" ")
    tags = [set() for _ in words]
    if kind == "bg+terms":
        for _ in range(rng.choice((1, 1, 2, 3))):
            t, ttag = rng.choice(terms)
            if banned is not None and rng.random() < 0.6:
                t, ttag = synth_insert(rng, en_lines, banned) or (t, ttag)
            elif False:
                ew = rng.choice(en_lines).split()
                k = rng.choice((1, 1, 2))
                j = rng.randrange(max(1, len(ew) - k + 1))
                cand = " ".join(w.strip('.,!?";:()') for w in ew[j:j + k]).strip()
                if rng.random() < 0.5:
                    cand = cand.lower()
                if cand and not any(w.lower() in banned for w in cand.split()):
                    t, ttag = cand, "enword"
            pos = rng.randrange(len(words) + 1)
            tw = t.split(" ")
            words[pos:pos] = tw
            tags[pos:pos] = [{"term", ttag} for _ in tw]
    # typos + name tags
    for i, w in enumerate(words):
        if "term" not in tags[i] and rng.random() < p_typo:
            w2 = typo(w, rng)
            if w2 != w:
                words[i] = w2
                tags[i].add("typo")
        if i > 0 and words[i][:1].isupper() and not words[i - 1].endswith((".", "!", "?")):
            tags[i].add("name")
    words = [w for w in words if w]
    tags = tags[: len(words)]
    text = normalize(" ".join(words))
    if not text or len(text) > 400:
        return None
    enc = encode(text)
    if enc is None:
        return None
    keys, intended = enc
    toks = tokens_of(keys)
    if len(toks) != len(tags):
        tags = [set() for _ in toks]  # normalization changed tokenization; drop tags

    # user layout behaviour: explicit selection model
    user_sel = {}
    first_letter = next((i for i, k in enumerate(keys) if not NEUTRAL[k]), 0)
    want0 = intended[first_letter] if keys else BG
    init_active = (1 - want0) if rng.random() < p_start else want0
    tok_start = [s for s, _ in toks]
    active = init_active
    prev_want = want0
    notice_at = None
    for i, k in enumerate(keys):
        if NEUTRAL[k]:
            continue
        w = intended[i]
        sel = None
        if notice_at is not None and i >= notice_at:
            sel, notice_at = w, None
        if w != prev_want:  # an intended switch point
            prev_want = w
            if rng.random() >= p_forget:
                sel = w
        if sel is not None:
            user_sel[i] = sel
            active = sel
        if active != w and notice_at is None:
            notice_at = _notice(rng, tok_start, i)
    return Episode(text, keys, intended, init_active, user_sel, tags, source, kind)


_CONS = "bcdfghjklmnpqrstvwxz"


def _enwords(rng, en_lines, banned, k):
    for _ in range(20):
        ew = [w.strip('.,!?";:()').lower() for w in rng.choice(en_lines).split()]
        ew = [w for w in ew if w.isalpha() and w not in banned]
        if len(ew) >= k:
            j = rng.randrange(len(ew) - k + 1)
            return ew[j:j + k]
    return None


def synth_insert(rng, en_lines, banned):
    """Random English material for training: corpus words, chat abbreviations,
    identifiers, file names, URLs, CLI commands. Never uses banned (held-out) words."""
    r = rng.random()
    if r < 0.45:
        w = _enwords(rng, en_lines, banned, rng.choice((1, 1, 1, 2)))
        if not w:
            return None
        t = " ".join(w)
        if rng.random() < 0.3:
            t = t.capitalize()
        return t, "enword"
    if r < 0.6:  # abbreviation-like: 2-4 mostly consonant letters
        n = rng.choice((2, 3, 3, 4))
        t = "".join(rng.choice(_CONS) if rng.random() < 0.8 else rng.choice("aeiouy") for _ in range(n))
        if rng.random() < 0.2:
            t = t.upper()
        return (None if t in banned else (t, "enword"))
    w = _enwords(rng, en_lines, banned, rng.choice((2, 2, 3)))
    if not w:
        return None
    w = [x[:8] for x in w]
    r = rng.random()
    if r < 0.2:
        t = w[0] + "".join(x.capitalize() for x in w[1:])
    elif r < 0.35:
        t = "_".join(w)
    elif r < 0.5:
        t = "".join(w[:-1]) + "." + rng.choice(("py", "js", "ts", "md", "json", "yaml", "txt", "go", "rs", "sh"))
    elif r < 0.65:
        t = "https://" + w[0] + rng.choice((".com/", ".io/", ".dev/", ".net/")) + "/".join(w[1:])
    elif r < 0.8:
        t = w[0] + " " + rng.choice(("-", "--")) + w[1][: rng.choice((1, 4, 8))]
    elif r < 0.9:
        t = rng.choice("@#") + w[0]
    else:
        t = w[0] + "@" + w[1] + rng.choice((".com", ".bg", ".org"))
    return t, "code"


def _notice(rng, tok_start, i):
    """User notices wrong layout after a few tokens; returns key index where they fix it."""
    n = 1
    while rng.random() < 0.6 and n < 8:
        n += 1
    later = [s for s in tok_start if s > i]
    return later[n - 1] if len(later) >= n else 10**9


# ---------------------------------------------------------------- simulation
class Tool:
    name = "none"

    def start(self, ep: Episode):
        pass

    def on_key(self, i, key, active, tok_keys, tok_lays, boundary) -> bool:
        """Called after key i appeared on screen. tok_keys/tok_lays: the token
        under consideration (current token, or the just-finished one if boundary).
        Return True to convert that token to the other layout and switch layout."""
        return False


@dataclass
class Result:
    lays: list
    fires: list = field(default_factory=list)  # (key index, token idx, correct)


def simulate(ep: Episode, tool: Tool | None, undo_false=True) -> Result:
    keys = ep.keys
    lays = [0] * len(keys)
    active = ep.init_active
    toks = tokens_of(keys)
    tok_of = [-1] * len(keys)
    for t, (s, e) in enumerate(toks):
        for j in range(s, e):
            tok_of[j] = t
    fired = set()
    res = Result(lays)
    if tool:
        tool.start(ep)
    cur_start = 0
    for i, k in enumerate(keys):
        if i in ep.user_sel:
            active = ep.user_sel[i]
        lays[i] = active
        if k == SPACE_ID:
            ts, te, t = cur_start, i, tok_of[i - 1] if i > 0 else -1
            cur_start = i + 1
            boundary = True
        else:
            ts, te, t = cur_start, i + 1, tok_of[i]
            boundary = False
        if tool is None or t < 0 or te <= ts or t in fired:
            continue
        if tool.on_key(i, k, active, keys[ts:te], lays[ts:te], boundary):
            fired.add(t)
            active = _apply_fix(ep, lays, ts, te, active, res, i, t, undo_false)
    if tool is not None and keys and keys[-1] != SPACE_ID:
        t = tok_of[len(keys) - 1]
        if t not in fired and tool.on_key(len(keys), SPACE_ID, active, keys[cur_start:], lays[cur_start:], True):
            _apply_fix(ep, lays, cur_start, len(keys), active, res, len(keys), t, undo_false)
    return res


def _apply_fix(ep, lays, ts, te, active, res, i, t, undo_false=True):
    other = 1 - active
    before = sum(1 for j in range(ts, te) if not NEUTRAL[ep.keys[j]] and lays[j] == ep.intended[j])
    after = sum(1 for j in range(ts, te) if not NEUTRAL[ep.keys[j]] and ep.intended[j] == other)
    correct = after > before
    res.fires.append((i, t, correct))
    if correct or not undo_false:
        for j in range(ts, te):
            lays[j] = other
        return other
    return active  # false fix: user hits undo, text and layout restored


# ---------------------------------------------------------------- scoring
LETTERS_RE = re.compile(r"[^\W\d_]+")


def tok_letters(text):
    return "".join(LETTERS_RE.findall(text))


class Scorer:
    def __init__(self, dicts=None):
        self.dicts = dicts  # [set(en words), set(bg words)] for OOV bucket
        self.c = {}

    def add(self, key, n=1):
        self.c[key] = self.c.get(key, 0) + n

    def score(self, ep: Episode, base: Result, res: Result):
        toks = tokens_of(ep.keys)
        ff_by_tok = {}
        for (_, t, ok) in res.fires:
            if not ok:
                ff_by_tok[t] = ff_by_tok.get(t, 0) + 1
        ep_ok = True
        for t, (s, e) in enumerate(toks):
            nn = [j for j in range(s, e) if not NEUTRAL[ep.keys[j]]]
            if not nn:
                continue
            intended_text = render(ep.keys[s:e], ep.intended[s:e])
            letters = tok_letters(intended_text)
            if not letters:
                continue
            lang = ep.intended[nn[0]]
            buckets = ["all", "bg" if lang == BG else "en"]
            if len(letters) <= 2:
                buckets.append("short")
            if self.dicts is not None:
                if letters.lower() not in self.dicts[lang] and letters not in self.dicts[lang]:
                    buckets.append("oov")
            tags = ep.tok_tags[t] if t < len(ep.tok_tags) else set()
            buckets += sorted(tags)
            if ep.kind in ("bg+terms", "bg|en"):
                buckets.append("mixed_ep")
            was_wrong = any(base.lays[j] != ep.intended[j] for j in nn)
            now_ok = all(res.lays[j] == ep.intended[j] for j in nn)
            ff = ff_by_tok.get(t, 0)
            if ff or not now_ok:
                ep_ok = False
            for b in buckets:
                if was_wrong:
                    self.add((b, "wrong"))
                    self.add((b, "fixed" if now_ok else "missed"))
                else:
                    self.add((b, "correct"))
                    if ff:
                        self.add((b, "ff"), ff)
        # detection latency per wrong run (in keys, from first wrong key)
        fires = sorted(res.fires)
        i = 0
        n = len(ep.keys)
        while i < n:
            if not NEUTRAL[ep.keys[i]] and base.lays[i] != ep.intended[i]:
                j = i
                last = i
                while j < n and (NEUTRAL[ep.keys[j]] or base.lays[j] != ep.intended[j]):
                    if not NEUTRAL[ep.keys[j]]:
                        last = j
                    j += 1
                self.add(("run", "n"))
                hit = next((f for f, _, ok in fires if ok and i <= f <= last + 1), None)
                if hit is not None:
                    self.add(("run", "detected"))
                    self.add(("run", "lat_sum"), hit - i + 1)
                    # detected before the first word of the run was finished?
                    if hit < n and ep.keys[min(hit, n - 1)] != SPACE_ID and hit <= last:
                        self.add(("run", "early"))
                i = j
            else:
                i += 1
        self.add(("ep", "n"))
        if ep_ok:
            self.add(("ep", "exact"))

    def summary(self):
        c = self.c
        out = {}
        bks = sorted({b for (b, _) in c if b not in ("run", "ep")})
        for b in bks:
            w, cor = c.get((b, "wrong"), 0), c.get((b, "correct"), 0)
            out[b] = {
                "wrong_tokens": w,
                "miss_rate": c.get((b, "missed"), 0) / w if w else None,
                "correct_tokens": cor,
                "ff_per_1k": 1000 * c.get((b, "ff"), 0) / cor if cor else None,
            }
        n = c.get(("run", "n"), 0)
        d = c.get(("run", "detected"), 0)
        out["runs"] = {
            "n": n,
            "detect_rate": d / n if n else None,
            "early_rate": c.get(("run", "early"), 0) / n if n else None,
            "mean_keys_to_detect": c.get(("run", "lat_sum"), 0) / d if d else None,
        }
        out["episodes"] = {"n": c.get(("ep", "n"), 0),
                           "exact": c.get(("ep", "exact"), 0) / max(1, c.get(("ep", "n"), 0))}
        return out

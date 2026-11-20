"""Corpus loading and deterministic train/test splits. Sources:
Leipzig Corpora (wiki+news, bg/en), OpenSubtitles 2018 via OPUS (first chunk, bg/en),
Tatoeba (bg/en, test only: unseen source)."""
import random
from pathlib import Path

from core import normalize, encode

RAW = Path(__file__).resolve().parent.parent / "data" / "raw"


def _leipzig(name):
    f = RAW / name / f"{name}-sentences.txt"
    return [l.split("\t", 1)[1].strip() for l in open(f, encoding="utf-8") if "\t" in l]


def _clean(lines, lo=3, hi=220):
    out = []
    for l in lines:
        l = normalize(l.lstrip("-").strip())
        if lo <= len(l) <= hi and encode(l) is not None:
            out.append(l)
    return out


def _subs(lang):
    lines = open(RAW / f"os_{lang}.txt", encoding="utf-8", errors="replace").read().splitlines()
    return lines[:-1]  # last line may be truncated


def _tatoeba(code):
    return [l.rstrip("\n").split("\t")[2] for l in open(RAW / f"{code}_sentences.tsv", encoding="utf-8")]


def load_all(seed=0):
    """returns {split: {group: (bg_lines, en_lines)}}"""
    rng = random.Random(seed)
    out = {"train": {}, "test": {}}
    lw = {L: _leipzig(n) for L, n in (("bg", "bul_wikipedia_2021_100K"), ("en", "eng_wikipedia_2016_100K"))}
    ln = {L: _leipzig(n) for L, n in (("bg", "bul_news_2022_100K"), ("en", "eng_news_2023_100K"))}
    for d in (lw, ln):
        for L in d:
            rng.shuffle(d[L])  # Leipzig sentences are independent; random split
    tr, te = {}, {}
    for L in ("bg", "en"):
        a, b = _clean(lw[L]), _clean(ln[L])
        tr[L] = a[: int(.85 * len(a))] + b[: int(.85 * len(b))]
        te[L] = a[int(.85 * len(a)):] + b[int(.85 * len(b)):]
    out["train"]["leipzig"] = (tr["bg"], tr["en"])
    out["test"]["leipzig"] = (te["bg"], te["en"])
    # subtitles: contiguous split so test films are unseen
    s = {}
    for L in ("bg", "en"):
        lines = _subs(L)
        cut = int(.7 * len(lines))
        s[L] = (_clean(lines[:cut]), _clean(rng.sample(lines[cut:], 200_000)))
    out["train"]["subs"] = (s["bg"][0], s["en"][0])
    out["test"]["subs"] = (s["bg"][1], s["en"][1])
    tb = _clean(_tatoeba("bul"))
    te_en = _clean(rng.sample(_tatoeba("eng"), 60_000))
    out["test"]["tatoeba"] = (tb, te_en)
    return out


# English terms / code / URLs inserted into Bulgarian text. Disjoint train/test lists
# so the model can't memorize the test terms.
TERMS_TRAIN = [(t, "tech") for t in """deploy merge commit build feature bug meeting deadline sprint backlog
review PR Slack Jira email laptop backend frontend release hotfix staging prod dashboard ticket standup
OK okay sorry thanks cool nice wow lol btw ASAP FYI demo call update login password server cache query
token API SDK CLI UI UX design roadmap feedback weekend party online offline download upload""".split()] + [
    (t, "code") for t in """npm install|git push|git status|docker compose up|ls -la|cd src|pip install numpy
getUserById|user_id|config.yaml|index.html|main.py|README.md|localhost:3000|https://github.com/acme/app
www.google.com|john@example.com|#general|@ivan|v2.1.3|C++|node_modules|.env|SELECT * FROM users""".split("|")]
TERMS_TEST = [(t, "tech") for t in """rebase pipeline issue branch iPhone Zoom Teams Figma Notion invoice
budget startup pitch refactor linter compile runtime crash patch spec mockup prototype workshop webinar
thx pls omg nope yep brb gg hype vibe chill sale discount Netflix YouTube podcast stream""".split()] + [
    (t, "code") for t in """yarn add react|git checkout -b fix|kubectl get pods|make test|rm -rf dist
fetchOrders|order_total|package.json|app.tsx|utils.go|CHANGELOG.md|127.0.0.1:8080|https://example.org/docs
maria@firma.bg|#random|@petar|1.0.0-beta|C#|__init__|.gitignore|DROP TABLE logs""".split("|")]


# val terms: held out from training too, so thresholds are tuned on unseen terms
TERMS_VAL = TERMS_TRAIN[2::3]
TERMS_FIT = [t for i, t in enumerate(TERMS_TRAIN) if i % 3 != 2]
BANNED = {w.lower() for t, _ in TERMS_TEST + TERMS_VAL for w in t.split()}

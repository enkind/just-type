"""Score live runs: compare what ended up in the text field with the intended text, per token.
usage: live_score.py results/live/*.jsonl"""
import difflib, json, sys
from collections import defaultdict
from pathlib import Path

import core

ROOT = Path(__file__).resolve().parent.parent
EPS = {e["id"]: e for e in map(json.loads, open(ROOT / "live" / "Resources" / "episodes.jsonl", encoding="utf-8"))}


def base_text(e):
    ep = core.Episode(e["text"], e["keys"], e["intended"], e["init"], {int(k): v for k, v in e["user_sel"].items()}, [])
    return core.render(ep.keys, core.simulate(ep, None).lays)


def score(path):
    c = defaultdict(int)
    for rec in map(json.loads, open(path, encoding="utf-8")):
        if rec.get("aborted"):
            continue
        e = EPS[rec["id"]]
        want = e["text"].split(" ")
        base = base_text(e).split(" ")
        got = rec["final"].rstrip(" ").split(" ")
        c["episodes"] += 1
        c["exact"] += rec["final"].rstrip(" ") == e["text"]
        # align got with want (tools may in rare cases add/remove spaces)
        sm = difflib.SequenceMatcher(a=want, b=got, autojunk=False)
        ok = set()
        for a0, b0, n in sm.get_matching_blocks():
            ok.update(range(a0, a0 + n))
        for i, w in enumerate(want):
            if not any(ch.isalpha() for ch in w):
                continue
            was_wrong = i >= len(base) or base[i] != w
            k = "wrong" if was_wrong else "correct"
            c[k] += 1
            if was_wrong:
                c["fixed" if i in ok else "missed"] += 1
            elif i not in ok:
                c["broken"] += 1
    return {"episodes": c["episodes"], "exact": c["exact"] / max(1, c["episodes"]),
            "wrong_tokens": c["wrong"], "miss_rate": c["missed"] / max(1, c["wrong"]),
            "correct_tokens": c["correct"], "broken_per_1k": 1000 * c["broken"] / max(1, c["correct"])}


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(Path(p).stem, score(p))


def expected_justtype(te=0.8, tm=0.995, nmin=4, model_path="model.pt"):
    """What the offline simulator predicts JustType will type live (false fixes not undone)."""
    import model as M
    m = M.load(model_path)
    out = {}
    eps = {i: core.Episode(e["text"], e["keys"], e["intended"], e["init"],
                           {int(k): v for k, v in e["user_sel"].items()}, []) for i, e in EPS.items()}
    probs = dict(zip(eps, M.predict(m, list(eps.values()))))
    tool = M.ModelTool({id(ep): probs[i] for i, ep in eps.items()}, te, tm, nmin)
    for i, ep in eps.items():
        out[i] = core.render(ep.keys, core.simulate(ep, tool, undo_false=False).lays)
    return out

"""Export model weights + key tables for the Swift app, and live-run episodes.
usage: export.py [model.pt] [n_episodes]"""
import json, sys, random
from pathlib import Path
import numpy as np, torch
import core, model as M, run
from data import TERMS_TEST

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "live" / "Resources"
OUT.mkdir(parents=True, exist_ok=True)


def export_model(path):
    m = M.load(path)
    sd = {k: v.numpy().astype(np.float32) for k, v in m.state_dict().items()}
    H = m.rnn.hidden_size
    # layer-0 input projection folded into a per-key table: emb @ W_ih0^T + b_ih0
    tab0 = sd["emb.weight"] @ sd["rnn.weight_ih_l0"].T + sd["rnn.bias_ih_l0"]
    parts = [("tab0", tab0), ("whh0", sd["rnn.weight_hh_l0"]), ("bhh0", sd["rnn.bias_hh_l0"]),
             ("wih1", sd["rnn.weight_ih_l1"]), ("bih1", sd["rnn.bias_ih_l1"]),
             ("whh1", sd["rnn.weight_hh_l1"]), ("bhh1", sd["rnn.bias_hh_l1"]),
             ("wout", sd["out.weight"].reshape(-1)), ("bout", sd["out.bias"])]
    meta = {"hid": H, "vocab": core.VOCAB, "pad": core.VOCAB, "tensors": []}
    off = 0
    with open(OUT / "weights.bin", "wb") as f:
        for name, a in parts:
            a = np.ascontiguousarray(a, np.float32)
            f.write(a.tobytes())
            meta["tensors"].append({"name": name, "shape": list(a.shape), "offset": off})
            off += a.size
    meta["keys"] = core.KEYS
    meta["render"] = core.RENDER
    json.dump(meta, open(OUT / "model.json", "w"), ensure_ascii=False)
    return m


def export_episodes(n, m):
    eps = run.episodes([("test", "leipzig"), ("test", "subs"), ("test", "tatoeba")], TERMS_TEST, 4000, seed=11)
    rng = random.Random(42)
    # oversample episodes that contain a wrong-layout span, keep some clean ones for false fixes
    wrong = [e for e in eps if any(b != i for b, i in zip(core.simulate(e, None).lays, e.intended))]
    clean = [e for e in eps if e not in wrong]
    pick = rng.sample(wrong, int(n * 0.7)) + rng.sample(clean, n - int(n * 0.7))
    rng.shuffle(pick)
    probs = M.predict(m, pick)
    with open(OUT / "episodes.jsonl", "w") as f:
        for k, (e, p) in enumerate(zip(pick, probs)):
            f.write(json.dumps({"id": k, "text": e.text, "keys": e.keys, "intended": e.intended,
                                "init": e.init_active, "user_sel": {str(a): b for a, b in e.user_sel.items()},
                                "source": e.source, "kind": e.kind, "tags": [sorted(t) for t in e.tok_tags],
                                "p_bg": [round(float(x), 6) for x in p]}, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    m = export_model(sys.argv[1] if len(sys.argv) > 1 else "model.pt")
    export_episodes(int(sys.argv[2]) if len(sys.argv) > 2 else 150, m)
    print("exported to", OUT)

"""Stage-1 offline contest: dictionary baselines vs micro-model on identical keystroke streams."""
import itertools
import json
import pickle
import random
import sys
import time
from pathlib import Path

import numpy as np
import torch

import baselines
import core
import model as M
from data import TERMS_TEST, TERMS_VAL

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "results"
OUT.mkdir(exist_ok=True)


def episodes(groups, terms, n, seed):
    d = pickle.load(open(ROOT / "data" / "splits.pkl", "rb"))
    out = []
    for g_i, (split, g) in enumerate(groups):
        bg, en = d[split][g]
        rng = random.Random(seed * 100 + g_i)
        k = 0
        while k < n:
            ep = core.make_episode(rng, bg, en, terms, g)
            if ep:
                out.append(ep); k += 1
    return out


def evaluate(eps, tool, hun, by_source=False):
    sc = {"all": core.Scorer(hun)}
    for ep in eps:
        base = core.simulate(ep, None)
        res = core.simulate(ep, tool)
        sc["all"].score(ep, base, res)
        if by_source:
            sc.setdefault(ep.source, core.Scorer(hun)).score(ep, base, res)
    return {k: v.summary() for k, v in sc.items()}


def headline(s):
    a, r = s["all"], s["runs"]
    return {"ff_per_1k": a["ff_per_1k"], "miss_rate": a["miss_rate"], "detect_rate": r["detect_rate"],
            "early_rate": r["early_rate"], "keys_to_detect": r["mean_keys_to_detect"],
            "episode_exact": s["episodes"]["exact"]}


def latency(model):
    m = model.cpu()
    torch.set_num_threads(1)
    x = torch.tensor([[5]])
    h = None
    with torch.no_grad():
        for _ in range(50):
            _, h = m(x, h)
        t = time.perf_counter()
        for _ in range(2000):
            _, h = m(x, h)
    return (time.perf_counter() - t) / 2000 * 1000


def main(n_val=3000, n_test=8000):
    t0 = time.time()
    dic, freq, hun = baselines.load_dicts()
    val = episodes([("train", "leipzig"), ("train", "subs")], TERMS_VAL, n_val, seed=7)
    test = episodes([("test", "leipzig"), ("test", "subs"), ("test", "tatoeba")], TERMS_TEST, n_test, seed=11)
    print(f"episodes ready {time.time()-t0:.0f}s", flush=True)
    tools = [baselines.DictBaseline(dic, freq), baselines.DictBaseline(dic, freq, use_freq=True),
             baselines.DictBaseline(dic, freq, prefix_min=3),
             baselines.DictBaseline(dic, freq, use_freq=True, prefix_min=3)]
    results = {"val": {}, "test": {}, "test_full": {}}
    for tool in tools:
        results["val"][tool.name] = headline(evaluate(val, tool, hun)["all"])
        full = evaluate(test, tool, hun, by_source=True)
        results["test_full"][tool.name] = full
        results["test"][tool.name] = headline(full["all"])
        print(tool.name, results["test"][tool.name], flush=True)

    model = M.load()
    pv = {id(ep): p for ep, p in zip(val, M.predict(model, val))}
    pt = {id(ep): p for ep, p in zip(test, M.predict(model, test))}
    print(f"model probs ready {time.time()-t0:.0f}s", flush=True)

    # threshold grid on the validation set (train sources, never the test set)
    veto = baselines.DictBaseline(dic, freq)
    grid = []
    for te, tm, n, vt in itertools.product([0.5, 0.7, 0.8, 0.9, 0.95, 0.98, 0.99, 0.995, 0.998],
                                           [0.9, 0.97, 0.99, 0.995, 0.999, 2.0], [3, 4], [None, 0.99, 0.999, 2.0, -0.99, -0.999]):
        if tm == 2.0 and n != 3:
            continue
        tool = M.ModelTool(pv, te, tm, n, veto=veto if vt else None, veto_theta=abs(vt or 0), strict=bool(vt and vt < 0))
        h = headline(evaluate(val, tool, hun)["all"])
        grid.append(((te, tm, n, vt), h))
    results["val_grid"] = [{"te": a, "tm": b, "n": c, "vt": v, **h} for (a, b, c, v), h in grid]
    best_ff = min(v["ff_per_1k"] for v in results["val"].values())
    safe = lambda g: g[1]["ff_per_1k"] <= best_ff
    plain = lambda g: g[0][3] is None
    picks = {
        # pure model, as safe as the safest baseline (on val), then fewest misses
        "model-safe": min(filter(lambda g: safe(g) and plain(g), grid), key=lambda g: g[1]["miss_rate"]),
        "model-balanced": max(filter(plain, grid), key=lambda g: g[1]["episode_exact"]),
        # hybrid: model decides, dictionary vetoes when the typed word is valid as-is
        "hybrid-safe": min(filter(lambda g: safe(g) and not plain(g), grid), key=lambda g: g[1]["miss_rate"]),
        "hybrid-balanced": max(filter(lambda g: not plain(g), grid), key=lambda g: g[1]["episode_exact"]),
    }
    results["picks"] = {k: dict(zip(("te", "tm", "n", "vt"), v[0])) for k, v in picks.items()}
    for name, ((te, tm, n, vt), h) in picks.items():
        tool = M.ModelTool(pt, te, tm, n, name=name, veto=veto if vt else None, veto_theta=abs(vt or 0), strict=bool(vt and vt < 0))
        full = evaluate(test, tool, hun, by_source=True)
        results["test_full"][name] = full
        results["test"][name] = headline(full["all"])
        results["val"][name] = dict(h)
        print(name, (te, tm, n, vt), results["test"][name], flush=True)
    # diagnostic only (uses test labels, NOT used for picking): model curve on test
    curve = []
    for te, vt in itertools.product([0.5, 0.8, 0.9, 0.95, 0.98, 0.99, 0.995, 0.998, 0.999], [None, 0.999, -0.99]):
        tool = M.ModelTool(pt, te, 2.0, 3, veto=veto if vt else None, veto_theta=abs(vt or 0), strict=bool(vt and vt < 0))
        curve.append({"te": te, "vt": vt, **headline(evaluate(test, tool, hun)["all"])})
    results["test_curve_diagnostic"] = curve
    results["model"] = {"params": sum(p.numel() for p in model.parameters()),
                        "ms_per_key_cpu_1thread": latency(model)}
    json.dump(results, open(OUT / "stage1.json", "w"), indent=1, default=float)
    print("done", time.time() - t0)


if __name__ == "__main__":
    main(**{k: int(v) for k, v in (a.split("=") for a in sys.argv[1:])})

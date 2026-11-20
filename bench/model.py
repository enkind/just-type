"""Micro-model: causal char-level GRU over the raw keystroke stream (layout independent).
Per keystroke it outputs P(intended layout = BG). The tool compares that with the active
layout and fires when P(wrong) crosses a threshold."""
from __future__ import annotations

import pickle
import random
import sys
import time
from multiprocessing import Pool
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

import core
from core import BG, EN, SPACE_ID, VOCAB, Tool

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"


class KeyGRU(nn.Module):
    def __init__(self, emb=64, hid=384, layers=2):
        super().__init__()
        self.emb = nn.Embedding(VOCAB + 1, emb)  # +1 = padding / BOS
        self.rnn = nn.GRU(emb, hid, layers, batch_first=True)
        self.out = nn.Linear(hid, 1)

    def forward(self, x, h=None):
        y, h = self.rnn(self.emb(x), h)
        return self.out(y).squeeze(-1), h


# ------------------------------------------------------------ data generation
_G = {}


def _init(split_groups, terms, seed, banned=None):
    d = pickle.load(open(DATA / "splits.pkl", "rb"))
    _G["groups"] = [d[s][g] for s, g in split_groups]
    _G["terms"] = terms
    _G["banned"] = banned


def _gen(args):
    seed, n = args
    rng = random.Random(seed)
    keys, labs, offs = [], [], [0]
    groups = _G["groups"]
    while len(offs) <= n:
        bg, en = rng.choice(groups)
        ep = core.make_episode(rng, bg, en, _G["terms"], "", banned=_G["banned"])
        if ep is None:
            continue
        keys.extend(ep.keys)
        labs.extend(ep.intended)
        offs.append(len(keys))
    return np.array(keys, np.uint8), np.array(labs, np.uint8), np.array(offs, np.int64)


def make_dataset(n, split_groups, terms, seed, procs=8, banned=None):
    chunks = [(seed * 1000 + i, n // procs) for i in range(procs)]
    with Pool(procs, _init, (split_groups, terms, seed, banned)) as p:
        parts = p.map(_gen, chunks)
    K, L, O = [], [], [0]
    for k, l, o in parts:
        base = O[-1]
        K.append(k); L.append(l); O.extend((o[1:] + base).tolist())
    return np.concatenate(K), np.concatenate(L), np.array(O)


def batches(K, L, O, bs, rng):
    idx = list(range(len(O) - 1))
    rng.shuffle(idx)
    # bucket by length for less padding
    for c in range(0, len(idx), bs * 50):
        chunk = sorted(idx[c:c + bs * 50], key=lambda i: O[i + 1] - O[i])
        bl = [chunk[j:j + bs] for j in range(0, len(chunk), bs)]
        rng.shuffle(bl)
        for b in bl:
            yield _pad(K, L, O, b)


def _pad(K, L, O, b):
    T = max(O[i + 1] - O[i] for i in b)
    x = np.full((len(b), T), VOCAB, np.int64)
    y = np.zeros((len(b), T), np.float32)
    m = np.zeros((len(b), T), np.float32)
    for r, i in enumerate(b):
        s, e = O[i], O[i + 1]
        x[r, : e - s] = K[s:e]; y[r, : e - s] = L[s:e]; m[r, : e - s] = 1
    return torch.from_numpy(x), torch.from_numpy(y), torch.from_numpy(m)


def train(n_train=1_200_000, steps=None, bs=256, hid=384, out="model.pt", dev=None):
    from data import TERMS_FIT, BANNED
    dev = dev or ("mps" if torch.backends.mps.is_available() else "cpu")
    t0 = time.time()
    groups = [("train", "leipzig"), ("train", "subs"), ("train", "subs")]
    K, L, O = make_dataset(n_train, groups, TERMS_FIT, seed=1, banned=BANNED)
    print(f"dataset: {len(O)-1} episodes, {len(K)} keys, {time.time()-t0:.0f}s", flush=True)
    model = KeyGRU(hid=hid).to(dev)
    print("params", sum(p.numel() for p in model.parameters()), flush=True)
    total = steps or (len(O) - 1) // bs
    opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=0.01)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=2e-3, total_steps=total, pct_start=0.05)
    lossf = nn.BCEWithLogitsLoss(reduction="none")
    rng = random.Random(0)
    step, t0, run = 0, time.time(), 0.0
    model.train()
    while step < total:
        for x, y, m in batches(K, L, O, bs, rng):
            x, y, m = x.to(dev), y.to(dev), m.to(dev)
            logit, _ = model(x)
            loss = (lossf(logit, y) * m).sum() / m.sum()
            opt.zero_grad()
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step(); sched.step()
            run = 0.98 * run + 0.02 * loss.item() if step else loss.item()
            step += 1
            if step % 200 == 0:
                print(f"step {step}/{total} loss {run:.4f} {time.time()-t0:.0f}s", flush=True)
            if step >= total:
                break
    torch.save({"state": model.state_dict(), "hid": hid}, ROOT / "bench" / out)
    return model


def load(path="model.pt", dev="cpu"):
    ck = torch.load(ROOT / "bench" / path, map_location=dev)
    m = KeyGRU(hid=ck["hid"]).to(dev)
    m.load_state_dict(ck["state"])
    m.eval()
    return m


@torch.no_grad()
def predict(model, eps, bs=512, dev="cpu"):
    """P(BG) per key for each episode (keys are tool-independent, so one pass suffices)."""
    K = np.array([k for ep in eps for k in ep.keys], np.uint8)
    L = np.zeros_like(K)
    O = np.cumsum([0] + [len(ep.keys) for ep in eps])
    out = [None] * len(eps)
    order = sorted(range(len(eps)), key=lambda i: len(eps[i].keys))
    for c in range(0, len(order), bs):
        b = order[c:c + bs]
        x, _, _ = _pad(K, L, O, b)
        p = torch.sigmoid(model(x.to(dev))[0]).cpu().numpy()
        for r, i in enumerate(b):
            out[i] = p[r, : len(eps[i].keys)]
    return out


class ModelTool(Tool):
    def __init__(self, probs, theta_end=0.5, theta_mid=0.95, nmin=3, name=None, veto=None, veto_theta=0.999, strict=False):
        self.probs = probs  # dict id(ep) -> array
        self.strict = strict
        self.veto, self.vt = veto, veto_theta  # DictBaseline used to veto: typed word valid -> need vt
        self.te, self.tm, self.nmin = theta_end, theta_mid, nmin
        self.name = name or f"model(te={theta_end},tm={theta_mid},n={nmin})"

    def start(self, ep):
        self.p = self.probs[id(ep)]

    def on_key(self, i, key, active, tok_keys, tok_lays, boundary):
        pb = float(self.p[min(i, len(self.p) - 1)])
        pw = pb if active == EN else 1 - pb
        if boundary:
            if pw < self.te:
                return False
            if self.veto is not None:
                import baselines
                t = baselines._strip.sub("", core.render(tok_keys, tok_lays))
                if self.veto.valid(t, active):
                    if pw < self.vt:
                        return False
                    if self.strict:
                        c = baselines._strip.sub("", core.render_one(tok_keys, 1 - active))
                        if not self.veto.valid(c, 1 - active):
                            return False
            return True
        n = sum(1 for k in tok_keys if not core.NEUTRAL[k])
        return n >= self.nmin and pw >= self.tm


if __name__ == "__main__":
    kw = dict(a.split("=") for a in sys.argv[1:])
    train(**{k: (int(v) if v.isdigit() else v) for k, v in kw.items()})

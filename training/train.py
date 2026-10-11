"""Train Frame guide's framing scorer from embedded examples (numpy only).

    python3 train.py <cache dir> <out FrameScorer.json>

A small MLP (768 -> 32 -> 1) on Vision feature prints, trained so each
real framing outscores its shifted alternatives (pairwise logistic loss).
Writes the JSON only if held-out pair accuracy beats chance clearly.
Exit code 0 = new model written, 3 = not enough data / not good enough.
"""
import glob, json, os, sys, datetime
import numpy as np

MIN_SAMPLES = 30

def load(cache):
    groups = []
    for f in sorted(glob.glob(os.path.join(cache, "*.emb.json"))):
        d = json.load(open(f))
        sid = os.path.basename(f)
        for p, ns in zip(d["pos"], d["neg"]):
            groups.append((sid, np.asarray(p, np.float32), np.asarray(ns, np.float32), d.get("kind", "shot")))
    return groups

def main(cache, out):
    groups = load(cache)
    ids = sorted({g[0] for g in groups})
    print(f"{len(ids)} samples, {len(groups)} groups")
    if len(ids) < MIN_SAMPLES:
        print(f"need {MIN_SAMPLES}+ samples to train"); return 3
    rng = np.random.default_rng(0)
    val_ids = set(rng.choice(ids, size=max(3, len(ids) // 5), replace=False))
    def pairs(sel):
        P, N, W = [], [], []
        for sid, p, ns, kind in groups:
            if (sid in val_ids) != sel: continue
            w = 2.0 if kind == "guided" else 1.0      # guided shots are the clearest signal
            for n in ns: P.append(p); N.append(n); W.append(w)
        return np.array(P), np.array(N), np.array(W, np.float32)
    Ptr, Ntr, Wtr = pairs(False); Pva, Nva, _ = pairs(True)
    X = np.concatenate([Ptr, Ntr])
    mean, std = X.mean(0), X.std(0) + 1e-6
    z = lambda a: (a - mean) / std
    Ptr, Ntr, Pva, Nva = z(Ptr), z(Ntr), z(Pva), z(Nva)

    D, H = Ptr.shape[1], 32
    w1 = rng.normal(0, 1 / np.sqrt(D), (H, D)).astype(np.float32); b1 = np.zeros(H, np.float32)
    w2 = rng.normal(0, 1 / np.sqrt(H), H).astype(np.float32); b2 = np.float32(0)
    params = [w1, b1, w2]
    m = [np.zeros_like(p) for p in params]; v = [np.zeros_like(p) for p in params]
    lr, l2, steps, bs = 3e-3, 1e-3, 1500, 256

    def fwd(x):
        a = x @ w1.T + b1; h = np.maximum(a, 0); return h @ w2 + b2, a, h
    def acc(P, N):
        return float((fwd(P)[0] > fwd(N)[0]).mean()) if len(P) else 0.0

    for t in range(1, steps + 1):
        idx = rng.integers(0, len(Ptr), min(bs, len(Ptr)))
        sp, ap, hp = fwd(Ptr[idx]); sn, an, hn = fwd(Ntr[idx]); wt = Wtr[idx]
        d = sp - sn
        g = -wt / (1 + np.exp(np.clip(d, -30, 30))) / len(idx)       # dLoss/d(d), loss = log(1+e^-d)
        gw2 = g @ hp - g @ hn + l2 * w2
        gp = np.outer(g, w2) * (ap > 0); gn = -np.outer(g, w2) * (an > 0)
        gw1 = gp.T @ Ptr[idx] + gn.T @ Ntr[idx] + l2 * w1
        gb1 = gp.sum(0) + gn.sum(0)
        for i, gr in enumerate([gw1, gb1, gw2]):
            m[i] = 0.9 * m[i] + 0.1 * gr; v[i] = 0.999 * v[i] + 0.001 * gr * gr
            params[i] -= lr * (m[i] / (1 - 0.9 ** t)) / (np.sqrt(v[i] / (1 - 0.999 ** t)) + 1e-8)
        if t % 500 == 0:
            print(f"step {t}: train {acc(Ptr, Ntr):.3f}  held-out {acc(Pva, Nva):.3f}")

    va = acc(Pva, Nva)
    if va < 0.6:
        print(f"held-out accuracy {va:.3f} < 0.60 — not shipping"); return 3
    json.dump({
        "version": 1, "trainedAt": datetime.datetime.now().isoformat(timespec="seconds"),
        "samples": len(ids), "accuracy": round(va, 4),
        "mean": mean.round(5).tolist(), "std": std.round(5).tolist(),
        "w1": w1.round(5).tolist(), "b1": b1.round(5).tolist(),
        "w2": w2.round(5).tolist(), "b2": float(b2),
    }, open(out, "w"))
    print(f"wrote {out} (held-out {va:.3f})"); return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))

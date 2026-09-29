"""Vocal-presence mask from the (already separated) vocal stem. The stem is used ONLY as a vocal DETECTOR,
never as ASR input. No absolute dB threshold: the song's own noise floor and vocal level are estimated from
its energy distribution (Otsu split of the log-RMS histogram) and every decision is RELATIVE to them.

Per transcription window we measure
  active_ratio   fraction of frames above the adaptive threshold (after hysteresis + gap closing)
  longest_run_s  longest sustained active run (seconds)
  level_db       median level of the active frames above the song's noise floor
and classify VOCAL / NON_VOCAL / UNCERTAIN (weak evidence stays UNCERTAIN)."""
import numpy as np

SR, FRAME, HOP = 16000, 400, 160          # 25 ms frames, 10 ms hop
CFG = {
    "hyst_down_db": 3.0,                  # hysteresis: stay active until level < T - 3 dB
    "close_gap_s": 0.25,                  # bridge silences shorter than this (breaths, consonants)
    "min_run_s": 0.15,                    # drop blips shorter than this
    "vocal_min_ratio": 0.20, "vocal_min_run_s": 1.0, "vocal_min_level_db": 10.0,
    "nonvocal_max_ratio": 0.04, "nonvocal_weak_ratio": 0.10, "nonvocal_weak_run_s": 0.5,
}


def frame_db(x):
    n = 1 + (len(x) - FRAME) // HOP
    out = np.empty(n, dtype=np.float32)
    for s in range(0, n, 4096):                                   # chunked to keep memory small
        e = min(n, s + 4096)
        idx = np.arange(FRAME)[None, :] + HOP * np.arange(s, e)[:, None]
        out[s:e] = 20 * np.log10(np.sqrt((x[idx] ** 2).mean(1)) + 1e-9)
    return out


def otsu(values, bins=120):
    hist, edges = np.histogram(values, bins=bins)
    p = hist / hist.sum(); centers = (edges[:-1] + edges[1:]) / 2
    w0 = np.cumsum(p); w1 = 1 - w0
    m0 = np.cumsum(p * centers) / np.maximum(w0, 1e-12); mt = (p * centers).sum()
    m1 = (mt - np.cumsum(p * centers)) / np.maximum(w1, 1e-12)
    var = w0 * w1 * (m0 - m1) ** 2
    return float(centers[int(np.argmax(var))])


def _smooth(db, k=7):
    pad = k // 2
    d = np.pad(db, pad, mode="edge")
    return np.array([np.median(d[i:i + k]) for i in range(len(db))], dtype=np.float32) if len(db) < 3000 else \
        np.median(np.lib.stride_tricks.sliding_window_view(d, k), axis=1).astype(np.float32)


def analyse(x, cfg=CFG):
    """-> dict(db, active(bool per frame), T, noise_db, vocal_db)"""
    db = _smooth(frame_db(x))
    valid = db[db > -75]
    T = otsu(valid)
    noise = float(np.median(valid[valid <= T])); vocal = float(np.median(valid[valid > T]))
    active = np.zeros(len(db), dtype=bool); on = False
    for i, v in enumerate(db):                                   # hysteresis
        if not on and v > T: on = True
        elif on and v < T - cfg["hyst_down_db"]: on = False
        active[i] = on
    fps = SR / HOP
    active = _close_gaps(active, int(cfg["close_gap_s"] * fps))
    active = _drop_short(active, int(cfg["min_run_s"] * fps))
    return {"db": db, "active": active, "T": T, "noise_db": noise, "vocal_db": vocal, "fps": fps}


def _runs(a):
    edges = np.diff(np.concatenate([[0], a.astype(np.int8), [0]]))
    return list(zip(np.where(edges == 1)[0], np.where(edges == -1)[0]))


def _close_gaps(a, n):
    a = a.copy(); runs = _runs(a)
    for (s0, e0), (s1, e1) in zip(runs, runs[1:]):
        if s1 - e0 <= n: a[e0:s1] = True
    return a


def _drop_short(a, n):
    a = a.copy()
    for s, e in _runs(a):
        if e - s < n: a[s:e] = False
    return a


def segments(an):
    return [(s / an["fps"], e / an["fps"]) for s, e in _runs(an["active"])]


def classify_window(an, t0, t1, cfg=CFG):
    fps = an["fps"]; a = an["active"][int(t0 * fps):int(t1 * fps)]; db = an["db"][int(t0 * fps):int(t1 * fps)]
    if len(a) == 0: return {"state": "NON_VOCAL", "active_ratio": 0.0, "longest_run_s": 0.0, "level_db": 0.0}
    ratio = float(a.mean())
    runs = _runs(a); longest = max([(e - s) / fps for s, e in runs], default=0.0)
    level = float(np.median(db[a]) - an["noise_db"]) if a.any() else 0.0
    if ratio >= cfg["vocal_min_ratio"] and longest >= cfg["vocal_min_run_s"] and level >= cfg["vocal_min_level_db"]:
        state = "VOCAL"
    elif ratio < cfg["nonvocal_max_ratio"] or (ratio < cfg["nonvocal_weak_ratio"] and longest < cfg["nonvocal_weak_run_s"]):
        state = "NON_VOCAL"
    else:
        state = "UNCERTAIN"
    return {"state": state, "active_ratio": round(ratio, 3), "longest_run_s": round(float(longest), 2), "level_db": round(level, 1)}

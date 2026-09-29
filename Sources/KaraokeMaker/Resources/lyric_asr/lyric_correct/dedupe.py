"""Overlap de-duplication — VERBATIM copy of the logic in ~/qwen3_asr_intel_test/assemble.py (same thresholds, same
fuzzy word equality). Deliberately NOT improved: the goal is comparing correction logic, not assemblers."""
import unicodedata

MAXK = 12

def base(s):
    s = s.replace("đ", "d")
    return "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")

def lev(a, b):
    d = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        p, d[0] = d[0], i
        for j, cb in enumerate(b, 1):
            p, d[j] = d[j], min(d[j] + 1, d[j-1] + 1, p + (ca != cb))
    return d[-1]

def feq(a, b):                                   # fuzzy word equality: same word, same letters w/o tones, or 1 letter apart (len>=3)
    if a == b: return True
    ba, bb = base(a), base(b)
    return ba == bb or (min(len(ba), len(bb)) >= 3 and lev(ba, bb) <= 1)

def lcs_count(a, b):
    dp = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            dp[i][j] = max(dp[i-1][j], dp[i][j-1], dp[i-1][j-1] + (1 if feq(a[i-1], b[j-1]) else 0))
    return dp[-1][-1]

def dedupe_join(prev, nxt):
    """prev/nxt: token lists. Compare END of prev with START of nxt; remove duplicated words from the START of nxt.
    Returns (tokens_to_append, log_entry)."""
    best = None
    for kp in range(1, min(MAXK, len(prev)) + 1):
        for kn in range(1, min(MAXK, len(nxt)) + 1):
            m = lcs_count(prev[-kp:], nxt[:kn])
            if m < 1: continue
            ratio = 2 * m / (kp + kn)
            score = 2 * m - (kp - m) - (kn - m)
            key = (score, -(kp + kn))
            if best is None or key > best[0]: best = (key, kp, kn, m, ratio)
    if best is None:
        return nxt, {"decision": "NO-MATCH keep all", "flag": True, "removed": [], "prev_tail": prev[-6:], "next_head": nxt[:6]}
    _, kp, kn, m, ratio = best
    entry = {"kp": kp, "kn": kn, "matched": m, "ratio": round(ratio, 2), "prev_tail": prev[-kp:], "next_head": nxt[:kn]}
    if m >= 2 and ratio >= 0.7 and kn <= 8:
        entry.update(decision="REMOVED from next", removed=nxt[:kn], flag=False)
        return nxt[kn:], entry
    entry.update(decision="UNCERTAIN keep all (possible duplicate)", removed=[], flag=True)
    return nxt, entry


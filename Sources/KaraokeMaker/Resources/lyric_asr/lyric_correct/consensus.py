"""Repeated-section discovery from ASR text ONLY (no reference lyrics, no time/lyric lookup).

Songs repeat choruses. We find repeated passages inside the transcript with a Smith-Waterman self-alignment
scored by Vietnamese phonetic similarity, iterating to extract several non-overlapping repeats, then group
corresponding word positions (union-find) into 'classes' = the same lyric word heard in several places."""
import viet

CFG = {"min_gap": 4, "min_score": 8.0, "min_pairs": 5, "min_ident": 0.55, "max_iter": 90,
       "exact": 2.0, "near": 1.0, "mismatch": -1.5, "gap": -1.5, "near_sim": 0.66,
       "local_win": 3, "local_min_neighbours": 3, "local_min_match_frac": 0.6, "local_near_sim": 0.85, "class_min_gap": 8}


def find_repeats(toks, cfg=CFG):
    n = len(toks)
    sc = [[0.0] * n for _ in range(n)]
    for i in range(n):
        for j in range(i + 1, n):
            if toks[i] == toks[j]: v = cfg["exact"]
            else: v = cfg["near"] if viet.similarity(toks[i], toks[j]) >= cfg["near_sim"] else cfg["mismatch"]
            sc[i][j] = v
    used, results = set(), []
    for _ in range(cfg["max_iter"]):
        H = [[0.0] * (n + 1) for _ in range(n + 1)]
        best, bpos = 0.0, None
        for i in range(1, n + 1):
            Hi, Hp, sci = H[i], H[i - 1], sc[i - 1]
            for j in range(i + cfg["min_gap"], n + 1):
                if (i - 1, j - 1) in used:
                    continue
                h = max(0.0, Hp[j - 1] + sci[j - 1], Hp[j] + cfg["gap"], Hi[j - 1] + cfg["gap"])
                Hi[j] = h
                if h > best: best, bpos = h, (i, j)
        if best < cfg["min_score"]:
            break
        i, j = bpos; pairs = []
        while i > 0 and j > 0 and H[i][j] > 0:
            h = H[i][j]
            if (i - 1, j - 1) not in used and abs(h - (H[i - 1][j - 1] + sc[i - 1][j - 1])) < 1e-9:
                pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            elif abs(h - (H[i - 1][j] + cfg["gap"])) < 1e-9: i -= 1
            else: j -= 1
        pairs.reverse()
        for p in pairs: used.add(p)
        if len(pairs) >= cfg["min_pairs"]:
            ident = sum(1 for a, b in pairs if toks[a] == toks[b]) / len(pairs)
            if ident >= cfg["min_ident"]:
                results.append({"pairs": pairs, "ident": round(ident, 2), "score": round(best, 1)})
    return results


def _confident_pairs(pairs, toks, cfg=CFG):
    """A long local alignment can drift across different lyrics (verse vs chorus). Only trust a pair whose immediate
    neighbours (contiguous in BOTH occurrences, within +-win words) mostly match (exactly, or a very close phonetic variant >= local_near_sim): high LOCAL alignment confidence."""
    W = cfg["local_win"]; keep = []
    for p, (a, b) in enumerate(pairs):
        if not (toks[a] == toks[b] or viet.similarity(toks[a], toks[b]) >= cfg["near_sim"]):
            continue
        nb = [(a2, b2) for (a2, b2) in pairs[max(0, p - W):p + W + 1] if (a2, b2) != (a, b) and abs(a2 - a) <= W and abs(b2 - b) <= W and a2 - a == b2 - b]
        if len(nb) >= cfg["local_min_neighbours"] and sum(1 for a2, b2 in nb if toks[a2] == toks[b2] or viet.similarity(toks[a2], toks[b2]) >= cfg["local_near_sim"]) / len(nb) >= cfg["local_min_match_frac"]:
            keep.append((a, b))
    return keep


def classes(results, toks, cfg=CFG):
    """Union-find over corresponding positions (only pairs that are at least phonetically near)."""
    parent = {}
    def find(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]; x = parent[x]
        return x
    members = {}
    for r in results:
        for a, b in _confident_pairs(r["pairs"], toks, cfg):
            ra, rb = find(a), find(b)
            if ra != rb:
                ma, mb = members.setdefault(ra, {ra}), members.setdefault(rb, {rb})
                if min(abs(x - y) for x in ma for y in mb) < cfg["class_min_gap"]:
                    continue                                   # cannot-link: two words of the SAME phrase are not 'the same word heard twice'
                parent[rb] = ra; members[ra] = ma | mb; members.pop(rb, None)
    groups = {}
    for x in list(parent):
        groups.setdefault(find(x), []).append(x)
    out = []
    for g in groups.values():
        g = sorted(g)
        if 2 <= len(g) <= 8 and all(b - a >= cfg["min_gap"] for a, b in zip(g, g[1:])):
            out.append(g)
    return out

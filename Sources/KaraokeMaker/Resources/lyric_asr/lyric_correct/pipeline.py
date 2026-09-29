"""Vietnamese lyric CORRECTION pipeline (app version). Everything except the ASR calls is plain portable Python.

FULL MIX --0.6B--> hypothesis --vocal mask--> (VOCAL only) 1.7B --> phonetic 0.6B<->1.7B alignment -->
repeat evidence (SUPPORTING only) --> evidence scoring --> context re-check (ONLY spans that are still uncertain) -->
FINAL draft. Unresolved words keep the best ORIGINAL hypothesis and are flagged 'uncertain' with alternatives;
nothing is silently replaced by a 'nicer' Vietnamese word.

Safety rules (from the integration brief, on top of the validated prototype):
  * context can never override a span that non-context evidence already decided; conflicts are ignored + logged
  * repeat consensus is only a supporting vote (its total can never beat two agreeing models, and a
    consensus-only word can never become confident by itself)
  * a word only the 1.7B heard is KEPT as an uncertain 'possible missing word' when the region is VOCAL and both
    neighbours are strongly aligned; it is never promoted to confident without extra evidence
  * instrumental (NON_VOCAL) windows always give an EMPTY lexical output; humming is stored separately."""
import collections
import json
import re

import align as AL
import consensus as CS
import dedupe as DD
import viet

CONFIG = {
    # ---- evidence weights (bigger = stronger evidence for a word in a column) ----
    "w_both_agree": 2.5,       # 0.6B and 1.7B produce the same word                      -> very strong
    "w_m06": 1.1,              # 0.6B only / 0.6B side of a disagreement (primary engine)   -> moderate
    "w_m17": 1.0,              # 1.7B only / 1.7B side of a disagreement (verifier)         -> moderate, slightly lower
    "w_gap": 0.6,              # 'the other model heard nothing here'                       -> weak
    # repeat consensus = SUPPORTING evidence only
    "w_cons_pair": 0.7,        # the ONLY other occurrence says it (class of 2: no majority possible)
    "w_cons_split": 0.3,       # some other occurrences say it but not a strict majority
    "w_cons_each": 0.75,       # strict majority of >=2 other occurrences: 0.75 per supporter ...
    "w_cons_cap": 1.5,         # ... capped at 1.5  (< both_agree 2.5: repetition cannot override two agreeing models)
    "cons_only_factor": 0.5,   # a word that NO model produced in this column counts half (can never win alone)
    "cons_min_sim": 0.55,      # a consensus word must be phonetically this close to what was heard
    # context re-transcription (only consulted for spans that are ALREADY uncertain)
    "w_ctx_supported": 1.5,    # context word that an original hypothesis also supports
    "w_ctx_unsupported": 0.5,  # context word that no original hypothesis supports
    "ctx_min_uncertain": 2, "ctx_prev_words": 12, "ctx_prev_min": 4, "ctx_repeat_words": 30,
    "ctx_min_sim": 0.60, "ctx_drift_max": 0.35,
    # supporting phonetic / neighbour evidence
    "w_phon": 0.8, "w_bigram": 0.6,
    # decision thresholds
    "min_score": 1.5, "min_margin": 1.0,
    # words only the 1.7B heard -> uncertain 'possible missing word' candidates (VOCAL windows, strong neighbours)
    "only17_max_run": 2, "only17_min_flank_sim": 0.66,
    # UNCERTAIN-mask chunks are accepted only if BOTH models independently transcribe the same words
    "unc_min_agree": 0.6, "unc_min_words": 3,
    # local candidate generation (from the SAME song's own confident ASR vocabulary; never wins alone)
    "vocab_min_sim": 0.85, "vocab_max": 3,
}
GAP = "∅"
HUM = re.compile(r"^(h+m+|m{2,}|ư+m+|ừ+m+|hừm+|ừm+)$")
tokens = AL.tokens
_BRK = re.compile(r"[,.;!?…]+")


def tokens_brk(text):
    """Same tokens as `tokens`, plus a flag per token: was it followed by , . ; ! ? (a phrase boundary the ASR heard)."""
    import unicodedata
    s = unicodedata.normalize("NFC", text.lower())
    s = _BRK.sub(" | ", s)
    s = re.sub(r"[^\w\s|]", " ", s).replace("_", " ")
    toks, brk = [], []
    for t in s.split():
        if t == "|":
            if brk: brk[-1] = True
        else:
            toks.append(t); brk.append(False)
    return toks, brk


class MissingASR(Exception):
    """Raised by a replay backend when a cached ASR result is not available."""


# ----------------------------------------------------------------------------------------------
# Stage 1: per-chunk columns (0.6B <-> 1.7B phonetic alignment, vocal-mask gating)
# ----------------------------------------------------------------------------------------------
def build_chunk(win, mask, r06, r17, cfg=CONFIG):
    st = mask["state"]
    ch = {"i": win["i"], "start": win["start"], "end": win["end"], "mask": mask, "state": st,
          "text06": r06 and r06["text"], "text17": r17 and r17["text"],
          "cap_hit06": bool(r06 and r06.get("cap_hit")), "cap_hit17": bool(r17 and r17.get("cap_hit")),
          "cols": [], "mode": None, "note": "", "hum": []}
    a, abrk = tokens_brk(r06["text"]) if r06 else ([], [])
    b, bbrk = tokens_brk(r17["text"]) if (r17 and st != "NON_VOCAL") else ([], [])
    if st == "NON_VOCAL":                                       # instrumental: lexical output is ALWAYS empty (1.7B never ran here)
        ch["mode"] = "EMPTY_NON_VOCAL"
        ch["note"] = f"mask NON_VOCAL -> output empty (0.6B had said {ch['text06']!r})" if a else "mask NON_VOCAL -> output empty"
        return ch
    if not a and not b:
        ch["mode"] = "EMPTY_NO_TEXT"; return ch
    if a and all(viet.is_nonlexical(t) for t in a) and (not b or all(viet.is_nonlexical(t) for t in b)):
        ch["mode"] = "NON_LEXICAL_VOCAL"; ch["note"] = "humming / non-lexical vocalisation, stored separately"; return ch
    ops = AL.align(a, b) if b else [("ONLY_A", i, None, 0.0) for i in range(len(a))]
    accepted_unc = False
    if st == "UNCERTAIN":                                      # extra evidence needed: both models must confirm the same words
        agree = sum(1 for o in ops if o[0] in ("AGREE", "MINOR_VARIANT"))
        if not (b and len(a) >= cfg["unc_min_words"] and len(b) >= cfg["unc_min_words"] and agree / max(1, len(ops)) >= cfg["unc_min_agree"]):
            ch["mode"] = "REJECTED_UNCERTAIN"
            ch["note"] = "weak vocal evidence and the two models do not confirm the same words -> nothing accepted"; return ch
        accepted_unc = True
        ch["note"] = f"UNCERTAIN mask accepted: both models agree on {agree}/{len(ops)} aligned words (1.7B may not add words here)"
    cols = []
    for cls, i, j, s in ops:
        if not b: cls = "ONLY_A"
        col = {"chunk": win["i"], "w06": a[i] if i is not None else None, "w17": b[j] if j is not None else None, "cls": cls, "sim": s,
               "cons": [], "ctx": [], "log": [], "final": None, "conf": None, "alts": [], "scores": {}, "solo06": not b,
               "kind": "word", "ctx_decision": "none",
               "brk": bool((i is not None and abrk[i]) or (j is not None and bbrk[j]))}
        if cls == "ONLY_A" and col["w06"] and HUM.match(col["w06"]):
            ch["hum"].append(col["w06"]); continue
        if accepted_unc and cls == "ONLY_B":
            col["forced_gap"] = True; col["log"].append("1.7B-only word in an UNCERTAIN-mask chunk -> not allowed")
        cols.append(col)
    _classify_only17(cols, st, cfg)
    for c in cols:                                              # first-pass token (models only): 0.6B is the primary engine
        if c.get("forced_gap") and c["cls"] == "ONLY_B": c["prelim"] = None
        elif c["cls"] == "ONLY_B": c["prelim"] = c["w17"]
        else: c["prelim"] = c["w06"]
    ch["cols"] = cols; ch["mode"] = "LEXICAL"
    return ch


def _classify_only17(cols, state, cfg):
    """Words only the 1.7B produced. Keep them as UNCERTAIN 'possible missing word' candidates when the region is
    definitely VOCAL, the run is short, BOTH neighbours are strongly aligned and the word is a plausible syllable
    that does not merely repeat a neighbour. Otherwise reject (logged)."""
    k = 0
    while k < len(cols):
        if cols[k]["cls"] == "ONLY_B" and not cols[k].get("forced_gap"):
            e = k
            while e < len(cols) and cols[e]["cls"] == "ONLY_B": e += 1
            run = e - k
            L = cols[k - 1] if k > 0 else None
            R = cols[e] if e < len(cols) else None
            reason = None
            if state != "VOCAL": reason = "region is not definitely VOCAL"
            elif run > cfg["only17_max_run"]: reason = f"run of {run} words is too long"
            elif L is None or R is None: reason = "no neighbour on one side (chunk edge)"
            else:
                for nb, side in ((L, "left"), (R, "right")):
                    strong = nb["cls"] == "AGREE" or (nb["cls"] == "MINOR_VARIANT" and nb["sim"] >= cfg["only17_min_flank_sim"])
                    if not strong: reason = f"{side} neighbour is not strongly aligned ({nb['cls']})"; break
            if reason is None:
                for c in cols[k:e]:
                    w = c["w17"]
                    nbw = {(L["w06"] if L else None), (R["w06"] if R else None), (L["w17"] if L else None), (R["w17"] if R else None)}
                    if not viet.parse(w)["ok"] or w in nbw:
                        reason = f"{w!r} is not a plausible new syllable (invalid or repeats a neighbour)"; break
            for c in cols[k:e]:
                if reason is None:
                    c["kind"] = "possible_missing"
                    c["log"].append("1.7B-only word kept as UNCERTAIN candidate (VOCAL region, strongly aligned neighbours)")
                else:
                    c["forced_gap"] = True
                    c["log"].append(f"1.7B-only word rejected: {reason}")
            k = e
        else:
            k += 1


# ----------------------------------------------------------------------------------------------
# Stage 2: assemble columns across chunks (same overlap de-dup as the validated prototype)
# ----------------------------------------------------------------------------------------------
def assemble(chunks):
    S, acc, dedupe_log = [], [], []
    for ch in chunks:
        if ch["mode"] != "LEXICAL": continue
        cols = [c for c in ch["cols"] if c.get("prelim") is not None]
        toks = [c["prelim"] for c in cols]
        if not toks: continue
        if not acc:
            keep = cols
        else:
            add, log = DD.dedupe_join(acc, toks)
            removed = len(log["removed"]) if log["decision"].startswith("REMOVED") else 0
            log["chunk"] = ch["i"]; dedupe_log.append(log)
            for c in cols[:removed]: c["overlap_removed"] = True
            keep = cols[removed:]
        for c in keep: c["gi"] = len(S); S.append(c)
        acc += [c["prelim"] for c in keep]
    return S, dedupe_log


# ----------------------------------------------------------------------------------------------
# Stage 3: repeated-section evidence (ASR text only) — SUPPORTING evidence
# ----------------------------------------------------------------------------------------------
def repeat_consensus(S, cfg=CONFIG):
    toks = [c["prelim"] for c in S]
    reps = CS.find_repeats(toks)
    classes = CS.classes(reps, toks)
    for c in S: c["cons"] = []
    for g in classes:
        for k in g:
            others = [x for x in g if x != k]
            for word in sorted(set(toks[x] for x in others)):
                sup = sum(1 for x in others if toks[x] == word)
                if word != toks[k] and viet.similarity(word, toks[k]) < cfg["cons_min_sim"]:
                    continue                                      # too different to be the same lyric word -> not a mis-hearing
                if len(others) == 1: w = cfg["w_cons_pair"]
                elif sup >= 2 and 2 * sup > len(others): w = min(cfg["w_cons_cap"], cfg["w_cons_each"] * sup)
                else: w = cfg["w_cons_split"]
                S[k]["cons"].append((word, round(w, 3), f"{sup}/{len(others)} other occurrence(s) say it (class positions {g})"))
    return {"repeats": len(reps), "class_positions": classes}


# ----------------------------------------------------------------------------------------------
# Stage 4-6: evidence scoring
# ----------------------------------------------------------------------------------------------
def _votes(col, cfg):
    v = collections.defaultdict(list)
    cls, a, b = col["cls"], col["w06"], col["w17"]
    if cls == "AGREE": v[a].append(("both_agree", cfg["w_both_agree"]))
    elif cls in ("MINOR_VARIANT", "DISAGREE"):
        v[a].append(("m06", cfg["w_m06"])); v[b].append(("m17", cfg["w_m17"]))
    elif cls == "ONLY_A":
        v[a].append(("m06", cfg["w_m06"]))
        if not col.get("solo06"): v[GAP].append(("m17_silent", cfg["w_gap"]))
    elif cls == "ONLY_B":
        v[GAP].append(("m06_silent", cfg["w_gap"]))
        if not col.get("forced_gap"): v[b].append(("m17", cfg["w_m17"]))
    return v


def _evidence(S, k, bc, vocab, flags, cfg, with_ctx):
    col = S[k]
    ev = collections.defaultdict(list)
    for w, lst in _votes(col, cfg).items(): ev[w] += lst
    model_words = {w for w in (col["w06"], col["w17"]) if w}
    if flags["cons"]:
        for w, wt, why in col["cons"]:
            ev[w].append(("consensus", wt if w in model_words else wt * cfg["cons_only_factor"]))
    if with_ctx:
        for w, wt, why in col["ctx"]: ev[w].append((why, wt))
    hyp = [w for w in ev if w != GAP]
    if flags["vocab"] and hyp and col.get("conf_prev") != "confident":
        near = []
        for v in vocab:
            if v in ev: continue
            s = max(viet.similarity(v, h) for h in hyp)
            if s >= cfg["vocab_min_sim"]: near.append((s, v))
        for s, v in sorted(near, reverse=True)[:cfg["vocab_max"]]: ev[v] = [("vocab_candidate", 0.0)]
    words = [w for w in ev if w != GAP]
    for w in words:
        others = [o for o in hyp if o != w]
        if others: ev[w].append(("phonetic", cfg["w_phon"] * sum(viet.similarity(w, o) for o in others) / len(others)))
    L = S[k - 1]["final"] if k > 0 and S[k - 1].get("conf") == "confident" else None
    R = S[k + 1]["final"] if k + 1 < len(S) and S[k + 1].get("conf") == "confident" else None
    if flags["bigram"]:
        cons_words = {w for w, _, _ in col["cons"]} if flags["cons"] else set()
        for w in words:
            if w in cons_words: continue                      # same repetition already counted as consensus: no double counting
            own = 1 if (col.get("conf") == "confident" and col["final"] == w) else 0
            n = 0
            if L is not None: n += bc[(L, w)] - own
            if R is not None: n += bc[(w, R)] - own
            if n > 0: ev[w].append(("bigram", cfg["w_bigram"]))
    return ev


def _decide(col, ev, cfg):
    total = {w: round(sum(x[1] for x in lst), 3) for w, lst in ev.items()}
    order = sorted(total, key=lambda w: -total[w])
    best = order[0]; second = total[order[1]] if len(order) > 1 else 0.0
    margin = total[best] - second
    if col.get("forced_gap") and col["cls"] == "ONLY_B":
        return None, "confident", total, order, margin
    if total[best] >= cfg["min_score"] and margin >= cfg["min_margin"]:
        return (None if best == GAP else best), "confident", total, order, margin
    cand = [w for w in (col["w06"], col["w17"]) if w is not None and w in total]      # keep the best ORIGINAL hypothesis, flag it
    final = max(cand, key=lambda w: (total[w], w == col["w06"])) if cand else None
    return final, "uncertain", total, order, margin


def _sources(lst):
    """How many INDEPENDENT non-context sources vote for a word (both models agreeing counts as two)."""
    kinds = {s for s, _ in lst if s in ("both_agree", "m06", "m17", "consensus", "bigram")}
    return sum(2 if s == "both_agree" else 1 for s in kinds)


def score_column(S, k, bc, vocab, flags, cfg=CONFIG):
    col = S[k]
    ev_nc = _evidence(S, k, bc, vocab, flags, cfg, with_ctx=False)
    final, conf, total, order, margin = _decide(col, ev_nc, cfg)
    col["ctx_decision"] = "none"
    if flags["ctx"] and col["ctx"]:
        ctx_words = sorted({w for w, _, _ in col["ctx"]})
        if conf == "confident":                                 # RULE: context never touches a span that is already decided
            col["ctx_decision"] = "ignored_confident"
            if any(w != final for w in ctx_words):
                col["log"].append(f"CONTEXT IGNORED: span already confident ({final!r}) — context said {ctx_words}")
        else:
            ev_c = _evidence(S, k, bc, vocab, flags, cfg, with_ctx=True)
            f2, c2, t2, o2, m2 = _decide(col, ev_c, cfg)
            if f2 != final:
                n_old = _sources(ev_nc.get(final, [])) if final else 0
                n_new = _sources(ev_nc.get(f2, [])) if f2 else 0
                if n_old >= 2 and n_new <= 1:                   # RULE: stronger non-context evidence wins over context
                    col["ctx_decision"] = "ignored_conflict"
                    col["log"].append(f"CONTEXT IGNORED: conflicts with stronger non-context evidence for {final!r} ({n_old} sources vs {n_new}); context said {f2!r}")
                else:
                    col["ctx_decision"] = "applied"
                    col["log"].append(f"context used: {final!r} -> {f2!r} (span was uncertain; stays flagged uncertain)")
                    ev_nc, final, conf, total, order, margin = ev_c, f2, "uncertain", t2, o2, m2   # never promoted to confident by context alone
            else:
                col["ctx_decision"] = "agrees"
                ev_nc, final, conf, total, order, margin = ev_c, f2, c2, t2, o2, m2
    col["scores"] = total; col["final"] = final; col["conf"] = conf; col["margin"] = round(margin, 3)
    col["alts"] = [w for w in order if w != final and w != GAP and total[w] > 0]
    col["evidence"] = {w: [(s, round(x, 3)) for s, x in lst] for w, lst in ev_nc.items()}


def rescore(S, use_cons=True, use_ctx=True, use_vocab=True, use_bigram=True):
    flags = {"cons": use_cons, "ctx": use_ctx, "vocab": use_vocab, "bigram": use_bigram}
    for c in S: c["final"], c["conf"], c["conf_prev"] = c["prelim"], None, None
    bc, vocab = collections.Counter(), collections.Counter()
    for k in range(len(S)): score_column(S, k, bc, vocab, {**flags, "vocab": False, "bigram": False, "ctx": False})
    for _ in range(2):                                          # bigram / vocabulary need neighbours' state: two settling passes
        bc = collections.Counter((a["final"], b["final"]) for a, b in zip(S, S[1:]) if a["conf"] == "confident" and b["conf"] == "confident" and a["final"] and b["final"])
        vocab = collections.Counter(c["final"] for c in S if c["conf"] == "confident" and c["final"])
        for c in S: c["conf_prev"] = c["conf"]
        for k in range(len(S)): score_column(S, k, bc, vocab, {**flags, "ctx": False})
    if flags["ctx"] and any(c["ctx"] for c in S):               # final pass: context consulted ONLY for spans still uncertain
        bc = collections.Counter((a["final"], b["final"]) for a, b in zip(S, S[1:]) if a["conf"] == "confident" and b["conf"] == "confident" and a["final"] and b["final"])
        vocab = collections.Counter(c["final"] for c in S if c["conf"] == "confident" and c["final"])
        for c in S: c["conf_prev"] = c["conf"]
        for k in range(len(S)): score_column(S, k, bc, vocab, flags)


# ----------------------------------------------------------------------------------------------
# Stage 7: context-assisted re-transcription (only for uncertain VOCAL spans)
# ----------------------------------------------------------------------------------------------
def uncertain_vocal_chunks(chunks, cfg=CONFIG):
    out = []
    for ch in chunks:
        if ch["mode"] != "LEXICAL" or ch["state"] != "VOCAL": continue      # context ONLY for chunks the mask calls VOCAL
        cols = [c for c in ch["cols"] if c.get("gi") is not None]
        if sum(1 for c in cols if c["conf"] == "uncertain") >= cfg["ctx_min_uncertain"]: out.append(ch)
    return out


def build_context(S, ch, classes_pos, cfg=CONFIG):
    """Context text comes ONLY from earlier ASR results that already passed the confidence rules:
    (a) the confident words immediately before the chunk, (b) the confident words of the EARLIER occurrence
    of a passage this chunk repeats (repeat discovered from ASR text only)."""
    cols = [c for c in ch["cols"] if c.get("gi") is not None]
    if not cols: return "", [], []
    first = cols[0]["gi"]
    prev = []
    for k in range(first - 1, -1, -1):
        if S[k]["conf"] != "confident" or S[k]["final"] is None: break
        prev.append(S[k]["final"])
        if len(prev) >= cfg["ctx_prev_words"]: break
    prev.reverse()
    if len(prev) < cfg["ctx_prev_min"]: prev = []
    cont = []
    ingi = {c["gi"] for c in cols}
    hits = []                                                    # nearest EARLIER occurrence of every repeated word that also occurs in this chunk
    for g in classes_pos:
        earlier = [x for x in g if x < first]
        if earlier and any(x in ingi for x in g): hits.append(max(earlier))
    hits.sort(); groups = []
    for h in hits:
        if groups and h - groups[-1][-1] <= 6: groups[-1].append(h)
        else: groups.append([h])
    if groups:                                                   # the biggest coherent earlier passage = the repeat this chunk is (part of)
        g = max(groups, key=len)
        if len(g) >= 3:
            for k in range(g[0], min(first, g[-1] + 3)):
                if S[k]["conf"] == "confident" and S[k]["final"]: cont.append(S[k]["final"])
            cont = cont[:cfg["ctx_repeat_words"]]
    return " ".join(prev + cont), prev, cont


def apply_context(ch, results, cfg=CONFIG):
    """Align every context re-transcription with the chunk's columns; it may only RE-VOTE existing columns (the
    scoring stage then decides whether the context may be used at all). A run whose words are mostly unsupported by
    the original hypotheses (drift = copying the context) is discarded."""
    cols = [c for c in ch["cols"] if c.get("prelim") is not None]      # the WHOLE chunk (incl. overlap words) so alignment starts in the right place
    cur = [c["prelim"] for c in cols]
    for model, r in results.items():
        if r is None: continue
        ctoks = tokens(r["text"]); ops = AL.align(cur, ctoks)
        total = unsup = 0; pairs = []
        for cls, i, j, s in ops:
            if j is None: continue
            total += 1
            if i is None: unsup += 1; continue                    # extra words cannot be added
            word = ctoks[j]; col = cols[i]
            supp = max((viet.similarity(word, w) for w in (col["w06"], col["w17"]) if w), default=0.0)
            if supp < cfg["ctx_min_sim"]: unsup += 1
            if col.get("gi") is not None: pairs.append((col, word, supp))    # words already owned by the previous chunk are not re-voted
        drift = unsup / max(1, total)
        ch.setdefault("ctx_log", []).append({"model": model, "context": r["context"], "text": r["text"], "drift": round(drift, 2), "used": drift <= cfg["ctx_drift_max"]})
        if drift > cfg["ctx_drift_max"]: continue
        for col, word, supp in pairs:
            col["ctx"].append((word, cfg["w_ctx_supported"] if supp >= cfg["ctx_min_sim"] else cfg["w_ctx_unsupported"], f"ctx_{model}"))

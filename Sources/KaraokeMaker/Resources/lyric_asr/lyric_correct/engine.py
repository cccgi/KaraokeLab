"""Orchestrates one lyric-generation run: vocal mask -> 0.6B (all windows) -> 1.7B (VOCAL windows) -> correction stages ->
context re-check (uncertain VOCAL spans only) -> draft lines. Progress is REAL (chunk counters), never time-based."""
import os
import sys

import numpy as np
import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import layout as LY
import pipeline as P
import vocal_mask as VM

CHUNK_S, OVERLAP_S = 20.0, 2.0
SCHEMA = 1


class Cancelled(Exception):
    pass


def windows(total, n=CHUNK_S, ov=OVERLAP_S):
    b = [0.0]; k = 1
    while k * n < total - 1.0:
        b.append(k * n); k += 1
    return [(s, min(total, (b[i + 1] if i + 1 < len(b) else total) + ov)) for i, s in enumerate(b)]


def _key(start, end, ctx=""): return f"{start:.3f}|{end:.3f}|{ctx}"


def run(mix_path, vocal_path, backend, emit, cfg=P.CONFIG, want_diagnostics=False, cancelled=lambda: False):
    def check():
        if cancelled(): raise Cancelled()

    emit({"event": "status", "phase": "prepare"})
    mix, sr = sf.read(mix_path, dtype="float32")
    if mix.ndim > 1: mix = mix.mean(axis=1)
    vocal, vsr = sf.read(vocal_path, dtype="float32")
    if vocal.ndim > 1: vocal = vocal.mean(axis=1)
    if sr != 16000 or vsr != 16000:
        raise ValueError("inputs must be 16 kHz mono WAV (the app prepares them)")
    total = len(mix) / sr
    if total < 1.0: raise ValueError("audio is shorter than 1 second")
    an = VM.analyse(vocal)
    segs = VM.segments(an)
    wins = []
    for i, (s, e) in enumerate(windows(total)):
        m = VM.classify_window(an, s, e)
        wins.append({"i": i, "start": s, "end": e, **m})
    nv = sum(1 for w in wins if w["state"] == "VOCAL")
    to_verify = [w for w in wins if w["state"] in ("VOCAL", "UNCERTAIN")]
    check()

    r06, r17 = {}, {}
    # ---- A: 0.6B on the FULL MIX, every window --------------------------------------------------------------
    for n, w in enumerate(wins):
        check()
        seg = mix[int(w["start"] * sr):int(w["end"] * sr)]
        r06[w["i"]] = backend.transcribe("06", seg, sr, "", start=w["start"], end=w["end"])
        emit({"event": "progress", "phase": "recognize", "done": n + 1, "total": len(wins)})
    backend.unload()
    # ---- B: 1.7B verifier, ONLY where the mask says VOCAL (UNCERTAIN = diagnostic, must be confirmed by agreement) ----
    for n, w in enumerate(to_verify):
        check()
        seg = mix[int(w["start"] * sr):int(w["end"] * sr)]
        r17[w["i"]] = backend.transcribe("17", seg, sr, "", start=w["start"], end=w["end"])
        emit({"event": "progress", "phase": "verify", "done": n + 1, "total": len(to_verify)})

    # ---- C: correction stages (pure Python) ----------------------------------------------------------------
    emit({"event": "status", "phase": "check"})
    chunks = [P.build_chunk(w, w, r06[w["i"]], r17.get(w["i"]), cfg) for w in wins]
    S, dedupe_log = P.assemble(chunks)
    cons = P.repeat_consensus(S, cfg)
    P.rescore(S, use_ctx=False)
    check()

    # ---- D: context re-check — ONLY chunks the mask calls VOCAL that still have uncertain spans -------------
    plan = []
    for ch in P.uncertain_vocal_chunks(chunks, cfg):
        text, prev, cont = P.build_context(S, ch, cons["class_positions"], cfg)
        if text: plan.append((ch, text, prev, cont))
    ctx_report = []
    if plan:
        total_runs = len(plan) * 2; done = 0
        ctx_res = {}
        for model_id in ("17", "06"):                            # 1.7B is still loaded from step B; then 0.6B
            for ch, text, _p, _c in plan:
                check()
                seg = mix[int(ch["start"] * sr):int(ch["end"] * sr)]
                ctx_res[(model_id, ch["i"])] = backend.transcribe(model_id, seg, sr, text, start=ch["start"], end=ch["end"])
                done += 1
                emit({"event": "progress", "phase": "context", "done": done, "total": total_runs})
        for ch, text, prev, cont in plan:
            P.apply_context(ch, {"06": ctx_res[("06", ch["i"])], "17": ctx_res[("17", ch["i"])]}, cfg)
            ctx_report.append({"chunk": ch["i"], "context": text, "runs": ch.get("ctx_log", [])})
        P.rescore(S)
    backend.unload()

    # ---- E: finish ------------------------------------------------------------------------------------------
    emit({"event": "status", "phase": "finish"})
    cols_by_chunk = {}
    for ch in chunks:
        kept = [c for c in ch["cols"] if c.get("gi") is not None and c["final"] is not None]
        if kept: cols_by_chunk[ch["i"]] = kept
    lines = LY.build_lines(chunks, segs, cols_by_chunk)
    out_lines = []
    for ln in lines:
        words = []
        for c in ln["words"]:
            sure = c["conf"] == "confident"
            words.append({"text": c["final"], "confidence": "confident" if sure else "uncertain",
                          "alternatives": [] if sure else list(c["alts"][:4]),
                          "kind": "possible_missing" if (c.get("kind") == "possible_missing" and not sure) else "word"})
        out_lines.append({"words": words, "section_break_before": ln["section_break_before"], "approx_start": ln["approx_start"]})
    n_words = sum(len(l["words"]) for l in out_lines)
    n_unc = sum(1 for l in out_lines for w in l["words"] if w["confidence"] == "uncertain")
    warnings = []
    for ch in chunks:
        if ch["cap_hit06"] or ch["cap_hit17"]:
            warnings.append(f"window {ch['i']} hit the token guard (repetitive output was cut)")
    result = {
        "schema": SCHEMA, "audio_seconds": round(total, 2), "backend": backend.describe(),
        "lines": out_lines,
        "non_lexical_vocal": [{"start": ch["start"], "end": ch["end"], "text": ch["text06"] or ch["text17"] or ""} for ch in chunks if ch["mode"] == "NON_LEXICAL_VOCAL"]
                             + [{"start": ch["start"], "end": ch["end"], "text": " ".join(ch["hum"])} for ch in chunks if ch["hum"]],
        "unconfirmed_vocal_chunks": [{"start": ch["start"], "end": ch["end"], "text06": ch["text06"], "text17": ch["text17"]} for ch in chunks if ch["mode"] == "REJECTED_UNCERTAIN"],
        "stats": {"windows": len(wins), "vocal_windows": nv, "instrumental_windows": sum(1 for w in wins if w["state"] == "NON_VOCAL"),
                  "verified_windows": len(to_verify), "context_windows": len(plan), "words": n_words, "uncertain_words": n_unc},
        "warnings": warnings,
    }
    if want_diagnostics:
        result["diagnostics"] = diagnostics(wins, chunks, S, cons, ctx_report, dedupe_log, r06, r17, cfg)
    return result


def diagnostics(wins, chunks, S, cons, ctx_report, dedupe_log, r06, r17, cfg):
    """Structured log of every automatic correction (kept OUT of the normal UI)."""
    corrections = []
    for c in S:
        old = c["w06"]; new = c["final"]
        if old == new and not c["log"]: continue                 # only real corrections / logged decisions
        ch = chunks[c["chunk"]]
        cols = [x for x in ch["cols"] if x.get("gi") is not None]
        idx = cols.index(c) if c in cols else 0
        t = round(ch["start"] + (ch["end"] - 2 - ch["start"]) * (idx + 0.5) / max(1, len(cols)), 1)
        corrections.append({
            "time": t, "chunk": c["chunk"], "w06": old, "w17": c["w17"], "align_class": c["cls"], "kind": c.get("kind"),
            "repeat_evidence": [{"word": w, "weight": wt, "why": why} for w, wt, why in c["cons"]],
            "context_result": [{"word": w, "weight": wt, "from": src} for w, wt, src in c["ctx"]], "context_decision": c["ctx_decision"],
            "final": new, "confidence": c["conf"], "alternatives": c["alts"], "scores": c["scores"], "notes": c["log"]})
    return {"config": cfg, "windows": wins,
            "chunk_modes": [{"i": ch["i"], "mode": ch["mode"], "note": ch["note"], "text06": ch["text06"], "text17": ch["text17"]} for ch in chunks],
            "repeat_classes": cons["class_positions"], "dedupe": dedupe_log, "context_runs": ctx_report, "corrections": corrections,
            "rejected_1p7b_only": [{"chunk": ch["i"], "word": c["w17"], "notes": c["log"]} for ch in chunks for c in ch["cols"] if c.get("forced_gap")]}

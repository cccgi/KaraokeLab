"""Turns the final word stream into DRAFT lyric lines (visual convenience only — TIMING is done by the app's own engine).

Qwen gives text without timestamps. To break the text into karaoke-sized lines we use the vocal presence mask's silences:
inside each transcription window the words are spread over that window's vocal-active time (a Vietnamese word is one
syllable, so 'equal time per word' is a fair proxy); a line break is placed where a word boundary falls inside a
silence >= LINE_GAP_S, a blank line (section break) where the silence is >= SECTION_GAP_S. These times are NEVER exported."""

LINE_GAP_S = 0.7
SECTION_GAP_S = 3.0
MAX_WORDS = 12
MIN_WORDS = 3
PUNCT_MIN_WORDS = 4


def _active_intervals(segments, t0, t1):
    out = []
    for s, e in segments:
        a, b = max(s, t0), min(e, t1)
        if b - a > 1e-3: out.append((a, b))
    return out


def _spread(n, intervals, t0, t1):
    """n word-centre times spread evenly over the active time (falls back to the whole window)."""
    if n == 0: return []
    if not intervals: intervals = [(t0, t1)]
    total = sum(b - a for a, b in intervals)
    times = []
    for j in range(n):
        target = (j + 0.5) / n * total; acc = 0.0
        for a, b in intervals:
            if acc + (b - a) >= target - 1e-9:
                times.append(a + (target - acc)); break
            acc += b - a
        else:
            times.append(intervals[-1][1])
    return times


def build_lines(chunks, segments, cols_by_chunk):
    """chunks: pipeline chunks; cols_by_chunk: {chunk_index: [column dicts with final/conf/alts/kind]} (kept columns only).
    Returns list of {'words': [...], 'section_break_before': bool, 'approx_start': float}."""
    stream = []                                                   # (time, word dict, chunk end)
    for ch in chunks:
        cols = cols_by_chunk.get(ch["i"], [])
        if not cols: continue
        t0, t1 = ch["start"], ch["end"]
        times = _spread(len(cols), _active_intervals(segments, t0, t1), t0, t1)
        for t, c in zip(times, cols): stream.append((t, c))
    lines, cur, prev_t = [], [], None      # cur = list of column dicts; 'brk' = the ASR heard a phrase boundary after this word
    def flush(section):
        if cur:
            lines.append({"words": list(cur), "section_break_before": section, "approx_start": round(cur_t0[0], 1)})
    cur_t0 = [0.0]; pending_section = False
    for idx, (t, w) in enumerate(stream):
        gap = 0.0
        if prev_t is not None:
            gap = _silence_between(segments, prev_t, t)
        brk = prev_t is not None and len(cur) >= MIN_WORDS and (gap >= LINE_GAP_S or (cur and cur[-1].get("brk") and len(cur) >= PUNCT_MIN_WORDS))
        forced = len(cur) >= MAX_WORDS and (gap > 0.15 or len(cur) >= MAX_WORDS + 6)
        if brk or forced or (prev_t is not None and gap >= SECTION_GAP_S and cur):
            flush(pending_section); pending_section = gap >= SECTION_GAP_S; cur.clear()
        if not cur: cur_t0[0] = t
        cur.append(w); prev_t = t
    flush(pending_section)
    if lines: lines[0]["section_break_before"] = False
    return lines


def _silence_between(segments, t_a, t_b):
    """Total NON-vocal time between two instants."""
    if t_b <= t_a: return 0.0
    active = 0.0
    for s, e in segments:
        a, b = max(s, t_a), min(e, t_b)
        if b > a: active += b - a
    return max(0.0, (t_b - t_a) - active)

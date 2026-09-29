"""Lightweight Vietnamese syllable comparator (pure Python, portable Intel/Apple Silicon).

Splits a syllable into  initial consonant | rhyme (vowel nucleus + final)  | tone  and measures
a SEPARATE distance for each part plus syllable length. Tone marks are NOT stripped-and-forgotten:
tone difference costs less than a different syllable structure but is never free.
Used ONLY to compare candidates that already exist. It never invents words."""
import re
import unicodedata

TONE_MARKS = {"̀": "huyen", "́": "sac", "̉": "hoi", "̃": "nga", "̣": "nang"}
VOWELS = set("aăâeêiyoôơuư")
INITIALS = ["ngh", "ng", "nh", "ch", "gh", "gi", "kh", "ph", "th", "tr", "qu",
            "b", "c", "d", "đ", "g", "h", "k", "l", "m", "n", "p", "r", "s", "t", "v", "x"]

# ---------------------------------------------------------------------------------------------
# weights of the 4 components (visible + configurable)
W_INIT, W_RHYME, W_TONE, W_LEN = 0.30, 0.40, 0.20, 0.10


def norm(tok):
    return unicodedata.normalize("NFC", tok.strip().lower())


def split_tone(syl):
    nfd = unicodedata.normalize("NFD", norm(syl))
    tone, out = "ngang", []
    for ch in nfd:
        if ch in TONE_MARKS:
            tone = TONE_MARKS[ch]
        else:
            out.append(ch)
    return unicodedata.normalize("NFC", "".join(out)), tone


def parse(tok):
    """-> dict(init, rhyme(list of symbols), tone, base). 'qu'->k+u, 'gi'/'gì' handled."""
    base, tone = split_tone(tok)
    init = ""
    for ini in sorted(INITIALS, key=len, reverse=True):
        if base.startswith(ini):
            init = ini
            break
    rest = base[len(init):]
    if init == "gi" and (rest == "" or rest[0] not in VOWELS):
        init, rest = "g", "i" + rest                      # "gì", "gin"
    if init == "qu":
        init, rest = "k", "u" + rest                      # quốc -> k + uôc (same rhyme as cuộc)
    syms, i = [], 0
    while i < len(rest):
        if rest[i:i + 2] in ("ng", "nh", "ch"):
            syms.append(rest[i:i + 2]); i += 2
        else:
            syms.append(rest[i]); i += 1
    return {"init": init, "rhyme": syms, "tone": tone, "base": base, "ok": bool(base) and all(c.isalpha() for c in base)}


# --------------------------- initial consonants ----------------------------------------------
# (place, manner, voiced) coarse phonetic description; orthographic variants collapse to one class
_INIT_CLASS = {"c": "k", "k": "k", "q": "k", "gh": "g", "ngh": "ng", "gi": "d", "r": "d"}
_INIT_FEAT = {
    "": ("glottal", "none", 0), "h": ("glottal", "fric", 0),
    "b": ("labial", "stop", 1), "m": ("labial", "nasal", 1), "ph": ("labial", "fric", 0), "v": ("labial", "fric", 1),
    "đ": ("alveolar", "stop", 1), "t": ("alveolar", "stop", 0), "th": ("alveolar", "asp", 0), "n": ("alveolar", "nasal", 1),
    "l": ("alveolar", "lateral", 1), "s": ("alveolar", "fric", 0), "x": ("alveolar", "fric", 0), "d": ("alveolar", "fric", 1),
    "tr": ("palatal", "affr", 0), "ch": ("palatal", "affr", 0), "nh": ("palatal", "nasal", 1),
    "k": ("velar", "stop", 0), "kh": ("velar", "fric", 0), "g": ("velar", "fric", 1), "ng": ("velar", "nasal", 1),
}
# frequent dialect / ASR confusions get a small fixed distance
_INIT_PAIR = {frozenset(("tr", "ch")): 0.15, frozenset(("s", "x")): 0.15, frozenset(("d", "g")): 0.45,
              frozenset(("n", "l")): 0.30, frozenset(("d", "v")): 0.45, frozenset(("k", "kh")): 0.45}


def init_dist(a, b):
    a, b = _INIT_CLASS.get(a, a), _INIT_CLASS.get(b, b)
    if a == b:
        return 0.0 if (a in _INIT_FEAT) else 0.5
    p = _INIT_PAIR.get(frozenset((a, b)))
    if p is not None:
        return p
    fa, fb = _INIT_FEAT.get(a), _INIT_FEAT.get(b)
    if fa is None or fb is None:
        return 1.0
    if "none" in (fa[1], fb[1]):
        return 0.7
    return min(1.0, 0.4 * (fa[0] != fb[0]) + 0.4 * (fa[1] != fb[1]) + 0.2 * (fa[2] != fb[2]))


# --------------------------- rhyme (vowel nucleus + final) ---------------------------------
_V = {  # (height 0 close..3 open, backness 0 front..2 back, rounded)
    "i": (0, 0, 0), "y": (0, 0, 0), "ê": (1, 0, 0), "e": (2, 0, 0), "a": (3, 1, 0), "ă": (3, 1, 0), "â": (2, 1, 0),
    "ơ": (2, 1.5, 0), "ư": (0, 2, 0), "u": (0, 2, 1), "ô": (1, 2, 1), "o": (2, 2, 1),
}
_CODA_SAME = {frozenset(("c", "ch")): 0.40, frozenset(("c", "t")): 0.50, frozenset(("t", "ch")): 0.45,
              frozenset(("n", "ng")): 0.40, frozenset(("ng", "nh")): 0.35, frozenset(("n", "nh")): 0.45,
              frozenset(("m", "n")): 0.50, frozenset(("m", "ng")): 0.60, frozenset(("c", "ng")): 0.60,
              frozenset(("t", "n")): 0.60, frozenset(("p", "m")): 0.60, frozenset(("ch", "nh")): 0.60}


def vowel_dist(a, b):
    if a == b:
        return 0.0
    x, y = _V[a], _V[b]
    d = (abs(x[0] - y[0]) / 3 + abs(x[1] - y[1]) / 2 + 0.6 * abs(x[2] - y[2])) / 2.6
    if {a, b} == {"i", "y"}:
        return 0.05
    if {a, b} == {"a", "ă"}:
        return 0.15
    return min(1.0, max(0.15, d))


def _sub(a, b):
    if a == b:
        return 0.0
    va, vb = a in _V, b in _V
    if va and vb:
        return vowel_dist(a, b)
    if not va and not vb:
        return _CODA_SAME.get(frozenset((a, b)), 0.9)
    return 1.0


def _indel(s, pos, n):
    if s in ("u", "o", "i", "y") and (pos == 0 or pos == n - 1):
        return 0.5                       # on-glide / off-glide
    return 0.8 if s in _V else 0.7


def rhyme_dist(ra, rb):
    n, m = len(ra), len(rb)
    if n == 0 and m == 0:
        return 0.0
    dp = [[0.0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        dp[i][0] = dp[i - 1][0] + _indel(ra[i - 1], i - 1, n)
    for j in range(1, m + 1):
        dp[0][j] = dp[0][j - 1] + _indel(rb[j - 1], j - 1, m)
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            dp[i][j] = min(dp[i - 1][j] + _indel(ra[i - 1], i - 1, n), dp[i][j - 1] + _indel(rb[j - 1], j - 1, m),
                           dp[i - 1][j - 1] + _sub(ra[i - 1], rb[j - 1]))
    return min(1.0, dp[n][m] / max(n, m))


# --------------------------- tone ------------------------------------------------------------
_TONE = {("ngang", "huyen"): 0.45, ("ngang", "sac"): 0.50, ("ngang", "hoi"): 0.60, ("ngang", "nga"): 0.65, ("ngang", "nang"): 0.70,
         ("huyen", "sac"): 0.80, ("huyen", "hoi"): 0.35, ("huyen", "nga"): 0.70, ("huyen", "nang"): 0.30,
         ("sac", "hoi"): 0.60, ("sac", "nga"): 0.30, ("sac", "nang"): 0.60,
         ("hoi", "nga"): 0.40, ("hoi", "nang"): 0.45, ("nga", "nang"): 0.50}


def tone_dist(a, b):
    if a == b:
        return 0.0
    return _TONE.get((a, b), _TONE.get((b, a), 0.7))


# --------------------------- public API -------------------------------------------------------
def components(a, b):
    pa, pb = parse(a), parse(b)
    if not (pa["ok"] and pb["ok"]):
        return None
    d_len = abs(len(pa["base"]) - len(pb["base"])) / max(len(pa["base"]), len(pb["base"]))
    return {"init": init_dist(pa["init"], pb["init"]), "rhyme": rhyme_dist(pa["rhyme"], pb["rhyme"]),
            "tone": tone_dist(pa["tone"], pb["tone"]), "len": d_len}


_cache = {}


def similarity(a, b):
    """0..1 (1 = identical syllable). Normalised weighted combination of the four component distances."""
    a, b = norm(a), norm(b)
    if a == b:
        return 1.0
    k = (a, b) if a < b else (b, a)
    if k in _cache:
        return _cache[k]
    c = components(a, b)
    if c is None:                                       # non-Vietnamese token (e.g. 'hmmm'): character similarity
        n = max(len(a), len(b)); s = 1 - _edit(a, b) / n if n else 1.0
        _cache[k] = max(0.0, s - 0.1)
        return _cache[k]
    pa, pb = parse(a), parse(b)
    w_init = W_INIT if (pa["init"] or pb["init"]) else 0.0      # both start with a vowel: the initial carries no evidence
    d = (w_init * c["init"] + W_RHYME * c["rhyme"] + W_TONE * c["tone"] + W_LEN * c["len"]) / (w_init + W_RHYME + W_TONE + W_LEN)
    _cache[k] = max(0.0, 1.0 - d)
    return _cache[k]


def _edit(a, b):
    d = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        p, d[0] = d[0], i
        for j, cb in enumerate(b, 1):
            p, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, p + (ca != cb))
    return d[-1]


_NONLEX = re.compile(r"^(h+m+|m+|m+h+|a+h+|o+h+|uh+|eh+|ơ+|ờ+|ừ+|ư+|la+)$")


def is_nonlexical(tok):
    """Humming / interjection vocalisation (hmm, ah, oh, ơ, la ...)."""
    return bool(_NONLEX.match(norm(tok)))

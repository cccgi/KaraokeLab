"""Word-level dynamic alignment of two Vietnamese transcripts with PHONETIC substitution costs.
Each aligned position is classified AGREE / MINOR_VARIANT / DISAGREE / ONLY_A / ONLY_B."""
import re
import unicodedata
import viet

MINOR_SIM = 0.66           # >= : near-phonetic variant (cuộc/quốc, vang/vãng, dìu/diều/dịu, nguy/may)
INDEL = 1.2


def tokens(text):
    s = unicodedata.normalize("NFC", text.lower())
    return re.sub(r"[^\w\s]", " ", s).replace("_", " ").split()


def align(a, b):
    """-> list of (cls, i, j, sim). cls in AGREE/MINOR_VARIANT/DISAGREE/ONLY_A/ONLY_B."""
    n, m = len(a), len(b)
    def sub(i, j):
        return 0.0 if a[i] == b[j] else 2.0 * (1.0 - viet.similarity(a[i], b[j]))
    dp = [[0.0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1): dp[i][0] = i * INDEL
    for j in range(1, m + 1): dp[0][j] = j * INDEL
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            dp[i][j] = min(dp[i - 1][j] + INDEL, dp[i][j - 1] + INDEL, dp[i - 1][j - 1] + sub(i - 1, j - 1))
    i, j, ops = n, m, []
    while i > 0 or j > 0:
        if i > 0 and j > 0 and abs(dp[i][j] - (dp[i - 1][j - 1] + sub(i - 1, j - 1))) < 1e-9:
            s = 1.0 if a[i - 1] == b[j - 1] else viet.similarity(a[i - 1], b[j - 1])
            cls = "AGREE" if a[i - 1] == b[j - 1] else ("MINOR_VARIANT" if s >= MINOR_SIM else "DISAGREE")
            ops.append((cls, i - 1, j - 1, s)); i -= 1; j -= 1
        elif i > 0 and abs(dp[i][j] - (dp[i - 1][j] + INDEL)) < 1e-9:
            ops.append(("ONLY_A", i - 1, None, 0.0)); i -= 1
        else:
            ops.append(("ONLY_B", None, j - 1, 0.0)); j -= 1
    ops.reverse()
    return ops

"""Reading assessment: lines up what Whisper heard with the text the learner was reading.

Each reference word ends up correct, close (a near miss such as "thought" heard as "taught"),
wrong (another word was heard), missed (skipped), or unclear (matched, but Whisper was unsure
of it, which usually means it was hard to understand). The app's live karaoke uses the same
alignment in Swift (ReadingTracker.swift) on Apple's on-device partial results; this pass runs
once at the end on the full recording with Whisper's word timings and confidences.
"""

from __future__ import annotations

import re
from typing import Optional

WORD = re.compile(r"[A-Za-z0-9]+(?:['’][A-Za-z]+)*")
# Whisper word probability under which a matched word counts as unclear.
UNCLEAR_BELOW = 0.45


def normalize(word: str) -> str:
    return word.lower().replace("’", "'").strip("'")


def tokens(text: str) -> list[str]:
    return [normalize(m.group(0)) for m in WORD.finditer(text)]


def similarity(a: str, b: str) -> float:
    if a == b:
        return 1.0
    if not a or not b:
        return 0.0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return 1 - prev[-1] / max(len(a), len(b))


def align(reference: list[str], heard: list[str]) -> list[tuple[Optional[int], Optional[int]]]:
    """Edit-distance alignment. Returns (ref_index, heard_index) pairs in order; None on one side
    means a skipped reference word or an extra heard word."""
    n, m = len(reference), len(heard)
    INF = float("inf")
    cost = [[INF] * (m + 1) for _ in range(n + 1)]
    back = [[0] * (m + 1) for _ in range(n + 1)]
    cost[0][0] = 0
    for i in range(n + 1):
        for j in range(m + 1):
            c = cost[i][j]
            if c == INF:
                continue
            if i < n and j < m:
                sim = similarity(reference[i], heard[j])
                step = 0 if sim == 1 else 0.4 if sim >= 0.7 else 1.0
                if c + step < cost[i + 1][j + 1]:
                    cost[i + 1][j + 1] = c + step
                    back[i + 1][j + 1] = 0
            if i < n and c + 1 < cost[i + 1][j]:
                cost[i + 1][j] = c + 1
                back[i + 1][j] = 1
            if j < m and c + 1 < cost[i][j + 1]:
                cost[i][j + 1] = c + 1
                back[i][j + 1] = 2
    pairs = []
    i, j = n, m
    while i > 0 or j > 0:
        move = back[i][j]
        if move == 0:
            pairs.append((i - 1, j - 1)); i -= 1; j -= 1
        elif move == 1:
            pairs.append((i - 1, None)); i -= 1
        else:
            pairs.append((None, j - 1)); j -= 1
    pairs.reverse()
    return pairs


def assess(reference_text: str, words: list[dict], duration: float) -> dict:
    """`words` are Whisper words: {"word", "start", "end", "probability"}."""
    display = [m.group(0) for m in WORD.finditer(reference_text)]
    reference = [normalize(w) for w in display]
    heard_words, heard = [], []
    for w in words:
        # Whisper words carry spaces and punctuation (" world."); a word can also be two tokens ("it's").
        for t in tokens(w["word"]):
            heard_words.append(w)
            heard.append(t)

    result = [{"text": d, "status": "missed", "heard": "", "probability": 0.0, "start": None, "end": None}
              for d in display]
    extra = 0
    for ri, hi in align(reference, heard):
        if ri is None:
            extra += 1
            continue
        if hi is None:
            continue
        w = heard_words[hi]
        r = result[ri]
        r.update(heard=heard[hi], probability=round(float(w.get("probability") or 0), 2),
                 start=w.get("start"), end=w.get("end"))
        sim = similarity(reference[ri], heard[hi])
        if sim == 1:
            r["status"] = "unclear" if r["probability"] < UNCLEAR_BELOW else "correct"
        elif sim >= 0.7:
            r["status"] = "close"
        else:
            r["status"] = "wrong"

    # Stop counting at the last word the learner reached: reading half the text is not "missing" the rest.
    reached = max((i for i, r in enumerate(result) if r["status"] != "missed"), default=-1) + 1
    for r in result[reached:]:
        r["status"] = "pending"
    attempted = result[:reached]
    weights = {"correct": 1.0, "unclear": 0.7, "close": 0.6, "wrong": 0.0, "missed": 0.0}
    accuracy = (sum(weights[r["status"]] for r in attempted) / len(attempted)) if attempted else 0.0
    completion = reached / len(result) if result else 0.0

    spoken = [w for w in heard_words if w.get("start") is not None]
    speaking_time = (spoken[-1]["end"] - spoken[0]["start"]) if len(spoken) >= 2 else duration
    wpm = int(len(heard_words) / speaking_time * 60) if speaking_time and speaking_time > 1 else 0
    pauses = sum(1 for a, b in zip(spoken, spoken[1:]) if b["start"] - a["end"] > 1.2)

    return {
        "words": result,
        "accuracy": round(accuracy * 100),
        "completion": round(completion * 100),
        # Weighted toward accuracy; completion keeps a half-read text from scoring 100.
        "score": round((accuracy * 0.8 + completion * 0.2) * 100),
        "wpm": wpm,
        "pauses": pauses,
        "extra_words": extra,
        "duration": round(duration, 1),
    }

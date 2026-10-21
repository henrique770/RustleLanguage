"""rustle-language-server: local speech recognition + English tutor service for RustleLanguage.

Same shape as RustleApp's rustle-server (Whisper on this Mac + an optional LLM), on its own port
(8766) so both apps can run side by side.

    POST /v1/transcribe            {"audio_wav_b64"}                          -> {"text", "words", "duration"}
    POST /v1/conversation/turn     {"audio_wav_b64"?, "text"?, "history", "scenario", "level"}
                                                                              -> {"user_text", "reply", "engine"}
    POST /v1/conversation/feedback {"text", "previous", "level"}              -> {"corrected", "ok", "issues", "natural"}
    POST /v1/conversation/report   {"turns", "scenario", "level"}             -> {"title", "summary", ..., "score"}
    POST /v1/conversation/ask      {"question", "turns", "report"}            -> {"answer"}
    POST /v1/text/analyze          {"text", "mode", "tone", "level"}          -> {"english", "changes", ...}
    POST /v1/read/assess           {"audio_wav_b64", "reference"}             -> {"words", "score", "tips", ...}
    POST /v1/llm/test                                                         -> {"ok", "sample" | "error"}
    GET  /health
"""

from __future__ import annotations

import base64
import io
import logging
import os
import re
import threading
import time
import wave
from typing import Any, Optional

import numpy as np
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

import llm
from alignment import assess
from settings import SettingsStore
from tutor import Tutor

log = logging.getLogger("rustle")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

# English-only checkpoints are faster and more accurate for English than the multilingual ones.
WHISPER_MODEL = os.environ.get("RUSTLE_WHISPER_MODEL", "small.en")
WHISPER_DEVICE = os.environ.get("RUSTLE_WHISPER_DEVICE", "cpu")
WHISPER_COMPUTE = os.environ.get("RUSTLE_WHISPER_COMPUTE", "int8")
MAX_AUDIO_SECONDS = 600
# Bumped when the app/server contract changes; the desktop app restarts older servers.
API_VERSION = 1

# Stock phrases Whisper produces from silence (subtitle credits in its training data).
HALLUCINATIONS = re.compile(r"^(thanks? (you )?(so much )?for watching[.!]?|subtitles by.*|amara\.org.*)$", re.IGNORECASE)


class HistoryTurn(BaseModel):
    role: str  # "you" | "tutor"
    text: str


class TranscribeRequest(BaseModel):
    audio_wav_b64: str


class TurnRequest(BaseModel):
    audio_wav_b64: Optional[str] = None
    text: Optional[str] = None
    history: list[HistoryTurn] = []
    scenario: str = ""
    level: Optional[str] = None


class FeedbackRequest(BaseModel):
    text: str
    previous: str = ""
    level: Optional[str] = None


class ReportRequest(BaseModel):
    turns: list[dict[str, Any]] = []
    scenario: str = ""
    level: Optional[str] = None


class AskRequest(BaseModel):
    question: str
    turns: list[dict[str, Any]] = []
    report: dict[str, Any] = {}


class AnalyzeRequest(BaseModel):
    text: str
    mode: str = "auto"  # auto | translate | improve
    tone: str = "neutral"  # neutral | formal | casual
    level: Optional[str] = None


class AssessRequest(BaseModel):
    audio_wav_b64: str
    reference: str


class Transcriber:
    def __init__(self, name: str = WHISPER_MODEL) -> None:
        from faster_whisper import WhisperModel

        self.name = name
        log.info("Loading Whisper model %s (%s/%s)", name, WHISPER_DEVICE, WHISPER_COMPUTE)
        self.model = WhisperModel(name, device=WHISPER_DEVICE, compute_type=WHISPER_COMPUTE)
        # faster-whisper models are not safe to call from several threads at once.
        self.lock = threading.Lock()

    def words(self, audio: np.ndarray) -> tuple[str, list[dict]]:
        """Transcript plus timed words with Whisper's confidence. No initial prompt on purpose: a
        prompt (e.g. the text being read) would make Whisper "hear" the right words and hide the
        learner's mistakes."""
        with self.lock:
            segments, _ = self.model.transcribe(
                audio,
                beam_size=5,
                language=None if self.name.endswith(".en") else "en",
                vad_filter=True,
                word_timestamps=True,
                condition_on_previous_text=False,
            )
            segments = list(segments)
        texts, words = [], []
        for s in segments:
            text = s.text.strip()
            if not text or (s.no_speech_prob > 0.6 and s.avg_logprob < -0.7) or s.compression_ratio > 2.4:
                continue
            texts.append(text)
            for w in s.words or []:
                words.append({"word": w.word, "start": round(w.start, 2), "end": round(w.end, 2),
                              "probability": round(w.probability, 3)})
        text = " ".join(texts).strip()
        if HALLUCINATIONS.match(text):
            log.info("dropped likely hallucination: %r", text)
            return "", []
        return text, words


def decode_wav(b64: str) -> np.ndarray:
    try:
        data = base64.b64decode(b64, validate=True)
        with wave.open(io.BytesIO(data)) as w:
            if w.getsampwidth() != 2 or w.getnchannels() != 1 or w.getframerate() != 16000:
                raise ValueError("expected 16 kHz mono PCM16 WAV")
            if w.getnframes() > MAX_AUDIO_SECONDS * 16000:
                raise ValueError("audio too long")
            frames = w.readframes(w.getnframes())
    except (wave.Error, EOFError, ValueError) as e:
        raise HTTPException(400, f"invalid audio: {e}") from e
    return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0


app = FastAPI(title="rustle-language-server")
settings_store = SettingsStore()
tutor = Tutor(settings_store)
transcriber: Optional[Transcriber] = None


@app.on_event("startup")
def _load() -> None:
    global transcriber
    transcriber = Transcriber()


def _transcriber() -> Transcriber:
    if transcriber is None:
        raise HTTPException(503, "model not loaded")
    return transcriber


@app.get("/health")
def health() -> dict:
    s = settings_store.get()
    return {"ok": transcriber is not None, "api_version": API_VERSION, "model": WHISPER_MODEL,
            "llm": llm.configured(s), "llm_provider": s.llm_provider, "llm_model": s.llm_model}


@app.post("/v1/transcribe")
def transcribe(req: TranscribeRequest) -> dict:
    audio = decode_wav(req.audio_wav_b64)
    started = time.perf_counter()
    text, words = _transcriber().words(audio)
    log.info("transcribe %.1fs -> %d words in %dms", len(audio) / 16000, len(words),
             int((time.perf_counter() - started) * 1000))
    return {"text": text, "words": words, "duration": round(len(audio) / 16000, 2)}


@app.post("/v1/conversation/turn")
def conversation_turn(req: TurnRequest) -> dict:
    """One exchange: the learner's audio (or typed text, or nothing to open the conversation) in,
    the tutor's reply out. Feedback on the learner's line is a separate call so the reply (which
    the learner is waiting to hear) is never held up by it."""
    started = time.perf_counter()
    user_text = (req.text or "").strip()
    duration = 0.0
    if req.audio_wav_b64:
        audio = decode_wav(req.audio_wav_b64)
        duration = len(audio) / 16000
        user_text, _ = _transcriber().words(audio)
        if not user_text:
            return {"user_text": "", "reply": "", "engine": "none", "error": "", "duration": round(duration, 2),
                    "latency_ms": int((time.perf_counter() - started) * 1000)}
    asr_ms = int((time.perf_counter() - started) * 1000)
    history = [t.model_dump() for t in req.history]
    if user_text:
        history.append({"role": "you", "text": user_text})
    result = tutor.reply(history, req.scenario, req.level)
    latency = int((time.perf_counter() - started) * 1000)
    log.info("turn: asr %dms, total %dms via %s (%d chars in, %d out)", asr_ms, latency, result["engine"],
             len(user_text), len(result["reply"]))
    return {"user_text": user_text, **result, "duration": round(duration, 2), "latency_ms": latency}


@app.post("/v1/conversation/feedback")
def conversation_feedback(req: FeedbackRequest) -> dict:
    started = time.perf_counter()
    result = tutor.feedback(req.text.strip(), req.previous, req.level)
    log.info("feedback %d issues via %s in %dms", len(result["issues"]), result["engine"],
             int((time.perf_counter() - started) * 1000))
    return result


@app.post("/v1/conversation/report")
def conversation_report(req: ReportRequest) -> dict:
    started = time.perf_counter()
    result = tutor.report(req.turns, req.scenario, req.level)
    log.info("report for %d turns via %s in %dms", len(req.turns), result["engine"],
             int((time.perf_counter() - started) * 1000))
    return result


@app.post("/v1/conversation/ask")
def conversation_ask(req: AskRequest) -> dict:
    return tutor.ask(req.question, req.turns, req.report)


@app.post("/v1/text/analyze")
def text_analyze(req: AnalyzeRequest) -> dict:
    text = req.text.strip()
    if not text:
        raise HTTPException(400, "empty text")
    started = time.perf_counter()
    result = tutor.analyze_text(text[:6000], req.mode, req.tone, req.level)
    log.info("analyze %d chars (%s) via %s in %dms", len(text), req.mode, result.get("engine", "none"),
             int((time.perf_counter() - started) * 1000))
    return result


@app.post("/v1/read/assess")
def read_assess(req: AssessRequest) -> dict:
    audio = decode_wav(req.audio_wav_b64)
    started = time.perf_counter()
    text, words = _transcriber().words(audio)
    result = assess(req.reference, words, len(audio) / 16000)
    result["heard_text"] = text
    result.update(tutor.reading_tips(result))
    log.info("reading %.1fs: score %d, accuracy %d%% via %s in %dms", len(audio) / 16000, result["score"],
             result["accuracy"], result["engine"], int((time.perf_counter() - started) * 1000))
    return result


@app.post("/v1/llm/test")
def llm_test() -> dict:
    s = settings_store.get()
    started = time.perf_counter()
    text = llm.complete(s, "You are a test endpoint.",
                        [{"role": "user", "content": "Reply with exactly: Hello from RustleLanguage!"}],
                        max_tokens=30, timeout=30)
    ms = int((time.perf_counter() - started) * 1000)
    if not text:
        return {"ok": False, "error": llm.last_error(), "provider": s.llm_provider, "model": s.llm_model}
    return {"ok": True, "sample": text[:200], "latency_ms": ms, "provider": s.llm_provider, "model": s.llm_model}


@app.post("/v1/shutdown")
def shutdown() -> dict:
    """Lets the desktop app restart a server it did not launch (e.g. after changing the model)."""
    threading.Timer(0.2, lambda: os._exit(0)).start()
    return {"ok": True}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=os.environ.get("RUSTLE_HOST", "127.0.0.1"), port=int(os.environ.get("RUSTLE_PORT", "8766")))

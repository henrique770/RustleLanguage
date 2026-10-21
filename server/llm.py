"""Any LLM, through one function.

Most providers speak OpenAI's chat-completions protocol (DeepSeek, OpenAI, OpenRouter, Groq,
Gemini's OpenAI endpoint, Ollama, LM Studio…), so the app only needs a base URL, a model name and
an optional key. Anthropic's Messages API is the one native exception. Both go through the stdlib
HTTP client (no SDKs to install).

The key for provider X is read from RUSTLE_LLM_KEY_X (the app passes it from the Keychain).
Every call returns None on failure and records why in `last_error`, so callers can fall back.
"""

from __future__ import annotations

import json
import logging
import os
import re
import threading
import urllib.error
import urllib.request
from typing import Optional

from settings import Settings

log = logging.getLogger("rustle.llm")

ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
# Providers that run on the user's machine and need no key.
KEYLESS = ("ollama", "lmstudio")

_local = threading.local()


def last_error() -> str:
    return getattr(_local, "error", "")


def _fail(message: str) -> None:
    _local.error = message
    log.warning("LLM: %s", message)


def api_key(provider: str) -> str:
    return os.environ.get(f"RUSTLE_LLM_KEY_{provider.upper()}", "").strip()


def configured(s: Settings) -> bool:
    if not s.llm_model.strip():
        return False
    if s.llm_provider == "anthropic":
        return bool(api_key("anthropic"))
    if not s.llm_base_url.strip():
        return False
    return s.llm_provider in KEYLESS or s.llm_provider == "custom" or bool(api_key(s.llm_provider))


def complete(s: Settings, system: str, messages: list[dict], *, max_tokens: int = 800,
             timeout: float = 60, json_mode: bool = False, temperature: Optional[float] = None) -> Optional[str]:
    """One chat completion. `messages` are {"role": "user"|"assistant", "content": str}."""
    _local.error = ""
    if not configured(s):
        _fail("nenhum provedor de IA configurado")
        return None
    if json_mode:
        system += "\n\nRespond with a single JSON object only (no code fences, no text around it)."
    if s.llm_provider == "anthropic":
        return _anthropic(s, system, messages, max_tokens, timeout, temperature)
    return _openai(s, system, messages, max_tokens, timeout, json_mode, temperature)


def complete_json(s: Settings, system: str, user: str, *, max_tokens: int = 1500,
                  timeout: float = 90, temperature: Optional[float] = 0.3) -> Optional[dict]:
    text = complete(s, system, [{"role": "user", "content": user}], max_tokens=max_tokens,
                    timeout=timeout, json_mode=True, temperature=temperature)
    data = parse_json(text) if text else None
    if text and data is None:
        _fail("a IA respondeu algo que não é JSON")
    return data


def parse_json(text: str) -> Optional[dict]:
    """Lenient: accepts code fences and prose around the object (some models ignore JSON mode)."""
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text.strip())
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        start, end = text.find("{"), text.rfind("}")
        if start < 0 or end <= start:
            return None
        try:
            data = json.loads(text[start:end + 1])
        except json.JSONDecodeError:
            return None
    return data if isinstance(data, dict) else None


def _post(url: str, body: dict, headers: dict, timeout: float) -> tuple[Optional[dict], Optional[int], str]:
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", **headers})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read()), resp.status, ""
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        return None, e.code, detail
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return None, None, str(getattr(e, "reason", e))
    except json.JSONDecodeError:
        return None, None, "resposta inválida"


def _openai(s: Settings, system: str, messages: list[dict], max_tokens: int, timeout: float,
            json_mode: bool, temperature: Optional[float]) -> Optional[str]:
    url = s.llm_base_url.rstrip("/") + "/chat/completions"
    key = api_key(s.llm_provider)
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    if s.llm_provider == "openrouter":
        headers["X-Title"] = "RustleLanguage"
    body: dict = {"model": s.llm_model, "messages": [{"role": "system", "content": system}, *messages],
                  "max_tokens": max_tokens, "stream": False}
    if temperature is not None:
        body["temperature"] = temperature
    if json_mode:
        body["response_format"] = {"type": "json_object"}
    data, status, detail = _post(url, body, headers, timeout)
    if data is None and status == 400:
        # Some models reject response_format, temperature or max_tokens (newer OpenAI models want
        # max_completion_tokens); retry once with the bare minimum.
        log.info("LLM 400 (%s); retrying with a minimal request", detail[:120])
        body = {"model": s.llm_model, "messages": body["messages"], "stream": False}
        data, status, detail = _post(url, body, headers, timeout)
    if data is None:
        _fail(f"{s.llm_provider} falhou ({status or 'sem conexão'}): {detail[:160]}")
        return None
    try:
        choice = data["choices"][0]
        text = (choice["message"].get("content") or "").strip()
    except (KeyError, IndexError, TypeError, AttributeError):
        _fail(f"{s.llm_provider} devolveu uma resposta inesperada")
        return None
    # Reasoning models served through Ollama/OpenRouter sometimes inline their thinking.
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()
    if choice.get("finish_reason") == "content_filter" or not text:
        _fail(f"{s.llm_provider} não devolveu texto ({choice.get('finish_reason')})")
        return None
    return text


def _anthropic(s: Settings, system: str, messages: list[dict], max_tokens: int, timeout: float,
               temperature: Optional[float]) -> Optional[str]:
    headers = {"x-api-key": api_key("anthropic"), "anthropic-version": "2023-06-01"}
    body: dict = {"model": s.llm_model, "max_tokens": max_tokens, "system": system, "messages": messages}
    if temperature is not None:
        body["temperature"] = temperature
    data, status, detail = _post(ANTHROPIC_URL, body, headers, timeout)
    if data is None and status == 400 and "temperature" in body:
        del body["temperature"]
        data, status, detail = _post(ANTHROPIC_URL, body, headers, timeout)
    if data is None:
        _fail(f"anthropic falhou ({status or 'sem conexão'}): {detail[:160]}")
        return None
    if data.get("stop_reason") == "refusal":
        _fail("anthropic recusou o pedido")
        return None
    text = "".join(b.get("text", "") for b in data.get("content") or [] if b.get("type") == "text").strip()
    if not text:
        _fail("anthropic não devolveu texto")
        return None
    return text

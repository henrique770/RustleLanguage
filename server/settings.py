"""Settings shared with the desktop app through settings.json (written by the app, reloaded here
whenever the file changes, so switching the AI provider or the learner's level needs no restart).

API keys never live in this file: the app keeps them in the macOS Keychain and passes them to the
server as environment variables (RUSTLE_LLM_KEY_<PROVIDER>) when it starts it.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass, field, fields
from typing import Optional

log = logging.getLogger("rustle.settings")


@dataclass
class Settings:
    # "deepseek", "openai", "openrouter", "groq", "gemini", "ollama", "anthropic" or "custom".
    llm_provider: str = "deepseek"
    # OpenAI-compatible base URL (".../v1"); ignored for "anthropic".
    llm_base_url: str = "https://api.deepseek.com"
    llm_model: str = "deepseek-chat"
    # CEFR level the tutor speaks at: A2, B1, B2, C1.
    level: str = "B1"
    # Language the explanations are written in.
    native_language: str = "pt"
    # Words the learner saved, offered to the tutor so it reuses them in conversation.
    vocabulary: list[str] = field(default_factory=list)


class SettingsStore:
    def __init__(self, path: Optional[str] = None) -> None:
        self.path = path or os.environ.get("RUSTLE_SETTINGS", "")
        self._mtime = -1.0
        self._settings = Settings()

    def get(self) -> Settings:
        if not self.path:
            return self._settings
        try:
            mtime = os.path.getmtime(self.path)
        except OSError:
            return self._settings
        if mtime != self._mtime:
            self._mtime = mtime
            try:
                with open(self.path, encoding="utf-8") as f:
                    data = json.load(f)
                known = {f.name for f in fields(Settings)}
                self._settings = Settings(**{k: v for k, v in data.items() if k in known})
                log.info("settings reloaded: provider=%s model=%s level=%s",
                         self._settings.llm_provider, self._settings.llm_model, self._settings.level)
            except (OSError, ValueError, TypeError) as e:
                log.warning("could not read %s (%s); keeping previous settings", self.path, e)
        return self._settings

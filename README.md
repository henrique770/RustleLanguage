# RustleLanguage (Rustle Language)

RustleLanguage is a macOS app for practicing languages by speaking, built on RustleApp's structure and design. This first version focuses on English. It has three ways to practice:

- **Conversa.** A real-time voice conversation with an AI tutor. You talk naturally, the app detects when you finish your turn, and the tutor answers out loud. Each of your sentences is annotated with a corrected version (changed words highlighted), the reason for each correction, and a more natural way to say it. When the conversation ends, a report gives you a score, your strengths, what to improve, and vocabulary to save. The layout comes from RustleApp's Notetaker: a list grouped by day, the session page with section pills, your notes, a floating footer with a live waveform, and a chat with the tutor.
- **Texto.** A Google Translate–style page that also teaches. Write in Portuguese to get natural English, or write your own English to get it corrected. Every change comes with an explanation, plus alternatives (more formal or more casual), vocabulary, and a tip.
- **Ler em voz alta.** Karaoke reading practice. The text follows you word by word as you read. When you finish, Whisper re-hears the whole recording and grades each word as correct, close, wrong, skipped, or unclear. You also get a score, accuracy, words per minute, pauses, and pronunciation tips with IPA.

Everything you save (words, readings, texts, and conversations) appears in **Vocabulário** and on **Início**. The tutor also tries to reuse the words you are studying in later conversations.

## Architecture

```
client-macos/  Swift + SwiftUI (same design system as RustleApp: Figtree / EB Garamond, sand/vast palette)
  ConversationController   voice activity detection → turn → reply spoken → listen again (interruption optional)
  ReadingTracker           live word alignment (karaoke) over Apple's on-device recognizer
  VoiceEngine              tutor voice: VoiceStudio (local API) or the macOS voices
server/        Python + FastAPI on 127.0.0.1:8766
  language_server.py       Whisper (faster-whisper, English-only models) + endpoints
  tutor.py                 prompts: reply, feedback, report, translator, pronunciation tips
  alignment.py             final reading assessment (Whisper word timings + confidence)
  llm.py                   any LLM: OpenAI-compatible chat-completions or Anthropic Messages
```

Your voice is transcribed on your Mac by Whisper. Only text goes to the AI provider you choose. Apple's on-device recognizer shows live captions and drives the karaoke. Whisper produces the final transcript and the grading.

### Any LLM

In **Configurações → IA do tutor**, pick a preset or enter a URL and model yourself:

| Provider | Base URL | Default model |
|---|---|---|
| DeepSeek | `https://api.deepseek.com` | `deepseek-chat` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |
| Claude (Anthropic) | Messages API | `claude-opus-5-5` |
| OpenRouter | `https://openrouter.ai/api/v1` | `deepseek/deepseek-chat` |
| Groq | `https://api.groq.com/openai/v1` | `llama-3.3-70b-versatile` |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | `gemini-2.5-flash` |
| Ollama (local, no key) | `http://127.0.0.1:11434/v1` | `llama3.1` |
| Other | any `/chat/completions` endpoint | — |

You can edit the model of any preset. Keys are stored in the macOS Keychain, one per provider, and passed to the server as `RUSTLE_LLM_KEY_<PROVIDER>`. Changes to provider, URL, or model apply without restarting the server, because it reloads `settings.json`. For voice conversation, fast models such as `deepseek-chat` or Groq give the shortest wait between turns.

### Voices (VoiceStudio)

The tutor's voice can come from [VoiceStudio](https://github.com/debpalash/VoiceStudio), which runs locally and serves an OpenAI-compatible `POST /v1/audio/speech` on port 3900. VoiceStudio offers OmniVoice, KittenTTS, PocketTTS, and your own cloned voices; the list comes from `GET /v1/audio/voices`. To use it:

1. Install and open VoiceStudio.
2. In **Configurações → Voz do tutor**, choose **VoiceStudio**.
3. Pick a voice and, optionally, an engine.

If VoiceStudio does not respond, the app falls back to the macOS voice. The macOS voice is also always used for the karaoke's **Ouvir modelo**, because it is the only one that reports which word is being spoken.

The integration goes through the HTTP API only. No VoiceStudio code is copied, since it is licensed AGPL-3.0.

## Installation

Requirements are the same as RustleApp: macOS 14+, Swift command-line tools, Python 3.10+, and about 2 GB of disk space.

```bash
./scripts/install.sh
```

The installer prepares the Python venv, creates the signing certificate ("RustleLanguage Local Signing"), builds the app, copies it to `/Applications`, and opens it. Don't move the folder afterwards: the app starts the server from it.

Other scripts:

| Script | What it does |
|---|---|
| `scripts/build-app.sh` | Builds `build/RustleLanguage.app` |
| `scripts/run-server.sh` | Runs the server in the terminal (logs in `~/Library/Logs/RustleLanguage-server.log` when started by the app) |
| `scripts/make-icon.sh` | Regenerates `AppIcon.icns` from the mark in `Brand.swift` |
| `RustleLanguage --snapshot <dir>` | Renders every screen to PNG with sample data |

## Known limits (v1)

- **Speakers without headphones:** the microphone is ignored while the tutor speaks, so the tutor doesn't hear itself. To interrupt by talking, use headphones and turn on **Interromper o tutor falando**. Without headphones, use the ✋ button in the footer.
- **Pronunciation:** Whisper and Apple's recognizer tend to "correct" what they hear toward real words. Grading catches skipped words, swapped words ("thin" → "tin"), and words that were hard to understand (low confidence). It does not measure phonemes; that is a natural next step.
- **Languages:** only English for now. The language-specific parts are isolated (en-US recognizer, `.en` Whisper models, prompts in `tutor.py`, presets in `Models.swift`) so other languages can be added.

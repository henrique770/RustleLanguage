#!/usr/bin/env bash
# Start rustle-language-server (local Whisper ASR + English tutor) on 127.0.0.1:8766.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$ROOT/server"
VENV="$SERVER/.venv"
PY="${RUSTLE_PYTHON:-$(command -v python3.12 || command -v python3.11 || command -v python3)}"

if [ ! -x "$VENV/bin/python" ]; then
  echo "Creating venv with $PY"
  "$PY" -m venv "$VENV"
  "$VENV/bin/pip" install --upgrade pip >/dev/null
  "$VENV/bin/pip" install -r "$SERVER/requirements.txt"
fi

cd "$SERVER"
exec "$VENV/bin/python" language_server.py

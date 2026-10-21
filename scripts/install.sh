#!/usr/bin/env bash
# Installs RustleLanguage on this Mac: checks the requirements, prepares the local transcription server
# (Python venv + Whisper dependencies), builds and signs the app, copies it to /Applications
# (or ~/Applications) and opens it. The first launch shows the setup questionnaire.
# Keep this folder where it is afterwards: the app starts the server from it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

say() { printf "\n==> %s\n" "$1"; }
fail() { printf "\nErro: %s\n" "$1" >&2; exit 1; }

say "Verificando requisitos"
MACOS="$(sw_vers -productVersion)"
[ "${MACOS%%.*}" -ge 14 ] || fail "o RustleLanguage precisa do macOS 14 (Sonoma) ou mais recente; este Mac tem $MACOS."
command -v swift >/dev/null || fail "Swift não encontrado. Instale as ferramentas de linha de comando: xcode-select --install"
PY="${RUSTLE_PYTHON:-$(command -v python3.12 || command -v python3.11 || command -v python3.10 || true)}"
[ -n "$PY" ] || fail "Python 3.10+ não encontrado. Instale com: brew install python@3.12"
echo "macOS $MACOS · $(swift --version 2>/dev/null | head -1) · $("$PY" --version)"

say "Preparando o servidor de transcrição (pode levar alguns minutos)"
VENV="$ROOT/server/.venv"
if [ ! -x "$VENV/bin/python" ]; then
  "$PY" -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$ROOT/server/requirements.txt"

say "Criando o certificado local de assinatura (mantém as permissões entre atualizações)"
"$ROOT/scripts/create-signing-cert.sh"

say "Compilando o app"
"$ROOT/scripts/build-app.sh"

say "Copiando para Aplicativos"
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x RustleLanguage 2>/dev/null || true
rm -rf "$DEST/RustleLanguage.app"
cp -R "$ROOT/build/RustleLanguage.app" "$DEST/RustleLanguage.app"
echo "Instalado em $DEST/RustleLanguage.app"

say "Abrindo o RustleLanguage"
open "$DEST/RustleLanguage.app"
cat <<MSG

Pronto! Na primeira abertura o Rustle Language pergunta seu nome, seu nível e qual IA usar
(DeepSeek, OpenAI, Claude, Groq, Gemini, OpenRouter ou Ollama) e pede Microfone e Reconhecimento
de fala. O modelo Whisper small.en (~500 MB) é baixado no primeiro uso.
Para vozes mais naturais, instale o VoiceStudio (github.com/debpalash/VoiceStudio) e escolha-o em
Configurações → Voz do tutor.
Não mova nem apague esta pasta ($ROOT): o app inicia o servidor a partir dela.
MSG

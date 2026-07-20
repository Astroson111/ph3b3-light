#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup.sh — Ph3b3-Light setup, WSL/Linux side.
#
# Runs the Linux-side steps of the first-run wizard: system audio libs, Python
# environment + pinned dependencies, the default Alba voice, a small Whisper
# model, and .env. Called by setup.ps1 (the Windows entry point) but also works
# standalone if you are already in the Ubuntu terminal:  ./setup.sh
#
# Idempotent: safe to re-run. Completed steps are skipped; broken ones repaired.
# It NEVER overwrites an existing .env (your password is not reprinted or lost).
# Writes only inside the repo, ~/ph3b3_data, and .env. No network beyond the
# named installs (apt, pip, the Alba voice, the Whisper model).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO"
VOICES="$HOME/ph3b3_data/voices"
PIPER_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main"

say()  { printf "\n\033[1;36m▶ %s\033[0m\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[1;33m!\033[0m %s\n" "$*"; }
die()  { printf "\n  \033[1;31m✗ %s\033[0m\n" "$1" >&2
         [ $# -ge 2 ] && printf "  \033[1;33m→ next: %s\033[0m\n" "$2" >&2
         exit 1; }

# ── System audio/video libraries (apt) ──────────────────────────────────────
setup_system() {
  say "System libraries (audio/video — apt may ask for your password)"
  if dpkg -s ffmpeg portaudio19-dev libsndfile1 python3-venv >/dev/null 2>&1; then
    ok "system libraries already present"; return
  fi
  sudo apt-get update -qq && \
  sudo apt-get install -y ffmpeg portaudio19-dev python3-pyaudio libsndfile1 v4l-utils python3-venv python3-pip \
    || die "apt install failed." \
       "run: sudo apt update && sudo apt install -y ffmpeg portaudio19-dev python3-pyaudio libsndfile1 python3-venv — then re-run ./setup.sh"
  ok "system libraries installed"
}

# ── Python env + pinned requirements ────────────────────────────────────────
setup_env() {
  say "Python environment + dependencies"
  command -v python3 >/dev/null 2>&1 || die "python3 not found." \
    "sudo apt update && sudo apt install -y python3 python3-venv python3-pip, then re-run ./setup.sh"
  if [ ! -d .venv ]; then
    python3 -m venv .venv 2>/tmp/ph3b3_venv.err || die \
      "Could not create the virtual environment. $(tail -1 /tmp/ph3b3_venv.err 2>/dev/null)" \
      "sudo apt install -y python3-venv, then re-run ./setup.sh"
    ok "created .venv"
  else
    ok ".venv already present"
  fi
  if .venv/bin/python -c "import fastapi, uvicorn, httpx, bs4, lxml, dotenv" >/dev/null 2>&1; then
    ok "dependencies already installed"
  else
    say "Installing pinned requirements — this can take a few minutes…"
    .venv/bin/python -m pip install -q --upgrade pip >/dev/null 2>&1 || true
    .venv/bin/python -m pip install -r requirements.txt || die \
      "pip install failed (see the error above)." \
      "fix the reported package, then re-run ./setup.sh — it resumes"
    ok "requirements installed"
  fi
}

# ── Default voice — Alba only ───────────────────────────────────────────────
setup_voice() {
  say "Default voice — Alba (English)"
  mkdir -p "$VOICES"
  local f="$VOICES/en_GB-alba-medium.onnx"
  if [ -s "$f" ] && [ -s "$f.json" ]; then ok "Alba already installed"; return; fi
  local url="$PIPER_BASE/en/en_GB/alba/medium/en_GB-alba-medium"
  say "Downloading Alba (~63 MB)…"
  curl -fL --progress-bar -o "$f.json" "$url.onnx.json" || die \
    "Alba config download failed (network?)." "check your connection, then re-run ./setup.sh"
  curl -fL --progress-bar -o "$f" "$url.onnx" || die \
    "Alba voice download failed (network?)." "check your connection, then re-run ./setup.sh"
  ok "Alba installed. Add the other 15 languages later with:  ./setup.sh voices-all"
}

# ── Optional: full 16-language voice bench (explicit, later) ─────────────────
voices_all() {
  say "Full multilingual voice bench (~1 GB)"
  mkdir -p "$VOICES"; cd "$VOICES"
  local V=(
    "de/de_DE/thorsten/medium|de_DE-thorsten-medium" "es/es_ES/davefx/medium|es_ES-davefx-medium"
    "fr/fr_FR/siwis/medium|fr_FR-siwis-medium"       "it/it_IT/riccardo/x_low|it_IT-riccardo-x_low"
    "pl/pl_PL/gosia/medium|pl_PL-gosia-medium"       "ru/ru_RU/irina/medium|ru_RU-irina-medium"
    "pt/pt_BR/cadu/medium|pt_BR-cadu-medium"         "nl/nl_BE/nathalie/medium|nl_BE-nathalie-medium"
    "uk/uk_UA/ukrainian_tts/medium|uk_UA-ukrainian_tts-medium" "tr/tr_TR/dfki/medium|tr_TR-dfki-medium"
    "ar/ar_JO/kareem/medium|ar_JO-kareem-medium"     "hi/hi_IN/pratham/medium|hi_IN-pratham-medium"
    "sv/sv_SE/alma/medium|sv_SE-alma-medium"         "vi/vi_VN/vais1000/medium|vi_VN-vais1000-medium"
    "zh/zh_CN/huayan/medium|zh_CN-huayan-medium"
  )
  for v in "${V[@]}"; do
    local rel="${v%%|*}" fn="${v##*|}"
    [ -s "$fn.onnx" ] && { ok "$fn (present)"; continue; }
    curl -fL --progress-bar -o "$fn.onnx.json" "$PIPER_BASE/$rel/$fn.onnx.json" && \
    curl -fL --progress-bar -o "$fn.onnx"      "$PIPER_BASE/$rel/$fn.onnx"      && ok "$fn" || warn "$fn skipped"
  done
  cd "$REPO"
}

# ── Whisper — smallest sane default (base) ──────────────────────────────────
setup_whisper() {
  say "Speech-to-text model — Whisper 'base' (small, upgradeable)"
  if .venv/bin/python - <<'PY' >/dev/null 2>&1
from pywhispercpp.model import Model
Model("base")   # downloads ggml-base.bin if absent; no-op if cached
PY
  then ok "Whisper 'base' ready (upgrade later via PH3B3_WHISPER_MODEL in .env)"
  else warn "Couldn't pre-fetch Whisper 'base' — it will download on your first voice use instead."
  fi
}

# ── .env — generate once, print the password once ───────────────────────────
_gen_pass() {
  .venv/bin/python - <<'PY' 2>/dev/null || (head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24)
import secrets; print(secrets.token_urlsafe(18))
PY
}

setup_dotenv() {
  say "Configuration — .env"
  if [ -f .env ] && grep -qE '^PH3B3_PASSWORD=.+' .env; then
    ok ".env already configured — leaving it (and your password) untouched"; return
  fi
  [ -f .env ] || cp .env.example .env
  local user="phoebe" pass; pass="$(_gen_pass)"
  sed -i "s|^PH3B3_USER=.*|PH3B3_USER=$user|"                 .env
  sed -i "s|^PH3B3_PASSWORD=.*|PH3B3_PASSWORD=$pass|"         .env
  sed -i "s|^PH3B3_WHISPER_MODEL=.*|PH3B3_WHISPER_MODEL=base|" .env
  ok "wrote .env (web access stays OFF by default)"
  printf "\n\033[1;33m  ┌───────────  SAVE THIS — your login (shown once)  ───────────┐\033[0m\n"
  printf "\033[1;33m  │\033[0m   username:  \033[1m%s\033[0m\n" "$user"
  printf "\033[1;33m  │\033[0m   password:  \033[1m%s\033[0m\n" "$pass"
  printf "\033[1;33m  └─────────────────────────────────────────────────────────────┘\033[0m\n"
}

# ── Dispatcher ──────────────────────────────────────────────────────────────
case "${1:-all}" in
  system)     setup_system ;;
  env)        setup_system; setup_env ;;
  voice)      setup_voice ;;
  voices-all) voices_all ;;
  whisper)    setup_env; setup_whisper ;;
  dotenv)     setup_env; setup_dotenv ;;
  all)        setup_system; setup_env; setup_voice; setup_whisper; setup_dotenv
              printf "\n\033[1;32m✓ Linux-side setup complete.\033[0m\n" ;;
  *)          die "unknown step '$1'" "run:  ./setup.sh   (or: env | voice | voices-all | whisper | dotenv)" ;;
esac

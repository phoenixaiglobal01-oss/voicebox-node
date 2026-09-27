#!/bin/bash
# Phoenix VoiceBox — pod bootstrap.
#
# Installs and starts the voice synthesis / cloning service on port 8005.
# Designed to run automatically at pod start (via the RunPod template's
# start command) or manually from the pod's web terminal:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/phoenixaiglobal01-oss/voicebox-node/main/pod-init.sh)
#
# Idempotent: if the service is already healthy, it exits without doing anything.
# Requires VOICEBOX_API_KEY in the environment (set by the RunPod template).
set -u

# Isolate from any venv activated in the calling shell (e.g. the pod's
# .venv-cu128): a leaked PYTHONPATH would expose numpy-2-only packages
# (opencv, scipy, contourpy) inside our isolated venv and break pip's
# dependency resolution for chatterbox-tts (needs numpy<2).
unset PYTHONPATH PYTHONHOME VIRTUAL_ENV

APP_DIR=/opt/voicebox
LOG=/var/log/voicebox.log
mkdir -p "$APP_DIR"
touch "$LOG" 2>/dev/null || LOG="$APP_DIR/voicebox.log"

ts() { date -u +%FT%TZ; }

# Already running? Nothing to do.
if curl -fsS --max-time 5 \
    -H "X-API-Key: ${VOICEBOX_API_KEY:-__none__}" \
    http://127.0.0.1:8005/v1/voicebox/health >/dev/null 2>&1; then
  echo "$(ts) voicebox already running — skipping install" >> "$LOG"
  exit 0
fi

if [ -z "${VOICEBOX_API_KEY:-}" ]; then
  echo "$(ts) ERROR: VOICEBOX_API_KEY is not set — refusing to start voicebox without auth" >> "$LOG"
  exit 1
fi

# System dependency: ffmpeg (mp3 encoding). Best-effort on slim images.
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "$(ts) installing ffmpeg ..." >> "$LOG"
  (apt-get update -qq && apt-get install -y -qq ffmpeg) >> "$LOG" 2>&1 || true
fi
if ! command -v curl >/dev/null 2>&1; then
  (apt-get update -qq && apt-get install -y -qq curl) >> "$LOG" 2>&1 || true
fi

# Latest service code (public repo).
echo "$(ts) downloading voicebox app ..." >> "$LOG"
curl -fsSL https://raw.githubusercontent.com/phoenixaiglobal01-oss/voicebox-node/main/app.py \
  -o "$APP_DIR/app.py" || { echo "$(ts) ERROR: app.py download failed" >> "$LOG"; exit 1; }

# Python dependencies. torch is usually pre-installed in RunPod CUDA images;
# pip skips anything already satisfied. chatterbox-tts pulls torchaudio.
# Isolated venv: the pod's main env ships numpy-2-only packages (opencv,
# scipy, contourpy) that conflict with chatterbox-tts (needs numpy<2).
# STRATEGY: use the system Python (ships working CUDA torch for ComfyUI).
# The isolated venv cannot resolve torch/chatterbox pins on this pod, so we
# install chatterbox-tts with --no-deps (pip never sees its broken pin set)
# plus only the runtime libraries the multilingual TTS path actually imports.
# --no-deps everywhere except the web server: nothing upgrades torch, numpy,
# scipy or opencv, so ComfyUI is untouched.
echo "$(ts) installing chatterbox-tts into system env (no-deps) ..." >> "$LOG"
python3 -m pip install --quiet --disable-pip-version-check --no-deps \
  "chatterbox-tts==0.1.7" \
  >> "$LOG" 2>&1 || { echo "$(ts) ERROR: chatterbox install failed" >> "$LOG"; exit 1; }

# Runtime libs WITH their own deps (only chatterbox-tts itself is --no-deps):
# librosa hard-requires lazy_loader, transformers needs tokenizers, etc.
echo "$(ts) installing chatterbox runtime libraries ..." >> "$LOG"
python3 -m pip install --quiet --disable-pip-version-check \
  "transformers" "tokenizers" "diffusers" "librosa" \
  "safetensors" "huggingface_hub" "einops" "omegaconf" "tqdm" \
  "conformer" "s3tokenizer" "resemble-perth" \
  >> "$LOG" 2>&1 || { echo "$(ts) ERROR: runtime libs install failed" >> "$LOG"; exit 1; }

echo "$(ts) installing web server dependencies ..." >> "$LOG"
python3 -m pip install --quiet --disable-pip-version-check \
  "fastapi>=0.110" "uvicorn[standard]>=0.29" "requests>=2.31" \
  >> "$LOG" 2>&1 || { echo "$(ts) ERROR: web deps install failed" >> "$LOG"; exit 1; }

# The service runs on the system python (no venv).
VPY="python3"

# Sanity check: the import the app needs must work.
echo "$(ts) verifying chatterbox import ..." >> "$LOG"
"$VPY" -c "from chatterbox.mtl_tts import ChatterboxMultilingualTTS; print('import OK')" \
  >> "$LOG" 2>&1 || { echo "$(ts) ERROR: chatterbox import failed" >> "$LOG"; exit 1; }

# Dependencies are in: mark the bootstrap complete so future runs reuse the venv.
touch "$MARKER"

# Start detached — survives this script exiting and the container's main process.
cd "$APP_DIR"
setsid nohup env VOICEBOX_API_KEY="$VOICEBOX_API_KEY" \
  "$VPY" -m uvicorn app:app --host 0.0.0.0 --port 8005 \
  >> "$LOG" 2>&1 < /dev/null &
echo "$(ts) voicebox starting (pid $!), logs at $LOG" >> "$LOG"
echo "VoiceBox starting on :8005 — check $LOG; /v1/voicebox/health turns ready once the model loads."

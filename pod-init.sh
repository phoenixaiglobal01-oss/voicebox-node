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
# A dedicated venv keeps the voice deps fully isolated from ComfyUI's env.
VENV="$APP_DIR/venv"
MARKER="$APP_DIR/.bootstrap-complete"
# A previous run that failed halfway leaves a broken venv: wipe it so the
# retry starts clean. A successful run leaves the marker behind.
if [ ! -f "$MARKER" ] && [ -d "$VENV" ]; then
  echo "$(ts) removing incomplete venv from a failed run ..." >> "$LOG"
  rm -rf "$VENV"
fi
if [ ! -x "$VENV/bin/python" ]; then
  echo "$(ts) creating isolated venv at $VENV ..." >> "$LOG"
  if ! python3 -m venv "$VENV" >> "$LOG" 2>&1; then
    echo "$(ts) venv failed, installing python3-venv ..." >> "$LOG"
    (apt-get update -qq && apt-get install -y -qq python3-venv) >> "$LOG" 2>&1 || true
    python3 -m venv "$VENV" >> "$LOG" 2>&1 || { echo "$(ts) ERROR: venv creation failed" >> "$LOG"; exit 1; }
  fi
fi
VPY="$VENV/bin/python"

# Upgrade the installer toolchain first: the base image ships an old setuptools
# whose pkg_resources breaks on Python 3.12 (AttributeError: module 'pkgutil'
# has no attribute 'ImpImporter'), which kills building numpy from source.
echo "$(ts) upgrading pip/setuptools/wheel ..." >> "$LOG"
"$VPY" -m pip install --quiet --disable-pip-version-check --upgrade \
  pip setuptools wheel >> "$LOG" 2>&1 || true

# Install numpy from a prebuilt wheel FIRST and forbid source builds for it:
# this pod's toolchain insists on building numpy from source, which fails on
# Python 3.12 (pkgutil.ImpImporter removed). A prebuilt numpy satisfies every
# dependent (incl. chatterbox-tts) so pip never tries to compile it.
echo "$(ts) installing numpy (prebuilt wheel, no source build) ..." >> "$LOG"
"$VPY" -m pip install --quiet --disable-pip-version-check --only-binary=numpy \
  "numpy>=1.26,<2" >> "$LOG" 2>&1 || { echo "$(ts) ERROR: numpy install failed" >> "$LOG"; exit 1; }

echo "$(ts) installing torch (pinned for chatterbox, a few minutes) ..." >> "$LOG"
"$VPY" -m pip install --quiet --disable-pip-version-check \
  "torch==2.6.0" "torchaudio==2.6.0" \
  >> "$LOG" 2>&1 || { echo "$(ts) ERROR: torch install failed" >> "$LOG"; exit 1; }

# chatterbox-tts's pinned dependency set cannot be resolved by pip on this
# pod (ResolutionImpossible across all 0.1.x). Install it WITHOUT deps and
# add only the runtime libraries its multilingual TTS path actually imports.
# (Skips gradio web UI, pykakasi/spacy-pkuseg language extras, pyloudnorm.)
echo "$(ts) installing chatterbox-tts (no-deps, bypassing broken resolver) ..." >> "$LOG"
"$VPY" -m pip install --quiet --disable-pip-version-check --no-deps \
  "chatterbox-tts==0.1.7" \
  >> "$LOG" 2>&1 || { echo "$(ts) ERROR: chatterbox install failed" >> "$LOG"; exit 1; }

echo "$(ts) installing chatterbox runtime libraries ..." >> "$LOG"
"$VPY" -m pip install --quiet --disable-pip-version-check --only-binary=numpy \
  "transformers==5.2.0" "tokenizers" "diffusers==0.29.0" "librosa==0.11.0" \
  "safetensors==0.5.3" "huggingface_hub" "einops" "omegaconf" "tqdm" \
  "conformer==0.3.2" "s3tokenizer" "resemble-perth" "scipy" \
  >> "$LOG" 2>&1 || { echo "$(ts) ERROR: runtime libs install failed" >> "$LOG"; exit 1; }

echo "$(ts) installing web server dependencies ..." >> "$LOG"
"$VPY" -m pip install --quiet --disable-pip-version-check \
  "fastapi>=0.110" "uvicorn[standard]>=0.29" "requests>=2.31" \
  >> "$LOG" 2>&1 || { echo "$(ts) ERROR: web deps install failed" >> "$LOG"; exit 1; }

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

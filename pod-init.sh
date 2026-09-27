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
# Upgrade the installer toolchain first: the base image ships an old setuptools
# whose pkg_resources breaks on Python 3.12 (AttributeError: module 'pkgutil'
# has no attribute 'ImpImporter'), which kills building numpy from source.
echo "$(ts) upgrading pip/setuptools/wheel ..." >> "$LOG"
python3 -m pip install --quiet --disable-pip-version-check --upgrade \
  pip setuptools wheel >> "$LOG" 2>&1 || true

# Install numpy from a prebuilt wheel FIRST and forbid source builds for it:
# this pod's toolchain insists on building numpy from source, which fails on
# Python 3.12 (pkgutil.ImpImporter removed). A prebuilt numpy satisfies every
# dependent (incl. chatterbox-tts) so pip never tries to compile it.
echo "$(ts) installing numpy (prebuilt wheel, no source build) ..." >> "$LOG"
python3 -m pip install --quiet --disable-pip-version-check --only-binary=numpy \
  "numpy>=1.26,<2" >> "$LOG" 2>&1 || { echo "$(ts) ERROR: numpy install failed" >> "$LOG"; exit 1; }

echo "$(ts) installing python dependencies (a few minutes on first boot) ..." >> "$LOG"
python3 -m pip install --quiet --disable-pip-version-check --only-binary=numpy \
  "fastapi>=0.110" "uvicorn[standard]>=0.29" "requests>=2.31" "chatterbox-tts" \
  >> "$LOG" 2>&1 || { echo "$(ts) ERROR: pip install failed" >> "$LOG"; exit 1; }

# Start detached — survives this script exiting and the container's main process.
cd "$APP_DIR"
setsid nohup env VOICEBOX_API_KEY="$VOICEBOX_API_KEY" \
  python3 -m uvicorn app:app --host 0.0.0.0 --port 8005 \
  >> "$LOG" 2>&1 < /dev/null &
echo "$(ts) voicebox starting (pid $!), logs at $LOG" >> "$LOG"
echo "VoiceBox starting on :8005 — check $LOG; /v1/voicebox/health turns ready once the model loads."

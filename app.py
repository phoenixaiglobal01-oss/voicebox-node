"""
VoiceBox node service — self-hosted open-source voice-cloning TTS for Phoenix.

Wraps genuinely open engines (Chatterbox Multilingual, MIT — more engines can
be added behind the same contract) and exposes the Phoenix node contract:

  GET  /health -> { ready, error?, gpu?, engines?, model? }
  POST /tts    -> { text, language, voice?, style?, speed?, format?, destination? }
  POST /clone  -> { voice_id, sample_url, language, transcript? }

Auth: every request must carry `X-API-Key: $VOICEBOX_API_KEY`
(constant-time compare). There is no anonymous mode — this service must never
be exposed to the public internet; it sits behind the Phoenix platform, which
owns auth, billing and the voice-cloning consent gate.

Notes / honest limits:
- Meta never open-sourced its Voicebox research model; this service does NOT
  run Meta's model. It runs the open-source zero-shot cloning stack
  (Chatterbox Multilingual V3, MIT) that the viral "Meta VoiceBox" carousel
  actually describes.
- `style` is accepted and logged but Chatterbox-MTL has no style-prompt
  input; `speed` is applied as a tempo filter at encode time (best-effort).
- First synthesis downloads ~500 MB of weights from Hugging Face; /health
  reports ready=false until the model is loaded so the platform fails over
  cleanly instead of hanging.
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import os
import subprocess
import tempfile
import threading
import time
from pathlib import Path

import requests
from fastapi import FastAPI, Header, HTTPException, Request, Response

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("voicebox-node")

API_KEY = os.environ.get("VOICEBOX_API_KEY", "").strip()
if not API_KEY:
    raise SystemExit("VOICEBOX_API_KEY is required — refusing to start without auth")

VOICES_DIR = Path(os.environ.get("VOICEBOX_VOICES_DIR", "/data/voices"))
VOICES_DIR.mkdir(parents=True, exist_ok=True)
DEVICE = os.environ.get("VOICEBOX_DEVICE", "cuda")
ENGINE_ID = "chatterbox-mtl"

# Phoenix language subtag -> Chatterbox-MTL language_id. Chatterbox-MTL uses
# ISO 639-1 ids; anything unmapped falls back to English rather than failing.
LANGUAGE_IDS = {"pt", "en", "es", "fr", "de", "it", "ja", "ko", "zh"}

_model = None
_model_error: str | None = None
_model_lock = threading.Lock()


def check_auth(x_api_key: str | None) -> None:
    if not x_api_key or not hmac.compare_digest(x_api_key, API_KEY):
        raise HTTPException(status_code=401, detail="invalid api key")


def gpu_name() -> str | None:
    try:
        import torch

        if torch.cuda.is_available():
            return torch.cuda.get_device_name(0)
    except Exception:
        pass
    return None


def get_model():
    """Lazy-load the TTS engine on first use (thread-safe)."""
    global _model, _model_error
    with _model_lock:
        if _model is not None or _model_error is not None:
            return _model
        try:
            log.info("loading %s on %s ...", ENGINE_ID, DEVICE)
            from chatterbox.mtl_tts import ChatterboxMultilingualTTS

            _model = ChatterboxMultilingualTTS.from_pretrained(device=DEVICE)
            log.info("model loaded (sr=%s)", _model.sr)
        except Exception as exc:  # noqa: BLE001 — surfaced via /health
            _model_error = f"{type(exc).__name__}: {exc}"
            log.exception("model load failed")
        return _model


def resolve_prompt(voice: str | None) -> str | None:
    """A cloned voice id maps to its stored reference sample."""
    if not voice:
        return None
    # Only accept safe ids (the platform mints UUIDs); never path-traverse.
    if not voice.replace("-", "").replace("_", "").isalnum():
        return None
    for ext in (".wav", ".mp3", ".ogg", ".m4a"):
        candidate = VOICES_DIR / f"{voice}{ext}"
        if candidate.is_file():
            return str(candidate)
    return None


def synth_wav(text: str, language: str, voice: str | None, style: str | None):
    import torch

    model = get_model()
    if model is None:
        raise HTTPException(status_code=503, detail=f"model not loaded: {_model_error}")
    lang = language.lower().split("-")[0]
    if lang not in LANGUAGE_IDS:
        log.warning("language %s not mapped, falling back to en", language)
        lang = "en"
    if style:
        log.info("style prompt received (not consumed by engine): %s", style[:120])
    prompt = resolve_prompt(voice)
    wav = model.generate(text, audio_prompt_path=prompt, language_id=lang)
    if isinstance(wav, torch.Tensor):
        wav = wav.detach().cpu()
    return wav, model.sr


def wav_to_mp3(wav, sr: int, speed: float) -> tuple[bytes, float]:
    """Encode to mp3 via ffmpeg, applying tempo for speed (best-effort)."""
    import torchaudio

    with tempfile.TemporaryDirectory() as tmp:
        wav_path = os.path.join(tmp, "in.wav")
        mp3_path = os.path.join(tmp, "out.mp3")
        torchaudio.save(wav_path, wav.unsqueeze(0) if wav.dim() == 1 else wav, sr)
        tempo = max(0.5, min(2.0, speed or 1.0))
        # atempo only accepts 0.5–2.0 per filter; chain for safety.
        filters = []
        remaining = tempo
        while remaining > 2.0:
            filters.append("atempo=2.0")
            remaining /= 2.0
        while remaining < 0.5:
            filters.append("atempo=0.5")
            remaining /= 0.5
        filters.append(f"atempo={remaining:.3f}")
        cmd = [
            "ffmpeg", "-y", "-v", "error", "-i", wav_path,
            "-filter:a", ",".join(filters), "-codec:a", "libmp3lame",
            "-b:a", "128k", mp3_path,
        ]
        subprocess.run(cmd, check=True, timeout=300)
        data = Path(mp3_path).read_bytes()
    duration = wav.shape[-1] / sr / tempo
    return data, duration


app = FastAPI(title="Phoenix VoiceBox node", version="1.0.0")


@app.get("/health")
def health(x_api_key: str | None = Header(default=None)):
    check_auth(x_api_key)
    get_model()  # trigger background-safe lazy load attempt once
    ready = _model is not None
    return {
        "ready": ready,
        "error": None if ready else (_model_error or "model loading"),
        "gpu": gpu_name(),
        "engines": [ENGINE_ID] if ready else [],
        "model": "ResembleAI/chatterbox (multilingual)" if ready else None,
    }


@app.post("/tts")
async def tts(request: Request, x_api_key: str | None = Header(default=None)):
    check_auth(x_api_key)
    t0 = time.time()
    body = await request.json()
    text = str(body.get("text") or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="text is required")
    language = str(body.get("language") or "en")
    voice = body.get("voice")
    style = body.get("style")
    try:
        speed = float(body.get("speed") or 1.0)
    except (TypeError, ValueError):
        speed = 1.0

    wav, sr = synth_wav(text, language, voice, style)
    audio, duration = wav_to_mp3(wav, sr, speed)
    latency_ms = int((time.time() - t0) * 1000)

    dest = body.get("destination") or {}
    dest_url = dest.get("url")
    if dest_url:
        # The platform gave us a pre-signed upload destination: deliver there.
        method = (dest.get("method") or "PUT").upper()
        resp = requests.request(
            method, dest_url, data=audio,
            headers={"Content-Type": "audio/mpeg", **(dest.get("headers") or {})},
            timeout=120,
        )
        resp.raise_for_status()
        return {"bytes": len(audio), "duration_seconds": duration, "latency_ms": latency_ms}

    # Direct playback: mp3 bytes in the response body.
    return Response(
        content=audio,
        media_type="audio/mpeg",
        headers={"X-Phoenix-Duration-Seconds": f"{duration:.2f}"},
    )


@app.post("/clone")
async def clone(request: Request, x_api_key: str | None = Header(default=None)):
    check_auth(x_api_key)
    body = await request.json()
    voice_id = str(body.get("voice_id") or "").strip()
    sample_url = str(body.get("sample_url") or "").strip()
    if not voice_id or not sample_url:
        raise HTTPException(status_code=400, detail="voice_id and sample_url are required")
    if not voice_id.replace("-", "").replace("_", "").isalnum():
        raise HTTPException(status_code=400, detail="invalid voice_id")

    # Fetch the reference sample (signed platform URL). Bounded: max ~20 MB.
    resp = requests.get(sample_url, timeout=60, stream=True)
    resp.raise_for_status()
    digest = hashlib.sha256()
    size = 0
    chunks: list[bytes] = []
    for chunk in resp.iter_content(65536):
        size += len(chunk)
        if size > 20 * 1024 * 1024:
            raise HTTPException(status_code=413, detail="sample too large")
        digest.update(chunk)
        chunks.append(chunk)
    if size < 4096:
        raise HTTPException(status_code=400, detail="sample too short")

    content_type = resp.headers.get("content-type", "")
    ext = ".wav"
    for probe, extension in (("wav", ".wav"), ("mpeg", ".mp3"), ("ogg", ".ogg"), ("mp4", ".m4a")):
        if probe in content_type:
            ext = extension
            break
    target = VOICES_DIR / f"{voice_id}{ext}"
    target.write_bytes(b"".join(chunks))
    log.info("stored clone sample %s (%d bytes, sha256 %.8s)", target, size, digest.hexdigest())
    return {"voice_id": voice_id, "stored": True}


# ---------------------------------------------------------------------------
# Platform contract: the Phoenix adapter reaches this service under the
# /v1/voicebox prefix (see src/lib/voice/voicebox.server.ts candidates()).
# Serve the same routes at both the prefixed path and the root so direct
# health probes keep working. `uvicorn app:app` keeps serving this module.
# ---------------------------------------------------------------------------
_prefixed = FastAPI(title="Phoenix VoiceBox node")
_prefixed.mount("/v1/voicebox", app)
_prefixed.mount("/", app)
app = _prefixed

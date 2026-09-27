# voicebox-node

Open-source GPU voice synthesis and voice-cloning service for
[Phoenix AI Global](https://phoenixaiglobal.com).

It wraps genuinely open engines — **Chatterbox Multilingual V3** (MIT license)
today, more engines can be added behind the same contract — and exposes the
Phoenix node contract:

| Method | Path     | Description                              |
| ------ | -------- | ---------------------------------------- |
| GET    | `/health`| `{ ready, error?, gpu?, engines?, model? }` |
| POST   | `/tts`   | Synthesize speech (mp3), optional cloned voice |
| POST   | `/clone` | Store a reference sample under a `voice_id` |

The same routes are also served under the `/v1/voicebox` prefix
(e.g. `/v1/voicebox/health`), which is how the Phoenix platform reaches it.

**Auth:** every request must carry `X-API-Key: $VOICEBOX_API_KEY`
(constant-time compare). The service refuses to start without the key.
It must never be exposed to the public internet — it sits behind the
Phoenix platform, which owns auth, billing and the voice-cloning consent gate.

**Honest note:** Meta never open-sourced its 2023 Voicebox research model.
This service does not run Meta's model — it runs the open-source zero-shot
cloning stack (Chatterbox Multilingual, MIT) that viral "Meta VoiceBox"
carousels actually describe.

## Run on a RunPod pod

One command (needs `VOICEBOX_API_KEY` in the environment):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/phoenixaiglobal01-oss/voicebox-node/main/pod-init.sh)
```

Or let the [Phoenix RunPod template](https://github.com/phoenixaiglobal01-oss/phoenix-sales-pilot)
do it automatically at pod start — any GPU (A6000, H100, H200, …) that the
template boots gets the voice service on port `8005` with zero manual steps.

First synthesis downloads ~500 MB of weights from Hugging Face;
`/health` reports `ready: false` until the model is loaded so callers can
fail over cleanly instead of hanging.

## Local dev

```bash
pip install fastapi "uvicorn[standard]" requests chatterbox-tts
VOICEBOX_API_KEY=dev-key python -m uvicorn app:app --port 8005
curl -H "X-API-Key: dev-key" localhost:8005/v1/voicebox/health
```

## License

MIT — see `app.py` header. Engine weights follow their own licenses
(Chatterbox: MIT).

# Arthur

Arthur is my personal silicon assistant — local-first and available on the desktop via a MacOS app and through an experimental hardware device that share the same conversational memory.

This repository is the voice layer: capture, speech, devices, and the spoken reply. The spoken-agent definition is [`config/arthur.agent.json`](config/arthur.agent.json).

STT and TTS run on the machine that hosts Intercom. [whisper.cpp](https://github.com/ggerganov/whisper.cpp) transcribes, [Kokoro](https://github.com/hexgrad/kokoro) speaks, and [Arbiter](https://github.com/tylerreckart/arbiter) handles reasoning.

```
Input ─┐
       │  PCM up while you hold talk
       ├─ ws://…:8093/v1/stream ── Intercom daemon (this repo)
       │  PCM down as Arthur answers      │
       │                                  ├── whisper.cpp  STT
       │                                  ├── Kokoro       TTS
       │                                  └── SQLite sessions
       │                                          │
       └──────── HTTP :8090 fallback ─────────────┤
                                                  │
                                            Arbiter :8080
                                              text + SSE
```

Hold talk, speak, release. The device streams 24 kHz mono s16le while the button is down, then sends `{"type":"end"}`. Intercom runs Whisper on the clip, then either answers locally (greetings, time, a few home commands) or sends the transcript to Arbiter. Kokoro starts speaking as sentences arrive; the same socket plays the PCM back. Idle sockets also take unsolicited speak-back — a scheduled reminder, spoken without another press.

Intercom maps each `X-Device-Id` to one Arbiter conversation in SQLite (`session_db`). In the Mac app, pick the hallway device so the desk and the wall button share that memory.

## Components

**Intercom daemon** — HTTP on `:8090` (`POST /v1/utterance`, health, cancel) and a WebSocket hub on `:8093` (`/v1/stream`). It owns STT, TTS, the turn pipeline, device sessions, optional Home Assistant fast-path, and speak-back from Arbiter’s notification stream.

**Mac desk app** (`macos/Arthur`) — a native SwiftUI window that uses the same WebSocket, `device_token`, and device id for shared conversation memory.

**Hardware device** (`firmware/`, `hardware/`) — a thin audio endpoint, not the brain. Firmware for an ESP32-S3 (Arduino Nano ESP32 or a board with the same pin map) plus I2S mic (INMP441) and amp (MAX98357A) lives in `firmware/nano-esp32/intercom-endpoint`.

Weather (home via Home Assistant, or any city via Open-Meteo), news (Google News RSS / configured feeds), and markets (Yahoo public quotes) each speak a short line and emit a versioned `{type:surface}` card on the desk WebSocket. Voice-only devices ignore `surface`. See [`docs/api.md`](docs/api.md).

## Build

**Daemon** needs C++20, CMake 3.20+, SQLite3, OpenSSL, and Threads. It fetches cpp-httplib and nlohmann/json.

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

**Mac app** (Apple Silicon, macOS 26+):

```bash
macos/Arthur/build.sh
open macos/Arthur/dist/Arthur.app
```

Speech tools are not vendored. Install them separately and point `intercom.json` at the binaries and models:

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — `whisper-cli`, `whisper-server`, and `ggml-base.en.bin`
- [Kokoro](https://github.com/hexgrad/kokoro) — `kokoro-tts` plus the ONNX model and voices bundle. Intercom starts [`scripts/kokoro_server.py`](scripts/kokoro_server.py) from that venv unless you already have a server running.

## Configure and run

Run Intercom beside `arbiter --api` on the same host.

```bash
cp config/intercom.example.json intercom.json
# also keep config/arthur.agent.json where agent_def can find it
# (same directory as intercom.json, or set agent_def to config/arthur.agent.json)
```

A local `intercom.json` is gitignored. Set at least:

- `arbiter_token` — Arbiter `atr_…` token (`arbiter_base_url` defaults to `http://127.0.0.1:8080`)
- `device_token` — bearer the wall button and Mac app send (not the Arbiter token)
- `whisper.binary` / `whisper.model` and `kokoro.binary` / `kokoro.model` / `kokoro.voices`

Then:

```bash
./build/intercom --config intercom.json
```

Default ports, all on `listen_host` (example config uses `0.0.0.0`):

| Port | Role |
|------|------|
| 8090 | HTTP: health, utterance, cancel |
| 8093 | WebSocket duplex (set `ws_listen_port` to `0` to disable) |
| 8092 | Warm `whisper-server` (spawned unless `whisper.server_url` is set) |
| 8091 | Warm Kokoro (`scripts/kokoro_server.py`, same for `kokoro.server_url`) |

`GET /health` is ready when Whisper and Kokoro are up; Arbiter may still be down. Set `whisper.use_server` / `kokoro.use_server` to `false` to force the one-shot CLI path.

Optional `home` block: when `ha_base_url` and `ha_token` are set, hallway phrases for lights, volume, weather at home, timers, and the next alarm skip Arbiter. Optional `news` and `markets` blocks configure RSS feeds and the quote host; both work without API keys (see `config/intercom.example.json`).

**Firmware.** Copy Wi-Fi and token into `firmware/nano-esp32/intercom-endpoint/secrets.h` (gitignored) or edit [`config.h`](firmware/nano-esp32/intercom-endpoint/config.h). `INTERCOM_HOST` must be the LAN address of the Intercom machine — not `127.0.0.1`. WebSocket is on `INTERCOM_WS_PORT` (8093); set it to `0` for HTTP-only. Flash the sketch in `firmware/nano-esp32/intercom-endpoint`. Contract: [`docs/device.md`](docs/device.md).

**Mac.** Settings load host, ports, and `device_token` from `intercom.json`. Choose the hallway device under Shared memory so this Mac and the wall button keep one conversation. Default global talk shortcut is ⌥Space (change it under Push to talk). Microphone permission is required to speak. Quiet text mode (Arthur menu or Settings → Typing) stops Space from starting push-to-talk so the composer is safe to type in; the global shortcut and menu bar extra still talk.

### Voice

Shipped `kokoro.voice` is `af_nova:0.6+af_nicole:0.3+af_heart:0.1` (language from the heaviest name prefix — `af_` → `en-us`). A single Kokoro name (`bm_lewis`) or a `+`-separated blend both work; weights are optional and normalized. Existing local `intercom.json` files are not overwritten — change `kokoro.voice` there if you want the new default. Blend syntax and speech DSP live in [`docs/api.md`](docs/api.md).

## Docs

- [`docs/api.md`](docs/api.md) — HTTP and WebSocket contract, Arbiter mapping, speak-back, Kokoro
- [`docs/device.md`](docs/device.md) — PCM format, PTT flow, ESP32 endpoint, colocation
- [`config/intercom.example.json`](config/intercom.example.json) — daemon config
- [`config/arthur.agent.json`](config/arthur.agent.json) — spoken-agent definition

## License

Apache-2.0

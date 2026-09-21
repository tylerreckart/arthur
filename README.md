# Intercom

A custom, local-first **voice bridge** for [Arbiter](https://arbiter.run): ESP32 (or any client) speaks PCM in, Intercom runs **whisper.cpp** STT + **Kokoro** TTS, and Arbiter stays text + SSE in the middle.

![PCB Board Front](.github/board_front.jpg)

```
ESP32  --WS PCM while PTT held-->  Intercom  --text/SSE-->  arbiter --api
ESP32  <--WS reply PCM-----------  Intercom  <--text------/
```

HTTP `POST /v1/utterance` on `:8090` remains the fallback if the WebSocket is down.

Intercom keeps Whisper and Kokoro loaded in local HTTP servers (`whisper-server` on `:8092`, `scripts/kokoro_server.py` on `:8091`) so each turn does not reload ONNX/ggml. Instant-ack phrases (`Yes, sir.`, `Of course.`, `Very good.`, …) are synthesized once at startup and replayed from PCM cache — including a local ack after `filler.instant_ack_ms` and an earlier tool ack after `filler.tool_ack_ms`. Spoken replies can start after about seven words (`early_flush_words`), not only at a period. Optional WebSocket duplex is `ws://<host>:8093/v1/stream`. Each turn logs a single `intercom latency …` line (`stt_ms`, `arbiter_ttft_ms`, `kokoro_ms`, `ttfa_ms`).

Colocate Intercom on the same host as `arbiter --api` (default `http://127.0.0.1:8080`). Device tokens never see the Arbiter bearer.

The default agent is **Arthur** — a British voice assistant with full Arbiter tool access (`config/arthur.agent.json`). Hallway commands (timers, lights, volume, home weather, next alarm) skip Arbiter when `home.ha_base_url` and `home.ha_token` point at Home Assistant. At boot Intercom sends a silent `PREFIX WARM` turn so a local model can cache Arthur's constitution before the first PTT. Completed `/schedule` runs are spoken back on the idle WebSocket (see `speakback` in `intercom.json` and [docs/api.md](docs/api.md#speak-back-scheduled-reminders)).

## Build

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

Requires C++20, CMake 3.20+, SQLite3, Threads. Fetches cpp-httplib and nlohmann/json.

## Configure

```bash
cp config/intercom.example.json intercom.json
# set arbiter_token, paths to whisper-cli + model, kokoro binary + voice
./build/intercom --config intercom.json
```

Install speech tools separately (not vendored):

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) → `whisper-cli` + `whisper-server` + `ggml-base.en.bin`
- [Kokoro](https://github.com/hexgrad/kokoro) → `kokoro-tts` + ONNX model and voices bundle (Intercom starts `scripts/kokoro_server.py` with that venv)

Set `whisper.use_server` / `kokoro.use_server` to `false` to force the old one-shot CLI path. Point `server_url` at an already-running daemon to skip spawn.

## Quick test (no mic)

Fast-path (skips Arbiter):

```bash
curl -N -H "Authorization: Bearer dev-device-secret-change-me" \
  -H "X-Device-Id: speaker-1" \
  -H "Content-Type: application/json" \
  -d '{"text":"what time is it"}' \
  --output reply.pcm \
  http://127.0.0.1:8090/v1/utterance/text
```

Play: `ffplay -f s16le -ar 16000 -ac 1 reply.pcm`

PCM utterance: see [docs/api.md](docs/api.md) and [docs/device.md](docs/device.md).

## License

Apache-2.0

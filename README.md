# Arthur

A custom, local-first voice assistant built against my personal orchestration harness. An ESP32 can send PCM in, Arthur runs **whisper.cpp** STT + **Kokoro** TTS, and Arbiter stays text + SSE in the middle.

![PCB Board Front](.github/board_front.jpg)

HTTP `POST /v1/utterance` on `:8090` remains the fallback if the WebSocket is down.

A native Mac desk app lives in `macos/Arthur`. It speaks through the same WebSocket and `device_token` as the hardware device, and defaults to that device’s `X-Device-Id` so Arthur’s conversation memory is shared.

```bash
macos/Arthur/build.sh
open macos/Arthur/dist/Arthur.app
```

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

## License

Apache-2.0

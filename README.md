# Arthur

A custom, local-first voice assistant. An ESP32 can send PCM in, Arthur runs **whisper.cpp** STT + **Kokoro** TTS, and Arbiter stays text + SSE in the middle.

A native Mac desk app lives in `macos/Arthur`. It speaks through the same WebSocket and `device_token` as the hardware device, and defaults to that device’s `X-Device-Id` so Arthur’s conversation memory is shared.

```bash
macos/Arthur/build.sh
open macos/Arthur/dist/Arthur.app
```

The desk app stays armed from the menu bar after you close the window. Hold the **Arthur** extra (or **Hold to Talk** in its menu) to speak; **Mute Sound** and **Quit** are there too. The default global shortcut is **⌥Space** (Option-Space). It calls the same `pttDown` / `pttUp` path as the in-window Talk button and Space bar.

That shortcut uses the system hotkey API (`RegisterEventHotKey`) and does **not** need Accessibility or Input Monitoring. Microphone permission is still required to speak. Change the chord in Arthur → Settings → Push to talk, or:

```bash
defaults write run.intercom.Arthur arthur.pttKeyCode -int 49
defaults write run.intercom.Arthur arthur.pttModifierFlags -int 524288   # NSEvent.ModifierFlags.option
```

If the system hotkey API cannot register the chord, Arthur falls back to a global key monitor and then needs **Input Monitoring** (System Settings → Privacy & Security) so ⌥Space works while another app is focused. In-window Space push-to-talk is unchanged and never needs that permission.

Pick the hallway device in Settings so this Mac shares Arbiter conversation memory with the wall button. Continuity is not shown as a title-bar status pill.

**Quiet text mode** (composer keyboard control, Arthur menu, or Settings → Typing) turns off Space-as-PTT so typing is safe. ⌥Space / the configured global chord and the menu bar extra still talk. Preference: `arthur.quietTextMode`.

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

# Device PCM contract

Target hardware: **ESP32-S3 with PSRAM** (e.g. Arduino Nano ESP32) + I2S mic (INMP441) + I2S amp (MAX98357A). Intercom runs on the server; the MCU is a thin audio endpoint.

## Audio format

| Direction | Format |
|-----------|--------|
| Mic → Intercom | Mono PCM s16le, **24 kHz**, WebSocket binary frames while PTT is held (HTTP body is the fallback) |
| Intercom → speaker | Mono PCM s16le, **24 kHz**, WebSocket binary frames (chunked HTTP response on fallback) |

Content-Type: `audio/L16; rate=24000; channels=1`

## Session model

1. Hold a stable `X-Device-Id` (e.g. MAC or flashed UUID).
2. Use the Intercom device bearer (not Arbiter’s token).
3. Intercom maps device → Arbiter `conversation_id` in SQLite (`session_db`).
4. Same device keeps memory/history across boots of the MCU.
5. On Intercom start, `warm_prefix` (default on) creates those conversations if needed and sends `PREFIX WARM` so the LLM KV cache is hot before the first PTT.

## Push-to-talk flow

Firmware (`firmware/nano-esp32/intercom-endpoint`, tag `intercom-lan-v8`) streams
while the button is down:

1. On boot (and after drops), open `ws://<host>:8093/v1/stream` with the device
   bearer and `X-Device-Id`. Keep the socket; ping every 20s while idle, and
   drain inbound frames so scheduled speak-back can play without another PTT.
2. User holds PTT → I2S capture into PSRAM **and** binary WS frames every
   ~1024 samples (~43 ms at 24 kHz).
3. On release, send `{"type":"end"}`. Intercom replies `{"type":"accept","turn_id"}`
   immediately, then Whisper on the buffered clip, then reply PCM as binary
   frames, then `turn` / `done`.
4. Play binary frames to the I2S amp as they arrive.
5. On barge-in: stop I2S, `{"type":"cancel"}` on the socket, and
   `POST /v1/turns/{turn_id}/cancel`.
6. If the WS handshake or a mid-hold send fails, fall back to
   `POST /v1/utterance` with the full clip (same as before).

Set `INTERCOM_WS_PORT` to `0` in `config.h` to force HTTP only. Serial `say` /
`ping` stay on HTTP. Serial `ws` prints the socket state and reconnects.

## Colocation

Run Intercom beside `arbiter --api` on the same host:

- `arbiter_base_url`: `http://127.0.0.1:8080`
- Intercom listen: `127.0.0.1:8090` (put TLS/auth on a reverse proxy for LAN/WAN devices)
- Warm Whisper: `127.0.0.1:8092` (`whisper-server`, spawned by Intercom)
- Warm Kokoro: `127.0.0.1:8091` (`scripts/kokoro_server.py`, spawned by Intercom)

## Generating a test PCM file

```bash
# 1s of silence (or replace with sox/ffmpeg from mic)
ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -ar 24000 -ac 1 -f s16le utterance.pcm

# Or speak via text path (no whisper needed for path test):
curl -N -H "Authorization: Bearer dev-device-secret-change-me" \
  -H "X-Device-Id: speaker-1" \
  -H "Content-Type: application/json" \
  -d '{"text":"status"}' -o reply.pcm \
  http://127.0.0.1:8090/v1/utterance/text

ffplay -f s16le -ar 24000 -ac 1 reply.pcm
```

## WebSocket (v1.1)

`ws://<host>:8093/v1/stream` (config `ws_listen_port`, `0` disables it).
`INTERCOM_WS_PORT` on the MCU (default `8093`, `0` disables the client).

1. Upgrade with the same device bearer and `X-Device-Id` as HTTP.
2. While PTT is held, send binary frames of mono s16le PCM (24 kHz).
3. On release, send `{"type":"end"}`. Intercom ACKs with `accept` + `turn_id`,
   runs Whisper on the buffered audio, and streams reply PCM back as binary
   frames.
4. `{"type":"text","text":"status"}` skips STT (same as `/v1/utterance/text`).
5. HTTP PTT on `:8090` remains the fallback and the serial `say` path.

Idle sockets also accept unsolicited speak-back: `{type:speak,kind:schedule}`
plus binary PCM plus `{type:done}`. That is how a `/schedule` reminder is
spoken without another PTT. HTTP-only devices cannot receive speak-back;
Intercom queues a few utterances (see `speakback.max_queued`) until the
WebSocket reconnects.

See [docs/api.md](api.md) for the frame table.

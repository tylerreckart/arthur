# Intercom HTTP API

Base URL default: `http://127.0.0.1:8090`  
Auth: `Authorization: Bearer <device_token>` (Intercom device secret — not an Arbiter `atr_` token).

## `GET /health`

Returns JSON readiness for whisper, kokoro, and Arbiter reachability.

- `200` when whisper + kokoro are ready (Arbiter may still be down).
- `503` if speech binaries/models are missing.

`whisper.detail` / `kokoro.detail` say `server http://127.0.0.1:8092` (or `8091`) when the warm daemons are up.

Each turn prints one stderr line:

```
intercom latency turn=… path=arbiter stt_ms=… conv_ms=… arbiter_ttft_ms=… first_sentence_ms=… kokoro_ms=… kokoro_total_ms=… ttfa_ms=… ttfa_kind=ack|answer|fast first_answer_ms=…
```

`ttfa_ms` is time-to-first-audio on the chunked PCM response. `-1` means that stage did not run.

## `POST /v1/utterance`

Push-to-talk audio in → chunked PCM out.

### Request

| Header | Required | Description |
|--------|----------|-------------|
| `Authorization` | yes | `Bearer <device_token>` |
| `X-Device-Id` | yes | Stable device id (session key) |
| `Content-Type` | recommended | `audio/L16; rate=24000; channels=1` |
| `X-Sample-Rate` | no | Overrides rate if Content-Type omitted |

Body: raw mono PCM **s16le** (default 24 kHz).

### Response

`Content-Type: audio/L16; rate=24000; channels=1` (chunked).

| Header | Description |
|--------|-------------|
| `X-Turn-Id` | Intercom turn id (use for cancel) |
| `X-Transcript` | STT text |
| `X-Device-Id` | Echo |
| `X-Conversation-Id` | Present when a prior session exists |
| `X-Fast-Path` | `1` when the turn skipped Arbiter |
| `X-Fast-Path-Kind` | `social`, `clock`, `echo`, `timer`, `light_on`, `light_off`, `light_toggle`, `volume_up`, `volume_down`, `weather`, or `alarm` |
| `X-Intercom-Error` | Error detail when present |

Errors before streaming are JSON (`401`, `400`, `502`).

### Example

```bash
curl -N \
  -H "Authorization: Bearer dev-device-secret-change-me" \
  -H "X-Device-Id: speaker-1" \
  -H "Content-Type: audio/L16; rate=24000; channels=1" \
  --data-binary @utterance.pcm \
  --output reply.pcm \
  -D headers.txt \
  http://127.0.0.1:8090/v1/utterance
```

## `POST /v1/utterance/text`

Same as utterance but skips STT — for bring-your-own transcript / bridge tests.

```json
{ "text": "what time is it" }
```

Fast-path phrases never call Arbiter:

- Social: `hello` / `good morning` and other greetings, thanks, `status`
- Clock: `what time is it`, `what's the date` (local clock, not tools)
- Echo: `echo …`
- Home (only when `home.ha_base_url` and `home.ha_token` are set): timers, lights, volume, weather at home, next alarm. Weather with a place (`in Tokyo`) still goes to Arthur. A timer with no duration answers `How long, sir?` even without Home Assistant.

Social turns greet back and invite a follow-up. Home intents that match but have no Home Assistant config fall through to Arthur (except the bare timer prompt).

## `POST /v1/turns/:turn_id/cancel`

Barge-in: stops TTS and cancels the Arbiter `request_id` when known.

Requires `Authorization` + `X-Device-Id`.

## `GET /v1/devices/:device_id/session`

Debug: `{ device_id, conversation_id, last_turn_id, updated_at }`.

## Arbiter mapping

| Intercom | Arbiter |
|--------|---------|
| First utterance per device | `POST /v1/conversations` (`agent_id` + `agent_def` from config) |
| Boot (`warm_prefix`) | Same create, then a silent `PREFIX WARM` message so a local model can cache Arthur's constitution. Arthur replies `Ready`. |
| Each turn | `POST /v1/conversations/:id/messages` + SSE |
| `message` | STT transcript only (no voice-intercom suffix) |
| body | `{ "message", "channel": "voice", "agent_def" }` — `agent_def` includes a fresh local date/time rule each turn |
| Arthur | `mode: "spoken"`, `intent.mode: "off"`. Spoken cadence is owned by Arbiter's constitution — Arthur's `agent_def` does not restack a sentence-count cap. Durable user facts are searched and written via `/mem`, then used as something Arthur simply knows — never entries, titles, ids, or search hits spoken aloud. |
| Cancel | `POST /v1/requests/:id/cancel` |
| Idempotency-Key | Intercom `turn_id` |

Default agent: **Arthur** (`config/arthur.agent.json`).

Reply PCM can start before the SSE `done` event. Intercom synthesizes each
completed sentence as depth-0 text deltas arrive, and also starts Kokoro after
about seven words (`early_flush_words`) even when the first sentence has no
period yet. Remaining text is flushed after `done`; already-spoken sentences
are not repeated.

Related short sentences received together are synthesized as one phrase so
prosody carries across them. PCM is faded once at the bridge and followed by
punctuation-aware pauses (short after commas, longer after questions). A cached
local ack (`Yes, sir.`, `Of course.`, `Very good.`, …) can play after `filler.instant_ack_ms` if
Arbiter has not started answering. A tool call speaks a matching cached ack
after `filler.tool_ack_ms` (default 250 ms) when nothing has been said yet.

## `WS /v1/stream`

Duplex on `ws_listen_port` (default `8093`). HTTP PTT on `:8090` is unchanged
and is the firmware fallback.

Handshake: `GET /v1/stream` with `Upgrade: websocket`, `Authorization: Bearer
<device_token>`, and `X-Device-Id` (or `?token=&device_id=`).

| Client | Meaning |
|--------|---------|
| binary frames | PCM s16le appended while PTT is held |
| `{"type":"end"}` | Run STT on the buffered PCM and speak the reply |
| `{"type":"text","text":"…"}` | Skip STT |
| `{"type":"cancel"}` | Cancel the current turn if one is active |

| Server | Meaning |
|--------|---------|
| `{"type":"ready","sample_rate"}` | After upgrade |
| `{"type":"accept","turn_id"}` | Turn id assigned before STT / Arbiter, so barge-in can cancel |
| binary frames | Reply PCM |
| `{"type":"turn",…}` | Transcript / turn id after the pipeline returns |
| `{"type":"done","ok","error"}` | Terminal |
| `{"type":"speak","kind","run_id"}` | Unsolicited speak-back (scheduled reminder) about to stream PCM |

Idle devices keep the socket open. When Arbiter fires a `/schedule` (or
Intercom sees `run.completed` on `GET /v1/notifications/stream`), Intercom
synthesizes `result_summary` and pushes `{type:speak}` + PCM + `{type:done}`
on that socket so the reminder is spoken without another PTT. Mid-PTT
utterances are queued (up to `speakback.max_queued`) and flushed when the
device is idle again. Offline devices are queued in memory the same way;
there is no durable disk queue.

STT is still one-shot at `end` (Whisper is not streaming). The gain is sending
mic bytes while the button is down instead of waiting for HTTP to open. The
Nano ESP32 firmware does this by default (`INTERCOM_WS_PORT`, `0` disables).

At 24 kHz, Intercom uses Kokoro's chunked raw-PCM endpoint and forwards each
native phoneme batch as soon as it is generated. Older external Kokoro servers,
and configurations requiring resampling, fall back to the complete-WAV
endpoint.

Arthur's delivery is inferred from each spoken phrase. Greetings and courtesies
are slightly warmer and more measured; tool-wait asides are quieter and briefer;
warnings are firmer and leave a little more space. The adjustments are subtle
speed, gain, and pause changes on top of the selected Kokoro voice.

Kokoro output passes through a stateful speech DSP chain before reaching the
device: a 70 Hz high-pass filter, a gentle 2.6 kHz presence lift, envelope
compression, makeup gain, and a minus-one-decibel limiter. All parameters are
under `kokoro.dsp`; set `enabled` to `false` for a bit-exact bypass.

## Speak-back (scheduled reminders)

When `speakback.enabled` is true (default), Intercom subscribes to Arbiter's
`GET /v1/notifications/stream` and speaks completed schedule runs on the
matching device.

Arbiter contract this path assumes:

- SSE `event: notification` with `kind` `run.started` | `run.completed` |
  `run.failed`. Intercom speaks `run.completed` (`status: succeeded`) using
  `result_summary` (truncated at 4 KiB on the Arbiter side). `run.started` is
  ignored. `run.failed` is silent unless `speakback.speak_failures` is true,
  in which case a short courtesy line is spoken — never the raw
  `error_message`.
- Notification payloads do **not** include `conversation_id`. Intercom looks
  up `GET /v1/schedules/:task_id` (`scheduled_task.conversation_id`). A pin
  greater than 0 maps through SessionStore to the device that owns that
  conversation. `0` (unscoped) maps to the sole Intercom session when only
  one device is known, and only if `agent_id` is this Intercom agent or
  `index`.
- The bus is not durable. After the SSE drop, Intercom reconnects (default
  2 s) and polls `GET /v1/runs?since=<last_seen_started_at>`. Runs use `id`
  for the run id. Duplicate `run_id`s are skipped in memory (not across
  Intercom restarts). Events that fire while Intercom itself is down are not
  replayed on boot.

Config (`speakback` in `intercom.json`):

| Field | Default | Meaning |
|-------|---------|---------|
| `enabled` | `true` | Subscribe and speak |
| `reconnect_ms` | `2000` | Pause after SSE drop before reconnect + runs poll |
| `max_queued` | `4` | In-memory utterances per offline or busy device (drop oldest) |
| `speak_failures` | `false` | Speak a courtesy line on `run.failed` |

How to test a reminder:

1. Device WebSocket idle on `:8093` (`ws` serial command shows `up`).
2. Hold PTT: *remind me in a minute to take the pie out*.
3. Arthur should emit `/schedule in 1 minute: …`. Wait for the fire (Arbiter
   ticker must be running: `arbiter --api`).
4. The device should play the result without another PTT. Intercom logs
   `intercom speakback: speaking run … to <device_id>`.

`GET /health` includes `speakback.enabled`.

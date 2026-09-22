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
| `X-Fast-Path-Kind` | `social`, `clock`, `echo`, `timer`, `light_on`, `light_off`, `light_toggle`, `volume_up`, `volume_down`, `weather`, `alarm`, `news`, or `markets` |
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
- Home (only when `home.ha_base_url` and `home.ha_token` are set): timers, lights, volume, weather at home, next alarm. A timer with no duration answers `How long, sir?` even without Home Assistant.
- Place weather (`what's the weather in Tokyo`, `forecast for London`): Open-Meteo geocoding + forecast (no API key, no Home Assistant). Speaks a short line and emits a weather `surface`. Home weather without a place still uses HA when configured.
- News (`what's in the news`, `news about Tesla`, `top headlines`): Google News RSS (or configured feeds). Speaks a short line and emits a news `surface`. No API key.
- Markets (`how's the market`, `what's AAPL doing`, `bitcoin price`): Yahoo Finance public v7 quote JSON. Speaks a short line and emits a markets `surface`. No API key. Quote lookup failure falls through to Arthur for speech only.

Social turns greet back and invite a follow-up. Home intents that match but have no Home Assistant config fall through to Arthur (except the bare timer prompt and place weather). News and markets fast-path when Intercom is confident and the fetch succeeds; otherwise Arthur speaks and Intercom still attaches a card if it can fetch structured data for that turn.

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
| `{"type":"heard","text"}` | User transcript as soon as Whisper finishes (immediately on text turns). Desk clients show a You line here — do not wait for `turn` |
| `{"type":"turn",…}` | Transcript / turn id after the pipeline returns |
| `{"type":"done","ok","error"}` | Terminal |
| `{"type":"speak","kind","run_id","text"}` | Unsolicited speak-back (scheduled reminder) about to stream PCM. `text` is the spoken line when known. |
| `{"type":"status","phase"}` | `thinking` while waiting on Arbiter (desk clients) |
| `{"type":"working","tool"}` | Master tool started; value is the tool name |
| `{"type":"said","text"}` | Sentence about to be spoken (same text Kokoro hears) |
| `{"type":"forming","text"}` | Tail of the answer as tokens arrive (~12 Hz, desk presence) |
| `{"type":"surface","turn_id","surface"}` | Versioned desk card for this turn. Voice-only devices ignore it. |

### `surface` (desk cards)

Spoken lines stay short. Dense data rides beside `{type:said}` as a
versioned `surface` so the Arthur desk can render a typed card. Voice
endpoints (hallway firmware) skip unknown event types and keep playing
PCM. Existing installs that never emit `surface` are unchanged.

```json
{
  "type": "surface",
  "turn_id": "…",
  "surface": {
    "kind": "weather",
    "version": 1,
    "title": "Home",
    "summary": "Partly cloudy, 18°C",
    "payload": {
      "condition": "partlycloudy",
      "condition_label": "Partly cloudy",
      "temperature": 18,
      "temperature_unit": "°C",
      "feels_like": 16,
      "humidity": 61,
      "hours": [{"label": "3 PM", "condition": "cloudy", "temperature": 17}],
      "days": [{"label": "Wed", "condition": "rainy", "temperature": 19, "temperature_low": 12}]
    },
    "sources": [{"title": "Weather forecast from met.no"}]
  }
}
```

`kind` is closed for this slice:

| Kind | Desk UI |
|------|---------|
| `weather` | Full card (condition, temperature, feel, forecast strip, source) |
| `news` | Headline stack (title, source, relative time, tappable link) |
| `markets` | Symbol / price / change rows (color for up/down) |
| `generic` | Title + summary, optional key-values / markdown-ish body |
| `article` / `source_list` | Decoded, rendered as generic until a later slice |

Unknown `kind` values decode as `generic`. They never drop the turn. The wire kind is `markets` (not `finance`).

Weather v1 uses the same schema for **home** and **place** forecasts. The
LLM is not asked to emit card JSON. `turn_id` matches `{type:accept}` /
`{type:said}` so the desk binds the card to that Arthur bubble.

| Query | Source | `surface.title` |
|-------|--------|-----------------|
| `what's the weather` (no place) | Home Assistant `home.weather_entity` when configured | HA `friendly_name` or `Home` |
| `what's the weather in Tokyo` (and similar `in` / `for` / `at`) | Open-Meteo geocoding + forecast (no API key; does not need `home.ha_*`) | Place name (e.g. `Tokyo, Japan`) |

Both paths emit `{type:surface, kind: weather, version: 1}` with condition,
temperature, feel, humidity, hours/days, and sources when the provider
returns them. Voice-only devices ignore `surface`. If the place lookup
fails, the turn falls through to Arthur for speech only.

Hallway / compact windows collapse the card to a summary line.

#### `news` v1

Headlines. Intercom fetches RSS; the LLM is not asked for card JSON.

```json
{
  "kind": "news",
  "version": 1,
  "title": "Top stories",
  "summary": "8 headlines",
  "payload": {
    "topic": "tesla",
    "items": [
      {
        "title": "Tesla deliveries rise",
        "summary": "…",
        "source": "Reuters",
        "url": "https://…",
        "published_at": "Tue, 22 Sep 2026 12:00:00 GMT"
      }
    ]
  },
  "sources": [{"title": "Google News", "url": "https://news.google.com/"}]
}
```

| Query | Source | `surface.title` |
|-------|--------|-----------------|
| `what's in the news` / `top headlines` | First configured feed, or Google News top RSS | Feed `name` or `Top stories` |
| `news about Tesla` / `headlines on Ukraine` | Google News RSS search (`{google_news_rss}/search?q=…`) | Topic (title-cased) |

Provider is **Google News RSS** (no API key). Default and extra feeds live under `news.feeds` in `intercom.json`. `news.google_news_rss` is the search base (default `https://news.google.com/rss`). Headlines and links only — no article body scrape. If the feed is empty or unreachable, the turn falls through to Arthur for speech only.

Hallway / compact windows show the first headline and hide the stack.

#### `markets` v1

Quotes. Kind name is `markets` in the schema and the Swift enum.

```json
{
  "kind": "markets",
  "version": 1,
  "title": "Markets",
  "summary": "Markets are mixed",
  "payload": {
    "market_summary": "Markets are mixed",
    "instruments": [
      {
        "symbol": "AAPL",
        "name": "Apple Inc.",
        "price": 230.12,
        "change": 1.5,
        "change_pct": 0.65,
        "currency": "USD",
        "as_of": 1758547200
      }
    ]
  },
  "sources": [{"title": "Yahoo Finance", "url": "https://finance.yahoo.com/"}]
}
```

| Query | Symbols | Source |
|-------|---------|--------|
| `how's the market` / `the markets` | `markets.default_symbols` (S&P, Dow, Nasdaq, BTC) | Yahoo v7 quote |
| `what's AAPL doing` / `apple stock` / `bitcoin price` | Resolved tickers (`AAPL`, `BTC-USD`, …) | same |

Provider is Yahoo Finance’s unofficial public quote JSON (`{quote_base}/v7/finance/quote?symbols=…`, default `https://query1.finance.yahoo.com`). No API key. It is the same family of endpoints Yahoo’s own pages use — not a licensed market-data product. Intercom sends a browser-like User-Agent; some networks still see `403`. Point `markets.quote_base` at a proxy if needed. Stooq CSV was considered (more ToS-friendly, weaker batch metadata) and was not used for v1.

If quote lookup fails, Intercom does **not** invent prices — Arthur speaks without a card.

Hallway / compact windows collapse to the summary line.

Idle devices keep the socket open. When Arbiter fires a `/schedule` (or
Intercom sees `run.completed` on `GET /v1/notifications/stream`), Intercom
synthesizes `result_summary` and pushes `{type:speak,text}` + `{type:said}`
+ PCM + `{type:done}` on that socket so the reminder is spoken without
another PTT. `{type:said}` is the same spoken line Kokoro hears, so desk
clients can show it without treating the event as a user turn. Mid-PTT
utterances are queued (up to `speakback.max_queued`) and flushed when the
device is idle again. Offline devices are queued in memory the same way;
there is no durable disk queue.

STT is still one-shot at `end` (Whisper is not streaming — there are no
word-level partials while the mic is down). After Whisper, Intercom emits
`heard` so a desk transcript can show the user line before Arthur answers.
The gain of the socket is sending mic bytes while the button is down instead
of waiting for HTTP to open. The Nano ESP32 firmware does this by default
(`INTERCOM_WS_PORT`, `0` disables).

At 24 kHz, Intercom uses Kokoro's chunked raw-PCM endpoint and forwards each
native phoneme batch as soon as it is generated. Older external Kokoro servers,
and configurations requiring resampling, fall back to the complete-WAV
endpoint.

Arthur's delivery is inferred from each spoken phrase. Greetings and courtesies
are slightly warmer and more measured; tool-wait asides are quieter and briefer;
warnings are firmer and leave a little more space. The adjustments are subtle
speed, gain, and pause changes on top of the selected Kokoro voice.

The default `kokoro.voice` is `af_nova:0.6+af_nicole:0.3+af_heart:0.1`
(language `en-us` from `af_nova`). A single name such as `bm_lewis` is still
valid. `left+right:weight` is still the two-way form (weight is the
fraction of the right voice). N-way mixes use `name:weight+name:weight`;
omitted weights are equal, and raw ratios such as `3:1:1` are normalized to
sum to 1. Language is taken from the heaviest component’s name prefix.
A gitignored local `intercom.json` is not overwritten — update `kokoro.voice`
there if you want the new default.

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

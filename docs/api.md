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
| `X-Fast-Path-Kind` | `clock`, `echo`, `timer`, `light_on`, `light_off`, `light_toggle`, `volume_up`, `volume_down`, `weather`, `alarm`, `news`, or `markets` |
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

- Clock: `what time is it`, `what's the date` (local clock, not tools)
- Echo/repeat: `echo …`, `repeat that`, `say that again`
- Home (only when `home.ha_base_url` and `home.ha_token` are set): timers, lights, volume, weather at home, next alarm. A timer with no duration answers `How long, sir?`; a standalone reply such as `five minutes` completes the pending timer for up to two minutes.
- Place weather (`what's the weather in Tokyo`, `forecast for London`): Open-Meteo geocoding + forecast (no API key, no Home Assistant). Speaks a short line and emits a weather `surface`. Home weather without a place still uses HA when configured.
- News (`what's in the news`, `news about Tesla`, `top headlines`): Google News RSS (or configured feeds). Speaks the first three headlines and emits a news `surface`. No API key.
- Markets (`how's the market`, `what's AAPL doing`, `bitcoin price`): Yahoo Finance public v7 quote JSON. Speaks a short snapshot and the first few quotes, and emits a markets `surface`. No API key. Quote lookup failure falls through to Arthur for speech only.
- Briefing (`brief me`, `morning briefing`, `what's the briefing`): one local turn, in order, with the local time, home weather when Home Assistant is configured or `weather.default_place` when that place resolves, the top headlines, and the default market snapshot. Each section that returns data also emits its surface card. A section that fails is skipped with a short gap and does not sink the turn. This stays separate from `what's in the news`. Arbiter is not called when the clock line succeeds.

Social turns always go through Arthur's constitution so their tone and history match substantive conversation. Home intents that match but have no Home Assistant config fall through to Arthur (place weather remains local). News and markets fast-path when Intercom is confident and the fetch succeeds; otherwise Arthur speaks and Intercom still attaches a card if it can fetch structured data for that turn.

When a short contextual follow-up follows a local clock, home, weather, news, or
market answer, Intercom sends Arthur one bounded turn of private continuity
metadata: the prior request, local answer, and fast-path kind. This lets turns
such as `what about tomorrow?` continue naturally even though the previous turn
did not run through Arbiter. The bridge is deliberately limited to clear,
short follow-ups; unrelated requests are sent unchanged. Arthur's constitution
instructs him to use this metadata silently and never quote it aloud.

Successful light and volume actions also keep a normalized local request so
short action follow-ups remain deterministic. `turn it off`, `the hallway too`,
`do that again`, and `undo that` resolve against the previous action without an
Arbiter round trip. Failed Home Assistant calls are never retained as action
context, so a failed command cannot later be repeated, reversed, or repaired.

A short correction can retarget that previous local turn without a general
rewrite. After a light action, `no, the bedroom`, `I meant the hallway`, and
`not the kitchen` replace the room and run the same operation again. After a
clock, weather, news, or market answer, `I meant tomorrow` or `no, tomorrow`
resubmits the prior request with that time scope. The corrected request stays
on the fast path when it is still deterministic. Otherwise Arthur receives one
private correction note — the prior request, the prior answer, and the
corrected line — and is told never to quote that note. `not that one` and
`the other one` switch to the other light only when exactly two lights are
configured and the previous target is one of them, or reverse the previous
volume step. When the alternative is ambiguous, the utterance is left intact
and Arthur gets a short private note with the prior request and answer.
Unrelated utterances are not rewritten.

One utterance can also contain two or three deterministic clauses joined by
`and`, `then`, or `and then`. Arthur performs each clause in order and speaks
each result, so `what time is it and the date` or
`turn off the kitchen lights and the hallway` stays local. A bare later target
inherits the preceding light action, and short tails such as `the news` expand
to their normal local request. A combined market or news request stays one
lookup. If any clause is not deterministic, the whole utterance is left intact.

After a news or markets card, a short pointer such as `the second one`,
`read the first headline`, or `the last quote` speaks that item from the stored
list. The spoken news and market lines name the first three items, so the
pointer matches what was just heard. `headline` selects the latest news list
and `quote` selects the latest markets list, including when a briefing showed
both. A missing item gets a short local answer. The list is kept across later
local answers such as the clock.

`more`, `tell me more`, and `more on the second one` read the stored summary
of the item in focus. Another `go on`, or a question such as `why does that
matter`, hands Arthur that title, source, and summary as private card context
so he can go further and look the story up. `what else` and `the rest` speak
the later items that were kept past the first three, and a further `what else`
says when the list is finished. A line that does not point at the card is left
unchanged.

## `POST /v1/turns/:turn_id/cancel`

Barge-in: stops TTS and cancels the Arbiter `request_id` when known.

Requires `Authorization` + `X-Device-Id`.

## `GET /v1/devices/:device_id/session`

Debug: `{ device_id, conversation_id, last_turn_id, last_user, last_spoken, last_fast_path_kind, last_fast_path_request, last_card, pending_intent, pending_at, updated_at }`.

Intercom keeps the last user request and completed spoken line per device.
Exact requests such as `say that again` can replay deterministic or Arbiter
answers without another model run; the fast-path kind supports the one-turn
continuity bridge described above, and the normalized fast-path request supports
local action chaining. This is device session context, separate from Arthur's
durable `/mem` facts.

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
completed sentence as depth-0 text deltas arrive. `early_flush_words` can force
a lower-latency mid-clause start, but defaults to `0` so Kokoro receives a
complete thought and preserves natural prosody. Forced fragments are marked as
continuations rather than full stops. Remaining text is flushed after `done`;
already-spoken sentences are not repeated.

Related short sentences received together are synthesized as one phrase so
prosody carries across them. PCM is faded once at the bridge and followed by
punctuation-aware pauses (short after commas, longer after questions). A cached
local ack (`Of course.`, `Certainly.`, `All right.`, …) can play after
`filler.instant_ack_ms` (default 1100 ms) if Arbiter has not started answering.
A tool call speaks a matching cached ack
after `filler.tool_ack_ms` (default 350 ms) when nothing has been said yet.
If tool work remains silent for eight more seconds, the default single
follow-up says `Still with you.`; `max_followups` can disable or extend this.

## `WS /v1/stream`

Duplex on `ws_listen_port` (default `8093`). HTTP PTT on `:8090` is unchanged
and is the firmware fallback.

Handshake: `GET /v1/stream` with `Upgrade: websocket`, `Authorization: Bearer
<device_token>`, and `X-Device-Id` (or `?token=&device_id=`).

| Client | Meaning |
|--------|---------|
| binary frames | PCM s16le appended while the mic is open |
| `{"type":"end"}` | Run STT on any PCM not already finished, and speak the reply. An optional `context` object is attached to that turn |
| `{"type":"text","text":"…"}` | Skip STT. Optional `context` is attached to that turn and is not the heard line |
| `{"type":"context","context":{…}}` | Remember desk context for the next utterance on this socket. Replaced by a later context frame, and consumed when the turn starts |
| `{"type":"cancel"}` | Cancel the current turn if one is active |
| `{"type":"arm_approval","id"}` | The next yes or no on this device resolves a Mac write. Expires after three minutes |
| `{"type":"clear_approval"}` | Drop that pending yes or no because the desk already resolved it |

`context` is `{sources:[{name,text}]}`. Intercom prepends it to the Arbiter
message as a private `LOCAL CONTEXT` block. It is not the heard line, and it
is not written to the session row. Empty and malformed context is ignored.
Clients that never send it are unchanged.

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
| `{"type":"forming","text"}` | Unspoken answer prefix as tokens arrive (~12 Hz, desk presence) |
| `{"type":"surface","turn_id","surface"}` | Versioned desk card for this turn. Voice-only devices ignore it. |
| `{"type":"approval","id","granted"}` | The user accepted or refused a pending Mac write. `reason` is `replaced` when a later request retires it. Voice-only devices still hear the short reply |

Turn execution runs independently of the socket reader, so `cancel`, ping, and
close frames remain responsive during STT, Arbiter work, and TTS. The turn is
registered before one-shot STT begins; clients may cancel as soon as they
receive `accept`. A new `text` or buffered-PCM `end` while a turn is still
unwinding implicitly cancels and retires the old turn, then immediately emits a
new `accept`. Terminal events remain keyed by `turn_id`, so the cancelled
turn's `done` may arrive after the replacement turn has been accepted.

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
device is idle again. Offline devices are queued in the session database
the same way, so a reminder accepted before Intercom exits is spoken on
the next attach. Spoken run ids are stored there too, and a restart does
not speak the same run twice.

STT is still one-shot at `end` (Whisper is not streaming — there are no
word-level partials while the mic is down). After Whisper, Intercom emits
`heard` so a desk transcript can show the user line before Arthur answers.
While PCM is arriving, Intercom runs a small energy detector on the 24 kHz
mono stream. Speech starts the utterance. About 700 ms of trailing silence
ends it, bursts under 300 ms are ignored, and an utterance is capped around
30 seconds. The completed audio starts the turn immediately — the client does
not have to send `end` first. A later `end` for that same audio is ignored, so
it cannot run twice. `end` is still the way a hold-to-talk client finishes a
clip that has no trailing silence. Speech that arrives during playback cancels
the active turn and becomes the next utterance.

The gain of the socket is sending mic bytes while the mic is open instead
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

The default `kokoro.voice` is `bm_lewis` (language `en-gb`), matching Arthur's 
persona. Other single names and weighted blends remain valid.
`left+right:weight` is still the two-way form (weight is the
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
| `max_queued` | `4` | Queued utterances per offline or busy device (drop oldest). Persisted in the session database |
| `speak_failures` | `false` | Speak a courtesy line on `run.failed` |

How to test a reminder:

1. Device WebSocket idle on `:8093` (`ws` serial command shows `up`).
2. Hold PTT: *remind me in a minute to take the pie out*.
3. Arthur should emit `/schedule in 1 minute: …`. Wait for the fire (Arbiter
   ticker must be running: `arbiter --api`).
4. The device should play the result without another PTT. Intercom logs
   `intercom speakback: speaking run … to <device_id>`.

`GET /health` includes `speakback.enabled`.

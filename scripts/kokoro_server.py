#!/usr/bin/env python3
"""Keep Kokoro ONNX loaded and serve WAV over HTTP.

POST /v1/tts  {"text": "..."}  -> audio/wav
GET  /health                   -> {"ok": true}
"""

from __future__ import annotations

import argparse
import io
import json
import math
import re
import sys
import threading
import wave
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np

# kokoro_onnx is imported in main() so unit tests can import this module
# without the ONNX package or a voices.bin.

ENGINE = None
LOCK = threading.Lock()
VOICE = "bm_lewis"
VOICE_STYLE = "bm_lewis"
SPEED = 0.96
LANG = "en-gb"

_LANG_BY_PREFIX = {
    "bf_": "en-gb",
    "bm_": "en-gb",
    "ff_": "fr-fr",
    "if_": "it",
    "im_": "it",
    "jf_": "ja",
    "jm_": "ja",
    "zf_": "cmn",
    "zm_": "cmn",
}
_WEIGHT_EPS = 1e-12


@dataclass(frozen=True)
class VoiceComponent:
    name: str
    weight: float
    explicit: bool = False


def lang_from_voice_name(name: str) -> str:
    prefix = name[:3] if len(name) >= 3 else ""
    return _LANG_BY_PREFIX.get(prefix, "en-us")


def parse_voice_spec(spec: str) -> list[VoiceComponent]:
    if spec is None or not str(spec).strip():
        raise ValueError("voice blend is empty")
    components: list[VoiceComponent] = []
    for raw_part in str(spec).split("+"):
        part = raw_part.strip()
        if not part:
            raise ValueError("voice blend has an empty component")
        if ":" in part:
            name, raw_weight = part.rsplit(":", 1)
            name = name.strip()
            raw_weight = raw_weight.strip()
            if not name:
                raise ValueError("voice blend component is missing a name")
            try:
                weight = float(raw_weight)
            except ValueError as exc:
                raise ValueError(
                    f"voice blend weight is not a number: {raw_weight!r}"
                ) from exc
            if not math.isfinite(weight):
                raise ValueError("voice blend weights must be finite")
            if weight < 0.0:
                raise ValueError("voice blend weights must not be negative")
            components.append(VoiceComponent(name, weight, True))
        else:
            components.append(VoiceComponent(part, 1.0, False))
    if not components:
        raise ValueError("voice blend is empty")
    return components


def apply_legacy_two_way(
    components: list[VoiceComponent],
) -> list[VoiceComponent]:
    """Keep `left+right:weight` as (1−w)·left + w·right when only right is weighted."""
    if (
        len(components) == 2
        and not components[0].explicit
        and components[1].explicit
    ):
        weight = components[1].weight
        if not 0.0 <= weight <= 1.0:
            raise ValueError("voice blend weight must be between zero and one")
        return [
            VoiceComponent(components[0].name, 1.0 - weight, True),
            VoiceComponent(components[1].name, weight, True),
        ]
    return components


def normalize_voice_weights(
    components: list[VoiceComponent],
) -> list[VoiceComponent]:
    if not components:
        raise ValueError("voice blend is empty")
    total = float(sum(component.weight for component in components))
    if not math.isfinite(total) or total <= _WEIGHT_EPS:
        raise ValueError(
            "voice blend weights must sum to a positive finite value"
        )
    return [
        VoiceComponent(component.name, component.weight / total, True)
        for component in components
    ]


def prepared_voice_components(spec: str) -> list[VoiceComponent]:
    return normalize_voice_weights(apply_legacy_two_way(parse_voice_spec(spec)))


def dominant_voice_name(components: list[VoiceComponent]) -> str:
    if not components:
        raise ValueError("voice blend is empty")
    return max(components, key=lambda component: component.weight).name


def voice_lang(voice: str, override: str | None = None) -> str:
    if override:
        return override
    return lang_from_voice_name(
        dominant_voice_name(prepared_voice_components(voice))
    )


def blend_voice_styles(
    named_styles: list[tuple[str, float, np.ndarray]],
) -> np.ndarray:
    if not named_styles:
        raise ValueError("voice blend is empty")
    first_name, _first_weight, first_style = named_styles[0]
    expected = np.asarray(first_style)
    expected_shape = expected.shape
    expected_dtype = expected.dtype
    acc = np.zeros(expected_shape, dtype=expected_dtype)
    for name, weight, style in named_styles:
        arr = np.asarray(style)
        if arr.shape != expected_shape or arr.dtype != expected_dtype:
            raise ValueError(
                f"voice style {name!r} has shape {arr.shape} dtype {arr.dtype}, "
                f"expected shape {expected_shape} dtype {expected_dtype} "
                f"to match {first_name!r}"
            )
        acc = acc + (weight * arr)
    if acc.dtype != expected_dtype:
        acc = acc.astype(expected_dtype, copy=False)
    return acc


def _style_loader(get_style):
    if get_style is not None:
        return get_style
    if ENGINE is None:
        raise RuntimeError("engine not loaded")
    return ENGINE.get_voice_style


def resolve_voice_components(components: list[VoiceComponent], get_style=None):
    if len(components) == 1:
        return components[0].name
    loader = _style_loader(get_style)
    return blend_voice_styles(
        [
            (component.name, component.weight, loader(component.name))
            for component in components
        ]
    )


def resolve_voice(spec: str, get_style=None):
    """Resolve a plain voice name or a `+`-separated style blend."""
    return resolve_voice_components(prepared_voice_components(spec), get_style)


def prepare_text(text: str) -> str:
    text = text.strip()
    if text and text[-1] not in ".!?,;:":
        text += "."
    return text


def trim_silence(audio: np.ndarray, sample_rate: int) -> np.ndarray:
    """Trim model padding without importing librosa/numba in worker threads."""
    samples = np.asarray(audio, dtype=np.float32)
    if samples.size == 0:
        return samples
    peak = float(np.max(np.abs(samples)))
    if peak <= 1e-6:
        return samples[:0]
    active = np.flatnonzero(np.abs(samples) >= peak * 0.003)
    if active.size == 0:
        return samples[:0]
    pad = max(1, int(sample_rate * 0.012))
    start = max(0, int(active[0]) - pad)
    end = min(samples.size, int(active[-1]) + pad + 1)
    return samples[start:end]


def phoneme_batches(text: str) -> list[str]:
    """Split below Kokoro's style-table edge; its native splitter may hit 510."""
    phonemes = ENGINE.tokenizer.phonemize(prepare_text(text), LANG)
    batches: list[str] = []
    for native in ENGINE._split_phonemes(phonemes):
        words = re.findall(r"\S+", native)
        current = ""
        for word in words:
            candidate = f"{current} {word}".strip()
            if current and len(ENGINE.tokenizer.tokenize(candidate)) > 480:
                batches.append(current)
                current = word
            else:
                current = candidate
        if current:
            batches.append(current)
    return batches


def generate_parts(text: str, speed: float):
    voice = VOICE_STYLE
    if isinstance(voice, str):
        voice = ENGINE.get_voice_style(voice)
    for batch in phoneme_batches(text):
        audio, sample_rate = ENGINE._create_audio(batch, voice, speed)
        audio = trim_silence(audio, int(sample_rate))
        if audio.size:
            yield audio, int(sample_rate)


def synthesize(text: str, speed: float = SPEED) -> tuple[bytes, int]:
    if ENGINE is None:
        raise RuntimeError("engine not loaded")
    with LOCK:
        parts = list(generate_parts(text, speed))
    if not parts:
        raise RuntimeError("empty synthesis")
    sr = parts[0][1]
    audio = np.concatenate([part for part, _ in parts])
    pcm = np.clip(np.asarray(audio) * 32767.0, -32768, 32767).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(int(sr))
        wav.writeframes(pcm.tobytes())
    return buf.getvalue(), int(sr)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path.split("?", 1)[0] != "/health":
            self._send(404, b'{"error":"not found"}', "application/json")
            return
        body = json.dumps({"ok": True, "voice": VOICE, "lang": LANG}).encode("utf-8")
        self._send(200, body, "application/json")

    def do_POST(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path not in ("/v1/tts", "/v1/tts/stream"):
            self._send(404, b'{"error":"not found"}', "application/json")
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0 or length > 32 * 1024:
            self._send(400, b'{"error":"invalid body"}', "application/json")
            return
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
            text = (payload.get("text") or "").strip()
            speed = float(payload.get("speed", SPEED))
            if not 0.5 <= speed <= 2.0:
                raise ValueError("speed out of range")
        except (
            json.JSONDecodeError,
            UnicodeDecodeError,
            AttributeError,
            TypeError,
            ValueError,
        ):
            self._send(400, b'{"error":"invalid json"}', "application/json")
            return
        if not text:
            self._send(400, b'{"error":"missing text"}', "application/json")
            return
        if path == "/v1/tts/stream":
            self._stream_pcm(text, speed)
            return
        try:
            wav, _sr = synthesize(text, speed)
        except Exception as exc:  # noqa: BLE001
            msg = json.dumps({"error": str(exc)}).encode("utf-8")
            self._send(500, msg, "application/json")
            return
        self._send(200, wav, "audio/wav")

    def _write_chunk(self, body: bytes) -> None:
        self.wfile.write(f"{len(body):X}\r\n".encode("ascii"))
        self.wfile.write(body)
        self.wfile.write(b"\r\n")
        self.wfile.flush()

    def _stream_pcm(self, text: str, speed: float) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "audio/L16; rate=24000; channels=1")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        try:
            # Stream each native Kokoro phoneme batch as soon as inference
            # finishes. Avoid create_stream's detached task: an inference or
            # trimming exception there can otherwise leave the HTTP body open.
            with LOCK:
                for audio, sample_rate in generate_parts(text, speed):
                    pcm = np.clip(
                        np.asarray(audio) * 32767.0, -32768, 32767
                    ).astype(np.int16)
                    self._write_chunk(pcm.tobytes())
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as exc:  # noqa: BLE001
            # Headers are already committed; terminate the chunked body and log.
            sys.stderr.write(f"stream synthesis failed: {exc}\n")
            try:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass


def main() -> int:
    global ENGINE, VOICE, VOICE_STYLE, SPEED, LANG

    parser = argparse.ArgumentParser(description="Warm Kokoro ONNX HTTP server")
    parser.add_argument("--model", required=True)
    parser.add_argument("--voices", required=True)
    parser.add_argument(
        "--voice",
        default="bm_lewis",
        help="Kokoro voice name or + blend (name:w+name:w; weights auto-normalized)",
    )
    parser.add_argument("--speed", type=float, default=0.96)
    parser.add_argument("--lang", default="")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8091)
    args = parser.parse_args()

    from kokoro_onnx import Kokoro

    VOICE = args.voice
    SPEED = args.speed
    try:
        components = prepared_voice_components(VOICE)
    except ValueError as exc:
        print(
            f"intercom kokoro-server: invalid --voice {VOICE!r}: {exc}",
            file=sys.stderr,
        )
        return 2
    LANG = args.lang or lang_from_voice_name(dominant_voice_name(components))

    print(f"intercom kokoro-server: loading {args.model}", flush=True)
    ENGINE = Kokoro(args.model, args.voices)
    try:
        VOICE_STYLE = resolve_voice_components(components)
    except ValueError as exc:
        print(
            f"intercom kokoro-server: invalid voice blend {VOICE!r}: {exc}",
            file=sys.stderr,
        )
        return 2
    print(
        f"intercom kokoro-server: listening on http://{args.host}:{args.port} "
        f"voice={VOICE} lang={LANG}",
        flush=True,
    )
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

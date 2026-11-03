#include "intercom/tts_kokoro.hpp"
#include "intercom/audio_dsp.hpp"
#include "intercom/filler_client.hpp"
#include "intercom/managed_server.hpp"
#include "intercom/util.hpp"

#include <httplib.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <sys/wait.h>
#include <unistd.h>

#ifndef INTERCOM_SCRIPTS_DIR
#define INTERCOM_SCRIPTS_DIR ""
#endif

namespace intercom {
namespace {

std::string shell_quote(const std::string& s) {
  std::string out = "'";
  for (char c : s) {
    if (c == '\'') out += "'\\''";
    else out += c;
  }
  out += "'";
  return out;
}

bool write_text_file(const std::string& path, const std::string& text) {
  std::ofstream out(path);
  if (!out) return false;
  out << text;
  return static_cast<bool>(out);
}

bool downmix_to_mono(std::vector<std::uint8_t>* pcm, int channels) {
  if (!pcm || pcm->empty() || channels <= 1) return true;
  if (channels > 1) {
    std::vector<std::uint8_t> mono(pcm->size() / static_cast<std::size_t>(channels));
    const auto* in = reinterpret_cast<const std::int16_t*>(pcm->data());
    auto* m = reinterpret_cast<std::int16_t*>(mono.data());
    const std::size_t frames = mono.size() / 2;
    for (std::size_t i = 0; i < frames; ++i) {
      m[i] = in[i * static_cast<std::size_t>(channels)];
    }
    *pcm = std::move(mono);
  }
  return true;
}

bool normalize_pcm(std::vector<std::uint8_t>* pcm, int wav_rate, int wav_ch, int target_rate) {
  if (!pcm) return false;
  downmix_to_mono(pcm, wav_ch);
  if (wav_rate <= 0) wav_rate = 24000;
  if (wav_rate != target_rate) {
    *pcm = resample_s16le_mono(*pcm, wav_rate, target_rate);
  }
  return true;
}

bool emit_chunks(const std::vector<std::uint8_t>& pcm,
                 TtsProvider::PcmChunkFn on_chunk,
                 std::string* err) {
  constexpr std::size_t kChunk = 4096;
  for (std::size_t off = 0; off < pcm.size(); off += kChunk) {
    const std::size_t n = std::min(kChunk, pcm.size() - off);
    if (on_chunk && !on_chunk(pcm.data() + off, n)) {
      if (err) *err = "tts sink aborted";
      return false;
    }
  }
  return true;
}

}  // namespace

KokoroTts::KokoroTts(KokoroConfig cfg, int target_sample_rate)
    : cfg_(std::move(cfg)), target_sample_rate_(target_sample_rate) {
  cfg_.model = expand_home(cfg_.model);
  cfg_.voices = expand_home(cfg_.voices);
  cfg_.binary = expand_home(cfg_.binary);
  cfg_.server_script = expand_home(cfg_.server_script);
  if (!cfg_.server_url.empty()) {
    server_url_ = cfg_.server_url;
    while (!server_url_.empty() && server_url_.back() == '/') server_url_.pop_back();
  } else if (cfg_.use_server) {
    server_url_ = "http://127.0.0.1:" + std::to_string(cfg_.server_port);
  }
  std::string err;
  if (cfg_.use_server && !server_url_.empty()) {
    if (!ensure_server(&err)) {
      std::cerr << "intercom kokoro: warm server unavailable (" << err
                << ") — falling back to CLI" << std::endl;
      child_.reset();
      if (cfg_.server_url.empty()) server_url_.clear();
    }
  }
}

KokoroTts::~KokoroTts() = default;

std::string KokoroTts::find_server_script() const {
  std::vector<std::string> candidates;
  if (!cfg_.server_script.empty()) candidates.push_back(cfg_.server_script);
  if (const char* env = std::getenv("INTERCOM_KOKORO_SERVER")) {
    if (*env) candidates.emplace_back(env);
  }
  if (INTERCOM_SCRIPTS_DIR[0] != '\0') {
    candidates.emplace_back(std::string(INTERCOM_SCRIPTS_DIR) + "/kokoro_server.py");
  }
  const std::string exe_dir = this_executable_dir();
  if (!exe_dir.empty()) {
    candidates.push_back(exe_dir + "/kokoro_server.py");
    candidates.push_back(exe_dir + "/../scripts/kokoro_server.py");
    candidates.push_back(exe_dir + "/../share/intercom/kokoro_server.py");
  }
  candidates.emplace_back("scripts/kokoro_server.py");

  for (const auto& raw : candidates) {
    std::error_code ec;
    const auto path = std::filesystem::weakly_canonical(std::filesystem::path(raw), ec);
    const std::string s = ec ? raw : path.string();
    if (file_exists(s)) return s;
  }
  return {};
}

bool KokoroTts::ensure_server(std::string* err) {
  if (!server_url_.empty() && http_get_ok(server_url_ + "/health", 400)) {
    return true;
  }
  if (!cfg_.server_url.empty()) {
    if (err) *err = "kokoro server_url not reachable: " + cfg_.server_url;
    return false;
  }

  if (!file_exists(cfg_.model) || !file_exists(cfg_.voices)) {
    if (err) *err = "kokoro model/voices missing";
    return false;
  }

  const std::string script = find_server_script();
  if (script.empty()) {
    if (err) *err = "kokoro_server.py not found";
    return false;
  }

  std::string python;
  const std::string tts_bin = which_executable(cfg_.binary);
  if (!tts_bin.empty()) {
    python = shebang_interpreter(tts_bin);
    if (python.empty()) {
      python = sibling_binary(tts_bin, "python");
    }
  }
  if (python.empty() || ::access(python.c_str(), X_OK) != 0) {
    python = which_executable("python3");
  }
  if (python.empty()) {
    if (err) *err = "python interpreter for kokoro_server.py not found";
    return false;
  }

  std::vector<std::string> argv = {
      python,
      script,
      "--model",
      cfg_.model,
      "--voices",
      cfg_.voices,
      "--voice",
      cfg_.voice,
      "--speed",
      std::to_string(cfg_.speed),
      "--host",
      "127.0.0.1",
      "--port",
      std::to_string(cfg_.server_port),
  };
  child_ = std::make_unique<ManagedServer>();
  return child_->start("kokoro", argv, server_url_ + "/health", 60000, err);
}

bool KokoroTts::ready(std::string* detail) const {
  if (!server_url_.empty() && http_get_ok(server_url_ + "/health", 400)) {
    std::size_t n = 0;
    {
      std::lock_guard<std::mutex> lk(mu_);
      n = cache_.size();
    }
    if (detail) {
      *detail = "server " + server_url_ + ", " + std::to_string(n) + " cached acks";
    }
    return true;
  }
  if (!executable_on_path_or_file(cfg_.binary)) {
    if (detail) *detail = "kokoro-tts binary not found: " + cfg_.binary;
    return false;
  }
  if (!file_exists(cfg_.model)) {
    if (detail) *detail = "kokoro model missing: " + cfg_.model;
    return false;
  }
  if (!file_exists(cfg_.voices)) {
    if (detail) *detail = "kokoro voices missing: " + cfg_.voices;
    return false;
  }
  if (detail) *detail = "ok (cli)";
  return true;
}

void KokoroTts::warmup() {
  std::string err;
  for (const auto& phrase : FillerClient::cached_ack_phrases()) {
    pending_delivery_ = classify_speech_delivery(phrase);
    pending_speed_ = std::clamp(
        cfg_.speed * delivery_speed_multiplier(pending_delivery_), 0.5, 2.0);
    pending_pause_ms_ = std::max(
        0, speech_pause_ms(phrase) +
               delivery_pause_adjustment_ms(pending_delivery_));
    std::vector<std::uint8_t> pcm;
    const bool ok = synthesize_live(phrase,
                                    [&](const std::uint8_t* data, std::size_t len) {
                                      pcm.insert(pcm.end(), data, data + len);
                                      return true;
                                    },
                                    &err);
    if (!ok || pcm.empty()) {
      std::cerr << "intercom kokoro: ack cache miss for \"" << phrase << "\"";
      if (!err.empty()) std::cerr << " (" << err << ")";
      std::cerr << std::endl;
      continue;
    }
    std::lock_guard<std::mutex> lk(mu_);
    cache_[phrase] = std::move(pcm);
  }
  std::lock_guard<std::mutex> lk(mu_);
  std::cout << "intercom kokoro: cached " << cache_.size() << " instant-ack phrases"
            << std::endl;
}

bool KokoroTts::emit_pcm(const std::vector<std::uint8_t>& pcm,
                         PcmChunkFn on_chunk,
                         std::string* err) {
  // Shape the trailing edge once here (not in the Python server). The device
  // already fades in the start of a response to protect the amplifier, so a
  // second leading fade would swallow initial consonants.
  SpeechDspProcessor processor(
      cfg_.dsp, target_sample_rate_, delivery_gain_db(pending_delivery_));
  std::vector<std::uint8_t> shaped = processor.process(pcm);
  fade_s16le_mono_edges(&shaped, target_sample_rate_, 0, 14);
  const auto tail =
      silence_s16le_mono(target_sample_rate_, pending_pause_ms_);
  shaped.insert(shaped.end(), tail.begin(), tail.end());
  return emit_chunks(shaped, on_chunk, err);
}

bool KokoroTts::synthesize(const std::string& text, PcmChunkFn on_chunk, std::string* err) {
  if (text.empty()) return true;
  std::lock_guard<std::mutex> utterance_lk(synthesize_mu_);
  pending_delivery_ = classify_speech_delivery(text);
  pending_speed_ = std::clamp(
      cfg_.speed * delivery_speed_multiplier(pending_delivery_), 0.5, 2.0);
  pending_pause_ms_ = std::max(
      0, speech_pause_ms(text) +
             delivery_pause_adjustment_ms(pending_delivery_));
  std::vector<std::uint8_t> cached;
  {
    std::lock_guard<std::mutex> lk(mu_);
    auto it = cache_.find(text);
    if (it != cache_.end()) cached = it->second;
  }
  // Warmup caches the already-shaped stream; do not fade or pad it twice.
  if (!cached.empty()) return emit_chunks(cached, on_chunk, err);
  return synthesize_live(text, on_chunk, err);
}

bool KokoroTts::synthesize_live(const std::string& text,
                                PcmChunkFn on_chunk,
                                std::string* err) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!server_url_.empty()) {
    std::string http_err;
    if (target_sample_rate_ == 24000 &&
        synthesize_http_stream(text, on_chunk, &http_err)) {
      return true;
    }
    if (http_err == "tts sink aborted" ||
        http_err.rfind("kokoro stream interrupted", 0) == 0) {
      if (err) *err = http_err;
      return false;
    }
    if (synthesize_http(text, on_chunk, &http_err)) return true;
    if (err) *err = http_err;
    if (cfg_.server_url.empty()) {
      // Spawned/attached server failed; try CLI once rather than stall the turn.
      std::cerr << "intercom kokoro: server synth failed (" << http_err
                << ") — trying CLI" << std::endl;
    } else {
      return false;
    }
  }
  return synthesize_cli(text, on_chunk, err);
}

bool KokoroTts::synthesize_http_stream(const std::string& text,
                                       PcmChunkFn on_chunk,
                                       std::string* err) {
  auto parsed = parse_http_url(server_url_);
  if (!parsed) {
    if (err) *err = "invalid kokoro server_url";
    return false;
  }

  httplib::Client cli(parsed->host, parsed->port);
  cli.set_connection_timeout(5, 0);
  cli.set_read_timeout(120, 0);
  cli.set_write_timeout(30, 0);

  httplib::Request req;
  req.method = "POST";
  req.path = parsed->path + "/v1/tts/stream";
  req.set_header("Content-Type", "application/json");
  req.set_header("Accept", "audio/L16");
  req.body =
      nlohmann::json({{"text", text}, {"speed", pending_speed_}}).dump();

  bool sink_aborted = false;
  bool delivered_audio = false;
  int response_status = 0;
  SpeechDspProcessor processor(
      cfg_.dsp, target_sample_rate_, delivery_gain_db(pending_delivery_));
  // Hold the final few milliseconds so the streaming path can shape the
  // trailing edge exactly like buffered synthesis instead of ending abruptly.
  const std::size_t fade_bytes =
      static_cast<std::size_t>(target_sample_rate_) * 14 / 1000 * 2;
  std::vector<std::uint8_t> stream_tail;
  req.response_handler = [&](const httplib::Response& response) {
    response_status = response.status;
    return true;
  };
  req.content_receiver = [&](const char* data, std::size_t len,
                             std::uint64_t, std::uint64_t) {
    if (len == 0) return true;
    if (response_status != 200) return true;
    delivered_audio = true;
    const auto processed = processor.process(
        reinterpret_cast<const std::uint8_t*>(data), len);
    stream_tail.insert(stream_tail.end(), processed.begin(), processed.end());
    if (stream_tail.size() > fade_bytes) {
      std::size_t emit_bytes = stream_tail.size() - fade_bytes;
      emit_bytes -= emit_bytes % 2;
      if (emit_bytes > 0 && on_chunk &&
          !on_chunk(stream_tail.data(), emit_bytes)) {
        sink_aborted = true;
        return false;
      }
      stream_tail.erase(stream_tail.begin(), stream_tail.begin() + emit_bytes);
    }
    return true;
  };

  auto res = cli.send(req);
  if (sink_aborted) {
    if (err) *err = "tts sink aborted";
    return false;
  }
  if (!res) {
    if (err) {
      *err = delivered_audio ? "kokoro stream interrupted after audio"
                             : "kokoro stream: connection failed";
    }
    return false;
  }
  if (res->status == 404) {
    if (err) *err = "kokoro stream endpoint unavailable";
    return false;
  }
  if (res->status != 200) {
    if (err) {
      *err = "kokoro stream HTTP " + std::to_string(res->status);
    }
    return false;
  }
  if (!delivered_audio) {
    if (err) *err = "kokoro stream: empty audio";
    return false;
  }

  fade_s16le_mono_edges(&stream_tail, target_sample_rate_, 0, 14);
  if (!stream_tail.empty() && on_chunk &&
      !on_chunk(stream_tail.data(), stream_tail.size())) {
    if (err) *err = "tts sink aborted";
    return false;
  }
  const auto tail =
      silence_s16le_mono(target_sample_rate_, pending_pause_ms_);
  return emit_chunks(tail, on_chunk, err);
}

bool KokoroTts::synthesize_http(const std::string& text,
                                PcmChunkFn on_chunk,
                                std::string* err) {
  auto parsed = parse_http_url(server_url_);
  if (!parsed) {
    if (err) *err = "invalid kokoro server_url";
    return false;
  }
  httplib::Client cli(parsed->host, parsed->port);
  cli.set_connection_timeout(5, 0);
  cli.set_read_timeout(120, 0);
  cli.set_write_timeout(30, 0);
  nlohmann::json body = {{"text", text}, {"speed", pending_speed_}};
  const std::string path = parsed->path + "/v1/tts";
  auto res = cli.Post(path.c_str(), body.dump(), "application/json");
  if (!res) {
    if (err) *err = "kokoro server: connection failed";
    return false;
  }
  if (res->status != 200) {
    if (err) *err = "kokoro server HTTP " + std::to_string(res->status) + ": " + res->body;
    return false;
  }
  int wav_rate = 0;
  int wav_ch = 0;
  auto pcm = parse_wav_s16le(reinterpret_cast<const std::uint8_t*>(res->body.data()),
                             res->body.size(), &wav_rate, &wav_ch);
  if (!pcm) {
    if (err) *err = "kokoro server: invalid wav";
    return false;
  }
  if (!normalize_pcm(&*pcm, wav_rate, wav_ch, target_sample_rate_)) {
    if (err) *err = "kokoro server: pcm normalize failed";
    return false;
  }
  return emit_pcm(*pcm, on_chunk, err);
}

bool KokoroTts::synthesize_cli(const std::string& text,
                               PcmChunkFn on_chunk,
                               std::string* err) {
  std::string ready_detail;
  if (!executable_on_path_or_file(cfg_.binary) || !file_exists(cfg_.model) ||
      !file_exists(cfg_.voices)) {
    if (err) *err = ready_detail.empty() ? "kokoro-tts not ready" : ready_detail;
    return false;
  }

  const std::string id = make_turn_id();
  const auto dir = std::filesystem::temp_directory_path();
  const std::string text_path =
      (dir / ("intercom-kokoro-tts-" + id + ".txt")).string();
  const std::string wav_path =
      (dir / ("intercom-kokoro-tts-" + id + ".wav")).string();

  if (!write_text_file(text_path, text)) {
    if (err) *err = "failed to write kokoro text temp file";
    return false;
  }

  std::ostringstream cmd;
  cmd << shell_quote(cfg_.binary)
      << " " << shell_quote(text_path)
      << " " << shell_quote(wav_path)
      << " --voice " << shell_quote(cfg_.voice)
      << " --speed " << pending_speed_
      << " --format wav"
      << " --model " << shell_quote(cfg_.model)
      << " --voices " << shell_quote(cfg_.voices)
      << " 2>/dev/null";

  const int rc = std::system(cmd.str().c_str());
  std::error_code ec;
  std::filesystem::remove(text_path, ec);

#if !defined(_WIN32)
  const int exit_code = WIFEXITED(rc) ? WEXITSTATUS(rc) : -1;
#else
  const int exit_code = rc;
#endif
  if (exit_code != 0 || !file_exists(wav_path)) {
    std::filesystem::remove(wav_path, ec);
    if (err) *err = "kokoro-tts failed (exit " + std::to_string(exit_code) + ")";
    return false;
  }

  int wav_rate = 0;
  int wav_ch = 0;
  auto pcm = read_wav_s16le(wav_path, &wav_rate, &wav_ch);
  std::filesystem::remove(wav_path, ec);
  if (!pcm) {
    if (err) *err = "failed to read kokoro wav";
    return false;
  }
  if (!normalize_pcm(&*pcm, wav_rate, wav_ch, target_sample_rate_)) {
    if (err) *err = "kokoro pcm normalize failed";
    return false;
  }
  return emit_pcm(*pcm, on_chunk, err);
}

}  // namespace intercom

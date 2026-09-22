#pragma once

#include "intercom/arbiter_client.hpp"
#include "intercom/config.hpp"
#include "intercom/fast_path.hpp"
#include "intercom/filler_client.hpp"
#include "intercom/session_store.hpp"
#include "intercom/stt.hpp"
#include "intercom/tts.hpp"

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace intercom {

// Sink for reply PCM — HTTP chunked body or WebSocket binary frames.
class AudioSink {
 public:
  virtual ~AudioSink() = default;
  // Return false to abort synthesis / pipeline.
  virtual bool write(const std::uint8_t* data, std::size_t len) = 0;
  // Optional side-channel (WS JSON). HTTP and tests ignore it.
  // type is "heard", "said", "working", "status", "forming", or "surface";
  // value is text, a tool name, or (for surface) a JSON object string
  // `{turn_id, surface}`.
  virtual void event(const char* type, const std::string& value) {
    (void)type;
    (void)value;
  }
};

struct TurnResult {
  std::string turn_id;
  std::string transcript;
  std::int64_t conversation_id = 0;
  bool ok = false;
  std::string error;
  bool used_fast_path = false;
  std::string fast_path_kind;
};

struct TurnHandle {
  std::string turn_id;
  std::atomic<bool> cancel{false};
  std::string arbiter_request_id;
  std::mutex mu;
};

// Transport-agnostic utterance pipeline (HTTP PTT and WS duplex).
class TurnPipeline {
 public:
  TurnPipeline(Config config,
               std::shared_ptr<SttProvider> stt,
               std::shared_ptr<TtsProvider> tts,
               std::shared_ptr<ArbiterClient> arbiter,
               std::shared_ptr<SessionStore> sessions,
               std::shared_ptr<FillerClient> filler = nullptr);

  TurnResult run_utterance(const std::string& device_id,
                           const std::vector<std::uint8_t>& pcm,
                           int sample_rate,
                           int channels,
                           AudioSink& sink,
                           std::string turn_id = {});

  // Same as run_utterance after STT — used when the transport already has text
  // (HTTP sets X-Transcript before streaming PCM; WS can feed partials later).
  // If turn_id is non-empty it is used; otherwise a new id is generated.
  TurnResult run_text_utterance(const std::string& device_id,
                                const std::string& transcript,
                                AudioSink& sink,
                                std::string turn_id = {},
                                int stt_ms = -1);

  bool cancel_turn(const std::string& turn_id, std::string* err);

  std::optional<DeviceSession> session_for(const std::string& device_id) const;

  // Create per-device conversations and send PREFIX WARM so a local model
  // caches Arthur's constitution before the first PTT. Best-effort.
  void warm_prefix();

  const Config& config() const { return config_; }
  SttProvider& stt() { return *stt_; }
  TtsProvider& tts() { return *tts_; }
  ArbiterClient& arbiter() { return *arbiter_; }

 private:
  std::int64_t ensure_conversation(const std::string& device_id, std::string* err);
  void register_turn(std::shared_ptr<TurnHandle> h);
  void unregister_turn(const std::string& turn_id);
  std::shared_ptr<TurnHandle> find_turn(const std::string& turn_id);

  Config config_;
  std::shared_ptr<SttProvider> stt_;
  std::shared_ptr<TtsProvider> tts_;
  std::shared_ptr<ArbiterClient> arbiter_;
  std::shared_ptr<SessionStore> sessions_;
  std::shared_ptr<FillerClient> filler_;
  FastPath fast_path_;

  mutable std::mutex turns_mu_;
  std::unordered_map<std::string, std::shared_ptr<TurnHandle>> turns_;
};

}  // namespace intercom

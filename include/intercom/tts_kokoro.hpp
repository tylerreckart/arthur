#pragma once

#include "intercom/config.hpp"
#include "intercom/speech_delivery.hpp"
#include "intercom/tts.hpp"

#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace intercom {

class ManagedServer;

class KokoroTts : public TtsProvider {
 public:
  KokoroTts(KokoroConfig cfg, int target_sample_rate);
  ~KokoroTts() override;

  KokoroTts(const KokoroTts&) = delete;
  KokoroTts& operator=(const KokoroTts&) = delete;

  bool synthesize(const std::string& text,
                  PcmChunkFn on_chunk,
                  std::string* err) override;

  bool ready(std::string* detail) const override;
  void warmup() override;

 private:
  bool emit_pcm(const std::vector<std::uint8_t>& pcm, PcmChunkFn on_chunk, std::string* err);
  bool synthesize_live(const std::string& text, PcmChunkFn on_chunk, std::string* err);
  bool synthesize_http_stream(const std::string& text,
                              PcmChunkFn on_chunk,
                              std::string* err);
  bool synthesize_http(const std::string& text, PcmChunkFn on_chunk, std::string* err);
  bool synthesize_cli(const std::string& text, PcmChunkFn on_chunk, std::string* err);
  bool ensure_server(std::string* err);
  std::string find_server_script() const;

  KokoroConfig cfg_;
  int target_sample_rate_;
  std::string server_url_;
  std::unique_ptr<ManagedServer> child_;
  // Delivery state is per utterance; keep it stable until that utterance has
  // finished even when speak-back and an interactive turn overlap.
  std::mutex synthesize_mu_;
  mutable std::mutex mu_;
  int pending_pause_ms_ = 200;
  double pending_speed_ = 1.1;
  SpeechDelivery pending_delivery_ = SpeechDelivery::Neutral;
  std::unordered_map<std::string, std::vector<std::uint8_t>> cache_;
};

}  // namespace intercom

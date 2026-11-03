#pragma once

#include "intercom/config.hpp"

#include <atomic>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace intercom {

enum class FillerStage {
  Initial,
  FollowUp,
};

// Lightweight spoken asides while Arbiter is still quiet.
class FillerClient {
 public:
  explicit FillerClient(FillerConfig config);

  bool enabled() const { return config_.enabled && !config_.api_key.empty(); }

  // Ultra-short local ack — no network, for immediate playback.
  static std::string instant_ack();
  static std::vector<std::string> instant_ack_phrases();
  // Local + tool acks, for Kokoro PCM warmup.
  static std::vector<std::string> cached_ack_phrases();
  // Cached tool-wait phrase chosen from the tool name.
  static std::string tool_ack(std::string_view tool);
  // Conservative local cue for a genuinely long tool wait.
  static std::string progress_ack();

  // Returns empty on failure, disabled, or cancel.
  std::string generate(const std::string& transcript,
                       FillerStage stage,
                       const std::string& previous_phrase,
                       std::atomic<bool>* cancel_flag,
                       std::string* err) const;

 private:
  FillerConfig config_;
};

}  // namespace intercom

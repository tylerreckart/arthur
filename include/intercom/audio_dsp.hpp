#pragma once

#include "intercom/config.hpp"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace intercom {

// Stateful mono s16le speech processor. State carries across HTTP chunks so
// streamed and complete-WAV synthesis sound the same.
class SpeechDspProcessor {
 public:
  SpeechDspProcessor(SpeechDspConfig config,
                     int sample_rate,
                     double delivery_gain_db = 0.0);

  std::vector<std::uint8_t> process(const std::uint8_t* data, std::size_t len);
  std::vector<std::uint8_t> process(const std::vector<std::uint8_t>& pcm) {
    return process(pcm.data(), pcm.size());
  }

 private:
  double process_sample(double input);

  SpeechDspConfig config_;
  int sample_rate_ = 24000;
  double output_gain_ = 1.0;
  double limiter_ = 0.891;

  double hp_alpha_ = 0.0;
  double hp_x1_ = 0.0;
  double hp_y1_ = 0.0;

  double b0_ = 1.0;
  double b1_ = 0.0;
  double b2_ = 0.0;
  double a1_ = 0.0;
  double a2_ = 0.0;
  double eq_x1_ = 0.0;
  double eq_x2_ = 0.0;
  double eq_y1_ = 0.0;
  double eq_y2_ = 0.0;

  double envelope_ = 0.0;
  double compressor_gain_ = 1.0;
  double attack_coeff_ = 0.0;
  double release_coeff_ = 0.0;
  bool has_odd_byte_ = false;
  std::uint8_t odd_byte_ = 0;
};

enum class UtteranceEndpointEvent {
  None,
  Completed,
};

// Energy detector for 24 kHz mono s16le. Speech starts the utterance, about
// 700 ms of trailing silence ends it, bursts under 300 ms are ignored, and
// an utterance is capped around 30 s.
struct UtteranceEndpointConfig {
  int sample_rate = 24000;
  int trailing_silence_ms = 700;
  int min_speech_ms = 300;
  int max_utterance_ms = 30000;
  // Window RMS, full scale 1.0. Set above typical room noise.
  double speech_rms = 0.02;
};

class UtteranceEndpoint {
 public:
  explicit UtteranceEndpoint(UtteranceEndpointConfig config = {});

  UtteranceEndpointEvent push(const std::uint8_t* data, std::size_t len);
  UtteranceEndpointEvent push(const std::vector<std::uint8_t>& pcm) {
    return push(pcm.data(), pcm.size());
  }
  void reset();

  bool speech_confirmed() const { return speech_confirmed_; }
  // True while the current clip has unconfirmed or confirmed speech.
  // False during leading silence and after a sub-300 ms blip is dropped.
  bool hearing() const { return speech_samples_ > 0 || speech_confirmed_; }
  // True once, on the push that first confirms speech.
  bool take_speech_onset();

 private:
  void consider_window(double sum_sq, int count);

  UtteranceEndpointConfig config_;
  int window_samples_ = 480;
  int min_speech_samples_ = 7200;
  int trailing_samples_ = 16800;
  int max_samples_ = 720000;

  std::vector<std::int16_t> pending_;
  std::size_t pending_read_ = 0;
  bool has_odd_byte_ = false;
  std::uint8_t odd_byte_ = 0;

  int speech_samples_ = 0;
  int silence_samples_ = 0;
  int utterance_samples_ = 0;
  bool speech_confirmed_ = false;
  bool onset_pending_ = false;
  bool completed_ = false;
};

}  // namespace intercom

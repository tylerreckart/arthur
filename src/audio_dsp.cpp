#include "intercom/audio_dsp.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <utility>

namespace intercom {
namespace {

constexpr double kPi = 3.14159265358979323846;

double db_to_gain(double db) {
  return std::pow(10.0, db / 20.0);
}

double time_coefficient(double milliseconds, int sample_rate) {
  if (milliseconds <= 0.0 || sample_rate <= 0) return 0.0;
  return std::exp(-1.0 / (milliseconds * 0.001 * sample_rate));
}

}  // namespace

SpeechDspProcessor::SpeechDspProcessor(SpeechDspConfig config,
                                       int sample_rate,
                                       double delivery_gain_db)
    : config_(std::move(config)),
      sample_rate_(std::max(8000, sample_rate)) {
  output_gain_ = db_to_gain(config_.makeup_db + delivery_gain_db);
  limiter_ = std::clamp(db_to_gain(config_.limiter_db), 0.1, 1.0);

  const double highpass =
      std::clamp(config_.highpass_hz, 0.0, sample_rate_ * 0.45);
  if (highpass > 0.0) {
    const double dt = 1.0 / sample_rate_;
    const double rc = 1.0 / (2.0 * kPi * highpass);
    hp_alpha_ = rc / (rc + dt);
  }

  const double presence =
      std::clamp(config_.presence_hz, 20.0, sample_rate_ * 0.45);
  const double q = std::max(0.1, config_.presence_q);
  if (std::abs(config_.presence_db) > 0.01) {
    const double a = std::pow(10.0, config_.presence_db / 40.0);
    const double omega = 2.0 * kPi * presence / sample_rate_;
    const double alpha = std::sin(omega) / (2.0 * q);
    const double cos_omega = std::cos(omega);
    const double a0 = 1.0 + alpha / a;
    b0_ = (1.0 + alpha * a) / a0;
    b1_ = (-2.0 * cos_omega) / a0;
    b2_ = (1.0 - alpha * a) / a0;
    a1_ = (-2.0 * cos_omega) / a0;
    a2_ = (1.0 - alpha / a) / a0;
  }

  attack_coeff_ =
      time_coefficient(std::max(0.1, config_.compressor_attack_ms), sample_rate_);
  release_coeff_ =
      time_coefficient(std::max(1.0, config_.compressor_release_ms), sample_rate_);
}

double SpeechDspProcessor::process_sample(double input) {
  if (!config_.enabled) return std::clamp(input, -1.0, 1.0);

  double sample = input;
  if (hp_alpha_ > 0.0) {
    const double filtered = hp_alpha_ * (hp_y1_ + sample - hp_x1_);
    hp_x1_ = sample;
    hp_y1_ = filtered;
    sample = filtered;
  }

  const double equalized =
      b0_ * sample + b1_ * eq_x1_ + b2_ * eq_x2_ -
      a1_ * eq_y1_ - a2_ * eq_y2_;
  eq_x2_ = eq_x1_;
  eq_x1_ = sample;
  eq_y2_ = eq_y1_;
  eq_y1_ = equalized;
  sample = equalized;

  const double level = std::abs(sample);
  const double env_coeff = level > envelope_ ? attack_coeff_ : release_coeff_;
  envelope_ = env_coeff * envelope_ + (1.0 - env_coeff) * level;

  const double threshold =
      std::clamp(db_to_gain(config_.compressor_threshold_db), 0.001, 1.0);
  const double ratio = std::max(1.0, config_.compressor_ratio);
  double target_gain = 1.0;
  if (envelope_ > threshold) {
    target_gain =
        std::pow(envelope_ / threshold, (1.0 / ratio) - 1.0);
  }
  const double gain_coeff =
      target_gain < compressor_gain_ ? attack_coeff_ : release_coeff_;
  compressor_gain_ =
      gain_coeff * compressor_gain_ + (1.0 - gain_coeff) * target_gain;

  sample *= compressor_gain_ * output_gain_;
  return std::clamp(sample, -limiter_, limiter_);
}

std::vector<std::uint8_t> SpeechDspProcessor::process(
    const std::uint8_t* data,
    std::size_t len) {
  if (!data || len == 0) return {};
  std::vector<std::uint8_t> input;
  input.reserve(len + (has_odd_byte_ ? 1 : 0));
  if (has_odd_byte_) {
    input.push_back(odd_byte_);
    has_odd_byte_ = false;
  }
  input.insert(input.end(), data, data + len);
  if (input.size() % 2 != 0) {
    odd_byte_ = input.back();
    has_odd_byte_ = true;
    input.pop_back();
  }
  if (!config_.enabled) return input;

  std::vector<std::uint8_t> output(input.size());
  for (std::size_t i = 0; i < input.size(); i += 2) {
    std::int16_t raw = 0;
    std::memcpy(&raw, input.data() + i, sizeof(raw));
    const double normalized = static_cast<double>(raw) / 32768.0;
    const double processed = process_sample(normalized);
    const auto value = static_cast<std::int16_t>(
        std::lround(processed * 32767.0));
    std::memcpy(output.data() + i, &value, sizeof(value));
  }
  return output;
}

UtteranceEndpoint::UtteranceEndpoint(UtteranceEndpointConfig config)
    : config_(std::move(config)) {
  const int rate = std::max(8000, config_.sample_rate);
  config_.sample_rate = rate;
  window_samples_ = std::max(1, rate / 50);
  const auto samples_for = [&](int ms) {
    return std::max(window_samples_, rate * std::max(0, ms) / 1000);
  };
  min_speech_samples_ = samples_for(config_.min_speech_ms);
  trailing_samples_ = samples_for(config_.trailing_silence_ms);
  max_samples_ = std::max(min_speech_samples_, samples_for(config_.max_utterance_ms));
  if (config_.speech_rms < 0.0) config_.speech_rms = 0.0;
}

void UtteranceEndpoint::reset() {
  pending_.clear();
  pending_read_ = 0;
  has_odd_byte_ = false;
  odd_byte_ = 0;
  speech_samples_ = 0;
  silence_samples_ = 0;
  utterance_samples_ = 0;
  speech_confirmed_ = false;
  onset_pending_ = false;
  completed_ = false;
}

bool UtteranceEndpoint::take_speech_onset() {
  if (!onset_pending_) return false;
  onset_pending_ = false;
  return true;
}

void UtteranceEndpoint::consider_window(double sum_sq, int count) {
  if (count <= 0 || completed_) return;
  const double rms = std::sqrt(sum_sq / static_cast<double>(count));
  const bool speech = rms >= config_.speech_rms;
  if (speech) {
    speech_samples_ += count;
    silence_samples_ = 0;
    utterance_samples_ += count;
    if (!speech_confirmed_ && speech_samples_ >= min_speech_samples_) {
      speech_confirmed_ = true;
      onset_pending_ = true;
    }
  } else if (speech_samples_ == 0) {
    return;
  } else {
    silence_samples_ += count;
    utterance_samples_ += count;
    if (!speech_confirmed_ && silence_samples_ >= min_speech_samples_) {
      speech_samples_ = 0;
      silence_samples_ = 0;
      utterance_samples_ = 0;
      return;
    }
  }
  if (speech_confirmed_ && (silence_samples_ >= trailing_samples_ ||
                            utterance_samples_ >= max_samples_)) {
    completed_ = true;
  }
}

UtteranceEndpointEvent UtteranceEndpoint::push(const std::uint8_t* data,
                                               std::size_t len) {
  if (completed_ || !data || len == 0) return UtteranceEndpointEvent::None;
  std::vector<std::uint8_t> bytes;
  bytes.reserve(len + (has_odd_byte_ ? 1 : 0));
  if (has_odd_byte_) {
    bytes.push_back(odd_byte_);
    has_odd_byte_ = false;
  }
  bytes.insert(bytes.end(), data, data + len);
  if (bytes.size() % 2 != 0) {
    odd_byte_ = bytes.back();
    has_odd_byte_ = true;
    bytes.pop_back();
  }
  for (std::size_t i = 0; i + 1 < bytes.size(); i += 2) {
    std::int16_t sample = 0;
    std::memcpy(&sample, bytes.data() + i, sizeof(sample));
    pending_.push_back(sample);
  }

  bool completed_now = false;
  while (pending_.size() - pending_read_ >=
         static_cast<std::size_t>(window_samples_)) {
    double sum_sq = 0.0;
    for (int i = 0; i < window_samples_; ++i) {
      const double x =
          static_cast<double>(pending_[pending_read_ + static_cast<std::size_t>(i)]) /
          32768.0;
      sum_sq += x * x;
    }
    pending_read_ += static_cast<std::size_t>(window_samples_);
    consider_window(sum_sq, window_samples_);
    if (pending_read_ >= 4096 && pending_read_ * 2 > pending_.size()) {
      pending_.erase(pending_.begin(),
                     pending_.begin() + static_cast<std::ptrdiff_t>(pending_read_));
      pending_read_ = 0;
    }
    if (completed_) {
      completed_now = true;
      pending_.clear();
      pending_read_ = 0;
      break;
    }
  }
  return completed_now ? UtteranceEndpointEvent::Completed
                       : UtteranceEndpointEvent::None;
}

}  // namespace intercom

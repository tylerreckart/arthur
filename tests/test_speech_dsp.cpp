#include "intercom/audio_dsp.hpp"
#include "intercom/speech_delivery.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
#include <iostream>
#include <string>
#include <vector>

namespace {

int g_fails = 0;

void expect(bool cond, const char* expr, const char* file, int line) {
  if (!cond) {
    std::cerr << "FAIL " << file << ":" << line << " " << expr << "\n";
    ++g_fails;
  }
}

#define CHECK(cond) expect((cond), #cond, __FILE__, __LINE__)

std::vector<std::uint8_t> pcm(std::size_t count,
                              const std::function<std::int16_t(std::size_t)>& fn) {
  std::vector<std::uint8_t> out(count * 2);
  for (std::size_t i = 0; i < count; ++i) {
    const std::int16_t sample = fn(i);
    std::memcpy(out.data() + i * 2, &sample, sizeof(sample));
  }
  return out;
}

std::int16_t sample_at(const std::vector<std::uint8_t>& data, std::size_t i) {
  std::int16_t value = 0;
  std::memcpy(&value, data.data() + i * 2, sizeof(value));
  return value;
}

}  // namespace

int main() {
  intercom::SpeechDspConfig off;
  off.enabled = false;
  const auto source = pcm(32, [](std::size_t i) {
    return static_cast<std::int16_t>(i * 1000 - 15000);
  });
  intercom::SpeechDspProcessor bypass(off, 24000);
  CHECK(bypass.process(source) == source);

  intercom::SpeechDspConfig config;
  const auto tone = pcm(2400, [](std::size_t i) {
    return static_cast<std::int16_t>(
        std::sin(2.0 * 3.14159265358979323846 * i / 48.0) * 28000.0);
  });
  intercom::SpeechDspProcessor whole(config, 24000);
  const auto processed_whole = whole.process(tone);

  intercom::SpeechDspProcessor chunked(config, 24000);
  std::vector<std::uint8_t> processed_chunks;
  for (std::size_t offset = 0; offset < tone.size(); offset += 317) {
    const std::size_t count = std::min<std::size_t>(317, tone.size() - offset);
    const auto part = chunked.process(tone.data() + offset, count);
    processed_chunks.insert(processed_chunks.end(), part.begin(), part.end());
  }
  CHECK(processed_chunks == processed_whole);

  const double limit = std::pow(10.0, config.limiter_db / 20.0) * 32767.0 + 1.0;
  for (std::size_t i = 0; i < processed_whole.size() / 2; ++i) {
    CHECK(std::abs(static_cast<int>(sample_at(processed_whole, i))) <= limit);
  }

  const auto dc = pcm(24000, [](std::size_t) {
    return static_cast<std::int16_t>(10000);
  });
  intercom::SpeechDspProcessor dc_filter(config, 24000);
  const auto filtered = dc_filter.process(dc);
  CHECK(std::abs(static_cast<int>(sample_at(filtered, 23999))) < 100);

  CHECK(intercom::classify_speech_delivery("Good morning, sir.") ==
        intercom::SpeechDelivery::Warm);
  CHECK(intercom::classify_speech_delivery("Just a moment.") ==
        intercom::SpeechDelivery::Subdued);
  CHECK(intercom::classify_speech_delivery("Just a tick.") ==
        intercom::SpeechDelivery::Subdued);
  CHECK(intercom::classify_speech_delivery("Yes, sir.") ==
        intercom::SpeechDelivery::Subdued);
  CHECK(intercom::classify_speech_delivery("Right away.") ==
        intercom::SpeechDelivery::Subdued);
  CHECK(intercom::classify_speech_delivery("Of course.") ==
        intercom::SpeechDelivery::Subdued);
  CHECK(intercom::classify_speech_delivery(
            "Warning, sir. The front door is still open.") ==
        intercom::SpeechDelivery::Firm);
  CHECK(intercom::classify_speech_delivery("It is twelve thirty.") ==
        intercom::SpeechDelivery::Neutral);
  CHECK(intercom::delivery_gain_db(intercom::SpeechDelivery::Subdued) < 0.0);
  CHECK(intercom::delivery_gain_db(intercom::SpeechDelivery::Firm) > 0.0);
  CHECK(intercom::delivery_speed_multiplier(intercom::SpeechDelivery::Warm) >= 1.0);
  CHECK(intercom::delivery_speed_multiplier(intercom::SpeechDelivery::Firm) >= 1.0);
  CHECK(intercom::delivery_speed_multiplier(intercom::SpeechDelivery::Subdued) >= 1.0);

  constexpr int kRate = 24000;
  auto burst = [](int ms, int amplitude) {
    const std::size_t n = static_cast<std::size_t>(kRate) * static_cast<std::size_t>(ms) / 1000;
    return pcm(n, [amplitude](std::size_t i) {
      if (amplitude == 0) return static_cast<std::int16_t>(0);
      return static_cast<std::int16_t>(
          std::sin(2.0 * 3.14159265358979323846 * static_cast<double>(i) / 48.0) *
          amplitude);
    });
  };

  intercom::UtteranceEndpoint silence;
  CHECK(silence.push(burst(1000, 0)) == intercom::UtteranceEndpointEvent::None);
  CHECK(!silence.speech_confirmed());

  intercom::UtteranceEndpoint blip;
  const auto blip_pcm = burst(200, 9000);
  const auto blip_gap = burst(1000, 0);
  CHECK(blip.push(blip_pcm) == intercom::UtteranceEndpointEvent::None);
  CHECK(blip.push(blip_gap) == intercom::UtteranceEndpointEvent::None);
  CHECK(!blip.speech_confirmed());

  intercom::UtteranceEndpoint spoken;
  CHECK(spoken.push(burst(400, 9000)) == intercom::UtteranceEndpointEvent::None);
  CHECK(spoken.speech_confirmed());
  CHECK(spoken.take_speech_onset());
  CHECK(!spoken.take_speech_onset());
  CHECK(spoken.push(burst(800, 0)) == intercom::UtteranceEndpointEvent::Completed);

  intercom::UtteranceEndpoint capped;
  const auto long_speech = burst(30100, 9000);
  bool capped_done = false;
  for (std::size_t offset = 0; offset < long_speech.size(); offset += 960) {
    const std::size_t n = std::min<std::size_t>(960, long_speech.size() - offset);
    if (capped.push(long_speech.data() + offset, n) ==
        intercom::UtteranceEndpointEvent::Completed) {
      capped_done = true;
      break;
    }
  }
  CHECK(capped_done);
  CHECK(capped.speech_confirmed());

  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_speech_dsp ok\n";
  return 0;
}

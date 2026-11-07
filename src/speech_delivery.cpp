#include "intercom/speech_delivery.hpp"
#include "intercom/util.hpp"

#include <array>
#include <string>

namespace intercom {
namespace {

bool contains_any(const std::string& text,
                  const std::initializer_list<const char*>& needles) {
  for (const char* needle : needles) {
    if (text.find(needle) != std::string::npos) return true;
  }
  return false;
}

bool equals_any(const std::string& text,
                const std::initializer_list<const char*>& needles) {
  for (const char* needle : needles) {
    if (text == needle) return true;
  }
  return false;
}

}  // namespace

SpeechDelivery classify_speech_delivery(std::string_view text) {
  const std::string lower = to_lower(trim(text));
  if (lower.empty()) return SpeechDelivery::Neutral;

  if (contains_any(lower, {"warning", "danger", "urgent", "smoke", "fire",
                           "gas leak", "water leak", "still open",
                           "unlocked", "failed", "failure", "cannot safely",
                           "immediately"})) {
    return SpeechDelivery::Firm;
  }

  if (equals_any(lower, {"yes.", "yes", "got it.", "got it"}) ||
      contains_any(lower, {"yes, sir", "of course", "very good", "right away",
                           "certainly", "still with you", "nearly there",
                           "just a moment", "just a tick", "one moment",
                           "let me check", "i'll have a look", "still looking",
                           "hang on"})) {
    return SpeechDelivery::Subdued;
  }

  if (contains_any(lower, {"good morning", "good afternoon", "good evening",
                           "good night", "you're welcome", "thank you",
                           "glad to", "how can i help", "what can i do for you",
                           "what's on your mind", "sleep well"})) {
    return SpeechDelivery::Warm;
  }

  return SpeechDelivery::Neutral;
}

double delivery_speed_multiplier(SpeechDelivery delivery) {
  // Stay at or above 1. Kokoro's speed is a phoneme-duration divisor, so a
  // multiplier under 1 stretches vowels and is what reads as slurred.
  switch (delivery) {
    case SpeechDelivery::Warm:
      return 1.0;
    case SpeechDelivery::Subdued:
      return 1.05;
    case SpeechDelivery::Firm:
      return 1.0;
    case SpeechDelivery::Neutral:
      return 1.0;
  }
  return 1.0;
}

double delivery_gain_db(SpeechDelivery delivery) {
  switch (delivery) {
    case SpeechDelivery::Subdued:
      return -1.8;
    case SpeechDelivery::Firm:
      return 0.8;
    case SpeechDelivery::Warm:
    case SpeechDelivery::Neutral:
      return 0.0;
  }
  return 0.0;
}

int delivery_pause_adjustment_ms(SpeechDelivery delivery) {
  switch (delivery) {
    case SpeechDelivery::Warm:
      return 25;
    case SpeechDelivery::Firm:
      return 35;
    case SpeechDelivery::Subdued:
      return -35;
    case SpeechDelivery::Neutral:
      return 0;
  }
  return 0;
}

}  // namespace intercom

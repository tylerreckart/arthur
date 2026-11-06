#pragma once

#include "intercom/local_context.hpp"

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace intercom {

// Classic short-term voiceprint (mean mel cepstra), not a neural model.
// Enough to keep two enrolled voices apart in tests, and conservative
// enough that a poor match becomes the household rather than the wrong name.
inline constexpr int kVoiceDims = 13;
inline constexpr float kSpeakerMinScore = 0.84f;
inline constexpr float kSpeakerMargin = 0.04f;
inline constexpr int kEnrollmentPhrases = 3;

struct Voiceprint {
  float v[kVoiceDims]{};
};

struct EnrolledSpeaker {
  std::string person_id;
  std::string name;
  std::vector<Voiceprint> prints;
};

struct SpeakerIdentity {
  std::string person_id;
  std::string name;
  float score = 0;
  bool confident = false;
  int score_ms = -1;
};

// Mono s16le. Stereo uses the first channel. A clip under half a second,
// or silence, yields a zero print that never matches.
Voiceprint embed_pcm(const std::uint8_t* pcm, std::size_t bytes, int sample_rate,
                     int channels);

float voice_cosine(const Voiceprint& a, const Voiceprint& b);

// Confident only when the best enrolled voice clears the absolute score and
// leads the runner-up. Fewer than three phrases is not enrolled yet.
// An empty roster is the household.
SpeakerIdentity identify_speaker(const std::vector<EnrolledSpeaker>& enrolled,
                                 const Voiceprint& utterance);

// Personal calendars are sources named cal-<person_id>. A confident speaker
// keeps only their own. Everyone else keeps the household `calendar` source
// and loses every personal one.
ClientContext context_for_speaker(ClientContext context, const SpeakerIdentity& who);

// Private instruction. Not stored on the session and not spoken back.
std::string speaker_note(const SpeakerIdentity& who);

}  // namespace intercom

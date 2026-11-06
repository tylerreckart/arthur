#include "intercom/voiceprint.hpp"

#include <algorithm>
#include <cmath>
#include <complex>
#include <vector>

namespace intercom {
namespace {

constexpr int kFft = 256;
constexpr int kMels = 20;
constexpr float kMinHz = 80.f;
constexpr float kMaxHz = 4000.f;

float hz_to_mel(float hz) { return 2595.f * std::log10(1.f + hz / 700.f); }
float mel_to_hz(float mel) { return 700.f * (std::pow(10.f, mel / 2595.f) - 1.f); }

void fft(std::vector<std::complex<float>>& a) {
  const int n = static_cast<int>(a.size());
  for (int i = 1, j = 0; i < n; ++i) {
    int bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) std::swap(a[i], a[j]);
  }
  for (int len = 2; len <= n; len <<= 1) {
    const float ang = -2.f * 3.1415926535f / static_cast<float>(len);
    const std::complex<float> wlen(std::cos(ang), std::sin(ang));
    for (int i = 0; i < n; i += len) {
      std::complex<float> w(1.f, 0.f);
      for (int j = 0; j < len / 2; ++j) {
        const auto u = a[i + j];
        const auto v = a[i + j + len / 2] * w;
        a[i + j] = u + v;
        a[i + j + len / 2] = u - v;
        w *= wlen;
      }
    }
  }
}

std::vector<std::vector<float>> mel_bank(int sample_rate) {
  std::vector<float> points(kMels + 2);
  const float low = hz_to_mel(kMinHz);
  const float high = hz_to_mel(std::min(kMaxHz, sample_rate * 0.5f - 1.f));
  for (int i = 0; i < kMels + 2; ++i) {
    const float mel = low + (high - low) * static_cast<float>(i) / (kMels + 1);
    points[i] = std::floor((kFft + 1) * mel_to_hz(mel) / sample_rate);
  }
  std::vector<std::vector<float>> bank(kMels, std::vector<float>(kFft / 2 + 1, 0.f));
  for (int m = 1; m <= kMels; ++m) {
    const float left = points[m - 1];
    const float mid = points[m];
    const float right = points[m + 1];
    for (int k = 0; k <= kFft / 2; ++k) {
      const float bin = static_cast<float>(k);
      if (bin > left && bin < mid && mid > left) {
        bank[m - 1][k] = (bin - left) / (mid - left);
      } else if (bin >= mid && bin < right && right > mid) {
        bank[m - 1][k] = (right - bin) / (right - mid);
      }
    }
  }
  return bank;
}

}  // namespace

Voiceprint embed_pcm(const std::uint8_t* pcm, std::size_t bytes, int sample_rate,
                     int channels) {
  Voiceprint out;
  if (!pcm || sample_rate < 8000 || channels < 1) return out;
  const int ch = channels;
  const std::size_t frames = bytes / (static_cast<std::size_t>(ch) * 2);
  if (frames < static_cast<std::size_t>(sample_rate) / 2) return out;

  std::vector<float> mono(frames);
  double energy = 0;
  for (std::size_t i = 0; i < frames; ++i) {
    const std::size_t off = i * static_cast<std::size_t>(ch) * 2;
    const int sample = static_cast<int>(pcm[off]) | (static_cast<int>(pcm[off + 1]) << 8);
    const auto s16 = static_cast<std::int16_t>(sample);
    mono[i] = static_cast<float>(s16) / 32768.f;
    energy += static_cast<double>(mono[i]) * mono[i];
  }
  if (energy / static_cast<double>(frames) < 1e-6) return out;

  const auto bank = mel_bank(sample_rate);
  const int win = std::min(kFft, sample_rate / 40);  // about 25 ms
  const int hop = std::max(1, win / 2);
  std::vector<float> window(win);
  for (int i = 0; i < win; ++i) {
    window[i] = 0.54f - 0.46f * std::cos(2.f * 3.1415926535f * i / (win - 1));
  }

  double acc[kVoiceDims] = {};
  int used = 0;
  for (std::size_t start = 0; start + static_cast<std::size_t>(win) <= frames; start += hop) {
    std::vector<std::complex<float>> spec(kFft);
    float prev = 0;
    for (int i = 0; i < win; ++i) {
      const float x = mono[start + i];
      const float emphasized = x - 0.97f * prev;
      prev = x;
      spec[i] = emphasized * window[i];
    }
    fft(spec);
    std::vector<float> mel(kMels, 0.f);
    for (int m = 0; m < kMels; ++m) {
      float sum = 0;
      for (int k = 0; k <= kFft / 2; ++k) {
        const float re = spec[k].real();
        const float im = spec[k].imag();
        sum += bank[m][k] * (re * re + im * im);
      }
      mel[m] = std::log(sum + 1e-8f);
    }
    for (int c = 0; c < kVoiceDims; ++c) {
      float sum = 0;
      for (int m = 0; m < kMels; ++m) {
        sum += mel[m] * std::cos(3.1415926535f * c * (m + 0.5f) / kMels);
      }
      acc[c] += sum;
    }
    ++used;
    if (used > 400) break;
  }
  if (used == 0) return out;
  double norm = 0;
  for (int c = 0; c < kVoiceDims; ++c) {
    out.v[c] = static_cast<float>(acc[c] / used);
    norm += static_cast<double>(out.v[c]) * out.v[c];
  }
  norm = std::sqrt(norm);
  if (norm < 1e-6) return Voiceprint{};
  for (int c = 0; c < kVoiceDims; ++c) out.v[c] = static_cast<float>(out.v[c] / norm);
  return out;
}

float voice_cosine(const Voiceprint& a, const Voiceprint& b) {
  double dot = 0;
  double na = 0;
  double nb = 0;
  for (int i = 0; i < kVoiceDims; ++i) {
    dot += static_cast<double>(a.v[i]) * b.v[i];
    na += static_cast<double>(a.v[i]) * a.v[i];
    nb += static_cast<double>(b.v[i]) * b.v[i];
  }
  if (na < 1e-8 || nb < 1e-8) return 0;
  return static_cast<float>(dot / (std::sqrt(na) * std::sqrt(nb)));
}

SpeakerIdentity identify_speaker(const std::vector<EnrolledSpeaker>& enrolled,
                                 const Voiceprint& utterance) {
  SpeakerIdentity out;
  float best = -1.f;
  float second = -1.f;
  const EnrolledSpeaker* winner = nullptr;
  for (const auto& speaker : enrolled) {
    if (static_cast<int>(speaker.prints.size()) < kEnrollmentPhrases) continue;
    if (speaker.person_id.empty() || speaker.name.empty()) continue;
    float top = -1.f;
    for (const auto& print : speaker.prints) {
      top = std::max(top, voice_cosine(print, utterance));
    }
    if (top > best) {
      second = best;
      best = top;
      winner = &speaker;
    } else if (top > second) {
      second = top;
    }
  }
  out.score = best < 0 ? 0 : best;
  if (!winner) return out;
  const float margin = second < 0 ? best : best - second;
  if (best >= kSpeakerMinScore && margin >= kSpeakerMargin) {
    out.person_id = winner->person_id;
    out.name = winner->name;
    out.confident = true;
  }
  return out;
}

ClientContext context_for_speaker(ClientContext context, const SpeakerIdentity& who) {
  const std::string mine = who.confident ? "cal-" + who.person_id : "";
  bool have_mine = false;
  if (!mine.empty()) {
    for (const auto& source : context.sources) {
      if (source.name == mine) have_mine = true;
    }
  }
  std::vector<ClientContext::Source> kept;
  for (const auto& source : context.sources) {
    const bool personal = source.name.rfind("cal-", 0) == 0 && source.name.size() > 4;
    if (personal) {
      if (have_mine && source.name == mine) kept.push_back(source);
      continue;
    }
    if (source.name == "calendar" && have_mine) continue;
    kept.push_back(source);
  }
  context.sources = std::move(kept);
  return context;
}

std::string speaker_note(const SpeakerIdentity& who) {
  if (!who.confident || who.person_id.empty() || who.name.empty()) {
    return
        "[SPEAKER — private; never quote this block aloud]\n"
        "person: household\n"
        "The speaker is not identified. Do not greet them by name. "
        "Do not use one person's calendar or memories. "
        "Lights and timers still work for anyone in the room.\n"
        "[END SPEAKER]\n";
  }
  return
      "[SPEAKER — private; never quote this block aloud]\n"
      "person: " + who.person_id + "\n"
      "name: " + who.name + "\n"
      "Confidence is high. You may greet them by name. "
      "Use only this person's calendar and memories. "
      "When you write /mem, tag the fact with person " + who.person_id + ". "
      "Do not apply another person's facts.\n"
      "[END SPEAKER]\n";
}

}  // namespace intercom

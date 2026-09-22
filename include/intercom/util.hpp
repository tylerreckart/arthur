#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace intercom {

struct ParsedHttpUrl {
  std::string host;
  int port = 80;
  std::string path;
  bool https = false;
};

std::string expand_home(std::string path);
std::string make_turn_id();
bool file_exists(const std::string& path);
bool executable_on_path_or_file(const std::string& binary);
std::optional<ParsedHttpUrl> parse_http_url(const std::string& url);

// Encode/decode mono s16le PCM as a minimal WAV.
std::vector<std::uint8_t> encode_wav_s16le(const std::vector<std::uint8_t>& pcm,
                                           int sample_rate,
                                           int channels);
bool write_wav_s16le(const std::string& path,
                     const std::vector<std::uint8_t>& pcm,
                     int sample_rate,
                     int channels);
std::optional<std::vector<std::uint8_t>> parse_wav_s16le(const std::uint8_t* data,
                                                         std::size_t len,
                                                         int* out_sample_rate,
                                                         int* out_channels);
std::optional<std::vector<std::uint8_t>> read_wav_s16le(const std::string& path,
                                                        int* out_sample_rate,
                                                        int* out_channels);

// Cubic resample mono s16le PCM.
std::vector<std::uint8_t> resample_s16le_mono(const std::vector<std::uint8_t>& pcm,
                                              int from_rate,
                                              int to_rate);

std::vector<std::uint8_t> silence_s16le_mono(int sample_rate, int milliseconds);
void fade_s16le_mono_edges(std::vector<std::uint8_t>* pcm,
                           int sample_rate,
                           int fade_in_ms,
                           int fade_out_ms);

// Natural inter-utterance pause inferred from the spoken punctuation.
int speech_pause_ms(std::string_view text);

// Keep related short sentences in one TTS call so prosody does not restart
// unnecessarily. Long chunks remain separate to bound synthesis latency.
std::vector<std::string> coalesce_speech_sentences(
    const std::vector<std::string>& sentences,
    std::size_t max_chars = 220);

std::string to_lower(std::string s);
std::string trim(std::string_view s);

// Lowercase, strip punctuation, drop leading/trailing "arthur" / "please" / "sir".
std::string fold_phatic(std::string_view raw);

// Pull completed sentences from a growing buffer; leaves incomplete tail in buf.
// When early_words > 0 and no sentence boundary is ready, emit a chunk once
// at least that many words are followed by a break (space or comma).
// Leading leftover clause punctuation ("," / ";" / ":") from a prior cut is
// stripped so the next emit does not start with a hanging comma.
std::vector<std::string> flush_sentences(std::string& buf, bool final_flush,
                                         std::size_t early_words = 0);

}  // namespace intercom

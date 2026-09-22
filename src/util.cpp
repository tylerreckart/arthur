#include "intercom/util.hpp"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <random>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

namespace intercom {
namespace {

#pragma pack(push, 1)
struct WavHeader {
  char riff[4] = {'R', 'I', 'F', 'F'};
  std::uint32_t chunk_size = 0;
  char wave[4] = {'W', 'A', 'V', 'E'};
  char fmt[4] = {'f', 'm', 't', ' '};
  std::uint32_t fmt_size = 16;
  std::uint16_t audio_format = 1;
  std::uint16_t num_channels = 1;
  std::uint32_t sample_rate = 16000;
  std::uint32_t byte_rate = 0;
  std::uint16_t block_align = 0;
  std::uint16_t bits_per_sample = 16;
  char data[4] = {'d', 'a', 't', 'a'};
  std::uint32_t data_size = 0;
};
#pragma pack(pop)

}  // namespace

std::string expand_home(std::string path) {
  if (path.empty() || path[0] != '~') return path;
  const char* home = std::getenv("HOME");
  if (!home) return path;
  if (path.size() == 1) return std::string(home);
  if (path[1] == '/') return std::string(home) + path.substr(1);
  return path;
}

std::string make_turn_id() {
  static thread_local std::mt19937_64 rng{
      static_cast<std::uint64_t>(
          std::chrono::high_resolution_clock::now().time_since_epoch().count()) ^
      static_cast<std::uint64_t>(reinterpret_cast<uintptr_t>(&rng))};
  std::uniform_int_distribution<std::uint64_t> dist;
  std::ostringstream oss;
  oss << std::hex << dist(rng) << dist(rng);
  return oss.str();
}

bool file_exists(const std::string& path) {
  struct stat st {};
  return ::stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

bool executable_on_path_or_file(const std::string& binary) {
  if (binary.find('/') != std::string::npos) {
    return ::access(binary.c_str(), X_OK) == 0;
  }
  const char* path_env = std::getenv("PATH");
  if (!path_env) return false;
  std::string path = path_env;
  std::size_t start = 0;
  while (start <= path.size()) {
    std::size_t end = path.find(':', start);
    if (end == std::string::npos) end = path.size();
    std::string dir = path.substr(start, end - start);
    if (!dir.empty()) {
      std::string full = dir + "/" + binary;
      if (::access(full.c_str(), X_OK) == 0) return true;
    }
    if (end == path.size()) break;
    start = end + 1;
  }
  return false;
}

std::optional<ParsedHttpUrl> parse_http_url(const std::string& url) {
  std::string u = url;
  while (!u.empty() && u.back() == '/') u.pop_back();
  ParsedHttpUrl out;
  if (u.rfind("https://", 0) == 0) {
    out.https = true;
    out.port = 443;
    u = u.substr(8);
  } else if (u.rfind("http://", 0) == 0) {
    out.https = false;
    out.port = 80;
    u = u.substr(7);
  } else {
    return std::nullopt;
  }
  const auto slash = u.find('/');
  const std::string hostport = slash == std::string::npos ? u : u.substr(0, slash);
  out.path = slash == std::string::npos ? "" : u.substr(slash);
  const auto colon = hostport.find(':');
  if (colon == std::string::npos) {
    out.host = hostport;
  } else {
    out.host = hostport.substr(0, colon);
    try {
      out.port = std::stoi(hostport.substr(colon + 1));
    } catch (...) {
      return std::nullopt;
    }
  }
  if (out.host.empty()) return std::nullopt;
  return out;
}

std::vector<std::uint8_t> encode_wav_s16le(const std::vector<std::uint8_t>& pcm,
                                           int sample_rate,
                                           int channels) {
  WavHeader h;
  h.num_channels = static_cast<std::uint16_t>(channels);
  h.sample_rate = static_cast<std::uint32_t>(sample_rate);
  h.bits_per_sample = 16;
  h.block_align = static_cast<std::uint16_t>(channels * 2);
  h.byte_rate = static_cast<std::uint32_t>(sample_rate * h.block_align);
  h.data_size = static_cast<std::uint32_t>(pcm.size());
  h.chunk_size = 36 + h.data_size;

  std::vector<std::uint8_t> out(sizeof(h) + pcm.size());
  std::memcpy(out.data(), &h, sizeof(h));
  if (!pcm.empty()) {
    std::memcpy(out.data() + sizeof(h), pcm.data(), pcm.size());
  }
  return out;
}

bool write_wav_s16le(const std::string& path,
                     const std::vector<std::uint8_t>& pcm,
                     int sample_rate,
                     int channels) {
  const auto bytes = encode_wav_s16le(pcm, sample_rate, channels);
  std::ofstream out(path, std::ios::binary);
  if (!out) return false;
  out.write(reinterpret_cast<const char*>(bytes.data()),
            static_cast<std::streamsize>(bytes.size()));
  return static_cast<bool>(out);
}

std::optional<std::vector<std::uint8_t>> parse_wav_s16le(const std::uint8_t* data,
                                                         std::size_t len,
                                                         int* out_sample_rate,
                                                         int* out_channels) {
  if (!data || len < 12) return std::nullopt;
  if (std::memcmp(data, "RIFF", 4) != 0 || std::memcmp(data + 8, "WAVE", 4) != 0) {
    return std::nullopt;
  }

  std::size_t off = 12;
  std::uint16_t audio_format = 0;
  std::uint16_t channels = 0;
  std::uint32_t sample_rate = 0;
  std::uint16_t bits = 0;
  std::vector<std::uint8_t> pcm;

  auto read_u32 = [&](std::size_t i) -> std::uint32_t {
    std::uint32_t v = 0;
    std::memcpy(&v, data + i, 4);
    return v;
  };
  auto read_u16 = [&](std::size_t i) -> std::uint16_t {
    std::uint16_t v = 0;
    std::memcpy(&v, data + i, 2);
    return v;
  };

  while (off + 8 <= len) {
    const char* id = reinterpret_cast<const char*>(data + off);
    const std::uint32_t size = read_u32(off + 4);
    off += 8;
    if (off + size > len) break;
    if (std::strncmp(id, "fmt ", 4) == 0 && size >= 16) {
      audio_format = read_u16(off);
      channels = read_u16(off + 2);
      sample_rate = read_u32(off + 4);
      bits = read_u16(off + 14);
    } else if (std::strncmp(id, "data", 4) == 0) {
      pcm.assign(data + off, data + off + size);
    }
    off += size + (size % 2);
  }

  if (audio_format != 1 || bits != 16 || channels < 1 || pcm.empty()) {
    return std::nullopt;
  }
  if (out_sample_rate) *out_sample_rate = static_cast<int>(sample_rate);
  if (out_channels) *out_channels = static_cast<int>(channels);
  return pcm;
}

std::optional<std::vector<std::uint8_t>> read_wav_s16le(const std::string& path,
                                                        int* out_sample_rate,
                                                        int* out_channels) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return std::nullopt;
  in.seekg(0, std::ios::end);
  const auto n = in.tellg();
  if (n <= 0) return std::nullopt;
  in.seekg(0, std::ios::beg);
  std::vector<std::uint8_t> bytes(static_cast<std::size_t>(n));
  in.read(reinterpret_cast<char*>(bytes.data()), n);
  if (!in) return std::nullopt;
  return parse_wav_s16le(bytes.data(), bytes.size(), out_sample_rate, out_channels);
}

std::vector<std::uint8_t> resample_s16le_mono(const std::vector<std::uint8_t>& pcm,
                                              int from_rate,
                                              int to_rate) {
  if (from_rate <= 0 || to_rate <= 0 || pcm.size() < 2) return pcm;
  if (from_rate == to_rate) return pcm;

  const std::size_t in_samples = pcm.size() / 2;
  const auto* in = reinterpret_cast<const std::int16_t*>(pcm.data());
  const double ratio = static_cast<double>(from_rate) / static_cast<double>(to_rate);
  const std::size_t out_samples =
      static_cast<std::size_t>(std::floor(static_cast<double>(in_samples) / ratio));
  std::vector<std::uint8_t> out(out_samples * 2);
  auto* o = reinterpret_cast<std::int16_t*>(out.data());
  auto at = [&](std::ptrdiff_t i) -> double {
    if (i < 0) i = 0;
    if (static_cast<std::size_t>(i) >= in_samples) i = static_cast<std::ptrdiff_t>(in_samples - 1);
    return static_cast<double>(in[i]);
  };
  for (std::size_t i = 0; i < out_samples; ++i) {
    const double src = static_cast<double>(i) * ratio;
    const auto i1 = static_cast<std::ptrdiff_t>(src);
    const double t = src - static_cast<double>(i1);
    const double y0 = at(i1 - 1);
    const double y1 = at(i1);
    const double y2 = at(i1 + 1);
    const double y3 = at(i1 + 2);
    const double c0 = y1;
    const double c1 = 0.5 * (y2 - y0);
    const double c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
    const double c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
    const double s = ((c3 * t + c2) * t + c1) * t + c0;
    const double clipped = std::max(-32768.0, std::min(32767.0, s));
    o[i] = static_cast<std::int16_t>(std::lround(clipped));
  }
  return out;
}

std::vector<std::uint8_t> silence_s16le_mono(int sample_rate, int milliseconds) {
  if (sample_rate <= 0 || milliseconds <= 0) return {};
  const std::size_t n =
      static_cast<std::size_t>(sample_rate) * static_cast<std::size_t>(milliseconds) / 1000;
  return std::vector<std::uint8_t>(n * 2, 0);
}

void fade_s16le_mono_edges(std::vector<std::uint8_t>* pcm,
                           int sample_rate,
                           int fade_in_ms,
                           int fade_out_ms) {
  if (!pcm || pcm->size() < 4 || sample_rate <= 0) return;
  auto* samples = reinterpret_cast<std::int16_t*>(pcm->data());
  const std::size_t n = pcm->size() / 2;
  auto ramp = [](std::size_t i, std::size_t count) -> double {
    const double t = static_cast<double>(i + 1) / static_cast<double>(count + 1);
    return 0.5 - 0.5 * std::cos(3.14159265358979323846 * t);
  };
  const std::size_t n_in = std::min(
      n / 2, static_cast<std::size_t>(std::max(0, fade_in_ms)) * static_cast<std::size_t>(sample_rate) /
                 1000);
  const std::size_t n_out = std::min(
      n / 2, static_cast<std::size_t>(std::max(0, fade_out_ms)) * static_cast<std::size_t>(sample_rate) /
                 1000);
  for (std::size_t i = 0; i < n_in; ++i) {
    const double g = ramp(i, n_in);
    samples[i] = static_cast<std::int16_t>(std::lround(static_cast<double>(samples[i]) * g));
  }
  for (std::size_t i = 0; i < n_out; ++i) {
    const double g = ramp(i, n_out);
    const std::size_t idx = n - 1 - i;
    samples[idx] = static_cast<std::int16_t>(std::lround(static_cast<double>(samples[idx]) * g));
  }
}

int speech_pause_ms(std::string_view text) {
  while (!text.empty() &&
         std::isspace(static_cast<unsigned char>(text.back()))) {
    text.remove_suffix(1);
  }
  if (text.empty()) return 0;
  switch (text.back()) {
    case ',':
      return 110;
    case ';':
    case ':':
      return 150;
    case '!':
      return 190;
    case '?':
      return 260;
    case '.':
      return 200;
    default:
      return 180;
  }
}

std::vector<std::string> coalesce_speech_sentences(
    const std::vector<std::string>& sentences,
    std::size_t max_chars) {
  std::vector<std::string> out;
  std::string chunk;
  for (const auto& sentence : sentences) {
    const std::string clean = trim(sentence);
    if (clean.empty()) continue;
    const std::size_t joined_size =
        chunk.empty() ? clean.size() : chunk.size() + 1 + clean.size();
    if (!chunk.empty() && joined_size > max_chars) {
      out.push_back(std::move(chunk));
      chunk.clear();
    }
    if (!chunk.empty()) chunk.push_back(' ');
    chunk += clean;
  }
  if (!chunk.empty()) out.push_back(std::move(chunk));
  return out;
}

std::string to_lower(std::string s) {
  for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return s;
}

std::string trim(std::string_view s) {
  while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front()))) s.remove_prefix(1);
  while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) s.remove_suffix(1);
  return std::string(s);
}

std::string fold_phatic(std::string_view raw) {
  std::string t = to_lower(trim(raw));
  std::string out;
  out.reserve(t.size());
  for (char c : t) {
    if (c == '.' || c == '!' || c == '?' || c == ',' || c == ';' || c == ':') {
      out.push_back(' ');
    } else if (c == '\'') {
      continue;
    } else {
      out.push_back(c);
    }
  }
  out = trim(out);
  std::vector<std::string> tok;
  std::string cur;
  for (char c : out) {
    if (c == ' ' || c == '\t') {
      if (!cur.empty()) {
        tok.push_back(cur);
        cur.clear();
      }
    } else {
      cur.push_back(c);
    }
  }
  if (!cur.empty()) tok.push_back(cur);

  auto drop = [](const std::string& w) {
    return w == "arthur" || w == "please" || w == "sir";
  };
  while (!tok.empty() && drop(tok.front())) tok.erase(tok.begin());
  while (!tok.empty() && drop(tok.back())) tok.pop_back();

  std::string joined;
  for (const auto& w : tok) {
    if (!joined.empty()) joined.push_back(' ');
    joined += w;
  }
  return joined;
}

namespace {

bool is_clause_punct(char c) {
  return c == ',' || c == ';' || c == ':';
}

std::size_t skip_space_and_clause_punct(std::string_view s, std::size_t i) {
  while (i < s.size() &&
         (std::isspace(static_cast<unsigned char>(s[i])) || is_clause_punct(s[i]))) {
    ++i;
  }
  return i;
}

void strip_leading_clause_punct(std::string& s) {
  const std::size_t i = skip_space_and_clause_punct(s, 0);
  if (i > 0) s.erase(0, i);
}

void strip_trailing_clause_punct(std::string& s) {
  while (!s.empty() &&
         (std::isspace(static_cast<unsigned char>(s.back())) || is_clause_punct(s.back()))) {
    s.pop_back();
  }
}

// Index after the Nth word if a break follows it; 0 if the Nth word is still
// growing or there are fewer than N words.
std::size_t early_word_cut(std::string_view s, std::size_t n) {
  if (n == 0) return 0;
  std::size_t words = 0;
  bool in_word = false;
  for (std::size_t i = 0; i < s.size(); ++i) {
    if (std::isspace(static_cast<unsigned char>(s[i]))) {
      if (in_word) {
        in_word = false;
        if (words >= n) {
          std::size_t j = i;
          while (j < s.size() &&
                 (s[j] == ',' || s[j] == ';' || s[j] == ':')) {
            ++j;
          }
          return j;
        }
      }
      continue;
    }
    if (s[i] == ',' || s[i] == ';' || s[i] == ':') {
      if (in_word) {
        in_word = false;
        if (words >= n) return i + 1;
      }
      continue;
    }
    if (!in_word) {
      in_word = true;
      ++words;
    }
  }
  return 0;
}

}  // namespace

std::vector<std::string> flush_sentences(std::string& buf, bool final_flush,
                                         std::size_t early_words) {
  // A previous early-word cut may leave ", and …" when the comma arrives
  // in a later token. Drop leftover clause punctuation so the next `said`
  // does not start with a hanging comma.
  strip_leading_clause_punct(buf);

  std::vector<std::string> out;
  std::size_t start = 0;
  for (std::size_t i = 0; i < buf.size(); ++i) {
    const char c = buf[i];
    if (c == '.' || c == '!' || c == '?') {
      const bool boundary =
          (i + 1 == buf.size()) ||
          std::isspace(static_cast<unsigned char>(buf[i + 1])) ||
          buf[i + 1] == '"' || buf[i + 1] == '\'';
      if (boundary) {
        std::string sentence = trim(buf.substr(start, i - start + 1));
        if (!sentence.empty()) out.push_back(std::move(sentence));
        start = i + 1;
        while (start < buf.size() &&
               std::isspace(static_cast<unsigned char>(buf[start]))) {
          ++start;
        }
      }
    }
  }
  if (final_flush) {
    std::string rest = trim(buf.substr(start));
    strip_leading_clause_punct(rest);
    if (!rest.empty()) out.push_back(std::move(rest));
    buf.clear();
    return out;
  }

  buf.erase(0, start);
  if (early_words > 0) {
    const std::size_t cut = early_word_cut(buf, early_words);
    if (cut > 0) {
      std::string chunk = trim(buf.substr(0, cut));
      strip_trailing_clause_punct(chunk);
      if (!chunk.empty()) out.push_back(std::move(chunk));
      const std::size_t next = skip_space_and_clause_punct(buf, cut);
      buf.erase(0, next);
    }
  }
  return out;
}

}  // namespace intercom

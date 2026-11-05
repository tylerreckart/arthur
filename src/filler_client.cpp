#include "intercom/filler_client.hpp"
#include "intercom/util.hpp"

#include <httplib.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <cctype>
#include <memory>
#include <optional>
#include <random>
#include <sstream>

namespace intercom {
namespace {

struct ParsedUrl {
  bool https = false;
  std::string host;
  int port = 80;
  std::string path_prefix;
};

std::optional<ParsedUrl> parse_base_url(const std::string& base) {
  std::string u = base;
  while (!u.empty() && u.back() == '/') u.pop_back();
  ParsedUrl out;
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
  std::string hostport = slash == std::string::npos ? u : u.substr(0, slash);
  out.path_prefix = slash == std::string::npos ? "" : u.substr(slash);
  const auto colon = hostport.find(':');
  if (colon == std::string::npos) {
    out.host = hostport;
  } else {
    out.host = hostport.substr(0, colon);
    out.port = std::stoi(hostport.substr(colon + 1));
  }
  if (out.host.empty()) return std::nullopt;
  return out;
}

std::unique_ptr<httplib::Client> make_client(const ParsedUrl& parsed) {
  std::ostringstream url;
  url << (parsed.https ? "https://" : "http://") << parsed.host;
  if ((parsed.https && parsed.port != 443) || (!parsed.https && parsed.port != 80)) {
    url << ':' << parsed.port;
  }
  return std::make_unique<httplib::Client>(url.str());
}

std::string strip_wrapping_quotes(std::string s) {
  s = trim(s);
  if (s.size() >= 2 &&
      ((s.front() == '"' && s.back() == '"') || (s.front() == '\'' && s.back() == '\''))) {
    return trim(s.substr(1, s.size() - 2));
  }
  return s;
}

std::string first_line(std::string s) {
  const auto pos = s.find('\n');
  if (pos != std::string::npos) s.resize(pos);
  return trim(s);
}

std::string cap_words(std::string s, std::size_t max_words) {
  s = trim(s);
  if (max_words == 0 || s.empty()) return s;
  std::size_t words = 0;
  bool in_word = false;
  for (std::size_t i = 0; i < s.size(); ++i) {
    const bool space = std::isspace(static_cast<unsigned char>(s[i])) != 0;
    if (space) {
      in_word = false;
      continue;
    }
    if (in_word) continue;
    in_word = true;
    ++words;
    if (words > max_words) {
      while (i > 0 && !std::isspace(static_cast<unsigned char>(s[i - 1]))) --i;
      s.resize(i);
      break;
    }
  }
  while (!s.empty() && (s.back() == ',' || s.back() == ';' || s.back() == ':')) s.pop_back();
  return trim(s);
}

std::string build_system_prompt(FillerStage stage) {
  if (stage == FillerStage::FollowUp) {
    return "Arthur, a personal assistant. The user is still waiting. "
           "Give one quiet progress cue, 1-3 words, like 'still with you'. "
           "Do not put them on hold. Do not say you are looking or thinking. "
           "Output only the phrase.";
  }
  return "Arthur, a personal assistant. The user just asked something. "
         "Acknowledge only if the silence has become awkward, 1-3 words, "
         "like 'of course' or 'all right'. Do not use 'sir'. "
         "Do not put them on hold. Do not narrate thinking, looking, or working. "
         "Output only the phrase.";
}

std::string build_user_prompt(const std::string& transcript,
                              FillerStage stage,
                              const std::string& previous_phrase) {
  if (stage == FillerStage::FollowUp && !previous_phrase.empty()) {
    return "User: \"" + transcript + "\". You said: \"" + previous_phrase +
           "\". Different phrase:";
  }
  return "User: \"" + transcript + "\". Phrase:";
}

std::string fallback_phrase(FillerStage stage) {
  static const char* kInitial[] = {
      "Of course.",
      "Certainly.",
      "All right.",
      "Understood.",
  };
  static const char* kFollowUp[] = {
      "Yes.",
      "Still with you.",
      "Nearly there.",
  };
  static thread_local std::mt19937 rng{std::random_device{}()};
  if (stage == FillerStage::FollowUp) {
    std::uniform_int_distribution<std::size_t> dist(0, 2);
    return kFollowUp[dist(rng)];
  }
  std::uniform_int_distribution<std::size_t> dist(0, 3);
  return kInitial[dist(rng)];
}

}  // namespace

FillerClient::FillerClient(FillerConfig config) : config_(std::move(config)) {}

std::vector<std::string> FillerClient::instant_ack_phrases() {
  return {
      "Of course.",
      "Certainly.",
      "All right.",
      "Understood.",
  };
}

std::vector<std::string> FillerClient::cached_ack_phrases() {
  auto out = instant_ack_phrases();
  for (const char* tool : {"search", "read", "schedule", "exec"}) {
    const std::string phrase = tool_ack(tool);
    if (std::find(out.begin(), out.end(), phrase) == out.end()) {
      out.push_back(phrase);
    }
  }
  out.push_back(progress_ack());
  return out;
}

std::string FillerClient::instant_ack() {
  const auto phrases = instant_ack_phrases();
  static thread_local std::mt19937 rng{std::random_device{}()};
  static thread_local std::size_t last = phrases.size();
  std::uniform_int_distribution<std::size_t> dist(0, phrases.size() - 1);
  std::size_t i = dist(rng);
  if (phrases.size() > 1 && i == last) i = (i + 1) % phrases.size();
  last = i;
  return phrases[i];
}

std::string FillerClient::tool_ack(std::string_view tool) {
  if (tool.find("search") != std::string_view::npos ||
      tool.find("fetch") != std::string_view::npos ||
      tool.find("browse") != std::string_view::npos) {
    return "Of course.";
  }
  if (tool.find("schedule") != std::string_view::npos) {
    return "Of course.";
  }
  if (tool.find("read") != std::string_view::npos ||
      tool.find("list") != std::string_view::npos) {
    return "All right.";
  }
  return "Certainly.";
}

std::string FillerClient::progress_ack() {
  return "Still with you.";
}

std::string FillerClient::generate(const std::string& transcript,
                                   FillerStage stage,
                                   const std::string& previous_phrase,
                                   std::atomic<bool>* cancel_flag,
                                   std::string* err) const {
  if (!enabled()) return {};
  if (transcript.empty()) return {};
  if (cancel_flag && cancel_flag->load()) return {};

  auto parsed = parse_base_url(config_.api_base_url);
  if (!parsed) {
    if (err) *err = "invalid filler api_base_url";
    return fallback_phrase(stage);
  }

#ifndef CPPHTTPLIB_OPENSSL_SUPPORT
  if (parsed->https) {
    if (err) *err = "filler: HTTPS requires OpenSSL (rebuild with OpenSSL)";
    return fallback_phrase(stage);
  }
#endif

  auto cli = make_client(*parsed);
  cli->set_connection_timeout(config_.timeout_ms / 1000,
                              (config_.timeout_ms % 1000) * 1000);
  cli->set_read_timeout(config_.timeout_ms / 1000,
                        (config_.timeout_ms % 1000) * 1000);
  cli->set_write_timeout(5, 0);

  nlohmann::json body = {
      {"model", config_.model},
      {"max_tokens", config_.max_tokens},
      {"temperature", config_.temperature},
      {"messages",
       nlohmann::json::array({
           {{"role", "system"}, {"content", build_system_prompt(stage)}},
           {{"role", "user"},
            {"content", build_user_prompt(transcript, stage, previous_phrase)}},
       })},
  };

  httplib::Headers headers = {
      {"Authorization", "Bearer " + config_.api_key},
      {"Content-Type", "application/json"},
  };

  const std::string path = parsed->path_prefix + "/chat/completions";
  auto res = cli->Post(path.c_str(), headers, body.dump(), "application/json");
  if (cancel_flag && cancel_flag->load()) return {};

  if (!res) {
    if (err) *err = "filler: connection failed";
    return fallback_phrase(stage);
  }
  if (res->status != 200) {
    if (err) {
      *err = "filler HTTP " + std::to_string(res->status) + ": " + res->body;
    }
    return fallback_phrase(stage);
  }

  try {
    auto j = nlohmann::json::parse(res->body);
    if (!j.contains("choices") || !j["choices"].is_array() || j["choices"].empty()) {
      if (err) *err = "filler: missing choices";
      return fallback_phrase(stage);
    }
    const auto& choice = j["choices"][0];
    if (!choice.contains("message") || !choice["message"].contains("content") ||
        choice["message"]["content"].is_null()) {
      if (err) *err = "filler: missing message content";
      return fallback_phrase(stage);
    }
    std::string phrase = cap_words(
        first_line(strip_wrapping_quotes(choice["message"]["content"].get<std::string>())),
        stage == FillerStage::FollowUp ? 4 : 5);
    if (phrase.empty()) {
      if (err) *err = "filler: empty message content";
      return fallback_phrase(stage);
    }
    if (phrase.size() > 80) phrase.resize(80);
    return phrase;
  } catch (const std::exception& e) {
    if (err) *err = std::string("filler parse: ") + e.what();
    return fallback_phrase(stage);
  }
}

}  // namespace intercom

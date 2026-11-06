#include "intercom/turn_pipeline.hpp"
#include "intercom/briefing.hpp"
#include "intercom/clock.hpp"
#include "intercom/home_client.hpp"
#include "intercom/speakable.hpp"
#include "intercom/speak_queue.hpp"
#include "intercom/surface.hpp"
#include "intercom/util.hpp"
#include "intercom/voiceprint.hpp"
#include "intercom/warm.hpp"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <future>
#include <iostream>
#include <iterator>
#include <optional>
#include <set>
#include <string_view>
#include <thread>
#include <vector>

namespace intercom {
namespace {

std::int64_t now_unix() {
  return std::chrono::duration_cast<std::chrono::seconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

void sleep_ms(int ms) {
  if (ms <= 0) return;
  std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

struct ArbiterRunState {
  std::atomic<bool> got_first_delta{false};
  std::atomic<bool> started_answer{false};
  std::atomic<bool> saw_tool{false};
  std::atomic<int> tool_started_ms{-1};
  std::atomic<bool> done{false};
  bool streamed = false;
  bool done_ok = false;
  std::string done_err;
  std::string full_content;
  std::string stream_err;
  std::string speak_buf;
  ToolSpeechGate speech_gate;
  std::string tool_name;
  int last_forming_ms = -1000;
  std::mutex speak_mu;
};

std::size_t non_space_count(std::string_view s) {
  std::size_t n = 0;
  for (char c : s) {
    if (!std::isspace(static_cast<unsigned char>(c))) ++n;
  }
  return n;
}

std::size_t early_flush_words(const Config& config) {
  return config.early_flush_words > 0
             ? static_cast<std::size_t>(config.early_flush_words)
             : 0;
}

bool is_repeat_request(std::string_view transcript) {
  const std::string t = fold_phatic(transcript);
  return t == "repeat that" || t == "say that again" ||
         t == "could you repeat that" || t == "what did you say";
}

bool is_contextual_followup(std::string_view transcript) {
  const std::string t = fold_phatic(transcript);
  if (t.empty() || t.size() > 120) return false;
  if (t == "tomorrow" || t == "today" || t == "tonight" ||
      t == "why" || t == "when" || t == "where" ||
      t == "which one" || t == "how much" || t == "how many" ||
      t == "tell me more") {
    return true;
  }
  for (const char* prefix : {
           "what about ", "how about ", "and ", "does that ", "is that ",
           "will it ", "which ", "why ", "when ", "where ", "more about ",
       }) {
    if (t.rfind(prefix, 0) == 0) return true;
  }
  return false;
}

bool bridges_fast_path_kind(std::string_view kind) {
  return kind == "clock" || kind == "timer" ||
         kind == "light_on" || kind == "light_off" ||
         kind == "light_toggle" || kind == "volume_up" ||
         kind == "volume_down" || kind == "weather" ||
         kind == "alarm" || kind == "news" || kind == "markets" ||
         kind == "briefing";
}

bool is_action_repeat(std::string_view t) {
  return t == "again" || t == "do that again" || t == "same again" ||
         t == "one more time";
}

bool is_action_undo(std::string_view t) {
  return t == "undo that" || t == "put it back" || t == "reverse that";
}

bool is_light_kind(std::string_view kind) {
  return kind == "light_on" || kind == "light_off" || kind == "light_toggle";
}

std::string light_request(std::string_view kind, std::string_view room) {
  std::string out;
  if (kind == "light_off") {
    out = "turn off ";
  } else if (kind == "light_toggle") {
    out = "toggle ";
  } else {
    out = "turn on ";
  }
  if (!room.empty()) {
    out += room;
    out += " ";
  }
  out += "lights";
  return out;
}

std::optional<std::string> resolve_local_action_followup(
    const DeviceSession& prior, std::string_view current) {
  const std::string t = fold_phatic(current);
  if (t.empty() || t.size() > 80) return std::nullopt;

  const std::string previous_request =
      prior.last_fast_path_request.empty() ? prior.last_user
                                          : prior.last_fast_path_request;
  if (previous_request.empty()) return std::nullopt;

  if (is_action_repeat(t) &&
      (is_light_kind(prior.last_fast_path_kind) ||
       prior.last_fast_path_kind == "volume_up" ||
       prior.last_fast_path_kind == "volume_down")) {
    return previous_request;
  }

  if (prior.last_fast_path_kind == "volume_up" && is_action_undo(t)) {
    return "turn the volume down";
  }
  if (prior.last_fast_path_kind == "volume_down" && is_action_undo(t)) {
    return "turn the volume up";
  }
  if (!is_light_kind(prior.last_fast_path_kind)) return std::nullopt;

  std::string room;
  if (auto previous = parse_home_intent(previous_request)) {
    room = previous->room;
  }

  if (is_action_undo(t)) {
    if (prior.last_fast_path_kind == "light_on") {
      return light_request("light_off", room);
    }
    if (prior.last_fast_path_kind == "light_off") {
      return light_request("light_on", room);
    }
    return light_request("light_toggle", room);
  }

  for (const auto& [phrase, kind] :
       std::initializer_list<std::pair<std::string_view, std::string_view>>{
           {"turn it on", "light_on"},
           {"switch it on", "light_on"},
           {"put it on", "light_on"},
           {"turn it off", "light_off"},
           {"switch it off", "light_off"},
           {"put it off", "light_off"},
           {"toggle it", "light_toggle"},
       }) {
    if (t == phrase) return light_request(kind, room);
  }

  std::string room_followup;
  if (t.rfind("and ", 0) == 0) {
    room_followup = trim(t.substr(4));
  } else if (t.size() > 4 && t.substr(t.size() - 4) == " too") {
    room_followup = trim(t.substr(0, t.size() - 4));
  }
  if (room_followup.empty()) return std::nullopt;

  const std::string candidate =
      light_request(prior.last_fast_path_kind, room_followup);
  const auto parsed = parse_home_intent(candidate);
  if (!parsed || parsed->room.empty()) return std::nullopt;
  return candidate;
}

bool has_token(std::string_view text, std::string_view word) {
  std::size_t pos = 0;
  while (pos <= text.size()) {
    const auto found = text.find(word, pos);
    if (found == std::string_view::npos) return false;
    const bool left = found == 0 ||
                      !std::isalnum(static_cast<unsigned char>(text[found - 1]));
    const bool right = found + word.size() == text.size() ||
                       !std::isalnum(static_cast<unsigned char>(
                           text[found + word.size()]));
    if (left && right) return true;
    pos = found + 1;
  }
  return false;
}

bool has_explicit_light_polarity(std::string_view text) {
  for (const char* word :
       {"on", "off", "toggle", "enable", "disable", "kill", "dark"}) {
    if (has_token(text, word)) return true;
  }
  return false;
}

std::string expand_clause_shorthand(std::string clause) {
  if (clause == "the time" || clause == "time") return "what time is it";
  if (clause == "the date" || clause == "date") return "whats the date";
  if (clause == "the weather" || clause == "weather") return "whats the weather";
  if (clause == "the forecast" || clause == "forecast") return "whats the forecast";
  if (clause == "the news" || clause == "news") return "whats in the news";
  if (clause == "the headlines" || clause == "headlines") return "top headlines";
  if (clause == "the market" || clause == "the markets" || clause == "markets") {
    return "hows the market";
  }
  return clause;
}

std::string inherit_light_target(const std::string& clause,
                                 const std::string& previous) {
  if (previous.empty() || has_explicit_light_polarity(clause)) return clause;
  const auto prev = parse_home_intent(previous);
  if (!prev || !is_light_kind(home_intent_kind_name(prev->kind))) return clause;
  if (auto own = parse_home_intent(clause);
      own && own->kind != HomeIntentKind::LightOn &&
      own->kind != HomeIntentKind::LightOff &&
      own->kind != HomeIntentKind::LightToggle) {
    return clause;
  }

  std::string probe = clause;
  if (clause.find("light") == std::string::npos &&
      clause.find("lamp") == std::string::npos) {
    probe = "turn on " + clause + " lights";
  }
  const auto probed = parse_home_intent(probe);
  if (!probed || probed->room.empty() ||
      clause.find(probed->room) == std::string::npos) {
    return clause;
  }
  return light_request(home_intent_kind_name(prev->kind), probed->room);
}

std::vector<std::string> split_compound(std::string_view folded) {
  const std::string_view delimiters[] = {" and then ", " then ", " and "};
  std::vector<std::string> parts;
  std::string current;
  std::size_t i = 0;
  while (i < folded.size()) {
    const std::string_view rest = folded.substr(i);
    std::string_view delimiter;
    for (const auto candidate : delimiters) {
      if (rest.rfind(candidate, 0) == 0) {
        delimiter = candidate;
        break;
      }
    }
    if (!delimiter.empty()) {
      parts.push_back(trim(current));
      current.clear();
      i += delimiter.size();
      continue;
    }
    current.push_back(folded[i]);
    ++i;
  }
  parts.push_back(trim(current));
  if (parts.size() < 2 || parts.size() > 3) return {};
  for (const auto& part : parts) {
    if (part.empty()) return {};
  }
  return parts;
}

bool is_deterministic_clause(const Config& config, const std::string& clause) {
  const std::string raw = to_lower(trim(clause));
  if (raw.rfind("echo ", 0) == 0 && !trim(raw.substr(5)).empty()) return true;
  if (is_clock_query(clause)) return true;
  if (auto intent = parse_home_intent(clause)) {
    if (intent->kind == HomeIntentKind::Weather && !intent->place.empty()) return true;
    if (!config.home.configured()) return false;
    if (intent->kind == HomeIntentKind::Timer && intent->timer_seconds <= 0 &&
        config.home.timer_entity.empty()) {
      return false;
    }
    return true;
  }
  if (auto briefing = parse_briefing_intent(clause)) {
    return briefing->confidence == BriefingConfidence::High;
  }
  return false;
}

std::vector<std::string> local_compound_clauses(const Config& config,
                                                std::string_view transcript) {
  if (!config.fast_path) return {};
  const auto parts = split_compound(fold_phatic(transcript));
  if (parts.empty()) return {};

  std::vector<std::string> resolved;
  std::string previous;
  bool all_same_briefing = true;
  std::optional<BriefingKind> briefing_kind;
  for (const auto& part : parts) {
    const std::string clause =
        inherit_light_target(expand_clause_shorthand(part), previous);
    if (!is_deterministic_clause(config, clause)) return {};
    if (auto briefing = parse_briefing_intent(clause);
        briefing && briefing->confidence == BriefingConfidence::High) {
      if (!briefing_kind) {
        briefing_kind = briefing->kind;
      } else if (*briefing_kind != briefing->kind) {
        all_same_briefing = false;
      }
    } else {
      all_same_briefing = false;
    }
    resolved.push_back(clause);
    previous = clause;
  }
  // "bitcoin and ethereum" is one market request, not two lookups.
  if (all_same_briefing) return {};
  return resolved;
}

bool take_word(std::string* text, std::string_view word) {
  if (!text || text->size() < word.size()) return false;
  if (text->compare(0, word.size(), word) != 0) return false;
  if (text->size() > word.size() && (*text)[word.size()] != ' ') return false;
  *text = trim(text->substr(word.size()));
  return true;
}

// Strip a conservative correction cue ("no", "I meant", "not") and return the
// remainder. False when the utterance is not a repair of the previous turn.
bool strip_correction_cue(std::string* text) {
  if (!text) return false;
  bool cued = false;
  bool progressed = true;
  while (progressed) {
    progressed = false;
    if (take_word(text, "no")) {
      cued = true;
      progressed = true;
    }
    if (take_word(text, "i")) {
      std::string rest = *text;
      if (take_word(&rest, "meant") || take_word(&rest, "mean")) {
        *text = std::move(rest);
        cued = true;
        progressed = true;
      }
    }
    if (take_word(text, "meant") || take_word(text, "mean")) {
      cued = true;
      progressed = true;
    }
    if (take_word(text, "not")) {
      cued = true;
      progressed = true;
    }
  }
  return cued;
}

std::optional<std::string> exact_room_phrase(std::string phrase) {
  phrase = trim(std::move(phrase));
  for (const char* tail : {" lights", " light", " lamps", " lamp"}) {
    const std::size_t n = std::char_traits<char>::length(tail);
    if (phrase.size() > n && phrase.compare(phrase.size() - n, n, tail) == 0) {
      phrase = trim(phrase.substr(0, phrase.size() - n));
    }
  }
  if (phrase.rfind("the ", 0) == 0) phrase = trim(phrase.substr(4));
  if (phrase.empty()) return std::nullopt;
  const auto parsed = parse_home_intent("turn on the " + phrase + " lights");
  if (!parsed || parsed->room.empty() || parsed->room != phrase) return std::nullopt;
  return phrase;
}

std::string previous_fast_request(const DeviceSession& prior) {
  if (!prior.last_fast_path_request.empty()) return prior.last_fast_path_request;
  return prior.last_user;
}

std::string apply_time_scope(std::string request, std::string_view scope) {
  request = fold_phatic(request);
  const char* phrases[] = {
      "this morning", "this afternoon", "this evening", "this weekend",
      "this week",    "right now",      "currently",    "yesterday",
      "tomorrow",     "tonight",        "today",        "now",
  };
  std::size_t best = std::string::npos;
  std::size_t best_len = 0;
  for (const char* phrase : phrases) {
    const std::string_view needle = phrase;
    std::size_t from = 0;
    while (from < request.size()) {
      const auto found = request.find(needle, from);
      if (found == std::string::npos) break;
      const bool left =
          found == 0 || !std::isalnum(static_cast<unsigned char>(request[found - 1]));
      const bool right =
          found + needle.size() == request.size() ||
          !std::isalnum(static_cast<unsigned char>(request[found + needle.size()]));
      if (left && right) {
        best = found;
        best_len = needle.size();
      }
      from = found + 1;
    }
  }
  if (best == std::string::npos) {
    if (!request.empty() && request.back() != ' ') request.push_back(' ');
    request.append(scope);
    return request;
  }
  request.replace(best, best_len, scope);
  return request;
}

bool is_other_choice(std::string_view t) {
  return t == "not that one" || t == "the other one" || t == "other one";
}

bool is_time_scope_kind(std::string_view kind) {
  return kind == "clock" || kind == "weather" || kind == "news" || kind == "markets";
}

std::vector<std::string> configured_light_rooms(const HomeConfig& home) {
  std::vector<std::string> rooms;
  rooms.reserve(home.lights.size());
  for (const auto& kv : home.lights) {
    if (kv.first.empty() || kv.first == "default") continue;
    rooms.push_back(kv.first);
  }
  std::sort(rooms.begin(), rooms.end());
  rooms.erase(std::unique(rooms.begin(), rooms.end()), rooms.end());
  return rooms;
}

enum class RepairKind { None, Rewrite, Note };

struct RepairPlan {
  RepairKind kind = RepairKind::None;
  std::string routing;
};

RepairPlan resolve_repair(const Config& config, const DeviceSession& prior,
                          std::string_view current) {
  const std::string folded = fold_phatic(current);
  if (folded.empty() || folded.size() > 80) return {};
  // A failed Home Assistant call clears the fast-path kind, so it cannot be
  // repeated, reversed, or retargeted.
  if (prior.last_fast_path_kind.empty() && !is_other_choice(folded)) return {};

  if (is_other_choice(folded)) {
    if (prior.last_fast_path_kind == "volume_up") {
      return {RepairKind::Rewrite, "turn the volume down"};
    }
    if (prior.last_fast_path_kind == "volume_down") {
      return {RepairKind::Rewrite, "turn the volume up"};
    }
    if (is_light_kind(prior.last_fast_path_kind)) {
      const auto rooms = configured_light_rooms(config.home);
      const auto previous = parse_home_intent(previous_fast_request(prior));
      if (rooms.size() == 2 && previous && !previous->room.empty()) {
        if (previous->room == rooms[0]) {
          return {RepairKind::Rewrite,
                  light_request(prior.last_fast_path_kind, rooms[1])};
        }
        if (previous->room == rooms[1]) {
          return {RepairKind::Rewrite,
                  light_request(prior.last_fast_path_kind, rooms[0])};
        }
      }
    }
    if (!prior.last_spoken.empty() &&
        (!prior.last_user.empty() || !prior.last_fast_path_request.empty())) {
      return {RepairKind::Note, {}};
    }
    return {};
  }

  std::string tail = folded;
  if (!strip_correction_cue(&tail)) return {};

  if (is_light_kind(prior.last_fast_path_kind)) {
    if (auto room = exact_room_phrase(tail)) {
      return {RepairKind::Rewrite, light_request(prior.last_fast_path_kind, *room)};
    }
  }

  if (is_time_scope_kind(prior.last_fast_path_kind) &&
      (tail == "tomorrow" || tail == "today" || tail == "tonight")) {
    const std::string previous = previous_fast_request(prior);
    if (previous.empty()) return {};
    return {RepairKind::Rewrite, apply_time_scope(previous, tail)};
  }
  return {};
}

bool consume_prefix(std::string* text, std::string_view prefix) {
  if (!text || text->size() < prefix.size()) return false;
  if (text->compare(0, prefix.size(), prefix) != 0) return false;
  if (text->size() == prefix.size()) {
    text->clear();
    return true;
  }
  if ((*text)[prefix.size()] != ' ') return false;
  *text = trim(text->substr(prefix.size()));
  return true;
}

int ordinal_index(std::string_view word) {
  if (word == "first" || word == "one" || word == "1") return 0;
  if (word == "second" || word == "two" || word == "2") return 1;
  if (word == "third" || word == "three" || word == "3") return 2;
  if (word == "fourth" || word == "four" || word == "4") return 3;
  if (word == "fifth" || word == "five" || word == "5") return 4;
  if (word == "sixth" || word == "six" || word == "6") return 5;
  if (word == "seventh" || word == "seven" || word == "7") return 6;
  if (word == "eighth" || word == "eight" || word == "8") return 7;
  if (word == "last") return -1;
  return -2;
}

std::string percent_phrase(double pct) {
  const int rounded = static_cast<int>(std::lround(std::abs(pct)));
  if (rounded == 0) return "about flat";
  return std::string(pct > 0 ? "up " : "down ") + spoken_number(rounded) + " percent";
}

std::string tidy_card_summary(std::string raw, const std::string& title) {
  std::string out;
  out.reserve(raw.size());
  bool tag = false;
  bool space = false;
  for (unsigned char uc : raw) {
    const char c = static_cast<char>(uc);
    if (c == '<') {
      tag = true;
      continue;
    }
    if (c == '>') {
      tag = false;
      space = true;
      continue;
    }
    if (tag) continue;
    if (std::isspace(uc)) {
      space = true;
      continue;
    }
    if (space && !out.empty()) out.push_back(' ');
    space = false;
    out.push_back(c);
  }
  out = trim(out);
  if (out.size() < 24 || out == title) return {};
  std::string lower = out;
  for (char& c : lower) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  if (lower == "read more" || lower.find("http://") != std::string::npos ||
      lower.find("https://") != std::string::npos) {
    return {};
  }
  constexpr std::size_t kCap = 320;
  if (out.size() > kCap) {
    out.resize(kCap);
    const auto dot = out.rfind('.');
    if (dot != std::string::npos && dot >= 80) {
      out.resize(dot + 1);
    } else {
      const auto sp = out.rfind(' ');
      if (sp != std::string::npos && sp >= 80) out.resize(sp);
      if (out.empty() || out.back() != '.') out.push_back('.');
    }
  }
  return out;
}

nlohmann::json card_items_from_surface(const nlohmann::json& surface) {
  if (!surface.is_object()) return nullptr;
  const std::string kind = surface.value("kind", "");
  const auto payload = surface.contains("payload") && surface["payload"].is_object()
                           ? surface["payload"]
                           : nlohmann::json::object();
  nlohmann::json items = nlohmann::json::array();
  if (kind == "news" && payload.contains("items") && payload["items"].is_array()) {
    for (const auto& row : payload["items"]) {
      if (!row.is_object()) continue;
      const std::string label = row.value("title", "");
      if (label.empty()) continue;
      nlohmann::json item = {{"label", label}};
      const std::string source = row.value("source", "");
      if (!source.empty()) item["detail"] = source;
      if (const std::string summary = tidy_card_summary(row.value("summary", ""), label);
          !summary.empty()) {
        item["summary"] = summary;
      }
      items.push_back(std::move(item));
      if (items.size() >= 8) break;
    }
  } else if (kind == "markets" && payload.contains("instruments") &&
             payload["instruments"].is_array()) {
    for (const auto& row : payload["instruments"]) {
      if (!row.is_object()) continue;
      std::string label = row.value("name", "");
      if (label.empty()) label = row.value("symbol", "");
      if (label.empty()) continue;
      std::string detail;
      if (row.contains("price") && row["price"].is_number()) {
        detail = spoken_number(static_cast<int>(std::lround(row["price"].get<double>())));
      }
      if (row.contains("change_pct") && row["change_pct"].is_number()) {
        const std::string change = percent_phrase(row["change_pct"].get<double>());
        if (!detail.empty()) detail += ", ";
        detail += change;
      }
      nlohmann::json item = {{"label", label}};
      if (!detail.empty()) item["detail"] = detail;
      items.push_back(std::move(item));
      if (items.size() >= 8) break;
    }
  }
  if (items.empty()) return nullptr;
  return {{"kind", kind}, {"items", std::move(items)}};
}

std::string merge_card_state(const std::string& prior, const nlohmann::json& surface) {
  const auto extracted = card_items_from_surface(surface);
  if (!extracted.is_object()) return prior;
  nlohmann::json state = nlohmann::json::object();
  if (!prior.empty()) {
    try {
      auto parsed = nlohmann::json::parse(prior);
      if (parsed.is_object()) state = std::move(parsed);
    } catch (...) {
    }
  }
  const std::string kind = extracted.value("kind", "");
  state[kind] = extracted["items"];
  state["active"] = kind;
  if (state.contains("focus") && state["focus"].is_object() &&
      state["focus"].value("kind", "") == kind) {
    state.erase("focus");
  }
  if (state.contains("read_through") && state["read_through"].is_object()) {
    state["read_through"].erase(kind);
  }
  return state.dump();
}

enum class CardAction { Speak, Discuss };

struct CardTurn {
  CardAction action = CardAction::Speak;
  std::string line;
  std::string list_kind;
  std::string label;
  std::string note;
  std::string card_state;
};

const char* ordinal_word(int ordinal) {
  static const char* words[] = {"first", "second", "third", "fourth",
                                "fifth", "sixth", "seventh", "eighth"};
  if (ordinal >= 0 && ordinal < 8) return words[ordinal];
  return "next";
}

bool card_topic_active(std::string_view kind) {
  return kind == "news" || kind == "markets" || kind == "briefing" || kind == "card";
}

bool contains_word(std::string_view hay, std::string_view word) {
  if (word.empty() || hay.size() < word.size()) return false;
  std::size_t pos = 0;
  while ((pos = hay.find(word, pos)) != std::string_view::npos) {
    const bool left = pos == 0 || hay[pos - 1] == ' ';
    const bool right =
        pos + word.size() == hay.size() || hay[pos + word.size()] == ' ';
    if (left && right) return true;
    pos += 1;
  }
  return false;
}

std::string lower_copy(std::string value) {
  for (char& c : value) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return value;
}

std::string one_line(std::string value) {
  for (char& c : value) {
    if (c == '\r' || c == '\n' || c == '\t') c = ' ';
  }
  value = trim(value);
  if (value.size() > 500) {
    value.resize(500);
    value += "…";
  }
  return value;
}

bool list_ok(const nlohmann::json& state, const std::string& kind) {
  return (kind == "news" || kind == "markets") && state.contains(kind) &&
         state[kind].is_array() && !state[kind].empty();
}

std::string spoken_item(const nlohmann::json& item, const std::string& kind,
                        const std::string& which) {
  const std::string label = item.value("label", "");
  const std::string detail = item.value("detail", "");
  if (kind == "news") {
    std::string line = "The " + which + " headline is " + label;
    if (!detail.empty()) line += ", from " + detail;
    line += ".";
    return line;
  }
  std::string line = label;
  if (!detail.empty()) line += " is " + detail;
  line += ".";
  return line;
}

std::string spoken_summary(const nlohmann::json& item) {
  std::string summary = trim(item.value("summary", ""));
  if (summary.empty()) return {};
  const char end = summary.back();
  if (end != '.' && end != '!' && end != '?') summary.push_back('.');
  const std::string label = item.value("label", "");
  if (!label.empty() && summary.find(label) == std::string::npos) {
    return label + ". " + summary;
  }
  return summary;
}

void set_focus(nlohmann::json* state, const std::string& kind, int index, int depth) {
  if (!state) return;
  (*state)["focus"] = {{"kind", kind}, {"index", index}, {"depth", depth}};
}

int focused_index(const nlohmann::json& state, const std::string& kind) {
  if (!state.contains("focus") || !state["focus"].is_object()) return -1;
  const auto& focus = state["focus"];
  if (focus.value("kind", "") != kind) return -1;
  if (!focus.contains("index") || !focus["index"].is_number_integer()) return -1;
  return focus["index"].get<int>();
}

int focused_depth(const nlohmann::json& state, const std::string& kind, int index) {
  if (focused_index(state, kind) != index) return -1;
  if (!state["focus"].contains("depth") || !state["focus"]["depth"].is_number_integer()) {
    return 0;
  }
  return state["focus"]["depth"].get<int>();
}

std::string card_discuss_note(const nlohmann::json& item, const std::string& kind,
                              std::string_view current) {
  std::string note =
      "[CARD CONTEXT — private story metadata; never quote this block aloud]\n";
  note += "Story kind: " + kind + "\n";
  note += "Title: " + one_line(item.value("label", "")) + "\n";
  const std::string detail = item.value("detail", "");
  if (!detail.empty()) {
    note += std::string(kind == "news" ? "Source: " : "Quote: ") + one_line(detail) + "\n";
  }
  const std::string summary = item.value("summary", "");
  if (!summary.empty()) note += "What we already have: " + one_line(summary) + "\n";
  note += "Go further than this. Stay with this story. You may look it up. "
          "Do not open by repeating the title.\n";
  note += "[CURRENT USER REQUEST]\n";
  note += current;
  return note;
}

int match_query(const nlohmann::json& items, const std::string& query) {
  if (query.size() < 3) return -1;
  const std::string needle = lower_copy(query);
  std::vector<std::string> words;
  std::string cur;
  for (char c : needle) {
    if (c == ' ') {
      if (cur.size() >= 3 && cur != "the" && cur != "one" && cur != "about") words.push_back(cur);
      cur.clear();
    } else {
      cur.push_back(c);
    }
  }
  if (cur.size() >= 3 && cur != "the" && cur != "one" && cur != "about") words.push_back(cur);
  if (words.empty()) return -1;

  int phrase = -1;
  int phrase_count = 0;
  int word_hit = -1;
  int word_count = 0;
  for (int i = 0; i < static_cast<int>(items.size()); ++i) {
    if (!items[i].is_object()) continue;
    const std::string hay = lower_copy(items[i].value("label", "") + " " +
                                        items[i].value("detail", ""));
    if (hay.find(needle) != std::string::npos) {
      phrase = i;
      ++phrase_count;
      continue;
    }
    bool all = !words.empty();
    for (const auto& word : words) {
      if (!contains_word(hay, word)) all = false;
    }
    if (all) {
      word_hit = i;
      ++word_count;
    }
  }
  if (phrase_count == 1) return phrase;
  if (phrase_count > 1) return -1;
  if (word_count == 1) return word_hit;
  return -1;
}

struct CardTarget {
  std::string kind;
  int index = -1;
  bool missing = false;
  std::string which;
};

std::optional<CardTarget> parse_card_target(const nlohmann::json& state, std::string text) {
  consume_prefix(&text, "the");
  if (text.empty()) return std::nullopt;
  if (text == "that" || text == "that one" || text == "this" || text == "this one" ||
      text == "it") {
    std::string kind = state.value("active", "");
    int index = 0;
    if (state.contains("focus") && state["focus"].is_object()) {
      const std::string focused = state["focus"].value("kind", "");
      const int at = focused_index(state, focused);
      if (list_ok(state, focused) && at >= 0 && at < static_cast<int>(state[focused].size())) {
        kind = focused;
        index = at;
      }
    }
    if (!list_ok(state, kind)) return std::nullopt;
    CardTarget target;
    target.kind = kind;
    target.index = index;
    target.which = ordinal_word(index);
    return target;
  }

  std::string first;
  std::string rest;
  const auto space = text.find(' ');
  if (space == std::string::npos) {
    first = text;
  } else {
    first = text.substr(0, space);
    rest = trim(text.substr(space + 1));
  }
  if (first == "number") {
    const auto next = rest.find(' ');
    first = next == std::string::npos ? rest : rest.substr(0, next);
    rest = next == std::string::npos ? std::string() : trim(rest.substr(next + 1));
  }
  const int ordinal = ordinal_index(first);
  const bool list_noun = rest == "one" || rest == "item" || rest.empty() ||
                         rest == "headline" || rest == "headlines" || rest == "story" ||
                         rest == "stories" || rest == "quote" || rest == "quotes" ||
                         rest == "stock" || rest == "stocks";
  if (ordinal != -2 && list_noun) {
    std::string want;
    if (rest == "one" || rest == "item" || rest.empty()) {
      want = state.value("active", "");
    } else if (rest == "headline" || rest == "headlines" || rest == "story" ||
               rest == "stories") {
      want = "news";
    } else {
      want = "markets";
    }
    if (!list_ok(state, want)) return std::nullopt;
    const int count = static_cast<int>(state[want].size());
    CardTarget target;
    target.kind = want;
    target.index = ordinal < 0 ? count - 1 : ordinal;
    target.missing = target.index >= count;
    target.which = first == "last" ? "last" : ordinal_word(target.index);
    return target;
  }

  std::string query;
  if (consume_prefix(&text, "one about") || consume_prefix(&text, "one on") ||
      consume_prefix(&text, "story about") || consume_prefix(&text, "headline about")) {
    query = text;
  } else {
    for (const char* tail : {" headline", " story", " quote", " stock", " one"}) {
      const std::size_t n = std::char_traits<char>::length(tail);
      if (text.size() > n && text.compare(text.size() - n, n, tail) == 0) {
        query = trim(text.substr(0, text.size() - n));
        break;
      }
    }
    if (query.empty() && text.find(' ') == std::string::npos) query = text;
  }
  if (query.empty()) return std::nullopt;

  const std::string active = state.value("active", "");
  std::string kinds[2];
  int n_kinds = 0;
  if (list_ok(state, active)) kinds[n_kinds++] = active;
  for (const char* kind : {"news", "markets"}) {
    if (n_kinds == 2) break;
    if (active == kind) continue;
    if (list_ok(state, kind)) kinds[n_kinds++] = kind;
  }
  int found = -1;
  std::string found_kind;
  for (int i = 0; i < n_kinds; ++i) {
    const int at = match_query(state[kinds[i]], query);
    if (at < 0) continue;
    if (found >= 0) return std::nullopt;
    found = at;
    found_kind = kinds[i];
  }
  if (found < 0) return std::nullopt;
  CardTarget target;
  target.kind = found_kind;
  target.index = found;
  target.which = ordinal_word(found);
  return target;
}

std::string rest_kind_of(const nlohmann::json& state) {
  const std::string active = state.value("active", "");
  if (list_ok(state, active)) return active;
  if (state.contains("focus") && state["focus"].is_object()) {
    const std::string kind = state["focus"].value("kind", "");
    if (list_ok(state, kind)) return kind;
  }
  if (list_ok(state, "news")) return "news";
  if (list_ok(state, "markets")) return "markets";
  return {};
}

std::optional<CardTurn> resolve_card_turn(const std::string& card_state,
                                          std::string_view transcript,
                                          std::string_view prior_kind) {
  if (card_state.empty()) return std::nullopt;
  nlohmann::json state;
  try {
    state = nlohmann::json::parse(card_state);
  } catch (...) {
    return std::nullopt;
  }
  if (!state.is_object()) return std::nullopt;

  const std::string text = fold_phatic(transcript);
  if (text.empty() || text.size() > 120) return std::nullopt;
  const bool topic = card_topic_active(prior_kind);

  enum class Ask { Title, More, Rest, Discuss };
  Ask ask = Ask::Title;
  std::string body = text;
  if (topic && (text == "what else" || text == "the rest" || text == "any others" ||
                text == "any more" || text == "what else is there" ||
                text == "the other headlines" || text == "the other stories" ||
                text == "what are the others")) {
    ask = Ask::Rest;
  } else if (topic && (text == "more" || text == "tell me more" || text == "go on" ||
                       text == "expand" || text == "elaborate" || text == "more on that" ||
                       text == "more about that" || text == "more on this" ||
                       text == "tell me more about that" || text == "go deeper" ||
                       text == "more detail" || text == "in more detail" ||
                       text == "expand on that")) {
    ask = Ask::More;
  } else if (topic && (text == "why" || text == "why is that" || text == "why does that matter" ||
                       text == "so what" || text == "what do you think" ||
                       text == "what does that mean" || text == "is that good" ||
                       text == "is that bad" || text == "and why" || text == "what about it")) {
    ask = Ask::Discuss;
  } else {
    for (const char* prefix : {"tell me more about", "more detail on", "in more detail on",
                               "expand on", "elaborate on", "go on about", "more about",
                               "more on"}) {
      if (consume_prefix(&body, prefix)) {
        ask = Ask::More;
        break;
      }
    }
    if (ask == Ask::Title) {
      bool progressed = true;
      while (progressed) {
        progressed = false;
        for (const char* prefix : {"tell me about", "tell me", "what about", "how about",
                                   "give me", "read me", "read", "whats", "what is"}) {
          if (consume_prefix(&body, prefix)) progressed = true;
        }
      }
    }
  }

  if (ask == Ask::Rest) {
    const std::string kind = rest_kind_of(state);
    if (!list_ok(state, kind)) return std::nullopt;
    const auto& items = state[kind];
    const int count = static_cast<int>(items.size());
    int start = std::min(3, count);
    if (state.contains("read_through") && state["read_through"].is_object() &&
        state["read_through"].contains(kind) &&
        state["read_through"][kind].is_number_integer()) {
      start = state["read_through"][kind].get<int>();
      if (start < 0) start = 0;
    }
    CardTurn hit;
    hit.list_kind = kind;
    if (start >= count) {
      hit.line = "That is the list.";
      return hit;
    }
    const int end = std::min(count, start + 3);
    for (int i = start; i < end; ++i) {
      if (!items[i].is_object()) continue;
      const std::string label = items[i].value("label", "");
      if (label.empty()) continue;
      if (!hit.line.empty()) hit.line.push_back(' ');
      hit.line += spoken_item(items[i], kind, ordinal_word(i));
      hit.label = label;
    }
    if (hit.line.empty()) return std::nullopt;
    if (!state.contains("read_through") || !state["read_through"].is_object()) {
      state["read_through"] = nlohmann::json::object();
    }
    state["read_through"][kind] = end;
    hit.card_state = state.dump();
    return hit;
  }

  std::optional<CardTarget> target;
  if (ask == Ask::More || ask == Ask::Discuss) {
    if (body == text) {
      std::string kind = state.value("active", "");
      int index = 0;
      if (state.contains("focus") && state["focus"].is_object()) {
        const std::string focused = state["focus"].value("kind", "");
        const int at = focused_index(state, focused);
        if (list_ok(state, focused) && at >= 0 &&
            at < static_cast<int>(state[focused].size())) {
          kind = focused;
          index = at;
        }
      }
      if (!list_ok(state, kind)) return std::nullopt;
      CardTarget bare;
      bare.kind = kind;
      bare.index = index;
      bare.which = ordinal_word(index);
      target = bare;
    }
  }
  if (!target) target = parse_card_target(state, body);
  if (!target) return std::nullopt;

  const char* noun = target->kind == "news" ? "headline" : "quote";
  if (target->missing) {
    CardTurn hit;
    hit.list_kind = target->kind;
    hit.line = std::string("There isn't a ") + target->which + " " + noun + ".";
    return hit;
  }
  const auto& item = state[target->kind][target->index];
  if (!item.is_object()) return std::nullopt;
  const std::string label = item.value("label", "");
  if (label.empty()) return std::nullopt;

  CardTurn hit;
  hit.list_kind = target->kind;
  hit.label = label;
  const bool deepen = ask == Ask::More || ask == Ask::Discuss;
  const std::string summary = item.value("summary", "");
  const int depth = focused_depth(state, target->kind, target->index);
  if (deepen && (ask == Ask::Discuss || summary.empty() || depth >= 1)) {
    hit.action = CardAction::Discuss;
    hit.note = card_discuss_note(item, target->kind, transcript);
    set_focus(&state, target->kind, target->index, 2);
    hit.card_state = state.dump();
    return hit;
  }
  if (deepen) {
    hit.line = spoken_summary(item);
    if (hit.line.empty()) return std::nullopt;
    set_focus(&state, target->kind, target->index, 1);
    hit.card_state = state.dump();
    return hit;
  }
  hit.line = spoken_item(item, target->kind, target->which);
  set_focus(&state, target->kind, target->index, 0);
  hit.card_state = state.dump();
  return hit;
}

std::string context_line(std::string value) {
  for (char& c : value) {
    if (c == '\r' || c == '\n' || c == '\t') c = ' ';
  }
  value = trim(value);
  constexpr std::size_t kContextCap = 500;
  if (value.size() > kContextCap) {
    value.resize(kContextCap);
    value += "…";
  }
  return value;
}

std::string with_fast_path_context(const DeviceSession& prior,
                                   std::string_view current) {
  return "[VOICE CONTEXT — private continuity metadata; never quote this block aloud]\n"
         "Previous local turn kind: " + context_line(prior.last_fast_path_kind) + "\n"
         "Previous user request: " + context_line(prior.last_user) + "\n"
         "Arthur's previous spoken answer: " + context_line(prior.last_spoken) + "\n"
         "[CURRENT USER REQUEST]\n" + std::string(current);
}

std::string understate(std::string line) {
  for (const char* tail : {", sir.", " sir."}) {
    const std::size_t n = std::char_traits<char>::length(tail);
    if (line.size() >= n && line.compare(line.size() - n, n, tail) == 0) {
      line.replace(line.size() - n, n, ".");
      break;
    }
  }
  return line;
}

std::string briefing_clock_line() {
  return understate(spoken_time_now());
}

std::string with_correction_note(const DeviceSession& prior,
                                 std::string_view current, bool rewritten) {
  const std::string request = prior.last_user.empty() ? prior.last_fast_path_request
                                                       : prior.last_user;
  std::string note =
      "[VOICE CONTEXT — private correction; never quote this block aloud]\n"
      "Previous user request: " +
      context_line(request) + "\n" +
      "Arthur's previous spoken answer: " + context_line(prior.last_spoken) + "\n";
  if (rewritten) {
    note += "Corrected request: " + context_line(std::string(current)) + "\n";
  }
  note += "[CURRENT USER REQUEST]\n";
  note += current;
  return note;
}

}  // namespace

std::string TurnPipeline::compose_spoken_briefing() {
  std::string joined = briefing_clock_line();
  if (!config_.fast_path) return joined;

  auto weather_future = std::async(std::launch::async, [this]() -> std::optional<FastPathResult> {
    if (config_.home.configured() && !config_.home.weather_entity.empty()) {
      if (auto fp = fast_path_.try_handle("what's the weather")) {
        if (fp->kind == "weather" && fp->context_valid && !fp->reply.empty()) return fp;
      }
    }
    const std::string place = trim(config_.weather.default_place);
    if (!place.empty()) {
      if (auto fp = fast_path_.try_handle("what's the weather in " + place)) {
        if (fp->kind == "weather" && fp->context_valid && !fp->reply.empty()) return fp;
      }
    }
    return std::nullopt;
  });
  auto news_future = std::async(std::launch::async, [this]() -> std::optional<FastPathResult> {
    if (auto fp = fast_path_.try_handle("what's in the news")) {
      if (fp->kind == "news" && fp->context_valid && !fp->reply.empty()) return fp;
    }
    return std::nullopt;
  });
  auto markets_future = std::async(std::launch::async, [this]() -> std::optional<FastPathResult> {
    if (auto fp = fast_path_.try_handle("how's the market")) {
      if (fp->kind == "markets" && fp->context_valid && !fp->reply.empty()) return fp;
    }
    return std::nullopt;
  });

  auto piece = [](std::optional<FastPathResult> section, const char* gap) {
    if (!section || section->reply.empty()) return std::string(gap);
    return understate(std::move(section->reply));
  };
  joined = morning_briefing_line(
      joined, piece(weather_future.get(), "No weather just now."),
      piece(news_future.get(), "No headlines just now."),
      piece(markets_future.get(), "No market snapshot just now."));
  return joined;
}

TurnPipeline::TurnPipeline(Config config,
                           std::shared_ptr<SttProvider> stt,
                           std::shared_ptr<TtsProvider> tts,
                           std::shared_ptr<ArbiterClient> arbiter,
                           std::shared_ptr<SessionStore> sessions,
                           std::shared_ptr<FillerClient> filler)
    : config_(std::move(config)),
      stt_(std::move(stt)),
      tts_(std::move(tts)),
      arbiter_(std::move(arbiter)),
      sessions_(std::move(sessions)),
      filler_(std::move(filler)),
      news_client_(std::make_shared<NewsClient>(config_.news)),
      markets_client_(std::make_shared<MarketsClient>(config_.markets)),
      fast_path_(config_.fast_path, config_.home,
                 std::make_shared<HomeClient>(config_.home),
                 std::make_shared<WeatherClient>(config_.weather),
                 news_client_,
                 markets_client_) {}

void TurnPipeline::register_turn(std::shared_ptr<TurnHandle> h) {
  std::lock_guard<std::mutex> lk(turns_mu_);
  turns_[h->turn_id] = std::move(h);
}

void TurnPipeline::unregister_turn(const std::string& turn_id) {
  std::lock_guard<std::mutex> lk(turns_mu_);
  turns_.erase(turn_id);
}

std::shared_ptr<TurnHandle> TurnPipeline::find_turn(const std::string& turn_id) {
  std::lock_guard<std::mutex> lk(turns_mu_);
  auto it = turns_.find(turn_id);
  if (it == turns_.end()) return nullptr;
  return it->second;
}

std::optional<DeviceSession> TurnPipeline::session_for(const std::string& device_id) const {
  return sessions_->get(device_id);
}

void TurnPipeline::prepare_turn(const std::string& turn_id) {
  if (turn_id.empty()) return;
  std::lock_guard<std::mutex> lk(turns_mu_);
  if (turns_.find(turn_id) != turns_.end()) return;
  auto handle = std::make_shared<TurnHandle>();
  handle->turn_id = turn_id;
  turns_.emplace(turn_id, std::move(handle));
}

void TurnPipeline::warm_prefix() {
  if (!config_.warm_prefix) return;

  std::set<std::string> ids;
  for (const auto& kv : config_.devices) {
    if (!kv.first.empty()) ids.insert(kv.first);
  }
  for (const auto& s : sessions_->list()) {
    if (!s.device_id.empty()) ids.insert(s.device_id);
  }
  if (ids.empty()) ids.insert("intercom-host");

  int ok = 0;
  int total = 0;
  for (const auto& id : ids) {
    ++total;
    std::string err;
    const auto conv = ensure_conversation(id, &err);
    if (conv <= 0) {
      std::cerr << "intercom warm: " << id << ": "
                << (err.empty() ? "no conversation" : err) << std::endl;
      continue;
    }
    std::atomic<bool> cancel{false};
    const std::string key = "warm-" + id + "-" + make_turn_id();
    if (!arbiter_->send_message(conv, kPrefixWarmMessage, key, ArbiterStreamCallbacks{},
                                &cancel, &err)) {
      std::cerr << "intercom warm: " << id << ": "
                << (err.empty() ? "send failed" : err) << std::endl;
      continue;
    }
    ++ok;
  }
  std::cout << "intercom warm: " << ok << "/" << total << std::endl;
}

std::int64_t TurnPipeline::ensure_conversation(const std::string& device_id, std::string* err) {
  if (auto existing = sessions_->get(device_id)) {
    if (existing->conversation_id > 0) {
      sessions_->remember_conversation(device_id, existing->conversation_id, nullptr);
      return existing->conversation_id;
    }
  }
  auto id = arbiter_->create_conversation("intercom:" + device_id, err);
  if (!id || *id <= 0) {
    if (err && err->empty()) *err = "conversation create failed";
    return 0;
  }
  if (!install_conversation(device_id, *id, false, err)) return 0;
  sessions_->remember_conversation(device_id, *id, nullptr);
  return *id;
}

std::int64_t TurnPipeline::begin_conversation(const std::string& device_id, std::string* err) {
  if (auto existing = sessions_->get(device_id)) {
    if (existing->conversation_id > 0) {
      sessions_->remember_conversation(device_id, existing->conversation_id, nullptr);
    }
  }
  auto id = arbiter_->create_conversation("intercom:" + device_id, err);
  if (!id || *id <= 0) {
    if (err && err->empty()) *err = "conversation create failed";
    return 0;
  }
  if (!sessions_->remember_conversation(device_id, *id, err)) return 0;
  if (!install_conversation(device_id, *id, true, err)) return 0;
  return *id;
}

bool TurnPipeline::resume_conversation(const std::string& device_id,
                                       std::int64_t conversation_id,
                                       std::string* err) {
  if (conversation_id <= 0) {
    if (err) *err = "missing conversation";
    return false;
  }
  const auto existing = sessions_->get(device_id);
  const bool current = existing && existing->conversation_id == conversation_id;
  if (!current && !sessions_->owns_conversation(device_id, conversation_id)) {
    if (err) *err = "unknown conversation";
    return false;
  }
  sessions_->remember_conversation(device_id, conversation_id, nullptr);
  if (current) return true;
  return install_conversation(device_id, conversation_id, true, err);
}

bool TurnPipeline::install_conversation(const std::string& device_id,
                                        std::int64_t conversation_id,
                                        bool clear_memory,
                                        std::string* err) {
  DeviceSession s;
  if (auto existing = sessions_->get(device_id)) s = *existing;
  s.device_id = device_id;
  s.conversation_id = conversation_id;
  if (clear_memory) {
    s.last_turn_id.clear();
    s.last_user.clear();
    s.last_spoken.clear();
    s.last_fast_path_kind.clear();
    s.last_fast_path_request.clear();
    s.last_card.clear();
    s.pending_intent.clear();
    s.pending_at = 0;
  }
  s.updated_at = now_unix();
  return sessions_->upsert(s, err);
}

bool TurnPipeline::arm_approval(const std::string& device_id, const std::string& id) {
  if (device_id.empty() || id.empty() || id.size() > 64) return false;
  for (unsigned char c : id) {
    if (!(std::isalnum(c) || c == '-' || c == '_')) return false;
  }
  std::lock_guard<std::mutex> lk(approval_mu_);
  DeviceSession s;
  if (auto existing = sessions_->get(device_id)) s = *existing;
  s.device_id = device_id;
  s.pending_intent = make_approval_intent(id);
  s.pending_at = now_unix();
  s.updated_at = s.pending_at;
  return sessions_->upsert(s, nullptr);
}

bool TurnPipeline::clear_approval(const std::string& device_id) {
  std::lock_guard<std::mutex> lk(approval_mu_);
  auto existing = sessions_->get(device_id);
  if (!existing || !is_approval_intent(existing->pending_intent)) return true;
  existing->pending_intent.clear();
  existing->pending_at = 0;
  existing->updated_at = now_unix();
  return sessions_->upsert(*existing, nullptr);
}

bool TurnPipeline::cancel_turn(const std::string& turn_id, std::string* err) {
  auto h = find_turn(turn_id);
  if (!h) {
    if (err) *err = "turn not found";
    return false;
  }
  h->cancel.store(true);
  std::string rid;
  {
    std::lock_guard<std::mutex> lk(h->mu);
    rid = h->arbiter_request_id;
  }
  if (!rid.empty()) {
    return arbiter_->cancel_request(rid, err);
  }
  return true;
}

TurnResult TurnPipeline::run_utterance(const std::string& device_id,
                                       const std::vector<std::uint8_t>& pcm,
                                       int sample_rate,
                                       int channels,
                                       AudioSink& sink,
                                       std::string turn_id,
                                       ClientContext client_context) {
  if (turn_id.empty()) turn_id = make_turn_id();
  // Register before one-shot STT so an accepted turn can be cancelled while
  // Whisper is still transcribing it.
  prepare_turn(turn_id);
  auto handle = find_turn(turn_id);

  std::string err;
  const auto stt_t0 = std::chrono::steady_clock::now();
  const std::string transcript = stt_->transcribe(pcm, sample_rate, channels, &err);
  const int stt_ms = static_cast<int>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - stt_t0)
          .count());
  if (transcript.empty()) {
    TurnResult result;
    result.turn_id = std::move(turn_id);
    result.error = handle->cancel.load() ? "canceled"
                                         : (err.empty() ? "stt failed" : err);
    unregister_turn(result.turn_id);
    std::cerr << "intercom latency turn=" << result.turn_id << " stt_ms=" << stt_ms
              << " error=" << result.error << std::endl;
    return result;
  }
  SpeakerIdentity speaker = identify_pcm(pcm.data(), pcm.size(), sample_rate, channels);
  return run_text_utterance(
      device_id, transcript, sink, std::move(turn_id), stt_ms, std::move(client_context),
      std::move(speaker));
}

TurnResult TurnPipeline::run_text_utterance(const std::string& device_id,
                                            const std::string& transcript,
                                            AudioSink& sink,
                                            std::string turn_id,
                                            int stt_ms,
                                            ClientContext client_context,
                                            SpeakerIdentity speaker) {
  TurnResult result;
  result.turn_id = turn_id.empty() ? make_turn_id() : std::move(turn_id);
  result.transcript = transcript;
  // Context is private metadata. It is never the heard line or last_user.
  result.client_context_sources = static_cast<int>(client_context.sources.size());
  // run_utterance registers before STT. Text-only transports arrive here
  // directly and need their handle created now.
  auto handle = find_turn(result.turn_id);
  if (!handle) {
    handle = std::make_shared<TurnHandle>();
    handle->turn_id = result.turn_id;
    register_turn(handle);
  }

  const auto turn_start = std::chrono::steady_clock::now();
  int ttfa_ms = -1;
  int kokoro_first_ms = -1;
  int kokoro_total_ms = 0;
  int conv_ms = -1;
  int first_sentence_ms = -1;
  int first_answer_ms = -1;
  int ctx_ms = 0;
  std::atomic<int> arbiter_ttft_ms{-1};
  const char* ttfa_kind = "";
  const char* pending_kind = "answer";
  const char* path_name = "arbiter";

  auto elapsed_now = [&]() -> int {
    return static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::steady_clock::now() - turn_start)
                                .count());
  };

  auto finish = [&](TurnResult r) {
    unregister_turn(result.turn_id);
    std::cerr << "intercom latency turn=" << result.turn_id << " path=" << path_name
              << " stt_ms=" << stt_ms << " conv_ms=" << conv_ms
              << " arbiter_ttft_ms=" << arbiter_ttft_ms.load()
              << " first_sentence_ms=" << first_sentence_ms
              << " kokoro_ms=" << kokoro_first_ms << " kokoro_total_ms=" << kokoro_total_ms
              << " ttfa_ms=" << ttfa_ms << " ttfa_kind=" << (ttfa_kind[0] ? ttfa_kind : "-")
              << " first_answer_ms=" << first_answer_ms
              << " ctx_sources=" << result.client_context_sources
              << " ctx_images=" << client_context.images.size()
              << " ctx_ms=" << ctx_ms
              << " speaker=" << (speaker.confident ? speaker.person_id : "household")
              << " speaker_ms=" << speaker.score_ms;
    if (!r.error.empty()) std::cerr << " error=" << r.error;
    std::cerr << std::endl;
    return r;
  };

  if (handle->cancel.load()) {
    result.error = "canceled";
    return finish(result);
  }
  if (!transcript.empty()) {
    // Desk clients need the user line before Arbiter / TTS so voice turns
    // cluster like typed ones. Whisper is still one-shot at `end`.
    sink.event("heard", transcript);
  }

  std::string routing_transcript = result.transcript;
  auto prior_session = sessions_->get(device_id);
  const auto household_memory = prior_session;
  if (speaker.confident) {
    DeviceSession scoped = prior_session.value_or(DeviceSession{});
    scoped.device_id = device_id;
    scoped.last_user.clear();
    scoped.last_spoken.clear();
    scoped.last_card.clear();
    scoped.last_fast_path_kind.clear();
    scoped.last_fast_path_request.clear();
    if (auto saved = sessions_->get_scope(device_id, speaker.person_id)) {
      scoped.last_user = saved->last_user;
      scoped.last_spoken = saved->last_spoken;
      scoped.last_card = saved->last_card;
      scoped.last_fast_path_kind = saved->last_fast_path_kind;
      scoped.last_fast_path_request = saved->last_fast_path_request;
    }
    if (household_memory) {
      scoped.conversation_id = household_memory->conversation_id;
      scoped.pending_intent = household_memory->pending_intent;
      scoped.pending_at = household_memory->pending_at;
      scoped.last_turn_id = household_memory->last_turn_id;
    }
    prior_session = scoped;
  }
  if (speaker.confident || speaker.score_ms >= 0) {
    nlohmann::json named = {
        {"id", speaker.confident ? speaker.person_id : ""},
        {"name", speaker.confident ? speaker.name : ""},
        {"confident", speaker.confident},
    };
    sink.event("speaker", named.dump());
  }
  std::string carried_card = prior_session ? prior_session->last_card : "";
  auto remember_surface = [&](const nlohmann::json& surface) {
    carried_card = merge_card_state(carried_card, surface);
  };
  if (prior_session && !prior_session->last_spoken.empty() &&
      is_repeat_request(result.transcript)) {
    routing_transcript = "echo " + prior_session->last_spoken;
  } else if (prior_session &&
      prior_session->pending_intent == "timer_duration" &&
      prior_session->pending_at > 0 &&
      now_unix() - prior_session->pending_at <= 120 &&
      !parse_home_intent(result.transcript).has_value()) {
    const int seconds = parse_duration_seconds(result.transcript);
    if (seconds > 0) {
      routing_transcript = "set a timer for " + spoken_duration(seconds);
    }
  } else if (prior_session && config_.home.configured() &&
             !parse_home_intent(result.transcript).has_value()) {
    if (auto resolved =
            resolve_local_action_followup(*prior_session, result.transcript)) {
      routing_transcript = *resolved;
    }
  }

  RepairPlan repair;
  if (prior_session && routing_transcript == result.transcript) {
    repair = resolve_repair(config_, *prior_session, result.transcript);
    if (repair.kind == RepairKind::Rewrite) {
      routing_transcript = repair.routing;
    }
  }

  std::string err;
  auto speak = [&](const std::string& text, bool continuation = false) -> bool {
    // A latency flush is not a sentence boundary. Preserve continuation
    // prosody instead of letting to_speakable() turn the fragment into a
    // complete sentence with a full stop.
    std::string delivery_text = text;
    if (continuation) {
      delivery_text = trim(delivery_text);
      if (!delivery_text.empty() &&
          delivery_text.back() != ',' && delivery_text.back() != ';' &&
          delivery_text.back() != ':') {
        delivery_text.push_back(',');
      }
    }
    const std::string spoken = to_speakable(delivery_text);
    if (spoken.empty()) return true;
    sink.event("said", spoken);
    const auto t0 = std::chrono::steady_clock::now();
    const bool ok = tts_->synthesize(
        spoken,
        [&](const std::uint8_t* data, std::size_t len) {
          if (handle->cancel.load()) return false;
          if (ttfa_ms < 0) {
            ttfa_ms = elapsed_now();
            ttfa_kind = pending_kind;
          }
          return sink.write(data, len);
        },
        &err);
    const int dt = static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                        std::chrono::steady_clock::now() - t0)
                                        .count());
    if (kokoro_first_ms < 0) kokoro_first_ms = dt;
    kokoro_total_ms += dt;
    return ok;
  };

  bool resolved_approval = false;
  auto save_session = [&](DeviceSession s) {
    std::lock_guard<std::mutex> lk(approval_mu_);
    if (!resolved_approval && !is_approval_intent(s.pending_intent)) {
      if (auto live = sessions_->get(device_id)) {
        if (is_approval_intent(live->pending_intent) && live->pending_at > 0 &&
            now_unix() - live->pending_at <= 180) {
          s.pending_intent = live->pending_intent;
          s.pending_at = live->pending_at;
        }
      }
    }
    if (s.updated_at <= 0) s.updated_at = now_unix();
    sessions_->upsert(s, &err);
  };
  auto keep_session = [&](DeviceSession s) {
    if (speaker.confident) {
      PersonScope scope;
      scope.device_id = device_id;
      scope.person_id = speaker.person_id;
      scope.last_user = s.last_user;
      scope.last_spoken = s.last_spoken;
      scope.last_card = s.last_card;
      scope.last_fast_path_kind = s.last_fast_path_kind;
      scope.last_fast_path_request = s.last_fast_path_request;
      sessions_->upsert_scope(scope, nullptr);
      if (household_memory) {
        s.last_user = household_memory->last_user;
        s.last_spoken = household_memory->last_spoken;
        s.last_card = household_memory->last_card;
        s.last_fast_path_kind = household_memory->last_fast_path_kind;
        s.last_fast_path_request = household_memory->last_fast_path_request;
        if (household_memory->conversation_id > 0) {
          s.conversation_id = household_memory->conversation_id;
        }
      } else {
        s.last_user.clear();
        s.last_spoken.clear();
        s.last_card.clear();
        s.last_fast_path_kind.clear();
        s.last_fast_path_request.clear();
      }
      s.person_id = speaker.person_id;
    } else {
      s.person_id.clear();
    }
    save_session(s);
  };

  if (prior_session && is_approval_intent(prior_session->pending_intent) &&
      prior_session->pending_at > 0) {
    const bool fresh = now_unix() - prior_session->pending_at <= 180;
    const std::string approval_id = approval_id_from_intent(prior_session->pending_intent);
    const auto decision = fresh ? classify_approval(result.transcript) : ApprovalDecision::Other;
    if (fresh && decision != ApprovalDecision::Other) {
      resolved_approval = true;
      nlohmann::json body = {
          {"id", approval_id},
          {"granted", decision == ApprovalDecision::Yes},
      };
      sink.event("approval", body.dump());
      const char* line = decision == ApprovalDecision::Yes ? "All right." : "All right, I won't.";
      result.used_fast_path = true;
      result.fast_path_kind = "approval";
      path_name = "fast";
      pending_kind = "fast";
      result.conversation_id = prior_session->conversation_id;
      if (!speak(line)) {
        result.error = err.empty() ? "tts failed" : err;
      } else {
        result.ok = true;
      }
      DeviceSession s = *prior_session;
      s.last_turn_id = result.turn_id;
      s.last_user = result.transcript;
      s.last_spoken = line;
      s.pending_intent.clear();
      s.pending_at = 0;
      s.updated_at = now_unix();
      keep_session(s);
      return finish(result);
    }
    {
      std::lock_guard<std::mutex> lk(approval_mu_);
      if (auto live = sessions_->get(device_id)) {
        if (live->pending_intent == prior_session->pending_intent) {
          live->pending_intent.clear();
          live->pending_at = 0;
          live->updated_at = now_unix();
          sessions_->upsert(*live, &err);
          if (fresh) {
            sink.event("approval",
                       nlohmann::json{{"id", approval_id}, {"granted", false}, {"reason", "replaced"}}
                           .dump());
          }
        }
      }
    }
  }

  std::string card_note;
  std::string card_follow_kind;
  std::string card_follow_request;
  if (prior_session && routing_transcript == result.transcript) {
    if (auto card = resolve_card_turn(prior_session->last_card, result.transcript,
                                      prior_session->last_fast_path_kind)) {
      if (!card->card_state.empty()) carried_card = card->card_state;
      if (card->action == CardAction::Discuss) {
        card_note = card->note;
        card_follow_kind = card->list_kind;
        card_follow_request = card->label;
      } else {
      result.used_fast_path = true;
      result.fast_path_kind = "card";
      path_name = "fast";
      pending_kind = "fast";
      if (auto existing = sessions_->get(device_id)) {
        result.conversation_id = existing->conversation_id;
      }
      if (!speak(card->line)) {
        result.error = err.empty() ? "tts failed" : err;
        return finish(result);
      }
      if (result.conversation_id <= 0) {
        std::string conv_err;
        result.conversation_id = ensure_conversation(device_id, &conv_err);
        if (result.conversation_id <= 0) {
          std::cerr << "intercom fast-path conversation: "
                    << (conv_err.empty() ? "create failed" : conv_err) << std::endl;
        }
      }
      result.ok = true;
      if (result.conversation_id > 0) {
        DeviceSession s;
        s.device_id = device_id;
        s.conversation_id = result.conversation_id;
        s.last_turn_id = result.turn_id;
        s.last_user = result.transcript;
        s.last_spoken = card->line;
        s.last_fast_path_kind = card->list_kind;
        s.last_fast_path_request =
            card->label.empty() ? prior_session->last_fast_path_request : card->label;
        s.last_card = carried_card;
        if (prior_session) {
          s.pending_intent = prior_session->pending_intent;
          s.pending_at = prior_session->pending_at;
        }
        s.updated_at = now_unix();
        keep_session(s);
      }
      return finish(result);
      }
    }
  }

  if (config_.fast_path && is_spoken_briefing(routing_transcript)) {
    result.used_fast_path = true;
    result.fast_path_kind = "briefing";
    path_name = "fast";
    pending_kind = "fast";
    if (auto existing = sessions_->get(device_id)) {
      result.conversation_id = existing->conversation_id;
    }

    auto weather_future = std::async(std::launch::async, [this]() -> std::optional<FastPathResult> {
      if (config_.home.configured() && !config_.home.weather_entity.empty()) {
        if (auto fp = fast_path_.try_handle("what's the weather")) {
          if (fp->kind == "weather" && fp->context_valid && !fp->reply.empty()) return fp;
        }
      }
      const std::string place = trim(config_.weather.default_place);
      if (!place.empty()) {
        if (auto fp = fast_path_.try_handle("what's the weather in " + place)) {
          if (fp->kind == "weather" && fp->context_valid && !fp->reply.empty()) return fp;
        }
      }
      return std::nullopt;
    });
    auto news_future = std::async(std::launch::async, [this]() -> std::optional<FastPathResult> {
      if (auto fp = fast_path_.try_handle("what's in the news")) {
        if (fp->kind == "news" && fp->context_valid && !fp->reply.empty()) return fp;
      }
      return std::nullopt;
    });
    auto markets_future = std::async(std::launch::async, [this]() -> std::optional<FastPathResult> {
      if (auto fp = fast_path_.try_handle("how's the market")) {
        if (fp->kind == "markets" && fp->context_valid && !fp->reply.empty()) return fp;
      }
      return std::nullopt;
    });

    std::string joined_reply;
    auto speak_piece = [&](std::string line, const nlohmann::json& surface) -> bool {
      line = understate(std::move(line));
      if (line.empty()) return true;
      if (!speak(line)) return false;
      if (surface.is_object()) {
        remember_surface(surface);
        sink.event("surface", surface_event_body(result.turn_id, surface).dump());
      }
      if (!joined_reply.empty()) joined_reply.push_back(' ');
      joined_reply += line;
      return true;
    };
    auto speak_optional = [&](std::optional<FastPathResult> section,
                              const char* gap) -> bool {
      if (handle->cancel.load()) {
        result.error = "canceled";
        return false;
      }
      if (!section) return speak_piece(gap, nullptr);
      nlohmann::json surface = section->surface.is_object() ? section->surface : nullptr;
      return speak_piece(std::move(section->reply), surface);
    };

    if (!speak_piece(briefing_clock_line(), nullptr)) {
      result.error = err.empty() ? "tts failed" : err;
      return finish(result);
    }
    if (!speak_optional(weather_future.get(), "No weather just now.")) {
      if (result.error.empty()) result.error = err.empty() ? "tts failed" : err;
      return finish(result);
    }
    if (!speak_optional(news_future.get(), "No headlines just now.")) {
      if (result.error.empty()) result.error = err.empty() ? "tts failed" : err;
      return finish(result);
    }
    if (!speak_optional(markets_future.get(), "No market snapshot just now.")) {
      if (result.error.empty()) result.error = err.empty() ? "tts failed" : err;
      return finish(result);
    }
    if (handle->cancel.load()) {
      result.error = "canceled";
      return finish(result);
    }

    if (result.conversation_id <= 0) {
      std::string conv_err;
      result.conversation_id = ensure_conversation(device_id, &conv_err);
      if (result.conversation_id <= 0) {
        std::cerr << "intercom fast-path conversation: "
                  << (conv_err.empty() ? "create failed" : conv_err) << std::endl;
      }
    }
    result.ok = true;
    if (result.conversation_id > 0) {
      DeviceSession s;
      s.device_id = device_id;
      s.conversation_id = result.conversation_id;
      s.last_turn_id = result.turn_id;
      s.last_user = result.transcript;
      s.last_spoken = joined_reply;
      s.last_fast_path_kind = "briefing";
      s.last_fast_path_request = routing_transcript;
      s.last_card = carried_card;
      s.updated_at = now_unix();
      keep_session(s);
    }
    return finish(result);
  }

  if (const auto clauses = local_compound_clauses(config_, routing_transcript);
      clauses.size() >= 2) {
    result.used_fast_path = true;
    path_name = "fast";
    pending_kind = "fast";
    if (auto existing = sessions_->get(device_id)) {
      result.conversation_id = existing->conversation_id;
    }
    std::string joined_reply;
    std::string joined_kind;
    std::string saved_kind;
    std::string saved_request;
    bool arm_timer = false;
    for (const auto& clause : clauses) {
      if (handle->cancel.load()) {
        result.error = "canceled";
        return finish(result);
      }
      auto handled = fast_path_.try_handle(clause);
      FastPathResult fp = handled
                              ? *handled
                              : FastPathResult{"I couldn't do that, sir.", "failed"};
      if (!handled) fp.context_valid = false;
      if (!speak(fp.reply)) {
        result.error = err.empty() ? "tts failed" : err;
        return finish(result);
      }
      if (fp.surface.is_object()) {
        remember_surface(fp.surface);
        sink.event("surface", surface_event_body(result.turn_id, fp.surface).dump());
      }
      if (!joined_reply.empty() && !fp.reply.empty()) joined_reply.push_back(' ');
      joined_reply += fp.reply;
      if (!joined_kind.empty()) joined_kind.push_back('+');
      joined_kind += fp.kind;
      if (fp.context_valid) {
        saved_kind = fp.kind;
        saved_request = clause;
      }
      if (auto intent = parse_home_intent(clause);
          intent && intent->kind == HomeIntentKind::Timer &&
          intent->timer_seconds <= 0) {
        arm_timer = true;
      }
    }
    result.fast_path_kind = joined_kind;
    if (result.conversation_id <= 0) {
      std::string conv_err;
      result.conversation_id = ensure_conversation(device_id, &conv_err);
      if (result.conversation_id <= 0) {
        std::cerr << "intercom fast-path conversation: "
                  << (conv_err.empty() ? "create failed" : conv_err) << std::endl;
      }
    }
    result.ok = true;
    if (result.conversation_id > 0) {
      DeviceSession s;
      s.device_id = device_id;
      s.conversation_id = result.conversation_id;
      s.last_turn_id = result.turn_id;
      s.last_user = result.transcript;
      s.last_spoken = joined_reply;
      s.last_fast_path_kind = saved_kind;
      s.last_fast_path_request = saved_request;
      s.last_card = carried_card;
      if (arm_timer) {
        s.pending_intent = "timer_duration";
        s.pending_at = now_unix();
      }
      s.updated_at = now_unix();
      keep_session(s);
    }
    return finish(result);
  }

  if (auto fp = fast_path_.try_handle(routing_transcript)) {
    result.used_fast_path = true;
    result.fast_path_kind = fp->kind;
    path_name = "fast";
    pending_kind = "fast";
    if (auto existing = sessions_->get(device_id)) {
      result.conversation_id = existing->conversation_id;
    }
    if (!speak(fp->reply)) {
      result.error = err.empty() ? "tts failed" : err;
      return finish(result);
    }
    if (fp->surface.is_object()) {
      remember_surface(fp->surface);
      sink.event("surface", surface_event_body(result.turn_id, fp->surface).dump());
    }
    if (result.conversation_id <= 0) {
      std::string conv_err;
      result.conversation_id = ensure_conversation(device_id, &conv_err);
      if (result.conversation_id <= 0) {
        std::cerr << "intercom fast-path conversation: "
                  << (conv_err.empty() ? "create failed" : conv_err) << std::endl;
      }
    }
    result.ok = true;
    if (result.conversation_id > 0) {
      DeviceSession s;
      s.device_id = device_id;
      s.conversation_id = result.conversation_id;
      s.last_turn_id = result.turn_id;
      s.last_user = result.transcript;
      s.last_spoken = fp->reply;
      if (fp->context_valid) {
        s.last_fast_path_kind = fp->kind;
        s.last_fast_path_request = routing_transcript;
      }
      s.last_card = carried_card;
      if (auto intent = parse_home_intent(routing_transcript);
          intent && intent->kind == HomeIntentKind::Timer &&
          intent->timer_seconds <= 0) {
        s.pending_intent = "timer_duration";
        s.pending_at = now_unix();
      }
      s.updated_at = now_unix();
      keep_session(s);
    }
    return finish(result);
  }

  std::string arbiter_message = routing_transcript;
  if (!card_note.empty()) {
    arbiter_message = card_note;
  } else if (prior_session &&
      (repair.kind == RepairKind::Rewrite || repair.kind == RepairKind::Note)) {
    const std::string current = repair.kind == RepairKind::Rewrite
                                    ? repair.routing
                                    : result.transcript;
    arbiter_message = with_correction_note(
        *prior_session, current, repair.kind == RepairKind::Rewrite);
  } else if (prior_session && bridges_fast_path_kind(prior_session->last_fast_path_kind) &&
      !prior_session->last_user.empty() && !prior_session->last_spoken.empty() &&
      is_contextual_followup(result.transcript)) {
    arbiter_message = with_fast_path_context(*prior_session, result.transcript);
  }

  {
    const auto ctx_t0 = std::chrono::steady_clock::now();
    client_context = context_for_speaker(std::move(client_context), speaker);
    // Typed turns have no voice. The agent rule covers them. A note on every
    // text turn would change replies the desk already sends without audio.
    if (speaker.score_ms >= 0) {
      arbiter_message = speaker_note(speaker) + arbiter_message;
    }
    if (!client_context.sources.empty()) {
      arbiter_message = with_local_context(client_context, arbiter_message);
    }
    ctx_ms = static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                  std::chrono::steady_clock::now() - ctx_t0)
                                  .count());
  }

  // Medium-confidence (or high-confidence fetch miss) news/markets: let
  // Arbiter speak, but still attach a card when Intercom can fetch data.
  std::future<nlohmann::json> briefing_surface_future;
  if (auto briefing = parse_briefing_intent(result.transcript)) {
    briefing_surface_future = std::async(std::launch::async, [this, briefing]() {
      std::string fetch_err;
      if (briefing->kind == BriefingKind::News && news_client_) {
        auto extracted = news_client_->fetch(briefing->topic, &fetch_err);
        if (extracted.ok) return surface_to_json(extracted.surface);
      } else if (briefing->kind == BriefingKind::Markets && markets_client_) {
        auto extracted = markets_client_->fetch(briefing->symbols, &fetch_err);
        if (extracted.ok) return surface_to_json(extracted.surface);
      }
      return nlohmann::json(nullptr);
    });
  }
  auto emit_briefing_surface = [&]() {
    if (!briefing_surface_future.valid() || handle->cancel.load()) return;
    auto surf = briefing_surface_future.get();
    if (surf.is_object()) {
      remember_surface(surf);
      sink.event("surface", surface_event_body(result.turn_id, surf).dump());
    }
  };

  const bool filler_enabled =
      filler_ && config_.filler.enabled &&
      !withholds_fillers(result.transcript);

  std::future<std::string> initial_filler_future;
  if (filler_enabled && config_.filler.instant_ack_ms <= 0) {
    initial_filler_future = std::async(std::launch::async, [&, transcript]() {
      std::string filler_err;
      const std::string phrase = filler_->generate(
          transcript, FillerStage::Initial, "", &handle->cancel, &filler_err);
      if (!filler_err.empty()) {
        std::cerr << "intercom filler: " << filler_err << std::endl;
      } else if (!phrase.empty()) {
        std::cerr << "intercom filler: generated \"" << phrase << "\"" << std::endl;
      } else if (!handle->cancel.load()) {
        std::cerr << "intercom filler: empty phrase" << std::endl;
      }
      return phrase;
    });
  }

  std::string conv_err;
  auto conv_future = std::async(std::launch::async, [&]() {
    const auto conv_t0 = std::chrono::steady_clock::now();
    const std::int64_t id = ensure_conversation(device_id, &conv_err);
    const int conv_get_ms = static_cast<int>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - conv_t0)
            .count());
    // A session read should be single-digit ms. Log the outliers so DB
    // contention shows up in the latency trail instead of hiding in conv_ms.
    if (conv_get_ms > 150) {
      std::cerr << "intercom conv slow: " << conv_get_ms << "ms" << std::endl;
    }
    return id;
  });

  const std::int64_t conv = conv_future.get();
  conv_ms = elapsed_now();
  if (conv == 0) {
    result.error = conv_err.empty() ? "conversation create failed" : conv_err;
    return finish(result);
  }
  result.conversation_id = conv;
  sink.event("status", "thinking");

  ArbiterRunState arb_state;
  std::string spoken_filler;
  bool instant_spoken = false;
  bool contextual_spoken = false;
  int followups_spoken = 0;
  std::optional<std::chrono::steady_clock::time_point> next_followup_at;
  std::future<std::string> followup_future;

  ArbiterStreamCallbacks cbs;
  cbs.on_request_id = [&](const std::string& rid) {
    std::lock_guard<std::mutex> lk(handle->mu);
    handle->arbiter_request_id = rid;
  };
  cbs.on_text_delta = [&](const std::string& delta) {
    if (handle->cancel.load()) return;
    if (!arb_state.got_first_delta.load()) {
      arbiter_ttft_ms.store(elapsed_now());
    }
    arb_state.got_first_delta.store(true);
    std::lock_guard<std::mutex> lk(arb_state.speak_mu);
    arb_state.speak_buf += arb_state.speech_gate.push(delta);
    const int now_ms = elapsed_now();
    if (now_ms - arb_state.last_forming_ms >= 80) {
      arb_state.last_forming_ms = now_ms;
      // Always the unspoken prefix — never a sliding tail. A tail made the
      // Mac join first-`said` + last-N chars and drop the middle as the
      // window moved (and `started_answer` stays false during the first TTS).
      std::string preview = arb_state.speak_buf;
      constexpr std::size_t kFormingCap = 2000;
      if (preview.size() > kFormingCap) preview = preview.substr(0, kFormingCap);
      sink.event("forming", preview);
    }
  };
  cbs.on_tool_call = [&](const std::string& tool) {
    {
      std::lock_guard<std::mutex> lk(arb_state.speak_mu);
      arb_state.tool_name = tool;
    }
    arb_state.tool_started_ms.store(elapsed_now());
    arb_state.saw_tool.store(true);
    sink.event("working", tool);
  };
  cbs.on_done = [&](bool ok, const std::string& content, const std::string& error) {
    arb_state.done_ok = ok;
    arb_state.full_content = content;
    arb_state.done_err = error;
    arb_state.done.store(true);
  };

  const nlohmann::json user_payload = user_message_json(client_context, arbiter_message);
  auto arbiter_future = std::async(std::launch::async, [&, user_payload]() {
    std::string stream_err;
    const bool streamed = user_payload.is_string()
        ? arbiter_->send_message(conv, user_payload.get<std::string>(), result.turn_id, cbs,
                                 &handle->cancel, &stream_err)
        : arbiter_->send_user_message(conv, user_payload, result.turn_id, cbs,
                                      &handle->cancel, &stream_err);
    arb_state.streamed = streamed;
    arb_state.stream_err = std::move(stream_err);
    arb_state.done.store(true);
    return streamed;
  });

  auto sentence_ready = [&]() -> bool {
    std::lock_guard<std::mutex> lk(arb_state.speak_mu);
    std::string copy = arb_state.speak_buf;
    return !flush_sentences(copy, false, early_flush_words(config_)).empty();
  };

  // Drain completed sentences (and ~N-word prefixes) from speak_buf.
  // Spoken sentences are not re-spoken on done: final_flush only emits the
  // leftover tail, and full_content is a fallback when nothing was spoken.
  auto drain_and_speak = [&](bool final_flush) -> bool {
    std::vector<std::string> sentences;
    {
      std::lock_guard<std::mutex> lk(arb_state.speak_mu);
      sentences = flush_sentences(arb_state.speak_buf, final_flush,
                                  early_flush_words(config_));
    }
    for (const auto& raw : coalesce_speech_sentences(sentences)) {
      if (handle->cancel.load()) return false;
      if (non_space_count(raw) < 3) continue;
      if (first_sentence_ms < 0) first_sentence_ms = elapsed_now();
      pending_kind = "answer";
      const bool complete_sentence =
          !raw.empty() && (raw.back() == '.' || raw.back() == '!' || raw.back() == '?');
      if (!speak(raw, !final_flush && !complete_sentence)) return false;
      if (first_answer_ms < 0) first_answer_ms = elapsed_now();
      arb_state.started_answer.store(true);
    }
    return true;
  };

  auto maybe_speak_filler = [&](const std::string& phrase, bool is_instant = false) -> bool {
    if (phrase.empty() || handle->cancel.load() || arb_state.done.load()) {
      return true;
    }
    if (arb_state.started_answer.load()) return true;
    if (arb_state.got_first_delta.load() && sentence_ready()) return true;
    if (!is_instant && phrase == spoken_filler) return true;
    std::cerr << "intercom filler: speaking \"" << phrase << "\"" << std::endl;
    spoken_filler = phrase;
    pending_kind = is_instant ? "ack" : "filler";
    if (config_.filler.max_followups > 0) {
      next_followup_at = std::chrono::steady_clock::now() +
                         std::chrono::milliseconds(config_.filler.followup_silence_ms);
    }
    const bool ok = speak(phrase);
    pending_kind = "answer";
    return ok;
  };

  while (!arb_state.done.load()) {
    if (handle->cancel.load()) break;

    if (arb_state.got_first_delta.load()) {
      if (!drain_and_speak(false)) {
        result.error = err.empty() ? "tts failed" : err;
        handle->cancel.store(true);
        break;
      }
    }

    const bool hold_local_ack =
        arb_state.got_first_delta.load() || arb_state.started_answer.load();
    const bool hold_llm_fillers =
        hold_local_ack || !arb_state.saw_tool.load();

    const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::steady_clock::now() - turn_start)
                                .count();

    const int tool_started_ms = arb_state.tool_started_ms.load();
    if (filler_enabled && !hold_local_ack && !instant_spoken && spoken_filler.empty() &&
        tool_started_ms >= 0 &&
        elapsed_ms - tool_started_ms >= std::max(0, config_.filler.tool_ack_ms)) {
      instant_spoken = true;
      std::string tool_name;
      {
        std::lock_guard<std::mutex> lk(arb_state.speak_mu);
        tool_name = arb_state.tool_name;
      }
      if (!maybe_speak_filler(FillerClient::tool_ack(tool_name), true)) {
        result.error = err.empty() ? "tts failed" : err;
        handle->cancel.store(true);
        break;
      }
    }

    if (filler_enabled && !hold_local_ack && !instant_spoken && spoken_filler.empty() &&
        config_.filler.instant_ack_ms > 0 &&
        elapsed_ms >= config_.filler.instant_ack_ms) {
      instant_spoken = true;
      if (!maybe_speak_filler(FillerClient::instant_ack(), true)) {
        result.error = err.empty() ? "tts failed" : err;
        handle->cancel.store(true);
        break;
      }
    }

    if (!hold_llm_fillers && filler_enabled && !contextual_spoken &&
        !instant_spoken && initial_filler_future.valid() &&
        elapsed_ms >= config_.filler.min_silence_ms &&
        initial_filler_future.wait_for(std::chrono::milliseconds(0)) ==
            std::future_status::ready) {
      contextual_spoken = true;
      if (!maybe_speak_filler(initial_filler_future.get())) {
        result.error = err.empty() ? "tts failed" : err;
        handle->cancel.store(true);
        break;
      }
    }

    if (!hold_llm_fillers && filler_enabled && next_followup_at &&
        followups_spoken < config_.filler.max_followups &&
        std::chrono::steady_clock::now() >= *next_followup_at) {
      next_followup_at.reset();
      if (!followup_future.valid()) {
        followup_future = std::async(std::launch::async, [&, transcript]() {
          if (!filler_->enabled()) return FillerClient::progress_ack();
          std::string filler_err;
          return filler_->generate(transcript, FillerStage::FollowUp, spoken_filler,
                                  &handle->cancel, &filler_err);
        });
      }
    }

    if (!hold_llm_fillers && followup_future.valid() &&
        followup_future.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready) {
      ++followups_spoken;
      const std::string followup = followup_future.get();
      followup_future = {};
      if (!followup.empty() && followup != spoken_filler) {
        if (!maybe_speak_filler(followup)) {
          result.error = err.empty() ? "tts failed" : err;
          handle->cancel.store(true);
          break;
        }
      }
    }

    sleep_ms(20);
  }

  arbiter_future.get();

  if (handle->cancel.load()) {
    result.error = "canceled";
    return finish(result);
  }

  {
    std::lock_guard<std::mutex> lk(arb_state.speak_mu);
    arb_state.speak_buf += arb_state.speech_gate.flush();
  }
  if (!drain_and_speak(true)) {
    result.error = err.empty() ? "tts failed" : err;
    emit_briefing_surface();
    return finish(result);
  }
  if (!arb_state.started_answer.load() && !arb_state.full_content.empty()) {
    if (!speak(arb_state.full_content)) {
      result.error = err.empty() ? "tts failed" : err;
      emit_briefing_surface();
      return finish(result);
    }
    arb_state.started_answer.store(true);
  }

  emit_briefing_surface();

  DeviceSession s;
  s.device_id = device_id;
  s.conversation_id = conv;
  s.last_turn_id = result.turn_id;
  s.last_user = result.transcript;
  s.last_spoken = arb_state.full_content;
  s.last_card = carried_card;
  if (!card_follow_kind.empty()) {
    s.last_fast_path_kind = card_follow_kind;
    s.last_fast_path_request = card_follow_request;
  }
  s.updated_at = now_unix();
  keep_session(s);

  if (!arb_state.streamed) {
    result.error =
        arb_state.stream_err.empty() ? "arbiter stream failed" : arb_state.stream_err;
    return finish(result);
  }

  result.ok = arb_state.done_ok;
  if (!arb_state.done_ok) {
    result.error = arb_state.done_err.empty() ? "arbiter done ok=false" : arb_state.done_err;
  }
  return finish(result);
}

std::vector<EnrolledSpeaker> TurnPipeline::enrolled_speakers() const {
  std::vector<EnrolledSpeaker> out;
  if (!sessions_) return out;
  for (const auto& row : sessions_->list_voices()) {
    if (row.embedding.size() != static_cast<std::size_t>(kVoiceDims)) continue;
    auto it = std::find_if(out.begin(), out.end(), [&](const EnrolledSpeaker& speaker) {
      return speaker.person_id == row.person_id;
    });
    if (it == out.end()) {
      out.push_back(EnrolledSpeaker{row.person_id, row.name, {}});
      it = std::prev(out.end());
    }
    Voiceprint print;
    for (int i = 0; i < kVoiceDims; ++i) print.v[i] = row.embedding[static_cast<std::size_t>(i)];
    it->prints.push_back(print);
  }
  return out;
}

SpeakerIdentity TurnPipeline::identify_pcm(const std::uint8_t* pcm, std::size_t bytes,
                                           int sample_rate, int channels) {
  const auto t0 = std::chrono::steady_clock::now();
  const Voiceprint print = embed_pcm(pcm, bytes, sample_rate, channels);
  SpeakerIdentity speaker = identify_speaker(enrolled_speakers(), print);
  speaker.score_ms = static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                          std::chrono::steady_clock::now() - t0)
                                          .count());
  return speaker;
}

namespace {

std::string clean_person_name(std::string_view raw) {
  std::string out;
  for (unsigned char c : raw) {
    if (out.size() >= 40) break;
    if (std::isalnum(c) || c == ' ' || c == '\'' || c == '-' || c == '.') {
      if (c == ' ' && (out.empty() || out.back() == ' ')) continue;
      out.push_back(static_cast<char>(c));
    }
  }
  while (!out.empty() && out.back() == ' ') out.pop_back();
  return out;
}

std::string clean_calendar_title(std::string_view raw) {
  std::string out;
  for (unsigned char c : raw) {
    if (out.size() >= 80) break;
    if (c < 32) continue;
    out.push_back(static_cast<char>(c));
  }
  while (!out.empty() && out.back() == ' ') out.pop_back();
  return out;
}

std::string make_person_id() {
  const std::string hex = make_turn_id();
  std::string id = "p";
  for (unsigned char c : hex) {
    if (!std::isxdigit(c)) continue;
    id.push_back(static_cast<char>(std::tolower(c)));
    if (id.size() == 9) break;
  }
  while (id.size() < 9) id.push_back('0');
  return id;
}

}  // namespace

std::vector<HouseholdPerson> TurnPipeline::list_people() const {
  if (!sessions_) return {};
  return sessions_->list_people();
}

std::optional<HouseholdPerson> TurnPipeline::enroll_person(const std::string& name,
                                                          const std::string& calendar,
                                                          std::string* err) {
  if (!sessions_) {
    if (err) *err = "session store not open";
    return std::nullopt;
  }
  const std::string clean = clean_person_name(name);
  if (clean.empty()) {
    if (err) *err = "missing name";
    return std::nullopt;
  }
  const std::string title = clean_calendar_title(calendar);
  for (int attempt = 0; attempt < 4; ++attempt) {
    auto person = sessions_->enroll_person(make_person_id(), clean, title, err);
    if (person) return person;
  }
  return std::nullopt;
}

bool TurnPipeline::enroll_voice(const std::string& person_id, int phrase,
                                const std::uint8_t* pcm, std::size_t bytes, int sample_rate,
                                std::string* err) {
  if (!sessions_) {
    if (err) *err = "session store not open";
    return false;
  }
  if (phrase < 0 || phrase >= kEnrollmentPhrases) {
    if (err) *err = "phrase out of range";
    return false;
  }
  if (!pcm || bytes == 0 || bytes > 2'000'000) {
    if (err) *err = "audio out of range";
    return false;
  }
  bool known = false;
  for (const auto& person : sessions_->list_people()) {
    if (person.person_id == person_id) known = true;
  }
  if (!known) {
    if (err) *err = "unknown person";
    return false;
  }
  const Voiceprint print = embed_pcm(pcm, bytes, sample_rate, 1);
  double energy = 0;
  for (int i = 0; i < kVoiceDims; ++i) energy += std::fabs(print.v[i]);
  if (energy < 1e-4) {
    if (err) *err = "could not hear a voice";
    return false;
  }
  return sessions_->put_voiceprint(person_id, phrase, print.v, kVoiceDims, err);
}

bool TurnPipeline::remove_person(const std::string& person_id, std::string* err) {
  if (!sessions_) {
    if (err) *err = "session store not open";
    return false;
  }
  return sessions_->remove_person(person_id, err);
}

}  // namespace intercom

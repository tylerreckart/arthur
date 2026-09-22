#include "intercom/fast_path.hpp"
#include "intercom/clock.hpp"
#include "intercom/util.hpp"

#include <iostream>
#include <random>
#include <string_view>
#include <vector>

namespace intercom {
namespace {

bool eq(std::string_view a, std::initializer_list<const char*> opts) {
  for (const char* o : opts) {
    if (a == o) return true;
  }
  return false;
}

std::string pick(std::initializer_list<const char*> phrases) {
  static thread_local std::mt19937 rng{std::random_device{}()};
  static thread_local std::string last;
  std::vector<const char*> opts(phrases);
  if (opts.empty()) return {};
  std::uniform_int_distribution<std::size_t> dist(0, opts.size() - 1);
  std::size_t i = dist(rng);
  if (opts.size() > 1 && opts[i] == last) i = (i + 1) % opts.size();
  last = opts[i];
  return last;
}

int local_hour() { return local_now().tm_hour; }

std::string hello_by_hour() {
  const int h = local_hour();
  if (h < 5 || h >= 22) {
    return pick({"Good evening, sir. What can I do for you?",
                 "Evening, sir. How can I help?"});
  }
  if (h < 12) {
    return pick({"Good morning, sir. What can I do for you?",
                 "Morning, sir. How can I help?",
                 "Good morning, sir. What's on your mind?"});
  }
  if (h < 17) {
    return pick({"Good afternoon, sir. What can I do for you?",
                 "Afternoon, sir. How can I help?"});
  }
  return pick({"Good evening, sir. What can I do for you?",
               "Evening, sir. How can I help?"});
}

bool social_folded(std::string_view t) {
  if (t.empty()) return true;
  return eq(t, {"good morning", "morning", "good afternoon", "afternoon",
                "good evening", "evening", "good night", "goodnight", "goodbye",
                "bye", "see you", "farewell", "hello", "hi", "hey", "ping",
                "hello there", "hi there", "hey there", "how are you",
                "how are you doing", "hows it going", "how is it going",
                "you alright", "you all right", "thanks", "thank you", "cheers",
                "ta", "status", "are you there", "you there", "you around"});
}

bool clock_folded(std::string_view t) {
  return eq(t, {"time", "the time", "what time", "what time is it",
                "whats the time", "what is the time", "current time",
                "date", "the date", "what date", "whats the date",
                "what is the date", "whats today", "what is today",
                "what day is it", "whats the day", "what day"});
}

}  // namespace

bool is_social_turn(std::string_view transcript) {
  return social_folded(fold_phatic(transcript));
}

bool is_clock_query(std::string_view transcript) {
  return clock_folded(fold_phatic(transcript));
}

bool withholds_fillers(std::string_view transcript) {
  return is_social_turn(transcript) || is_clock_query(transcript) ||
         parse_home_intent(transcript).has_value();
}

FastPath::FastPath(bool enabled) : enabled_(enabled) {}

FastPath::FastPath(bool enabled, HomeConfig home, std::shared_ptr<HomeClient> home_client)
    : enabled_(enabled), home_(std::move(home)), home_client_(std::move(home_client)) {}

std::optional<FastPathResult> FastPath::try_handle(const std::string& transcript) const {
  if (!enabled_) return std::nullopt;
  const std::string raw = to_lower(trim(transcript));
  if (raw.empty()) return std::nullopt;

  if (raw.rfind("echo ", 0) == 0) {
    return FastPathResult{trim(transcript.substr(5)), "echo"};
  }

  if (is_clock_query(transcript)) {
    const std::string t = fold_phatic(transcript);
    if (t.find("date") != std::string::npos || t.find("day") != std::string::npos ||
        t.find("today") != std::string::npos) {
      return FastPathResult{spoken_date_now(), "clock"};
    }
    return FastPathResult{spoken_time_now(), "clock"};
  }

  const std::string t = fold_phatic(transcript);
  if (t.empty()) {
    return FastPathResult{hello_by_hour(), "social"};
  }

  if (eq(t, {"good morning", "morning"})) {
    return FastPathResult{pick({"Good morning, sir. What can I do for you?",
                                "Morning, sir. How can I help?",
                                "Good morning, sir. What's on your mind?"}),
                          "social"};
  }
  if (eq(t, {"good afternoon", "afternoon"})) {
    return FastPathResult{pick({"Good afternoon, sir. What can I do for you?",
                                "Afternoon, sir. How can I help?"}),
                          "social"};
  }
  if (eq(t, {"good evening", "evening"})) {
    return FastPathResult{pick({"Good evening, sir. What can I do for you?",
                                "Evening, sir. How can I help?"}),
                          "social"};
  }
  if (eq(t, {"good night", "goodnight"})) {
    return FastPathResult{pick({"Good night, sir.", "Sleep well, sir."}), "social"};
  }
  if (eq(t, {"goodbye", "bye", "see you", "farewell"})) {
    return FastPathResult{pick({"Goodbye, sir.", "Until later, sir."}), "social"};
  }
  if (eq(t, {"hello", "hi", "hey", "ping", "hello there", "hi there", "hey there"})) {
    return FastPathResult{hello_by_hour(), "social"};
  }
  if (eq(t, {"how are you", "how are you doing", "hows it going", "how is it going",
             "you alright", "you all right"})) {
    return FastPathResult{pick({"Very well, sir, thank you. What can I do for you?",
                                "I'm well, sir. How can I help?",
                                "All good, sir. What do you need?"}),
                          "social"};
  }
  if (eq(t, {"thanks", "thank you", "cheers", "ta"})) {
    return FastPathResult{pick({"You're welcome, sir. Anything else?",
                                "Glad to, sir. What else can I do?"}),
                          "social"};
  }
  if (eq(t, {"status", "are you there", "you there", "you around"})) {
    return FastPathResult{pick({"Right here, sir. What do you need?",
                                "I'm here, sir. How can I help?"}),
                          "social"};
  }

  if (auto intent = parse_home_intent(transcript)) {
    if (intent->kind == HomeIntentKind::Timer && intent->timer_seconds <= 0) {
      return FastPathResult{"How long, sir?", home_intent_kind_name(intent->kind)};
    }
    const bool ha_ready = home_client_ && home_client_->configured();
    if (!ha_ready) return std::nullopt;
    std::string err;
    HomeAction action = home_client_->run(*intent, &err);
    if (action.reply.empty()) {
      std::cerr << "intercom home: " << (err.empty() ? "failed" : err) << std::endl;
      return FastPathResult{"I couldn't do that, sir.", home_intent_kind_name(intent->kind)};
    }
    FastPathResult result{std::move(action.reply), home_intent_kind_name(intent->kind)};
    if (action.surface.is_object()) {
      result.surface = std::move(action.surface);
    }
    return result;
  }

  return std::nullopt;
}

}  // namespace intercom

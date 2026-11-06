#pragma once

#include <nlohmann/json.hpp>

#include <cctype>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <optional>
#include <string>
#include <string_view>

namespace intercom {

// What to do with one queued utterance at `now`. Hold keeps the row.
// Drop removes it. Speak plays it.
enum class SpeakAction { Speak, Hold, Drop };

struct SpeakCandidate {
  std::string kind;
  std::int64_t created_at = 0;
  std::int64_t expires_at = 0;
};

struct SpeakPolicy {
  bool quiet_enabled = false;
  int quiet_start_minute = 22 * 60;
  int quiet_end_minute = 7 * 60;
  bool dnd = false;
};

struct BriefingSchedule {
  bool enabled = true;
  int minute = 7 * 60 + 30;
  int grace_minutes = 20;
};

// Doorbell and timer lines go stale quickly. A morning briefing can wait
// out a short delay. Schedule reminders last the longest.
inline int speak_ttl_seconds(std::string_view kind) {
  if (kind == "doorbell") return 180;
  if (kind == "timer") return 600;
  if (kind == "briefing") return 2 * 60 * 60;
  return 6 * 60 * 60;
}

inline int minute_of_day(std::time_t now) {
  std::tm local{};
  localtime_r(&now, &local);
  return local.tm_hour * 60 + local.tm_min;
}

inline int civil_day(std::time_t now) {
  std::tm local{};
  localtime_r(&now, &local);
  return (local.tm_year + 1900) * 10000 + (local.tm_mon + 1) * 100 + local.tm_mday;
}

inline std::string morning_clock_line(std::time_t now) {
  std::tm local{};
  localtime_r(&now, &local);
  const char* half = "in the evening";
  if (local.tm_hour < 12) half = "in the morning";
  else if (local.tm_hour < 17) half = "in the afternoon";
  int hour = local.tm_hour % 12;
  if (hour == 0) hour = 12;
  char buf[64];
  std::snprintf(buf, sizeof(buf), "It's %d:%02d %s.", hour, local.tm_min, half);
  return buf;
}

// Quiet windows may wrap midnight. A zero-length window is never quiet.
inline bool in_quiet_hours(int minute, int start, int end) {
  auto wrap = [](int value) {
    const int day = 24 * 60;
    value %= day;
    if (value < 0) value += day;
    return value;
  };
  minute = wrap(minute);
  start = wrap(start);
  end = wrap(end);
  if (start == end) return false;
  if (start < end) return minute >= start && minute < end;
  return minute >= start || minute < end;
}

inline std::int64_t effective_expiry(const SpeakCandidate& item) {
  if (item.expires_at > 0) return item.expires_at;
  if (item.created_at <= 0) return 0;
  return item.created_at + speak_ttl_seconds(item.kind);
}

inline SpeakAction decide_speak(const SpeakCandidate& item, std::int64_t now,
                                int minute, const SpeakPolicy& policy) {
  const std::int64_t expires = effective_expiry(item);
  if (expires > 0 && now >= expires) return SpeakAction::Drop;
  if (policy.dnd) return SpeakAction::Hold;
  if (policy.quiet_enabled &&
      in_quiet_hours(minute, policy.quiet_start_minute, policy.quiet_end_minute)) {
    return SpeakAction::Hold;
  }
  return SpeakAction::Speak;
}

// True once, inside [minute, minute + grace), when this civil day has not
// been spoken. Do Not Disturb and quiet hours hold the utterance; they do
// not spend the day.
inline bool briefing_due(int minute, int day, int last_day,
                         const BriefingSchedule& schedule,
                         const SpeakPolicy& policy) {
  if (!schedule.enabled || day <= 0 || day == last_day) return false;
  if (schedule.grace_minutes <= 0) return false;
  const int start = schedule.minute;
  const int end = start + schedule.grace_minutes;
  if (minute < start || minute >= end) return false;
  if (policy.dnd) return false;
  if (policy.quiet_enabled &&
      in_quiet_hours(minute, policy.quiet_start_minute, policy.quiet_end_minute)) {
    return false;
  }
  return true;
}

inline std::string morning_briefing_line(std::string_view clock,
                                         std::string_view weather,
                                         std::string_view news,
                                         std::string_view markets) {
  std::string out;
  auto add = [&](std::string_view part) {
    while (!part.empty() && (part.front() == ' ' || part.front() == '\n')) {
      part.remove_prefix(1);
    }
    while (!part.empty() && (part.back() == ' ' || part.back() == '\n')) {
      part.remove_suffix(1);
    }
    if (part.empty()) return;
    if (!out.empty()) out.push_back(' ');
    out.append(part.data(), part.size());
  };
  add(clock);
  add(weather);
  add(news);
  add(markets);
  return out;
}

// First partial after a quarter second of audio, then about every 400 ms,
// and never two transcriptions at once. 24 kHz mono s16.
inline bool partial_due(std::size_t bytes, std::size_t last_bytes, bool in_flight) {
  constexpr std::size_t kMinBytes = 12000;
  constexpr std::size_t kStepBytes = 19200;
  if (in_flight || bytes < kMinBytes) return false;
  if (last_bytes != 0 && bytes < last_bytes + kStepBytes) return false;
  return true;
}

struct HomeAlert {
  std::string kind;
  std::string text;
};

inline std::string timer_label(std::string_view raw) {
  const auto dot = raw.rfind('.');
  if (dot != std::string_view::npos) raw.remove_prefix(dot + 1);
  std::string tidy;
  for (unsigned char c : raw) {
    if (tidy.size() >= 32) break;
    if (std::isalnum(c)) {
      tidy.push_back(static_cast<char>(std::tolower(c)));
    } else if (c == '_' || c == ' ' || c == '-') {
      if (!tidy.empty() && tidy.back() != ' ') tidy.push_back(' ');
    } else {
      break;
    }
  }
  while (!tidy.empty() && tidy.back() == ' ') tidy.pop_back();
  return tidy;
}

inline std::string timer_done_line(std::string_view name) {
  const std::string label = timer_label(name);
  if (label.empty()) return "The timer is done.";
  return "The " + label + " timer is done.";
}

// Doorbell and timer-finished hooks. Explicit kinds, plus the Home Assistant
// state_changed and timer.finished shapes an automation can POST.
inline std::optional<HomeAlert> home_alert_from_json(const nlohmann::json& j) {
  if (!j.is_object()) return std::nullopt;
  std::string tag = j.value("kind", "");
  if (tag.empty()) tag = j.value("event_type", "");
  if (tag.empty()) tag = j.value("type", "");
  if (tag == "home_event") tag.clear();

  const nlohmann::json* data = nullptr;
  if (j.contains("data") && j["data"].is_object()) data = &j["data"];
  std::string entity = j.value("entity_id", "");
  if (entity.empty() && data) entity = data->value("entity_id", "");
  std::string state;
  std::string previous;
  if (data && data->contains("new_state") && (*data)["new_state"].is_object()) {
    state = (*data)["new_state"].value("state", "");
  }
  if (state.empty()) state = j.value("state", "");
  if (data && data->contains("old_state") && (*data)["old_state"].is_object()) {
    previous = (*data)["old_state"].value("state", "");
  }

  auto is_doorbell = [&](std::string_view text) {
    return text.find("doorbell") != std::string_view::npos;
  };
  auto is_timer = [&](std::string_view text) {
    return text.find("timer") != std::string_view::npos;
  };

  if (tag == "state_changed") {
    if (is_doorbell(entity) && (state == "on" || state == "ringing")) {
      return HomeAlert{"doorbell", "Someone is at the door."};
    }
    if (is_timer(entity) && state == "idle" && previous == "active") {
      return HomeAlert{"timer", timer_done_line(entity)};
    }
    return std::nullopt;
  }
  if (tag == "doorbell" || tag == "doorbell_ring") {
    return HomeAlert{"doorbell", "Someone is at the door."};
  }
  if (tag == "timer" || tag == "timer_done" || tag == "timer.finished") {
    std::string name = j.value("name", "");
    if (name.empty()) name = entity;
    return HomeAlert{"timer", timer_done_line(name)};
  }
  return std::nullopt;
}

}  // namespace intercom

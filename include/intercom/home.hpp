#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>

namespace intercom {

struct HomeConfig {
  std::string ha_base_url;
  std::string ha_token;
  int timeout_ms = 800;
  std::string weather_entity = "weather.home";
  std::string timer_entity;
  std::string media_player;
  double volume_step = 0.08;
  std::string alarm_entity;
  // Spoken room name (lowercase) -> Home Assistant entity_id.
  std::unordered_map<std::string, std::string> lights;

  bool configured() const { return !ha_base_url.empty() && !ha_token.empty(); }
};

enum class HomeIntentKind {
  Timer,
  LightOn,
  LightOff,
  LightToggle,
  VolumeUp,
  VolumeDown,
  Weather,
  NextAlarm,
};

struct HomeIntent {
  HomeIntentKind kind = HomeIntentKind::Weather;
  int timer_seconds = 0;  // 0 = duration not given
  std::string room;       // raw room phrase, may be empty
  std::string place;      // weather place ("Tokyo"); empty = home / HA
};

const char* home_intent_kind_name(HomeIntentKind kind);

// Keyword router for hallway commands. Does not call Home Assistant.
std::optional<HomeIntent> parse_home_intent(std::string_view transcript);

// Place after "in" / "for" / "at" on a weather utterance. Empty when the
// tail is a time-of-day or unit, not a city ("in the morning").
std::string extract_weather_place(std::string_view transcript);

std::string spoken_duration(int seconds);
std::string spoken_number(int n);

}  // namespace intercom

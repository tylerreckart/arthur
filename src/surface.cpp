#include "intercom/surface.hpp"
#include "intercom/home.hpp"
#include "intercom/util.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <sstream>
#include <vector>

namespace intercom {
namespace {

int round_nearest(double v) {
  return static_cast<int>(v + (v < 0 ? -0.5 : 0.5));
}

bool is_finite_number(const nlohmann::json& j) {
  if (!j.is_number()) return false;
  if (j.is_number_float()) {
    const double v = j.get<double>();
    return std::isfinite(v);
  }
  return true;
}

double as_number(const nlohmann::json& j, double fallback = 0) {
  if (!is_finite_number(j)) return fallback;
  return j.get<double>();
}

std::string as_string(const nlohmann::json& j) {
  if (j.is_string()) return j.get<std::string>();
  if (j.is_number_integer()) return std::to_string(j.get<std::int64_t>());
  if (j.is_number()) {
    std::ostringstream oss;
    oss << j.get<double>();
    return oss.str();
  }
  return {};
}

const nlohmann::json* attr_object(const nlohmann::json& ha) {
  if (!ha.is_object()) return nullptr;
  if (ha.contains("attributes") && ha["attributes"].is_object()) {
    return &ha["attributes"];
  }
  return nullptr;
}

std::string normalize_condition_key(std::string raw) {
  raw = to_lower(trim(raw));
  for (char& c : raw) {
    if (c == '_' || c == '-') c = ' ';
  }
  std::string out;
  out.reserve(raw.size());
  bool space = false;
  for (char c : raw) {
    if (c == ' ') {
      if (!out.empty()) space = true;
      continue;
    }
    if (space) {
      out.push_back(' ');
      space = false;
    }
    out.push_back(c);
  }
  return out;
}

std::string title_case(std::string_view words) {
  std::string out;
  bool cap = true;
  for (char c : words) {
    if (c == ' ') {
      out.push_back(c);
      cap = true;
      continue;
    }
    out.push_back(static_cast<char>(cap ? std::toupper(static_cast<unsigned char>(c))
                                        : c));
    cap = false;
  }
  return out;
}

bool looks_fahrenheit(std::string_view unit) {
  const std::string u = to_lower(std::string(unit));
  return u.find('f') != std::string::npos && u.find("c") == std::string::npos;
}

bool looks_celsius(std::string_view unit) {
  const std::string u = to_lower(std::string(unit));
  return u.find('c') != std::string::npos;
}

std::string degree_text(int temp, std::string_view unit) {
  if (looks_fahrenheit(unit)) return std::to_string(temp) + "°F";
  if (looks_celsius(unit)) return std::to_string(temp) + "°C";
  return std::to_string(temp) + "°";
}

const nlohmann::json* first_number(const nlohmann::json& obj,
                                   std::initializer_list<const char*> keys) {
  for (const char* k : keys) {
    if (obj.contains(k) && is_finite_number(obj[k])) return &obj[k];
  }
  return nullptr;
}

std::string first_string(const nlohmann::json& obj,
                         std::initializer_list<const char*> keys) {
  for (const char* k : keys) {
    if (obj.contains(k) && obj[k].is_string()) {
      const std::string s = trim(obj[k].get<std::string>());
      if (!s.empty()) return s;
    }
  }
  return {};
}

// Tomohiko Sakamoto — Sunday = 0.
int weekday_sun0(int y, int m, int d) {
  static const int t[] = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4};
  if (m < 3) --y;
  return (y + y / 4 - y / 100 + y / 400 + t[m - 1] + d) % 7;
}

const char* weekday_short(int sun0) {
  static const char* names[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
  if (sun0 < 0 || sun0 > 6) return "";
  return names[sun0];
}

std::string hour_label(int hour24) {
  if (hour24 < 0 || hour24 > 23) return {};
  const int h12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
  const char* ap = hour24 < 12 ? "AM" : "PM";
  char buf[16];
  std::snprintf(buf, sizeof(buf), "%d %s", h12, ap);
  return buf;
}

struct DateBits {
  bool ok = false;
  int year = 0;
  int month = 0;
  int day = 0;
  int hour = 0;
  int minute = 0;
  bool has_time = false;
};

DateBits parse_iso_datetime(std::string_view s) {
  DateBits b;
  // YYYY-MM-DD[ T]HH:MM
  if (s.size() < 10) return b;
  try {
    b.year = std::stoi(std::string(s.substr(0, 4)));
    if (s[4] != '-') return b;
    b.month = std::stoi(std::string(s.substr(5, 2)));
    if (s[7] != '-') return b;
    b.day = std::stoi(std::string(s.substr(8, 2)));
    if (b.month < 1 || b.month > 12 || b.day < 1 || b.day > 31) return b;
    if (s.size() >= 16 && (s[10] == 'T' || s[10] == ' ')) {
      b.hour = std::stoi(std::string(s.substr(11, 2)));
      if (s[13] == ':') b.minute = std::stoi(std::string(s.substr(14, 2)));
      if (b.hour < 0 || b.hour > 23) return b;
      b.has_time = true;
    }
    b.ok = true;
  } catch (...) {
    return {};
  }
  return b;
}

bool looks_daily_item(const nlohmann::json& item, const DateBits& dt) {
  if (item.contains("templow") || item.contains("temperature_low") ||
      item.contains("temp_low") || item.contains("low")) {
    return true;
  }
  if (dt.ok && dt.has_time && dt.hour == 0 && dt.minute == 0) return true;
  if (dt.ok && !dt.has_time) return true;
  return false;
}

nlohmann::json forecast_slot(const nlohmann::json& item, bool daily) {
  nlohmann::json slot = nlohmann::json::object();
  const std::string cond = first_string(item, {"condition", "state"});
  if (!cond.empty()) {
    slot["condition"] = cond;
    slot["condition_label"] = weather_condition_label(cond);
  }
  if (const auto* t = first_number(item, {"temperature", "temp", "high"})) {
    slot["temperature"] = round_nearest(as_number(*t));
  }
  if (const auto* lo =
          first_number(item, {"templow", "temperature_low", "temp_low", "low"})) {
    slot["temperature_low"] = round_nearest(as_number(*lo));
  }
  const std::string dt = first_string(item, {"datetime", "datetime_iso", "time"});
  const DateBits bits = parse_iso_datetime(dt);
  if (daily) {
    if (bits.ok) {
      const char* wd = weekday_short(weekday_sun0(bits.year, bits.month, bits.day));
      if (wd[0]) slot["label"] = wd;
    }
    if (!slot.contains("label")) slot["label"] = "Day";
  } else {
    if (bits.ok && bits.has_time) {
      slot["label"] = hour_label(bits.hour);
    }
    if (!slot.contains("label") || slot["label"].get<std::string>().empty()) {
      slot["label"] = "Later";
    }
  }
  return slot;
}

void append_forecast(const nlohmann::json& arr, std::vector<nlohmann::json>* hours,
                     std::vector<nlohmann::json>* days) {
  if (!arr.is_array()) return;
  for (const auto& item : arr) {
    if (!item.is_object()) continue;
    const std::string dt = first_string(item, {"datetime", "datetime_iso", "time"});
    const DateBits bits = parse_iso_datetime(dt);
    if (looks_daily_item(item, bits)) {
      if (days->size() < 5) days->push_back(forecast_slot(item, true));
    } else {
      if (hours->size() < 8) hours->push_back(forecast_slot(item, false));
    }
  }
}

}  // namespace

const char* surface_kind_name(SurfaceKind kind) {
  switch (kind) {
    case SurfaceKind::Weather:
      return "weather";
    case SurfaceKind::Generic:
      return "generic";
    case SurfaceKind::Article:
      return "article";
    case SurfaceKind::News:
      return "news";
    case SurfaceKind::SourceList:
      return "source_list";
    case SurfaceKind::Markets:
      return "markets";
  }
  return "generic";
}

SurfaceKind surface_kind_from_name(std::string_view name) {
  const std::string k = to_lower(trim(std::string(name)));
  if (k == "weather") return SurfaceKind::Weather;
  if (k == "article") return SurfaceKind::Article;
  if (k == "news") return SurfaceKind::News;
  if (k == "source_list" || k == "sources") return SurfaceKind::SourceList;
  if (k == "markets" || k == "market") return SurfaceKind::Markets;
  return SurfaceKind::Generic;
}

nlohmann::json surface_to_json(const Surface& surface) {
  nlohmann::json j = {
      {"kind", surface_kind_name(surface.kind)},
      {"version", surface.version > 0 ? surface.version : kSurfaceVersion},
      {"title", surface.title},
      {"summary", surface.summary},
      {"payload", surface.payload.is_null() ? nlohmann::json::object() : surface.payload},
  };
  nlohmann::json sources = nlohmann::json::array();
  for (const auto& src : surface.sources) {
    if (src.title.empty() && src.url.empty()) continue;
    nlohmann::json s = nlohmann::json::object();
    if (!src.title.empty()) s["title"] = src.title;
    if (!src.url.empty()) s["url"] = src.url;
    sources.push_back(std::move(s));
  }
  if (!sources.empty()) j["sources"] = std::move(sources);
  return j;
}

Surface surface_from_json(const nlohmann::json& j) {
  Surface s;
  if (!j.is_object()) return s;
  s.kind = surface_kind_from_name(j.value("kind", "generic"));
  s.version = j.value("version", kSurfaceVersion);
  if (s.version <= 0) s.version = kSurfaceVersion;
  s.title = j.value("title", "");
  s.summary = j.value("summary", "");
  if (j.contains("payload") && j["payload"].is_object()) {
    s.payload = j["payload"];
  }
  if (j.contains("sources") && j["sources"].is_array()) {
    for (const auto& src : j["sources"]) {
      if (!src.is_object()) continue;
      SurfaceSource out;
      out.title = src.value("title", "");
      out.url = src.value("url", "");
      if (!out.title.empty() || !out.url.empty()) s.sources.push_back(std::move(out));
    }
  }
  return s;
}

nlohmann::json surface_event_body(std::string_view turn_id, const nlohmann::json& surface) {
  return {{"turn_id", std::string(turn_id)}, {"surface", surface}};
}

nlohmann::json surface_ws_event(std::string_view turn_id, const nlohmann::json& surface) {
  nlohmann::json j = surface_event_body(turn_id, surface);
  j["type"] = "surface";
  return j;
}

std::string weather_condition_label(std::string_view raw) {
  const std::string key = normalize_condition_key(std::string(raw));
  if (key.empty() || key == "unknown" || key == "unavailable") return {};
  if (key == "partlycloudy" || key == "partly cloudy") return "Partly cloudy";
  if (key == "clear night" || key == "clearnight") return "Clear night";
  if (key == "lightning rainy" || key == "lightningrainy") return "Thunderstorms";
  if (key == "snowy rainy" || key == "snowyrainy") return "Wintry mix";
  if (key == "windy variant" || key == "windyvariant") return "Windy";
  if (key == "exceptional") return "Unusual weather";
  return title_case(key);
}

WeatherExtract weather_from_ha_state(const nlohmann::json& ha, std::string_view title) {
  WeatherExtract out;
  if (!ha.is_object()) return out;

  const std::string cond = ha.value("state", "");
  const std::string cond_label = weather_condition_label(cond);
  const nlohmann::json* attrs = attr_object(ha);

  std::string unit;
  double temp = 0;
  bool has_temp = false;
  double feels = 0;
  bool has_feels = false;
  int humidity = 0;
  bool has_humidity = false;
  double wind = 0;
  bool has_wind = false;
  std::string wind_unit;
  std::string friendly;
  std::string attribution;
  std::vector<nlohmann::json> hours;
  std::vector<nlohmann::json> days;

  if (attrs) {
    if (const auto* t = first_number(*attrs, {"temperature", "temp"})) {
      temp = as_number(*t);
      has_temp = true;
    }
    if (const auto* f =
            first_number(*attrs, {"apparent_temperature", "feels_like", "apparent_temp"})) {
      feels = as_number(*f);
      has_feels = true;
    }
    unit = first_string(*attrs, {"temperature_unit", "unit_of_measurement"});
    if (attrs->contains("humidity") && is_finite_number((*attrs)["humidity"])) {
      humidity = round_nearest(as_number((*attrs)["humidity"]));
      has_humidity = humidity >= 0 && humidity <= 100;
    }
    if (const auto* w = first_number(*attrs, {"wind_speed", "wind"})) {
      wind = as_number(*w);
      has_wind = true;
    }
    wind_unit = first_string(*attrs, {"wind_speed_unit", "wind_unit"});
    friendly = first_string(*attrs, {"friendly_name"});
    attribution = first_string(*attrs, {"attribution"});
    if (attrs->contains("forecast")) append_forecast((*attrs)["forecast"], &hours, &days);
    if (attrs->contains("forecast_hourly")) {
      append_forecast((*attrs)["forecast_hourly"], &hours, &days);
    }
    if (attrs->contains("forecast_daily")) {
      append_forecast((*attrs)["forecast_daily"], &hours, &days);
    }
  }

  if (cond_label.empty() && !has_temp) return out;

  const int temp_i = has_temp ? round_nearest(temp) : 0;
  const int feels_i = has_feels ? round_nearest(feels) : 0;

  std::string spoken;
  if (!cond_label.empty() && has_temp) {
    spoken = cond_label + ", " + spoken_number(temp_i) + " degrees, sir.";
  } else if (has_temp) {
    spoken = "It's " + spoken_number(temp_i) + " degrees, sir.";
  } else {
    spoken = cond_label + ", sir.";
  }

  std::string summary;
  if (!cond_label.empty() && has_temp) {
    summary = cond_label + ", " + degree_text(temp_i, unit);
  } else if (has_temp) {
    summary = degree_text(temp_i, unit);
  } else {
    summary = cond_label;
  }

  nlohmann::json payload = nlohmann::json::object();
  if (!cond.empty()) payload["condition"] = cond;
  if (!cond_label.empty()) payload["condition_label"] = cond_label;
  if (has_temp) {
    payload["temperature"] = temp_i;
    if (!unit.empty()) payload["temperature_unit"] = unit;
  }
  if (has_feels) payload["feels_like"] = feels_i;
  if (has_humidity) payload["humidity"] = humidity;
  if (has_wind) {
    payload["wind_speed"] = wind;
    if (!wind_unit.empty()) payload["wind_unit"] = wind_unit;
  }
  if (!hours.empty()) payload["hours"] = hours;
  if (!days.empty()) payload["days"] = days;

  Surface surface;
  surface.kind = SurfaceKind::Weather;
  surface.version = kSurfaceVersion;
  surface.title = friendly.empty() ? std::string(title) : friendly;
  surface.summary = summary;
  surface.payload = std::move(payload);
  if (!attribution.empty()) {
    surface.sources.push_back(SurfaceSource{attribution, {}});
  }

  out.spoken = std::move(spoken);
  out.surface = std::move(surface);
  out.ok = true;
  return out;
}

WeatherExtract weather_from_ha_state(std::string_view raw_json, std::string_view title) {
  try {
    return weather_from_ha_state(nlohmann::json::parse(std::string(raw_json)), title);
  } catch (...) {
    return {};
  }
}

}  // namespace intercom

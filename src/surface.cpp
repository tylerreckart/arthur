#include "intercom/surface.hpp"
#include "intercom/home.hpp"
#include "intercom/util.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
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

std::string weather_condition_from_wmo(int code, bool is_day) {
  if (code == 0 || code == 1) return is_day ? "sunny" : "clear-night";
  if (code == 2) return "partlycloudy";
  if (code == 3) return "cloudy";
  if (code == 45 || code == 48) return "fog";
  if (code == 51 || code == 53 || code == 55 || code == 56 || code == 57) return "rainy";
  if (code == 61 || code == 63 || code == 65 || code == 66 || code == 67) return "rainy";
  if (code == 71 || code == 73 || code == 75 || code == 77) return "snowy";
  if (code == 80 || code == 81 || code == 82) return "rainy";
  if (code == 85 || code == 86) return "snowy";
  if (code == 95) return "lightning";
  if (code == 96 || code == 99) return "lightning-rainy";
  return "cloudy";
}

namespace {

WeatherExtract make_weather_card(std::string title, std::string spoken_place,
                                 std::string condition, std::string condition_label,
                                 bool has_temp, int temp, std::string unit,
                                 bool has_feels, int feels, bool has_humidity, int humidity,
                                 bool has_wind, double wind, std::string wind_unit,
                                 std::vector<nlohmann::json> hours,
                                 std::vector<nlohmann::json> days,
                                 std::vector<SurfaceSource> sources) {
  WeatherExtract out;
  if (condition_label.empty() && !has_temp) return out;

  std::string spoken;
  const std::string place_tail =
      spoken_place.empty() ? std::string() : (" in " + spoken_place);
  if (!condition_label.empty() && has_temp) {
    spoken = condition_label + place_tail + ", " + spoken_number(temp) + " degrees, sir.";
  } else if (has_temp) {
    spoken = "It's " + spoken_number(temp) + " degrees" + place_tail + ", sir.";
  } else if (!spoken_place.empty()) {
    spoken = condition_label + " in " + spoken_place + ", sir.";
  } else {
    spoken = condition_label + ", sir.";
  }

  std::string summary;
  if (!condition_label.empty() && has_temp) {
    summary = condition_label + ", " + degree_text(temp, unit);
  } else if (has_temp) {
    summary = degree_text(temp, unit);
  } else {
    summary = condition_label;
  }

  nlohmann::json payload = nlohmann::json::object();
  if (!condition.empty()) payload["condition"] = condition;
  if (!condition_label.empty()) payload["condition_label"] = condition_label;
  if (has_temp) {
    payload["temperature"] = temp;
    if (!unit.empty()) payload["temperature_unit"] = unit;
  }
  if (has_feels) payload["feels_like"] = feels;
  if (has_humidity) payload["humidity"] = humidity;
  if (has_wind) {
    payload["wind_speed"] = wind;
    if (!wind_unit.empty()) payload["wind_unit"] = wind_unit;
  }
  if (!hours.empty()) payload["hours"] = std::move(hours);
  if (!days.empty()) payload["days"] = std::move(days);

  Surface surface;
  surface.kind = SurfaceKind::Weather;
  surface.version = kSurfaceVersion;
  surface.title = title.empty() ? "Weather" : std::move(title);
  surface.summary = summary;
  surface.payload = std::move(payload);
  surface.sources = std::move(sources);

  out.spoken = std::move(spoken);
  out.surface = std::move(surface);
  out.ok = true;
  return out;
}

const nlohmann::json* json_obj(const nlohmann::json& j, const char* key) {
  if (j.contains(key) && j[key].is_object()) return &j[key];
  return nullptr;
}

}  // namespace

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

  std::vector<SurfaceSource> sources;
  if (!attribution.empty()) sources.push_back(SurfaceSource{attribution, {}});
  return make_weather_card(friendly.empty() ? std::string(title) : friendly, {}, cond,
                           cond_label, has_temp, has_temp ? round_nearest(temp) : 0, unit,
                           has_feels, has_feels ? round_nearest(feels) : 0, has_humidity,
                           humidity, has_wind, wind, wind_unit, std::move(hours),
                           std::move(days), std::move(sources));
}

WeatherExtract weather_from_ha_state(std::string_view raw_json, std::string_view title) {
  try {
    return weather_from_ha_state(nlohmann::json::parse(std::string(raw_json)), title);
  } catch (...) {
    return {};
  }
}

WeatherExtract weather_from_open_meteo(const nlohmann::json& geocode,
                                       const nlohmann::json& forecast) {
  WeatherExtract out;
  if (!forecast.is_object()) return out;

  std::string title = "Weather";
  std::string spoken_place;
  if (geocode.is_object() && geocode.contains("results") && geocode["results"].is_array() &&
      !geocode["results"].empty() && geocode["results"][0].is_object()) {
    const auto& loc = geocode["results"][0];
    const std::string name = loc.value("name", "");
    const std::string country = loc.value("country", "");
    if (!name.empty() && !country.empty() && to_lower(name) != to_lower(country)) {
      title = name + ", " + country;
    } else if (!name.empty()) {
      title = name;
    } else if (!country.empty()) {
      title = country;
    }
    spoken_place = name.empty() ? title : name;
  }

  const nlohmann::json* current = json_obj(forecast, "current");
  const nlohmann::json* current_units = json_obj(forecast, "current_units");
  const nlohmann::json* hourly = json_obj(forecast, "hourly");
  const nlohmann::json* daily = json_obj(forecast, "daily");

  std::string cond;
  std::string cond_label;
  bool has_temp = false;
  int temp = 0;
  std::string unit;
  bool has_feels = false;
  int feels = 0;
  bool has_humidity = false;
  int humidity = 0;
  bool has_wind = false;
  double wind = 0;
  std::string wind_unit;
  std::string current_time;

  if (current) {
    current_time = current->value("time", "");
    const bool is_day = current->value("is_day", 1) != 0;
    if (current->contains("weather_code") && (*current)["weather_code"].is_number()) {
      cond = weather_condition_from_wmo((*current)["weather_code"].get<int>(), is_day);
      cond_label = weather_condition_label(cond);
    }
    if (const auto* t = first_number(*current, {"temperature_2m", "temperature"})) {
      temp = round_nearest(as_number(*t));
      has_temp = true;
    }
    if (const auto* f = first_number(*current, {"apparent_temperature", "feels_like"})) {
      feels = round_nearest(as_number(*f));
      has_feels = true;
    }
    if (current->contains("relative_humidity_2m") &&
        is_finite_number((*current)["relative_humidity_2m"])) {
      humidity = round_nearest(as_number((*current)["relative_humidity_2m"]));
      has_humidity = humidity >= 0 && humidity <= 100;
    }
    if (const auto* w = first_number(*current, {"wind_speed_10m", "wind_speed"})) {
      wind = as_number(*w);
      has_wind = true;
    }
  }
  if (current_units) {
    unit = first_string(*current_units, {"temperature_2m", "temperature"});
    wind_unit = first_string(*current_units, {"wind_speed_10m", "wind_speed"});
  }

  std::vector<nlohmann::json> hours;
  if (hourly && hourly->contains("time") && (*hourly)["time"].is_array()) {
    const auto& times = (*hourly)["time"];
    const nlohmann::json* temps =
        hourly->contains("temperature_2m") && (*hourly)["temperature_2m"].is_array()
            ? &(*hourly)["temperature_2m"]
            : nullptr;
    const nlohmann::json* codes =
        hourly->contains("weather_code") && (*hourly)["weather_code"].is_array()
            ? &(*hourly)["weather_code"]
            : nullptr;
    for (std::size_t i = 0; i < times.size() && hours.size() < 8; ++i) {
      if (!times[i].is_string()) continue;
      const std::string ts = times[i].get<std::string>();
      if (!current_time.empty() && ts <= current_time) continue;
      nlohmann::json item = {{"datetime", ts}};
      if (temps && i < temps->size() && is_finite_number((*temps)[i])) {
        item["temperature"] = (*temps)[i];
      }
      if (codes && i < codes->size() && (*codes)[i].is_number()) {
        item["condition"] = weather_condition_from_wmo((*codes)[i].get<int>(), true);
      }
      hours.push_back(forecast_slot(item, false));
    }
  }

  std::vector<nlohmann::json> days;
  if (daily && daily->contains("time") && (*daily)["time"].is_array()) {
    const auto& times = (*daily)["time"];
    const nlohmann::json* highs =
        daily->contains("temperature_2m_max") && (*daily)["temperature_2m_max"].is_array()
            ? &(*daily)["temperature_2m_max"]
            : nullptr;
    const nlohmann::json* lows =
        daily->contains("temperature_2m_min") && (*daily)["temperature_2m_min"].is_array()
            ? &(*daily)["temperature_2m_min"]
            : nullptr;
    const nlohmann::json* codes =
        daily->contains("weather_code") && (*daily)["weather_code"].is_array()
            ? &(*daily)["weather_code"]
            : nullptr;
    for (std::size_t i = 0; i < times.size() && days.size() < 5; ++i) {
      if (!times[i].is_string()) continue;
      nlohmann::json item = {{"datetime", times[i].get<std::string>()}};
      if (highs && i < highs->size() && is_finite_number((*highs)[i])) {
        item["temperature"] = (*highs)[i];
      }
      if (lows && i < lows->size() && is_finite_number((*lows)[i])) {
        item["templow"] = (*lows)[i];
      }
      if (codes && i < codes->size() && (*codes)[i].is_number()) {
        item["condition"] = weather_condition_from_wmo((*codes)[i].get<int>(), true);
      }
      days.push_back(forecast_slot(item, true));
    }
  }

  std::vector<SurfaceSource> sources;
  sources.push_back(SurfaceSource{"Open-Meteo", "https://open-meteo.com/"});

  return make_weather_card(std::move(title), std::move(spoken_place), cond, cond_label,
                           has_temp, temp, unit, has_feels, feels, has_humidity, humidity,
                           has_wind, wind, wind_unit, std::move(hours), std::move(days),
                           std::move(sources));
}

WeatherExtract weather_from_open_meteo(std::string_view geocode_json,
                                       std::string_view forecast_json) {
  try {
    return weather_from_open_meteo(nlohmann::json::parse(std::string(geocode_json)),
                                   nlohmann::json::parse(std::string(forecast_json)));
  } catch (...) {
    return {};
  }
}

namespace {

void replace_all(std::string* s, std::string_view from, std::string_view to) {
  if (!s || from.empty()) return;
  std::size_t pos = 0;
  while ((pos = s->find(from, pos)) != std::string::npos) {
    s->replace(pos, from.size(), to);
    pos += to.size();
  }
}

std::string decode_entities(std::string s) {
  replace_all(&s, "&amp;", "&");
  replace_all(&s, "&lt;", "<");
  replace_all(&s, "&gt;", ">");
  replace_all(&s, "&quot;", "\"");
  replace_all(&s, "&apos;", "'");
  replace_all(&s, "&#39;", "'");
  replace_all(&s, "&#x27;", "'");
  replace_all(&s, "&nbsp;", " ");
  return s;
}

std::string strip_html(std::string_view raw) {
  std::string out;
  out.reserve(raw.size());
  bool in_tag = false;
  for (char c : raw) {
    if (c == '<') {
      in_tag = true;
      continue;
    }
    if (c == '>') {
      in_tag = false;
      continue;
    }
    if (!in_tag) out.push_back(c);
  }
  return trim(decode_entities(out));
}

std::string xml_text(std::string_view block, std::string_view tag) {
  const std::string open = "<" + std::string(tag);
  auto start = block.find(open);
  if (start == std::string_view::npos) return {};
  start = block.find('>', start);
  if (start == std::string_view::npos) return {};
  ++start;
  const std::string close = "</" + std::string(tag) + ">";
  auto end = block.find(close, start);
  if (end == std::string_view::npos) return {};
  std::string inner(block.substr(start, end - start));
  constexpr std::string_view cdata = "<![CDATA[";
  if (inner.compare(0, cdata.size(), cdata) == 0) {
    auto cend = inner.find("]]>");
    if (cend != std::string::npos) {
      inner = inner.substr(cdata.size(), cend - cdata.size());
    }
  }
  return trim(decode_entities(strip_html(inner)));
}

std::string xml_attr(std::string_view block, std::string_view tag, std::string_view attr) {
  const std::string open = "<" + std::string(tag);
  auto start = block.find(open);
  if (start == std::string_view::npos) return {};
  auto gt = block.find('>', start);
  if (gt == std::string_view::npos) return {};
  const std::string head(block.substr(start, gt - start));
  const std::string needle = std::string(attr) + "=\"";
  auto a = head.find(needle);
  if (a == std::string::npos) return {};
  a += needle.size();
  auto b = head.find('"', a);
  if (b == std::string::npos) return {};
  return decode_entities(std::string(head.substr(a, b - a)));
}

std::string split_source_from_title(std::string* title) {
  if (!title) return {};
  auto pos = title->rfind(" - ");
  if (pos == std::string::npos || pos == 0) return {};
  std::string source = trim(title->substr(pos + 3));
  if (source.empty() || source.size() > 48) return {};
  *title = trim(title->substr(0, pos));
  return source;
}

std::string spoken_instrument_name(std::string_view symbol, std::string_view name) {
  if (symbol == "^GSPC") return "The S and P";
  if (symbol == "^DJI") return "The Dow";
  if (symbol == "^IXIC") return "The Nasdaq";
  if (symbol == "BTC-USD") return "Bitcoin";
  if (symbol == "ETH-USD") return "Ethereum";
  std::string n(name);
  for (const char* tail : {" Inc.", " Inc", " Corporation", " Corp.", " Corp",
                           " Company", " Co.", " Holdings", " Ltd.", " Ltd"}) {
    if (n.size() > std::strlen(tail) &&
        n.compare(n.size() - std::strlen(tail), std::strlen(tail), tail) == 0) {
      n = trim(n.substr(0, n.size() - std::strlen(tail)));
      break;
    }
  }
  if (!n.empty()) return n;
  return std::string(symbol);
}

const nlohmann::json* quote_result_array(const nlohmann::json& quote) {
  if (quote.is_array()) return &quote;
  if (!quote.is_object()) return nullptr;
  if (quote.contains("quoteResponse") && quote["quoteResponse"].is_object() &&
      quote["quoteResponse"].contains("result") &&
      quote["quoteResponse"]["result"].is_array()) {
    return &quote["quoteResponse"]["result"];
  }
  if (quote.contains("result") && quote["result"].is_array()) return &quote["result"];
  return nullptr;
}

}  // namespace

NewsExtract news_from_rss(std::string_view rss_xml, std::string_view topic, int max_items) {
  NewsExtract out;
  if (rss_xml.empty()) return out;
  if (max_items <= 0) max_items = 8;

  nlohmann::json items = nlohmann::json::array();
  std::size_t pos = 0;
  const std::string body(rss_xml);
  while (static_cast<int>(items.size()) < max_items) {
    auto item_start = body.find("<item", pos);
    std::string close_tag = "</item>";
    if (item_start == std::string::npos) {
      item_start = body.find("<entry", pos);
      close_tag = "</entry>";
    }
    if (item_start == std::string::npos) break;
    auto item_end = body.find(close_tag, item_start);
    if (item_end == std::string::npos) break;
    item_end += close_tag.size();
    const std::string item = body.substr(item_start, item_end - item_start);
    pos = item_end;

    std::string title = xml_text(item, "title");
    if (title.empty()) continue;
    std::string link = xml_text(item, "link");
    if (link.empty()) link = xml_attr(item, "link", "href");
    std::string source = xml_text(item, "source");
    if (source.empty()) source = xml_text(item, "author");
    if (source.empty()) source = split_source_from_title(&title);
    if (title.empty()) continue;

    std::string summary = xml_text(item, "description");
    if (summary.empty()) summary = xml_text(item, "summary");
    std::string published = xml_text(item, "pubDate");
    if (published.empty()) published = xml_text(item, "published");
    if (published.empty()) published = xml_text(item, "updated");

    nlohmann::json row = {{"title", title}};
    if (!summary.empty()) row["summary"] = summary;
    if (!source.empty()) row["source"] = source;
    if (!link.empty()) row["url"] = link;
    if (!published.empty()) row["published_at"] = published;
    items.push_back(std::move(row));
  }
  if (items.empty()) return out;

  const std::string topic_s = trim(std::string(topic));
  Surface surface;
  surface.kind = SurfaceKind::News;
  surface.version = kSurfaceVersion;
  if (!topic_s.empty()) {
    surface.title = title_case(topic_s);
    surface.summary = "Latest on " + surface.title;
  } else {
    surface.title = "Top stories";
    surface.summary = std::to_string(items.size()) +
                      (items.size() == 1 ? " headline" : " headlines");
  }
  nlohmann::json payload = {{"items", items}};
  if (!topic_s.empty()) payload["topic"] = topic_s;
  surface.payload = std::move(payload);
  surface.sources.push_back(SurfaceSource{"Google News", "https://news.google.com/"});

  if (!topic_s.empty()) {
    out.spoken = "Here's the latest on " + topic_s + ", sir.";
  } else {
    out.spoken = "Here are the top headlines, sir.";
  }
  out.surface = std::move(surface);
  out.ok = true;
  return out;
}

MarketsExtract markets_from_yahoo_quote(const nlohmann::json& quote) {
  MarketsExtract out;
  const nlohmann::json* rows = quote_result_array(quote);
  if (!rows || rows->empty()) return out;

  nlohmann::json instruments = nlohmann::json::array();
  int up = 0;
  int down = 0;
  std::string lead_name;
  double lead_price = 0;
  bool lead_has_price = false;

  for (const auto& row : *rows) {
    if (!row.is_object()) continue;
    const std::string symbol = first_string(row, {"symbol"});
    if (symbol.empty()) continue;
    const std::string name =
        first_string(row, {"shortName", "displayName", "longName", "name"});
    nlohmann::json inst = {{"symbol", symbol}};
    if (!name.empty()) inst["name"] = name;

    if (const auto* p =
            first_number(row, {"regularMarketPrice", "price", "regularMarketPreviousClose"})) {
      inst["price"] = as_number(*p);
      if (!lead_has_price) {
        lead_has_price = true;
        lead_price = as_number(*p);
        lead_name = spoken_instrument_name(symbol, name);
      }
    }
    if (const auto* c = first_number(row, {"regularMarketChange", "change"})) {
      const double ch = as_number(*c);
      inst["change"] = ch;
      if (ch > 0) ++up;
      else if (ch < 0) ++down;
    }
    if (const auto* pct =
            first_number(row, {"regularMarketChangePercent", "changePercent", "change_pct"})) {
      inst["change_pct"] = as_number(*pct);
    }
    const std::string currency = first_string(row, {"currency"});
    if (!currency.empty()) inst["currency"] = currency;
    if (row.contains("regularMarketTime") && row["regularMarketTime"].is_number_integer()) {
      inst["as_of"] = row["regularMarketTime"].get<std::int64_t>();
    } else {
      const std::string as_of = first_string(row, {"as_of", "regularMarketTime"});
      if (!as_of.empty()) inst["as_of"] = as_of;
    }
    instruments.push_back(std::move(inst));
  }
  if (instruments.empty()) return out;

  std::string market_summary;
  if (up && down) {
    market_summary = "Markets are mixed";
  } else if (up) {
    market_summary = "Markets are up";
  } else if (down) {
    market_summary = "Markets are down";
  } else {
    market_summary = "Here's the market";
  }

  Surface surface;
  surface.kind = SurfaceKind::Markets;
  surface.version = kSurfaceVersion;
  if (instruments.size() == 1) {
    const auto& first = instruments[0];
    surface.title = first.value("symbol", "Markets");
    if (first.contains("name")) {
      surface.title = first.value("name", surface.title);
    }
    if (first.contains("price")) {
      char buf[64];
      std::snprintf(buf, sizeof(buf), "%.2f", first["price"].get<double>());
      std::string change_s;
      if (first.contains("change_pct")) {
        const double pct = first["change_pct"].get<double>();
        char pbuf[32];
        std::snprintf(pbuf, sizeof(pbuf), "%+.2f%%", pct);
        change_s = pbuf;
      }
      surface.summary = std::string(buf) + (change_s.empty() ? "" : ("  " + change_s));
    } else {
      surface.summary = market_summary;
    }
  } else {
    surface.title = "Markets";
    surface.summary = market_summary;
  }

  nlohmann::json payload = {{"instruments", instruments}};
  payload["market_summary"] = market_summary;
  surface.payload = std::move(payload);
  surface.sources.push_back(
      SurfaceSource{"Yahoo Finance", "https://finance.yahoo.com/"});

  if (instruments.size() == 1 && lead_has_price) {
    out.spoken = lead_name + " is at " + spoken_number(round_nearest(lead_price)) + ", sir.";
  } else {
    out.spoken = market_summary + ", sir.";
  }
  out.surface = std::move(surface);
  out.ok = true;
  return out;
}

MarketsExtract markets_from_yahoo_quote(std::string_view raw_json) {
  try {
    return markets_from_yahoo_quote(nlohmann::json::parse(std::string(raw_json)));
  } catch (...) {
    return {};
  }
}

}  // namespace intercom


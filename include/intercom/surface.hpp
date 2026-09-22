#pragma once

#include <nlohmann/json.hpp>

#include <string>
#include <string_view>
#include <vector>

namespace intercom {

inline constexpr int kSurfaceVersion = 1;

// Closed kinds for this slice. The desk maps anything else to generic.
enum class SurfaceKind {
  Weather,
  Generic,
  Article,
  News,
  SourceList,
  Markets,
};

const char* surface_kind_name(SurfaceKind kind);
// Unknown names become Generic (never a hard failure).
SurfaceKind surface_kind_from_name(std::string_view name);

struct SurfaceSource {
  std::string title;
  std::string url;
};

struct Surface {
  SurfaceKind kind = SurfaceKind::Generic;
  int version = kSurfaceVersion;
  std::string title;
  std::string summary;
  nlohmann::json payload = nlohmann::json::object();
  std::vector<SurfaceSource> sources;
};

nlohmann::json surface_to_json(const Surface& surface);
Surface surface_from_json(const nlohmann::json& j);

// WS body (without the outer type). Pipeline wraps this as event("surface", …).
nlohmann::json surface_event_body(std::string_view turn_id, const nlohmann::json& surface);
// Full `{type:surface, turn_id, surface}` text frame.
nlohmann::json surface_ws_event(std::string_view turn_id, const nlohmann::json& surface);

// Spoken line + versioned desk card. Weather, news, and markets share this.
struct WeatherExtract {
  std::string spoken;
  Surface surface;
  bool ok = false;
};

using NewsExtract = WeatherExtract;
using MarketsExtract = WeatherExtract;

WeatherExtract weather_from_ha_state(const nlohmann::json& ha,
                                     std::string_view title = "Home");
WeatherExtract weather_from_ha_state(std::string_view raw_json,
                                     std::string_view title = "Home");

// Same weather v1 card from Open-Meteo geocoding + forecast JSON (no HA).
WeatherExtract weather_from_open_meteo(const nlohmann::json& geocode,
                                       const nlohmann::json& forecast);
WeatherExtract weather_from_open_meteo(std::string_view geocode_json,
                                       std::string_view forecast_json);

// WMO weather interpretation code → HA-ish condition token ("partlycloudy").
std::string weather_condition_from_wmo(int code, bool is_day = true);

// Title-case / alias HA condition tokens ("partlycloudy" → "Partly cloudy").
std::string weather_condition_label(std::string_view raw);

// News v1 card from an RSS 2.0 / Atom-ish feed body (Google News or any
// configured feed). Topic is optional ("news about X").
NewsExtract news_from_rss(std::string_view rss_xml, std::string_view topic = {},
                          int max_items = 8);

// Markets v1 card from Yahoo v7 `quoteResponse` JSON (or a raw result array).
MarketsExtract markets_from_yahoo_quote(const nlohmann::json& quote);
MarketsExtract markets_from_yahoo_quote(std::string_view raw_json);

}  // namespace intercom

#include "intercom/surface.hpp"

#include <iostream>
#include <string>
#include <string_view>

namespace {

int g_fails = 0;

void expect(bool cond, const char* expr, const char* file, int line) {
  if (!cond) {
    std::cerr << "FAIL " << file << ":" << line << " " << expr << "\n";
    ++g_fails;
  }
}

#define CHECK(cond) expect((cond), #cond, __FILE__, __LINE__)

bool contains(const std::string& s, const char* needle) {
  return s.find(needle) != std::string::npos;
}

}  // namespace

int main() {
  CHECK(std::string(intercom::surface_kind_name(intercom::SurfaceKind::Weather)) ==
        "weather");
  CHECK(intercom::surface_kind_from_name("weather") == intercom::SurfaceKind::Weather);
  CHECK(intercom::surface_kind_from_name("article") == intercom::SurfaceKind::Article);
  CHECK(intercom::surface_kind_from_name("news") == intercom::SurfaceKind::News);
  CHECK(intercom::surface_kind_from_name("source_list") == intercom::SurfaceKind::SourceList);
  CHECK(intercom::surface_kind_from_name("markets") == intercom::SurfaceKind::Markets);
  CHECK(intercom::surface_kind_from_name("unknown-kind") == intercom::SurfaceKind::Generic);
  CHECK(intercom::surface_kind_from_name("") == intercom::SurfaceKind::Generic);

  CHECK(intercom::weather_condition_label("partlycloudy") == "Partly cloudy");
  CHECK(intercom::weather_condition_label("clear-night") == "Clear night");
  CHECK(intercom::weather_condition_label("lightning-rainy") == "Thunderstorms");
  CHECK(intercom::weather_condition_label("sunny") == "Sunny");

  const char* ha = R"({
    "entity_id": "weather.home",
    "state": "partlycloudy",
    "attributes": {
      "temperature": 18.4,
      "apparent_temperature": 16.2,
      "temperature_unit": "°C",
      "humidity": 61,
      "wind_speed": 12.3,
      "wind_speed_unit": "km/h",
      "friendly_name": "Home",
      "attribution": "Weather forecast from met.no",
      "forecast": [
        {
          "datetime": "2026-09-22T15:00:00",
          "condition": "cloudy",
          "temperature": 17
        },
        {
          "datetime": "2026-09-23T00:00:00",
          "condition": "rainy",
          "temperature": 19,
          "templow": 12
        }
      ]
    }
  })";

  auto extracted = intercom::weather_from_ha_state(std::string_view{ha});
  CHECK(extracted.ok);
  CHECK(contains(extracted.spoken, "sir"));
  CHECK(contains(extracted.spoken, "eighteen"));
  CHECK(contains(extracted.spoken, "Partly cloudy"));
  CHECK(!contains(extracted.spoken, "61"));
  CHECK(!contains(extracted.spoken, "forecast"));

  const auto wire = intercom::surface_to_json(extracted.surface);
  CHECK(wire.value("kind", "") == "weather");
  CHECK(wire.value("version", 0) == 1);
  CHECK(wire.value("title", "") == "Home");
  CHECK(contains(wire.value("summary", ""), "18"));
  CHECK(contains(wire.value("summary", ""), "Partly cloudy"));
  CHECK(wire.contains("payload"));
  const auto& p = wire["payload"];
  CHECK(p.value("condition", "") == "partlycloudy");
  CHECK(p.value("condition_label", "") == "Partly cloudy");
  CHECK(p.value("temperature", 0) == 18);
  CHECK(p.value("feels_like", 0) == 16);
  CHECK(p.value("humidity", 0) == 61);
  CHECK(p.contains("hours"));
  CHECK(p.contains("days"));
  if (p.contains("hours") && p["hours"].is_array() && !p["hours"].empty()) {
    CHECK(p["hours"][0].value("label", "") == "3 PM");
    CHECK(p["hours"][0].value("temperature", 0) == 17);
  }
  if (p.contains("days") && p["days"].is_array() && !p["days"].empty()) {
    CHECK(p["days"][0].value("temperature_low", 0) == 12);
  }
  CHECK(wire.contains("sources"));
  if (wire.contains("sources") && wire["sources"].is_array() && !wire["sources"].empty()) {
    CHECK(contains(wire["sources"][0].value("title", ""), "met.no"));
  }

  const auto body = intercom::surface_event_body("turn-abc", wire);
  CHECK(body.value("turn_id", "") == "turn-abc");
  CHECK(body.contains("surface"));
  CHECK(body["surface"].value("kind", "") == "weather");
  CHECK(!body.contains("type"));

  const auto frame = intercom::surface_ws_event("turn-abc", wire);
  CHECK(frame.value("type", "") == "surface");
  CHECK(frame.value("turn_id", "") == "turn-abc");
  CHECK(frame["surface"].value("kind", "") == "weather");
  CHECK(frame["surface"].contains("payload"));

  auto back = intercom::surface_from_json(wire);
  CHECK(back.kind == intercom::SurfaceKind::Weather);
  CHECK(back.version == 1);
  CHECK(back.title == "Home");

  auto unknown = intercom::surface_from_json(nlohmann::json{
      {"kind", "portfolio"},
      {"version", 2},
      {"title", "Holdings"},
      {"summary", "Up today"},
      {"payload", {{"aapl", 1}}},
  });
  CHECK(unknown.kind == intercom::SurfaceKind::Generic);
  CHECK(unknown.title == "Holdings");
  CHECK(unknown.summary == "Up today");

  auto empty = intercom::weather_from_ha_state(std::string_view{R"({"state":"unknown"})"});
  CHECK(!empty.ok);

  auto temp_only = intercom::weather_from_ha_state(std::string_view{R"({
    "state": "unknown",
    "attributes": {"temperature": 4}
  })"});
  CHECK(temp_only.ok);
  CHECK(contains(temp_only.spoken, "four"));

  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_surface ok\n";
  return 0;
}

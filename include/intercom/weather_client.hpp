#pragma once

#include "intercom/surface.hpp"

#include <string>

namespace intercom {

struct WeatherClientConfig {
  std::string geocode_base = "https://geocoding-api.open-meteo.com";
  std::string forecast_base = "https://api.open-meteo.com";
  int timeout_ms = 2500;
};

// Place forecast for desk weather cards. Default implementation is Open-Meteo
// (no API key). Tests inject a fake or point the bases at a mock HTTP server.
class WeatherClient {
 public:
  WeatherClient() = default;
  explicit WeatherClient(WeatherClientConfig cfg);
  virtual ~WeatherClient() = default;

  virtual WeatherExtract lookup_place(const std::string& place, std::string* err) const;

 private:
  WeatherClientConfig cfg_;
};

}  // namespace intercom

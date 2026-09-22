#include "intercom/weather_client.hpp"
#include "intercom/util.hpp"

#include <httplib.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <memory>
#include <sstream>

namespace intercom {
namespace {

std::string url_query(std::string_view s) {
  std::string out;
  out.reserve(s.size() * 3);
  for (unsigned char c : s) {
    if (std::isalnum(c) || c == '-' || c == '.' || c == '_' || c == '~') {
      out.push_back(static_cast<char>(c));
    } else if (c == ' ') {
      out += "%20";
    } else {
      char buf[8];
      std::snprintf(buf, sizeof(buf), "%%%02X", c);
      out += buf;
    }
  }
  return out;
}

void apply_timeouts(httplib::Client* cli, int timeout_ms) {
  if (!cli) return;
  const int sec = std::max(1, timeout_ms / 1000);
  const int usec = (timeout_ms % 1000) * 1000;
  cli->set_connection_timeout(sec, usec);
  cli->set_read_timeout(sec, usec);
  cli->set_write_timeout(sec, usec);
}

std::unique_ptr<httplib::Client> make_client(const ParsedHttpUrl& u, std::string* err) {
#ifndef CPPHTTPLIB_OPENSSL_SUPPORT
  if (u.https) {
    if (err) *err = "weather: HTTPS requires OpenSSL";
    return nullptr;
  }
#endif
  std::ostringstream url;
  url << (u.https ? "https://" : "http://") << u.host;
  if ((u.https && u.port != 443) || (!u.https && u.port != 80)) {
    url << ':' << u.port;
  }
  return std::make_unique<httplib::Client>(url.str());
}

std::string http_get(const std::string& base, const std::string& path, int timeout_ms,
                     std::string* err) {
  auto parsed = parse_http_url(base);
  if (!parsed) {
    if (err) *err = "invalid weather URL";
    return {};
  }
  auto cli = make_client(*parsed, err);
  if (!cli) return {};
  apply_timeouts(cli.get(), timeout_ms);
  const std::string prefix = parsed->path;
  const std::string full = (prefix.empty() || prefix == "/" ? std::string() : prefix) + path;
  auto res = cli->Get(full.c_str());
  if (!res) {
    if (err) *err = "weather provider unreachable";
    return {};
  }
  if (res->status != 200) {
    if (err) *err = "weather HTTP " + std::to_string(res->status);
    return {};
  }
  return res->body;
}

}  // namespace

WeatherClient::WeatherClient(WeatherClientConfig cfg) : cfg_(std::move(cfg)) {}

WeatherExtract WeatherClient::lookup_place(const std::string& place, std::string* err) const {
  const std::string q = trim(place);
  if (q.empty()) {
    if (err) *err = "empty place";
    return {};
  }

  std::ostringstream geo_path;
  geo_path << "/v1/search?name=" << url_query(q) << "&count=1&language=en&format=json";
  const std::string geo_raw = http_get(cfg_.geocode_base, geo_path.str(), cfg_.timeout_ms, err);
  if (geo_raw.empty()) return {};

  nlohmann::json geo;
  try {
    geo = nlohmann::json::parse(geo_raw);
  } catch (const std::exception& e) {
    if (err) *err = std::string("geocode parse: ") + e.what();
    return {};
  }
  if (!geo.contains("results") || !geo["results"].is_array() || geo["results"].empty() ||
      !geo["results"][0].is_object()) {
    if (err) *err = "place not found";
    return {};
  }
  const auto& loc = geo["results"][0];
  if (!loc.contains("latitude") || !loc.contains("longitude") || !loc["latitude"].is_number() ||
      !loc["longitude"].is_number()) {
    if (err) *err = "geocode missing coordinates";
    return {};
  }
  const double lat = loc["latitude"].get<double>();
  const double lon = loc["longitude"].get<double>();

  std::ostringstream fc_path;
  fc_path << "/v1/forecast?latitude=" << lat << "&longitude=" << lon
          << "&current=temperature_2m,apparent_temperature,relative_humidity_2m,"
             "weather_code,wind_speed_10m,is_day"
          << "&hourly=temperature_2m,weather_code"
          << "&daily=weather_code,temperature_2m_max,temperature_2m_min"
          << "&timezone=auto&forecast_days=5";
  const std::string fc_raw = http_get(cfg_.forecast_base, fc_path.str(), cfg_.timeout_ms, err);
  if (fc_raw.empty()) return {};

  nlohmann::json forecast;
  try {
    forecast = nlohmann::json::parse(fc_raw);
  } catch (const std::exception& e) {
    if (err) *err = std::string("forecast parse: ") + e.what();
    return {};
  }

  auto extracted = weather_from_open_meteo(geo, forecast);
  if (!extracted.ok) {
    if (err) *err = "forecast missing current conditions";
    return {};
  }
  return extracted;
}

}  // namespace intercom

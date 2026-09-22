#include "intercom/home_client.hpp"
#include "intercom/surface.hpp"
#include "intercom/util.hpp"

#include <httplib.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <cstdio>
#include <memory>
#include <sstream>

namespace intercom {
namespace {

std::unique_ptr<httplib::Client> make_ha_client(const HomeConfig& cfg, std::string* err) {
  auto parsed = parse_http_url(cfg.ha_base_url);
  if (!parsed) {
    if (err) *err = "invalid home.ha_base_url";
    return nullptr;
  }
  auto cli = std::make_unique<httplib::Client>(parsed->host, parsed->port);
  const int sec = std::max(1, cfg.timeout_ms / 1000);
  const int usec = (cfg.timeout_ms % 1000) * 1000;
  cli->set_connection_timeout(sec, usec);
  cli->set_read_timeout(sec, usec);
  cli->set_write_timeout(sec, usec);
  return cli;
}

httplib::Headers ha_headers(const HomeConfig& cfg) {
  return {
      {"Authorization", "Bearer " + cfg.ha_token},
      {"Content-Type", "application/json"},
  };
}

std::string title_room(std::string room) {
  if (room.empty()) return "the lights";
  if (room == "living room" || room == "lounge") return "the living room lights";
  if (room == "kitchen") return "the kitchen lights";
  return "the " + room + " lights";
}

std::string ha_path(const ParsedHttpUrl& u, const std::string& suffix) {
  std::string prefix = u.path;
  while (!prefix.empty() && prefix.back() == '/') prefix.pop_back();
  if (prefix == "/") prefix.clear();
  return prefix + suffix;
}

}  // namespace

HomeClient::HomeClient(HomeConfig cfg) : cfg_(std::move(cfg)) {}

bool HomeClient::configured() const { return cfg_.configured(); }

std::string HomeClient::resolve_light(const std::string& room, std::string* err) const {
  if (!room.empty()) {
    auto it = cfg_.lights.find(room);
    if (it != cfg_.lights.end()) return it->second;
    // "living room" vs "livingroom"
    std::string compact = room;
    compact.erase(std::remove(compact.begin(), compact.end(), ' '), compact.end());
    for (const auto& kv : cfg_.lights) {
      std::string key = kv.first;
      key.erase(std::remove(key.begin(), key.end(), ' '), key.end());
      if (key == compact) return kv.second;
    }
  }
  auto it = cfg_.lights.find("default");
  if (it != cfg_.lights.end()) return it->second;
  if (cfg_.lights.size() == 1) return cfg_.lights.begin()->second;
  if (err) *err = "no light mapping for " + (room.empty() ? std::string("default") : room);
  return {};
}

bool HomeClient::call_service(const std::string& domain, const std::string& service,
                              const std::string& entity_id, const std::string& extra_json,
                              std::string* err) const {
  auto parsed = parse_http_url(cfg_.ha_base_url);
  auto cli = make_ha_client(cfg_, err);
  if (!cli || !parsed) return false;

  nlohmann::json body = nlohmann::json::object();
  if (!entity_id.empty()) body["entity_id"] = entity_id;
  if (!extra_json.empty()) {
    try {
      auto extra = nlohmann::json::parse(extra_json);
      if (extra.is_object()) {
        for (auto it = extra.begin(); it != extra.end(); ++it) {
          body[it.key()] = it.value();
        }
      }
    } catch (...) {
      if (err) *err = "invalid home service payload";
      return false;
    }
  }

  const std::string path =
      ha_path(*parsed, "/api/services/" + domain + "/" + service);
  auto res = cli->Post(path.c_str(), ha_headers(cfg_), body.dump(), "application/json");
  if (!res) {
    if (err) *err = "home assistant unreachable";
    return false;
  }
  if (res->status < 200 || res->status >= 300) {
    if (err) {
      *err = "home assistant HTTP " + std::to_string(res->status) + ": " + res->body;
    }
    return false;
  }
  return true;
}

std::string HomeClient::get_state_json(const std::string& entity_id, std::string* err) const {
  auto parsed = parse_http_url(cfg_.ha_base_url);
  auto cli = make_ha_client(cfg_, err);
  if (!cli || !parsed) return {};
  const std::string path = ha_path(*parsed, "/api/states/" + entity_id);
  auto res = cli->Get(path.c_str(), ha_headers(cfg_));
  if (!res) {
    if (err) *err = "home assistant unreachable";
    return {};
  }
  if (res->status != 200) {
    if (err) {
      *err = "home assistant HTTP " + std::to_string(res->status) + ": " + res->body;
    }
    return {};
  }
  return res->body;
}

HomeAction HomeClient::run(const HomeIntent& intent, std::string* err) const {
  HomeAction out;
  if (!configured()) {
    if (err) *err = "home assistant is not configured";
    return out;
  }

  switch (intent.kind) {
    case HomeIntentKind::Timer: {
      if (intent.timer_seconds <= 0) {
        out.reply = "How long, sir?";
        return out;
      }
      if (cfg_.timer_entity.empty()) {
        if (err) *err = "home.timer_entity is empty";
        return out;
      }
      const int s = intent.timer_seconds;
      char dur[16];
      std::snprintf(dur, sizeof(dur), "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60);
      const std::string extra = std::string("{\"duration\":\"") + dur + "\"}";
      if (!call_service("timer", "start", cfg_.timer_entity, extra, err)) {
        return out;
      }
      out.reply = spoken_duration(intent.timer_seconds) + ", sir.";
      return out;
    }
    case HomeIntentKind::LightOn:
    case HomeIntentKind::LightOff:
    case HomeIntentKind::LightToggle: {
      std::string entity = resolve_light(intent.room, err);
      if (entity.empty()) return out;
      const char* service = "toggle";
      if (intent.kind == HomeIntentKind::LightOn) service = "turn_on";
      if (intent.kind == HomeIntentKind::LightOff) service = "turn_off";
      if (!call_service("light", service, entity, {}, err)) return out;
      const std::string who = title_room(intent.room);
      if (intent.kind == HomeIntentKind::LightOff) {
        out.reply = "I've switched off " + who + ", sir.";
      } else if (intent.kind == HomeIntentKind::LightOn) {
        out.reply = "I've switched on " + who + ", sir.";
      } else {
        out.reply = "I've toggled " + who + ", sir.";
      }
      return out;
    }
    case HomeIntentKind::VolumeUp:
    case HomeIntentKind::VolumeDown: {
      if (cfg_.media_player.empty()) {
        if (err) *err = "home.media_player is empty";
        return out;
      }
      const char* service =
          intent.kind == HomeIntentKind::VolumeUp ? "volume_up" : "volume_down";
      if (!call_service("media_player", service, cfg_.media_player, {}, err)) return out;
      out.reply = intent.kind == HomeIntentKind::VolumeUp ? "Louder, sir." : "Quieter, sir.";
      return out;
    }
    case HomeIntentKind::Weather: {
      if (cfg_.weather_entity.empty()) {
        if (err) *err = "home.weather_entity is empty";
        return out;
      }
      const std::string raw = get_state_json(cfg_.weather_entity, err);
      if (raw.empty()) return out;
      try {
        auto extracted = weather_from_ha_state(nlohmann::json::parse(raw));
        if (!extracted.ok) {
          if (err) *err = "weather parse: no condition or temperature";
          return out;
        }
        out.reply = std::move(extracted.spoken);
        out.surface = surface_to_json(extracted.surface);
        return out;
      } catch (const std::exception& e) {
        if (err) *err = std::string("weather parse: ") + e.what();
        return out;
      }
    }
    case HomeIntentKind::NextAlarm: {
      if (cfg_.alarm_entity.empty()) {
        if (err) *err = "home.alarm_entity is empty";
        return out;
      }
      const std::string raw = get_state_json(cfg_.alarm_entity, err);
      if (raw.empty()) return out;
      try {
        auto j = nlohmann::json::parse(raw);
        const std::string state = j.value("state", "");
        if (state.empty() || state == "unknown" || state == "unavailable") {
          out.reply = "I don't see a next alarm, sir.";
          return out;
        }
        out.reply = "The next alarm is " + state + ", sir.";
        return out;
      } catch (const std::exception& e) {
        if (err) *err = std::string("alarm parse: ") + e.what();
        return out;
      }
    }
  }
  if (err) *err = "unhandled home intent";
  return out;
}

}  // namespace intercom

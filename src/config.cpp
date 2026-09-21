#include "intercom/config.hpp"
#include "intercom/util.hpp"

#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <cstdlib>

#include <nlohmann/json.hpp>

namespace intercom {
namespace {

namespace fs = std::filesystem;

std::string require_string(const nlohmann::json& j, const char* key, const std::string& def = {}) {
  if (!j.contains(key) || j[key].is_null()) return def;
  if (!j[key].is_string()) {
    throw std::runtime_error(std::string("config field '") + key + "' must be a string");
  }
  return j[key].get<std::string>();
}

int require_int(const nlohmann::json& j, const char* key, int def) {
  if (!j.contains(key) || j[key].is_null()) return def;
  if (!j[key].is_number_integer()) {
    throw std::runtime_error(std::string("config field '") + key + "' must be an integer");
  }
  return j[key].get<int>();
}

double require_number(const nlohmann::json& j, const char* key, double def) {
  if (!j.contains(key) || j[key].is_null()) return def;
  if (!j[key].is_number()) {
    throw std::runtime_error(std::string("config field '") + key + "' must be a number");
  }
  return j[key].get<double>();
}

bool require_bool(const nlohmann::json& j, const char* key, bool def) {
  if (!j.contains(key) || j[key].is_null()) return def;
  if (!j[key].is_boolean()) {
    throw std::runtime_error(std::string("config field '") + key + "' must be a boolean");
  }
  return j[key].get<bool>();
}

std::string load_agent_def_json(const fs::path& config_path,
                                const std::string& agent,
                                const std::string& agent_def_path) {
  if (agent == "index") return {};

  fs::path path = agent_def_path.empty()
                      ? config_path.parent_path() / "arthur.agent.json"
                      : fs::path(agent_def_path);
  if (!path.is_absolute()) {
    path = config_path.parent_path() / path;
  }
  path = fs::path(expand_home(path.string()));

  std::ifstream in(path);
  if (!in) {
    throw std::runtime_error("failed to open agent_def: " + path.string());
  }
  nlohmann::json def;
  in >> def;
  if (!def.is_object()) {
    throw std::runtime_error("agent_def root must be a JSON object");
  }
  if (!def.contains("id") || !def["id"].is_string()) {
    throw std::runtime_error("agent_def must contain string field 'id'");
  }
  if (def["id"].get<std::string>() != agent) {
    throw std::runtime_error("agent_def id '" + def["id"].get<std::string>() +
                             "' does not match config agent '" + agent + "'");
  }
  return def.dump();
}

}  // namespace

Config Config::load(const std::string& path) {
  const fs::path config_path = fs::path(path).lexically_normal();
  std::ifstream in(config_path);
  if (!in) {
    throw std::runtime_error("failed to open config: " + path);
  }
  nlohmann::json j;
  in >> j;
  if (!j.is_object()) {
    throw std::runtime_error("config root must be a JSON object");
  }

  Config c;
  c.listen_host = require_string(j, "listen_host", c.listen_host);
  c.listen_port = require_int(j, "listen_port", c.listen_port);
  c.device_token = require_string(j, "device_token", "");
  c.arbiter_base_url = require_string(j, "arbiter_base_url", c.arbiter_base_url);
  c.arbiter_token = require_string(j, "arbiter_token", "");
  c.agent = require_string(j, "agent", c.agent);
  c.agent_def_path = require_string(j, "agent_def", c.agent_def_path);
  c.agent_def_json =
      load_agent_def_json(config_path, c.agent, c.agent_def_path);
  c.session_db = expand_home(require_string(j, "session_db", c.session_db));
  c.sample_rate = require_int(j, "sample_rate", c.sample_rate);
  c.channels = require_int(j, "channels", c.channels);
  c.fast_path = require_bool(j, "fast_path", c.fast_path);
  c.ws_listen_port = require_int(j, "ws_listen_port", c.ws_listen_port);
  c.early_flush_words = require_int(j, "early_flush_words", c.early_flush_words);
  c.warm_prefix = require_bool(j, "warm_prefix", c.warm_prefix);

  if (j.contains("home") && j["home"].is_object()) {
    const auto& h = j["home"];
    c.home.ha_base_url = require_string(h, "ha_base_url", c.home.ha_base_url);
    c.home.ha_token = require_string(h, "ha_token", c.home.ha_token);
    c.home.timeout_ms = require_int(h, "timeout_ms", c.home.timeout_ms);
    c.home.weather_entity =
        require_string(h, "weather_entity", c.home.weather_entity);
    c.home.timer_entity = require_string(h, "timer_entity", c.home.timer_entity);
    c.home.media_player = require_string(h, "media_player", c.home.media_player);
    c.home.volume_step = require_number(h, "volume_step", c.home.volume_step);
    c.home.alarm_entity = require_string(h, "alarm_entity", c.home.alarm_entity);
    if (h.contains("lights") && h["lights"].is_object()) {
      for (auto it = h["lights"].begin(); it != h["lights"].end(); ++it) {
        if (it.value().is_string()) {
          c.home.lights[to_lower(it.key())] = it.value().get<std::string>();
        }
      }
    }
  }
  if (c.home.ha_token.empty()) {
    if (const char* tok = std::getenv("HOMEASSISTANT_TOKEN")) {
      c.home.ha_token = tok;
    } else if (const char* tok = std::getenv("SUPERVISOR_TOKEN")) {
      c.home.ha_token = tok;
    }
  }

  if (j.contains("devices") && j["devices"].is_object()) {
    for (auto it = j["devices"].begin(); it != j["devices"].end(); ++it) {
      if (it.value().is_string()) {
        c.devices[it.key()] = it.value().get<std::string>();
      }
    }
  }

  if (j.contains("whisper") && j["whisper"].is_object()) {
    const auto& w = j["whisper"];
    c.whisper.binary = require_string(w, "binary", c.whisper.binary);
    c.whisper.model = expand_home(require_string(w, "model", c.whisper.model));
    c.whisper.timeout_seconds = require_int(w, "timeout_seconds", c.whisper.timeout_seconds);
    c.whisper.language = require_string(w, "language", c.whisper.language);
    c.whisper.use_server = require_bool(w, "use_server", c.whisper.use_server);
    c.whisper.server_binary = expand_home(require_string(w, "server_binary", c.whisper.server_binary));
    c.whisper.server_url = require_string(w, "server_url", c.whisper.server_url);
    c.whisper.server_port = require_int(w, "server_port", c.whisper.server_port);
  }

  if (j.contains("kokoro") && j["kokoro"].is_object()) {
    const auto& k = j["kokoro"];
    c.kokoro.binary = require_string(k, "binary", c.kokoro.binary);
    c.kokoro.voice = require_string(k, "voice", c.kokoro.voice);
    c.kokoro.speed = require_number(k, "speed", c.kokoro.speed);
    c.kokoro.model = expand_home(require_string(k, "model", c.kokoro.model));
    c.kokoro.voices = expand_home(require_string(k, "voices", c.kokoro.voices));
    c.kokoro.use_server = require_bool(k, "use_server", c.kokoro.use_server);
    c.kokoro.server_script =
        expand_home(require_string(k, "server_script", c.kokoro.server_script));
    c.kokoro.server_url = require_string(k, "server_url", c.kokoro.server_url);
    c.kokoro.server_port = require_int(k, "server_port", c.kokoro.server_port);
    if (k.contains("dsp") && k["dsp"].is_object()) {
      const auto& d = k["dsp"];
      c.kokoro.dsp.enabled = require_bool(d, "enabled", c.kokoro.dsp.enabled);
      c.kokoro.dsp.highpass_hz =
          require_number(d, "highpass_hz", c.kokoro.dsp.highpass_hz);
      c.kokoro.dsp.presence_hz =
          require_number(d, "presence_hz", c.kokoro.dsp.presence_hz);
      c.kokoro.dsp.presence_db =
          require_number(d, "presence_db", c.kokoro.dsp.presence_db);
      c.kokoro.dsp.presence_q =
          require_number(d, "presence_q", c.kokoro.dsp.presence_q);
      c.kokoro.dsp.compressor_threshold_db = require_number(
          d, "compressor_threshold_db", c.kokoro.dsp.compressor_threshold_db);
      c.kokoro.dsp.compressor_ratio =
          require_number(d, "compressor_ratio", c.kokoro.dsp.compressor_ratio);
      c.kokoro.dsp.compressor_attack_ms = require_number(
          d, "compressor_attack_ms", c.kokoro.dsp.compressor_attack_ms);
      c.kokoro.dsp.compressor_release_ms = require_number(
          d, "compressor_release_ms", c.kokoro.dsp.compressor_release_ms);
      c.kokoro.dsp.makeup_db =
          require_number(d, "makeup_db", c.kokoro.dsp.makeup_db);
      c.kokoro.dsp.limiter_db =
          require_number(d, "limiter_db", c.kokoro.dsp.limiter_db);
    }
  }

  if (j.contains("filler") && j["filler"].is_object()) {
    const auto& f = j["filler"];
    c.filler.enabled = require_bool(f, "enabled", c.filler.enabled);
    c.filler.api_base_url = require_string(f, "api_base_url", c.filler.api_base_url);
    c.filler.api_key = require_string(f, "api_key", c.filler.api_key);
    c.filler.model = require_string(f, "model", c.filler.model);
    c.filler.instant_ack_ms = require_int(f, "instant_ack_ms", c.filler.instant_ack_ms);
    c.filler.tool_ack_ms = require_int(f, "tool_ack_ms", c.filler.tool_ack_ms);
    c.filler.min_silence_ms = require_int(f, "min_silence_ms", c.filler.min_silence_ms);
    c.filler.followup_silence_ms =
        require_int(f, "followup_silence_ms", c.filler.followup_silence_ms);
    c.filler.max_followups = require_int(f, "max_followups", c.filler.max_followups);
    c.filler.timeout_ms = require_int(f, "timeout_ms", c.filler.timeout_ms);
    c.filler.max_tokens = require_int(f, "max_tokens", c.filler.max_tokens);
    c.filler.temperature = require_number(f, "temperature", c.filler.temperature);
  }

  if (c.filler.api_key.empty()) {
    if (const char* key = std::getenv("OPENROUTER_API_KEY")) {
      c.filler.api_key = key;
    } else if (const char* key = std::getenv("FILLER_API_KEY")) {
      c.filler.api_key = key;
    }
  }

  if (j.contains("speakback") && j["speakback"].is_object()) {
    const auto& s = j["speakback"];
    c.speakback.enabled = require_bool(s, "enabled", c.speakback.enabled);
    c.speakback.reconnect_ms =
        require_int(s, "reconnect_ms", c.speakback.reconnect_ms);
    c.speakback.max_queued = require_int(s, "max_queued", c.speakback.max_queued);
    c.speakback.speak_failures =
        require_bool(s, "speak_failures", c.speakback.speak_failures);
  }

  if (c.device_token.empty() && c.devices.empty()) {
    throw std::runtime_error("config needs device_token or devices map");
  }
  if (c.arbiter_token.empty()) {
    throw std::runtime_error("config arbiter_token is required");
  }
  return c;
}

bool Config::authorize_device(const std::string& device_id,
                              const std::string& bearer_token) const {
  if (bearer_token.empty()) return false;
  auto it = devices.find(device_id);
  if (it != devices.end()) {
    return it->second == bearer_token;
  }
  if (!device_token.empty()) {
    return device_token == bearer_token;
  }
  return false;
}

}  // namespace intercom

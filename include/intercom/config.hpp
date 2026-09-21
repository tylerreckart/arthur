#pragma once

#include "intercom/home.hpp"

#include <string>
#include <unordered_map>

namespace intercom {

struct WhisperConfig {
  std::string binary = "whisper-cli";
  std::string model;
  int timeout_seconds = 120;
  std::string language = "en";
  bool use_server = true;
  std::string server_binary;
  std::string server_url;
  int server_port = 8092;
};

struct SpeechDspConfig {
  bool enabled = true;
  double highpass_hz = 70.0;
  double presence_hz = 2600.0;
  double presence_db = 1.5;
  double presence_q = 0.8;
  double compressor_threshold_db = -16.0;
  double compressor_ratio = 2.2;
  double compressor_attack_ms = 8.0;
  double compressor_release_ms = 90.0;
  double makeup_db = 1.0;
  double limiter_db = -1.0;
};

struct KokoroConfig {
  std::string binary = "kokoro-tts";
  std::string voice = "bm_lewis";
  double speed = 0.96;
  std::string model;
  std::string voices;
  bool use_server = true;
  std::string server_script;
  std::string server_url;
  int server_port = 8091;
  SpeechDspConfig dsp;
};

struct FillerConfig {
  bool enabled = true;
  // OpenAI-compatible chat completions endpoint (OpenRouter or DeepSeek direct).
  std::string api_base_url = "https://openrouter.ai/api/v1";
  std::string api_key;
  std::string model = "deepseek/deepseek-v4-flash";
  // Speak a cached local backchannel this many ms after the turn starts
  // (0 = disabled). High enough that a fast Arbiter reply skips filler.
  int instant_ack_ms = 700;
  // After a tool_call, speak a cached tool ack this many ms later if no
  // local ack has been spoken yet (0 = immediately).
  int tool_ack_ms = 250;
  // Earliest ms to speak an LLM phrase when instant ack is off.
  int min_silence_ms = 1100;
  int followup_silence_ms = 8000;
  int max_followups = 0;
  int timeout_ms = 2500;
  int max_tokens = 16;
  double temperature = 0.6;
};

struct SpeakbackConfig {
  bool enabled = true;
  // After the SSE stream drops, wait this long before reconnect + runs poll.
  int reconnect_ms = 2000;
  // Cap of in-memory utterances queued per offline/busy device.
  int max_queued = 4;
  // Speak a short courtesy line on run.failed (never the raw error_message).
  bool speak_failures = false;
};

struct Config {
  std::string listen_host = "127.0.0.1";
  int listen_port = 8090;
  // WebSocket duplex (0 = disabled). PCM up while PTT is held; PCM down on the
  // same connection. HTTP PTT on listen_port is unchanged.
  int ws_listen_port = 8093;
  // Start Kokoro after this many streaming words, even without .?! (0 = off).
  int early_flush_words = 7;
  std::string device_token;
  std::unordered_map<std::string, std::string> devices;  // device_id -> token
  std::string arbiter_base_url = "http://127.0.0.1:8080";
  std::string arbiter_token;
  std::string agent = "arthur";
  // Inline agent constitution snapshotted into Arbiter on conversation create.
  // Empty → {config_dir}/arthur.agent.json when agent != "index".
  std::string agent_def_path;
  std::string agent_def_json;
  std::string session_db = "~/.intercom/sessions.db";
  int sample_rate = 16000;
  int channels = 1;
  bool fast_path = true;
  bool warm_prefix = true;
  HomeConfig home;
  WhisperConfig whisper;
  KokoroConfig kokoro;
  FillerConfig filler;
  SpeakbackConfig speakback;

  static Config load(const std::string& path);

  bool authorize_device(const std::string& device_id,
                        const std::string& bearer_token) const;
};

}  // namespace intercom

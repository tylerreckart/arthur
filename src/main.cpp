#include "intercom/arbiter_client.hpp"
#include "intercom/config.hpp"
#include "intercom/device_hub.hpp"
#include "intercom/filler_client.hpp"
#include "intercom/http_server.hpp"
#include "intercom/session_store.hpp"
#include "intercom/speakback.hpp"
#include "intercom/stt_whisper.hpp"
#include "intercom/tts_kokoro.hpp"
#include "intercom/turn_pipeline.hpp"

#include <iostream>
#include <memory>
#include <string>

namespace {

void usage(const char* argv0) {
  std::cerr << "Usage: " << argv0 << " --config <path>\n"
            << "  Intercom — local voice bridge for Arbiter (whisper.cpp + Kokoro).\n";
}

}  // namespace

int main(int argc, char** argv) {
  std::string config_path;
  bool test_filler = false;
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--config" && i + 1 < argc) {
      config_path = argv[++i];
    } else if (arg == "--test-filler") {
      test_filler = true;
    } else if (arg == "-h" || arg == "--help") {
      usage(argv[0]);
      return 0;
    } else {
      std::cerr << "unknown argument: " << arg << "\n";
      usage(argv[0]);
      return 2;
    }
  }
  if (config_path.empty()) {
    usage(argv[0]);
    return 2;
  }

  intercom::Config config;
  try {
    config = intercom::Config::load(config_path);
  } catch (const std::exception& e) {
    std::cerr << "config error: " << e.what() << "\n";
    return 1;
  }

  if (test_filler) {
    intercom::FillerClient client(config.filler);
    std::string err;
    const std::string phrase = client.generate(
        "what is the weather in London", intercom::FillerStage::Initial, "", nullptr, &err);
    if (!err.empty()) std::cerr << "filler error: " << err << "\n";
    std::cout << phrase << "\n";
    return phrase.empty() ? 1 : 0;
  }

  auto sessions = std::make_shared<intercom::SessionStore>(config.session_db);
  std::string err;
  if (!sessions->open(&err)) {
    std::cerr << "session store: " << err << "\n";
    return 1;
  }

  auto stt = std::make_shared<intercom::WhisperStt>(config.whisper);
  auto tts = std::make_shared<intercom::KokoroTts>(config.kokoro, config.sample_rate);
  tts->warmup();
  auto arbiter = std::make_shared<intercom::ArbiterClient>(
      config.arbiter_base_url, config.arbiter_token, config.agent,
      config.agent_def_json);
  std::shared_ptr<intercom::FillerClient> filler;
  if (config.filler.enabled) {
    filler = std::make_shared<intercom::FillerClient>(config.filler);
    if (filler->enabled()) {
      std::cout << "intercom filler enabled (model=" << config.filler.model << ")"
                << std::endl;
    } else {
      std::cerr << "intercom filler configured but no api_key — silence fillers disabled"
                << std::endl;
    }
  }
  auto pipeline = std::make_shared<intercom::TurnPipeline>(
      config, stt, tts, arbiter, sessions, filler);
  pipeline->warm_prefix();

  auto hub = std::make_shared<intercom::DeviceHub>(tts, config.speakback.max_queued);
  intercom::Speakback speakback(config.speakback, config.agent, arbiter, sessions, hub);
  speakback.start();

  intercom::ServerDeps deps;
  deps.config = config;
  deps.pipeline = pipeline;
  deps.hub = hub;
  intercom::run_http_server(std::move(deps));
  speakback.stop();
  return 0;
}

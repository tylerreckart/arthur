#include "intercom/http_server.hpp"
#include "intercom/pcm_stream.hpp"
#include "intercom/util.hpp"
#include "intercom/ws.hpp"

#include <httplib.h>
#include <nlohmann/json.hpp>

#include <atomic>
#include <chrono>
#include <csignal>
#include <iostream>
#include <memory>
#include <mutex>
#include <string_view>
#include <thread>
#include <vector>

namespace intercom {
namespace {

httplib::Server* g_svr = nullptr;
WsServer* g_ws = nullptr;

void on_stop_signal(int) {
  if (g_svr) g_svr->stop();
  if (g_ws) g_ws->stop();
}

std::string bearer_token(const httplib::Request& req) {
  const auto auth = req.get_header_value("Authorization");
  constexpr std::string_view prefix = "Bearer ";
  if (auth.size() > prefix.size() &&
      auth.compare(0, prefix.size(), prefix) == 0) {
    return auth.substr(prefix.size());
  }
  return {};
}

int parse_sample_rate(const httplib::Request& req, int fallback) {
  if (req.has_header("X-Sample-Rate")) {
    try {
      return std::stoi(req.get_header_value("X-Sample-Rate"));
    } catch (...) {
    }
  }
  const auto ct = req.get_header_value("Content-Type");
  const auto pos = ct.find("rate=");
  if (pos != std::string::npos) {
    try {
      return std::stoi(ct.substr(pos + 5));
    } catch (...) {
    }
  }
  return fallback;
}

std::string header_safe(std::string s) {
  for (char& c : s) {
    if (c == '\r' || c == '\n' || c == '\0') c = ' ';
  }
  if (s.size() > 240) s.resize(240);
  return s;
}

struct StreamingTurnState {
  PcmStream stream;
  TurnResult result;
  std::mutex result_mu;
  std::atomic<bool> pipeline_done{false};
  std::atomic<std::uint64_t> bytes_written{0};
};

void set_turn_headers(httplib::Response& res, const TurnResult& result,
                      const std::string& device_id,
                      std::int64_t known_conversation_id) {
  res.set_header("X-Turn-Id", result.turn_id);
  res.set_header("X-Transcript", header_safe(result.transcript));
  res.set_header("X-Device-Id", device_id);
  if (known_conversation_id != 0) {
    res.set_header("X-Conversation-Id", std::to_string(known_conversation_id));
  }
  if (result.used_fast_path) {
    res.set_header("X-Fast-Path", "1");
    if (!result.fast_path_kind.empty()) {
      res.set_header("X-Fast-Path-Kind", result.fast_path_kind);
    }
  }
}

void start_streaming_turn(httplib::Response& res,
                          const ServerDeps& deps,
                          const std::string& device_id,
                          const std::string& transcript,
                          const std::string& turn_id,
                          int stt_ms) {
  auto state = std::make_shared<StreamingTurnState>();
  state->result.turn_id = turn_id;
  state->result.transcript = transcript;

  std::int64_t known_conversation_id = 0;
  if (auto session = deps.pipeline->session_for(device_id)) {
    known_conversation_id = session->conversation_id;
  }

  set_turn_headers(res, state->result, device_id, known_conversation_id);

  const std::string ctype =
      "audio/L16; rate=" + std::to_string(deps.config.sample_rate) + "; channels=1";
  res.status = 200;

  res.set_chunked_content_provider(
      ctype,
      [state](size_t /*offset*/, httplib::DataSink& sink) -> bool {
        auto chunk = state->stream.wait_pop();
        if (chunk.empty()) {
          sink.done();
          return true;
        }
        state->bytes_written.fetch_add(chunk.size());
        return sink.write(reinterpret_cast<const char*>(chunk.data()), chunk.size());
      },
      [state](bool /*success*/) {
        std::lock_guard<std::mutex> lk(state->result_mu);
        if (!state->result.error.empty()) {
          std::cerr << "intercom turn warning: " << state->result.error << std::endl;
        }
      });

  auto pipeline = deps.pipeline;
  std::thread([state, pipeline, device_id, transcript, turn_id, stt_ms]() {
    StreamingAudioSink audio(state->stream);
    TurnResult result =
        pipeline->run_text_utterance(device_id, transcript, audio, turn_id, stt_ms);
    {
      std::lock_guard<std::mutex> lk(state->result_mu);
      state->result = std::move(result);
      state->pipeline_done.store(true);
    }
    state->stream.finish();
  }).detach();
}

}  // namespace

void run_http_server(ServerDeps deps) {
  httplib::Server svr;
  g_svr = &svr;
  std::signal(SIGINT, on_stop_signal);
  std::signal(SIGTERM, on_stop_signal);

  WsServer ws(deps);
  if (deps.config.ws_listen_port > 0) {
    if (!ws.listen(deps.config.listen_host, deps.config.ws_listen_port)) {
      std::cerr << "intercom ws failed to bind " << deps.config.listen_host << ":"
                << deps.config.ws_listen_port << std::endl;
    } else {
      g_ws = &ws;
      std::cout << "intercom ws on ws://" << deps.config.listen_host << ":" << ws.port()
                << "/v1/stream" << std::endl;
    }
  }

  svr.Get("/health", [&](const httplib::Request&, httplib::Response& res) {
    std::string stt_detail;
    std::string tts_detail;
    std::string arb_detail;
    const bool stt_ok = deps.pipeline->stt().ready(&stt_detail);
    const bool tts_ok = deps.pipeline->tts().ready(&tts_detail);
    const bool arb_ok = deps.pipeline->arbiter().health_reachable(&arb_detail);
    nlohmann::json j = {
        {"ok", stt_ok && tts_ok},
        {"whisper", {{"ready", stt_ok}, {"detail", stt_detail}}},
        {"kokoro", {{"ready", tts_ok}, {"detail", tts_detail}}},
        {"arbiter", {{"reachable", arb_ok}, {"detail", arb_detail}}},
        {"ws",
         {{"port", deps.config.ws_listen_port},
          {"path", "/v1/stream"}}},
        {"speakback", {{"enabled", deps.config.speakback.enabled}}},
    };
    res.status = (stt_ok && tts_ok) ? 200 : 503;
    res.set_content(j.dump(2), "application/json");
  });

  svr.Get(R"(/v1/devices/([^/]+)/session)",
          [&](const httplib::Request& req, httplib::Response& res) {
            const std::string device_id = req.matches[1];
            const std::string token = bearer_token(req);
            if (!deps.config.authorize_device(device_id, token)) {
              res.status = 401;
              res.set_content(R"({"error":"unauthorized"})", "application/json");
              return;
            }
            auto session = deps.pipeline->session_for(device_id);
            if (!session) {
              res.status = 404;
              res.set_content(R"({"error":"no session"})", "application/json");
              return;
            }
            nlohmann::json j = {
                {"device_id", session->device_id},
                {"conversation_id", session->conversation_id},
                {"last_turn_id", session->last_turn_id},
                {"updated_at", session->updated_at},
            };
            res.set_content(j.dump(2), "application/json");
          });

  svr.Post(R"(/v1/turns/([^/]+)/cancel)",
           [&](const httplib::Request& req, httplib::Response& res) {
             const std::string turn_id = req.matches[1];
             const std::string device_id = req.get_header_value("X-Device-Id");
             const std::string token = bearer_token(req);
             if (device_id.empty() ||
                 !deps.config.authorize_device(device_id, token)) {
               res.status = 401;
               res.set_content(R"({"error":"unauthorized"})", "application/json");
               return;
             }
             std::string err;
             if (!deps.pipeline->cancel_turn(turn_id, &err)) {
               res.status = 404;
               nlohmann::json j = {{"error", err.empty() ? "cancel failed" : err}};
               res.set_content(j.dump(), "application/json");
               return;
             }
             res.set_content(R"({"cancelled":true})", "application/json");
           });

  svr.Post("/v1/utterance", [&](const httplib::Request& req, httplib::Response& res) {
    const std::string device_id = req.get_header_value("X-Device-Id");
    const std::string token = bearer_token(req);
    if (device_id.empty() || !deps.config.authorize_device(device_id, token)) {
      res.status = 401;
      res.set_content(R"({"error":"unauthorized"})", "application/json");
      return;
    }
    if (req.body.empty()) {
      res.status = 400;
      res.set_content(R"({"error":"empty body"})", "application/json");
      return;
    }

    const int sample_rate = parse_sample_rate(req, deps.config.sample_rate);
    std::vector<std::uint8_t> pcm(req.body.begin(), req.body.end());

    std::string stt_err;
    const auto stt_t0 = std::chrono::steady_clock::now();
    const std::string transcript = deps.pipeline->stt().transcribe(
        pcm, sample_rate, deps.config.channels, &stt_err);
    const int stt_ms = static_cast<int>(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - stt_t0)
            .count());
    if (transcript.empty()) {
      res.status = 502;
      const std::string err = stt_err.empty() ? "stt failed" : stt_err;
      res.set_header("X-Intercom-Error", header_safe(err));
      nlohmann::json j = {{"error", err}, {"stt_ms", stt_ms}};
      res.set_content(j.dump(), "application/json");
      std::cerr << "intercom latency stt_ms=" << stt_ms << " error=" << err << std::endl;
      return;
    }

    const std::string turn_id = intercom::make_turn_id();
    start_streaming_turn(res, deps, device_id, transcript, turn_id, stt_ms);
  });

  svr.Post("/v1/utterance/text", [&](const httplib::Request& req, httplib::Response& res) {
    const std::string device_id = req.get_header_value("X-Device-Id");
    const std::string token = bearer_token(req);
    if (device_id.empty() || !deps.config.authorize_device(device_id, token)) {
      res.status = 401;
      res.set_content(R"({"error":"unauthorized"})", "application/json");
      return;
    }
    std::string transcript;
    try {
      auto j = nlohmann::json::parse(req.body.empty() ? "{}" : req.body);
      if (j.contains("text") && j["text"].is_string()) {
        transcript = j["text"].get<std::string>();
      }
    } catch (...) {
      res.status = 400;
      res.set_content(R"({"error":"invalid json"})", "application/json");
      return;
    }
    if (transcript.empty()) {
      res.status = 400;
      res.set_content(R"({"error":"missing text"})", "application/json");
      return;
    }

    const std::string turn_id = intercom::make_turn_id();
    start_streaming_turn(res, deps, device_id, transcript, turn_id, -1);
  });

  std::cout << "intercom listening on http://" << deps.config.listen_host << ":"
            << deps.config.listen_port << std::endl;
  if (!svr.listen(deps.config.listen_host.c_str(), deps.config.listen_port)) {
    std::cerr << "intercom failed to bind " << deps.config.listen_host << ":"
              << deps.config.listen_port << std::endl;
  }
  g_ws = nullptr;
  ws.stop();
}

}  // namespace intercom

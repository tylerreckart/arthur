#include "intercom/http_server.hpp"
#include "intercom/local_context.hpp"
#include "intercom/pcm_stream.hpp"
#include "intercom/speak_queue.hpp"
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
#include <optional>
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

int base64_value(char c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

std::optional<std::vector<std::uint8_t>> decode_base64(std::string_view in) {
  std::string filtered;
  filtered.reserve(in.size());
  for (char c : in) {
    if (c == '\n' || c == '\r' || c == ' ' || c == '\t') continue;
    filtered.push_back(c);
  }
  if (filtered.empty() || filtered.size() % 4 != 0) return std::nullopt;
  std::vector<std::uint8_t> out;
  out.reserve(filtered.size() / 4 * 3);
  for (std::size_t i = 0; i < filtered.size(); i += 4) {
    int value[4];
    int pad = 0;
    for (int k = 0; k < 4; ++k) {
      const char c = filtered[i + static_cast<std::size_t>(k)];
      if (c == '=') {
        value[k] = 0;
        ++pad;
      } else {
        value[k] = base64_value(c);
        if (value[k] < 0 || pad) return std::nullopt;
      }
    }
    if (pad > 2) return std::nullopt;
    out.push_back(static_cast<std::uint8_t>((value[0] << 2) | (value[1] >> 4)));
    if (pad < 2) {
      out.push_back(static_cast<std::uint8_t>(((value[1] & 15) << 4) | (value[2] >> 2)));
    }
    if (pad < 1) {
      out.push_back(static_cast<std::uint8_t>(((value[2] & 3) << 6) | value[3]));
    }
  }
  return out;
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

bool device_authorized(const ServerDeps& deps, const httplib::Request& req) {
  const std::string device_id = req.get_header_value("X-Device-Id");
  return !device_id.empty() && deps.config.authorize_device(device_id, bearer_token(req));
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
                          int stt_ms,
                          ClientContext client_context = {},
                          SpeakerIdentity speaker = {}) {
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
  std::thread([state, pipeline, device_id, transcript, turn_id, stt_ms, speaker,
               client_context = std::move(client_context)]() {
    StreamingAudioSink audio(state->stream);
    TurnResult result = pipeline->run_text_utterance(
        device_id, transcript, audio, turn_id, stt_ms, client_context, speaker);
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
                {"last_user", session->last_user},
                {"last_spoken", session->last_spoken},
                {"last_fast_path_kind", session->last_fast_path_kind},
                {"last_fast_path_request", session->last_fast_path_request},
                {"last_card", session->last_card},
                {"pending_intent", session->pending_intent},
                {"pending_at", session->pending_at},
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

  svr.Post("/v1/home/event", [&](const httplib::Request& req, httplib::Response& res) {
    const std::string device_id = req.get_header_value("X-Device-Id");
    const std::string token = bearer_token(req);
    if (device_id.empty() || !deps.config.authorize_device(device_id, token)) {
      res.status = 401;
      res.set_content(R"({"error":"unauthorized"})", "application/json");
      return;
    }
    nlohmann::json body;
    try {
      body = nlohmann::json::parse(req.body.empty() ? "{}" : req.body);
    } catch (...) {
      res.status = 400;
      res.set_content(R"({"error":"invalid json"})", "application/json");
      return;
    }
    const auto alert = home_alert_from_json(body);
    if (!alert || !deps.hub) {
      res.status = 400;
      res.set_content(R"({"error":"unsupported home event"})", "application/json");
      return;
    }
    if (!deps.hub->speak(device_id, alert->text, alert->kind, 0)) {
      res.status = 500;
      res.set_content(R"({"error":"could not queue"})", "application/json");
      return;
    }
    nlohmann::json ok = {{"queued", true}, {"kind", alert->kind}};
    res.set_content(ok.dump(), "application/json");
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
    const SpeakerIdentity speaker =
        deps.pipeline->identify_pcm(pcm.data(), pcm.size(), sample_rate, deps.config.channels);
    start_streaming_turn(res, deps, device_id, transcript, turn_id, stt_ms, {}, speaker);
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
    ClientContext context;
    try {
      auto j = nlohmann::json::parse(req.body.empty() ? "{}" : req.body);
      if (j.contains("text") && j["text"].is_string()) {
        transcript = j["text"].get<std::string>();
      }
      if (j.contains("context")) context = client_context_from_json(j["context"]);
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
    start_streaming_turn(res, deps, device_id, transcript, turn_id, -1, std::move(context));
  });

  svr.Get("/v1/household/people", [&](const httplib::Request& req, httplib::Response& res) {
    if (!device_authorized(deps, req)) {
      res.status = 401;
      res.set_content(R"({"error":"unauthorized"})", "application/json");
      return;
    }
    nlohmann::json people = nlohmann::json::array();
    for (const auto& person : deps.pipeline->list_people()) {
      people.push_back({
          {"id", person.person_id},
          {"name", person.name},
          {"calendar", person.calendar},
          {"phrases", person.phrases},
      });
    }
    res.set_content(nlohmann::json{{"people", people}}.dump(), "application/json");
  });

  svr.Post("/v1/household/people", [&](const httplib::Request& req, httplib::Response& res) {
    if (!device_authorized(deps, req)) {
      res.status = 401;
      res.set_content(R"({"error":"unauthorized"})", "application/json");
      return;
    }
    std::string name;
    std::string calendar;
    try {
      auto body = nlohmann::json::parse(req.body.empty() ? "{}" : req.body);
      if (body.contains("name") && body["name"].is_string()) name = body["name"].get<std::string>();
      if (body.contains("calendar") && body["calendar"].is_string()) {
        calendar = body["calendar"].get<std::string>();
      }
    } catch (...) {
      res.status = 400;
      res.set_content(R"({"error":"invalid json"})", "application/json");
      return;
    }
    std::string err;
    auto person = deps.pipeline->enroll_person(name, calendar, &err);
    if (!person) {
      res.status = 400;
      nlohmann::json j = {{"error", err.empty() ? "could not enroll" : err}};
      res.set_content(j.dump(), "application/json");
      return;
    }
    nlohmann::json j = {
        {"id", person->person_id},
        {"name", person->name},
        {"calendar", person->calendar},
    };
    res.set_content(j.dump(), "application/json");
  });

  svr.Delete(R"(/v1/household/people/([^/]+))",
             [&](const httplib::Request& req, httplib::Response& res) {
               if (!device_authorized(deps, req)) {
                 res.status = 401;
                 res.set_content(R"({"error":"unauthorized"})", "application/json");
                 return;
               }
               std::string err;
               if (!deps.pipeline->remove_person(req.matches[1], &err)) {
                 res.status = 400;
                 nlohmann::json j = {{"error", err.empty() ? "could not remove" : err}};
                 res.set_content(j.dump(), "application/json");
                 return;
               }
               res.set_content(R"({"removed":true})", "application/json");
             });

  svr.Post(R"(/v1/household/people/([^/]+)/voice)",
           [&](const httplib::Request& req, httplib::Response& res) {
             if (!device_authorized(deps, req)) {
               res.status = 401;
               res.set_content(R"({"error":"unauthorized"})", "application/json");
               return;
             }
             int phrase = -1;
             int sample_rate = deps.config.sample_rate;
             std::string pcm_b64;
             try {
               auto body = nlohmann::json::parse(req.body.empty() ? "{}" : req.body);
               if (body.contains("phrase") && body["phrase"].is_number_integer()) {
                 phrase = body["phrase"].get<int>();
               }
               if (body.contains("sample_rate") && body["sample_rate"].is_number_integer()) {
                 sample_rate = body["sample_rate"].get<int>();
               }
               if (body.contains("pcm") && body["pcm"].is_string()) {
                 pcm_b64 = body["pcm"].get<std::string>();
               }
             } catch (...) {
               res.status = 400;
               res.set_content(R"({"error":"invalid json"})", "application/json");
               return;
             }
             auto pcm = decode_base64(pcm_b64);
             if (!pcm) {
               res.status = 400;
               res.set_content(R"({"error":"invalid audio"})", "application/json");
               return;
             }
             std::string err;
             if (!deps.pipeline->enroll_voice(req.matches[1], phrase, pcm->data(), pcm->size(),
                                             sample_rate, &err)) {
               res.status = 400;
               nlohmann::json j = {{"error", err.empty() ? "could not enroll voice" : err}};
               res.set_content(j.dump(), "application/json");
               return;
             }
             res.set_content(R"({"stored":true})", "application/json");
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

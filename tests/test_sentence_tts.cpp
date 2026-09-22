#include "intercom/arbiter_client.hpp"
#include "intercom/filler_client.hpp"
#include "intercom/session_store.hpp"
#include "intercom/stt.hpp"
#include "intercom/tts.hpp"
#include "intercom/turn_pipeline.hpp"
#include "intercom/warm.hpp"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

int g_fails = 0;

void expect(bool cond, const char* expr, const char* file, int line) {
  if (!cond) {
    std::cerr << "FAIL " << file << ":" << line << " " << expr << "\n";
    ++g_fails;
  }
}

#define CHECK(cond) expect((cond), #cond, __FILE__, __LINE__)

class DummyStt : public intercom::SttProvider {
 public:
  std::string transcribe(const std::vector<std::uint8_t>&, int, int, std::string*) override {
    return {};
  }
  bool ready(std::string*) const override { return true; }
};

class RecordingTts : public intercom::TtsProvider {
 public:
  bool synthesize(const std::string& text, PcmChunkFn on_chunk, std::string*) override {
    {
      std::lock_guard<std::mutex> lk(mu);
      texts.push_back(text);
    }
    const std::uint8_t pcm[4] = {0, 0, 0, 0};
    if (on_chunk) on_chunk(pcm, sizeof(pcm));
    return true;
  }
  bool ready(std::string*) const override { return true; }

  std::size_t count() const {
    std::lock_guard<std::mutex> lk(mu);
    return texts.size();
  }
  std::vector<std::string> snapshot() const {
    std::lock_guard<std::mutex> lk(mu);
    return texts;
  }

 private:
  mutable std::mutex mu;
  std::vector<std::string> texts;
};

class StreamingArbiter : public intercom::ArbiterClient {
 public:
  explicit StreamingArbiter(std::shared_ptr<RecordingTts> tts)
      : ArbiterClient("http://127.0.0.1:9", "", "arthur"), tts_(std::move(tts)) {}

  std::optional<std::int64_t> create_conversation(const std::string&,
                                                  std::string*) const override {
    return 42;
  }

  bool send_message(std::int64_t, const std::string& message, const std::string&,
                    intercom::ArbiterStreamCallbacks cbs, std::atomic<bool>*,
                    std::string*) const override {
    last_message = message;
    if (cbs.on_request_id) cbs.on_request_id("req-test");
    if (cbs.on_text_delta) cbs.on_text_delta("Hello. ");
    for (int i = 0; i < 200 && tts_->count() < 1; ++i) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    spoke_first_before_done = tts_->count() >= 1;
    if (cbs.on_text_delta) cbs.on_text_delta("How are you?");
    if (cbs.on_done) cbs.on_done(true, "Hello. How are you?", "");
    return true;
  }

  bool cancel_request(const std::string&, std::string*) const override { return true; }

  mutable std::string last_message;
  mutable bool spoke_first_before_done = false;

 private:
  std::shared_ptr<RecordingTts> tts_;
};

class CollectingSink : public intercom::AudioSink {
 public:
  bool write(const std::uint8_t*, std::size_t) override { return true; }
  void event(const char* type, const std::string& value) override {
    events.emplace_back(type ? type : "", value);
  }
  std::vector<std::pair<std::string, std::string>> events;
};

}  // namespace

int main() {
  auto tts = std::make_shared<RecordingTts>();
  auto arbiter = std::make_shared<StreamingArbiter>(tts);
  auto stt = std::make_shared<DummyStt>();

  const auto db_path = std::filesystem::temp_directory_path() / "intercom_sentence_tts.db";
  std::filesystem::remove(db_path);
  auto sessions = std::make_shared<intercom::SessionStore>(db_path.string());
  std::string err;
  CHECK(sessions->open(&err));

  intercom::Config config;
  config.fast_path = false;
  config.filler.enabled = false;

  intercom::TurnPipeline pipeline(config, stt, tts, arbiter, sessions, nullptr);
  CollectingSink sink;
  const auto result = pipeline.run_text_utterance("dev-1", "tell me something long", sink);

  CHECK(result.ok);
  CHECK(result.error.empty());
  CHECK(arbiter->last_message == "tell me something long");
  CHECK(arbiter->spoke_first_before_done);
  CHECK(!sink.events.empty());
  if (!sink.events.empty()) {
    CHECK(sink.events.front().first == "heard");
    CHECK(sink.events.front().second == "tell me something long");
  }

  const auto texts = tts->snapshot();
  CHECK(texts.size() == 2);
  if (texts.size() == 2) {
    CHECK(texts[0] == "Hello.");
    CHECK(texts[1] == "How are you?");
  }

  std::filesystem::remove(db_path);

  {
    class EarlyArbiter : public intercom::ArbiterClient {
     public:
      explicit EarlyArbiter(std::shared_ptr<RecordingTts> tts)
          : ArbiterClient("http://127.0.0.1:9", "", "arthur"), tts_(std::move(tts)) {}
      std::optional<std::int64_t> create_conversation(const std::string&,
                                                      std::string*) const override {
        return 7;
      }
      bool send_message(std::int64_t, const std::string&, const std::string&,
                        intercom::ArbiterStreamCallbacks cbs, std::atomic<bool>*,
                        std::string*) const override {
        if (cbs.on_request_id) cbs.on_request_id("req-early");
        if (cbs.on_text_delta) {
          cbs.on_text_delta("one two three four five six seven leftover");
        }
        for (int i = 0; i < 200 && tts_->count() < 1; ++i) {
          std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        spoke_before_done = tts_->count() >= 1;
        if (cbs.on_done) cbs.on_done(true, "one two three four five six seven leftover", "");
        return true;
      }
      bool cancel_request(const std::string&, std::string*) const override { return true; }
      mutable bool spoke_before_done = false;

     private:
      std::shared_ptr<RecordingTts> tts_;
    };

    auto tts_e = std::make_shared<RecordingTts>();
    auto arb_e = std::make_shared<EarlyArbiter>(tts_e);
    auto stt_e = std::make_shared<DummyStt>();
    const auto db_e = std::filesystem::temp_directory_path() / "intercom_early_flush.db";
    std::filesystem::remove(db_e);
    auto sessions_e = std::make_shared<intercom::SessionStore>(db_e.string());
    CHECK(sessions_e->open(&err));
    intercom::Config cfg;
    cfg.fast_path = false;
    cfg.filler.enabled = false;
    cfg.early_flush_words = 7;
    intercom::TurnPipeline pipe(cfg, stt_e, tts_e, arb_e, sessions_e, nullptr);
    CollectingSink sink_e;
    const auto r = pipe.run_text_utterance("dev-e", "long answer please", sink_e);
    CHECK(r.ok);
    CHECK(arb_e->spoke_before_done);
    const auto texts_e = tts_e->snapshot();
    CHECK(texts_e.size() >= 1);
    if (!texts_e.empty()) {
      CHECK(texts_e[0].find("one two three four five six seven") != std::string::npos);
    }
    std::filesystem::remove(db_e);
  }

  {
    class SlowToolArbiter : public intercom::ArbiterClient {
     public:
      SlowToolArbiter() : ArbiterClient("http://127.0.0.1:9", "", "arthur") {}
      std::optional<std::int64_t> create_conversation(const std::string&,
                                                      std::string*) const override {
        return 8;
      }
      bool send_message(std::int64_t, const std::string&, const std::string&,
                        intercom::ArbiterStreamCallbacks cbs, std::atomic<bool>*,
                        std::string*) const override {
        if (cbs.on_request_id) cbs.on_request_id("req-tool");
        if (cbs.on_tool_call) cbs.on_tool_call("search");
        std::this_thread::sleep_for(std::chrono::milliseconds(400));
        if (cbs.on_text_delta) cbs.on_text_delta("Here you go.");
        if (cbs.on_done) cbs.on_done(true, "Here you go.", "");
        return true;
      }
      bool cancel_request(const std::string&, std::string*) const override { return true; }
    };

    auto tts_f = std::make_shared<RecordingTts>();
    auto arb_f = std::make_shared<SlowToolArbiter>();
    auto stt_f = std::make_shared<DummyStt>();
    const auto db_f = std::filesystem::temp_directory_path() / "intercom_filler_ack.db";
    std::filesystem::remove(db_f);
    auto sessions_f = std::make_shared<intercom::SessionStore>(db_f.string());
    CHECK(sessions_f->open(&err));
    intercom::Config cfg;
    cfg.fast_path = false;
    cfg.filler.enabled = true;
    cfg.filler.instant_ack_ms = 700;
    cfg.filler.tool_ack_ms = 20;
    cfg.early_flush_words = 0;
    auto filler = std::make_shared<intercom::FillerClient>(cfg.filler);
    intercom::TurnPipeline pipe(cfg, stt_f, tts_f, arb_f, sessions_f, filler);
    CollectingSink sink_f;
    const auto r = pipe.run_text_utterance("dev-f", "look this up please", sink_f);
    CHECK(r.ok);
    const auto texts_f = tts_f->snapshot();
    CHECK(texts_f.size() >= 2);
    if (texts_f.size() >= 2) {
      CHECK(texts_f[0] == "Of course.");
      CHECK(texts_f[1].find("Here you go") != std::string::npos);
    }
    std::filesystem::remove(db_f);
  }

  {
    class SlowAnswerArbiter : public intercom::ArbiterClient {
     public:
      SlowAnswerArbiter() : ArbiterClient("http://127.0.0.1:9", "", "arthur") {}
      std::optional<std::int64_t> create_conversation(const std::string&,
                                                      std::string*) const override {
        return 9;
      }
      bool send_message(std::int64_t, const std::string&, const std::string&,
                        intercom::ArbiterStreamCallbacks cbs, std::atomic<bool>*,
                        std::string*) const override {
        if (cbs.on_request_id) cbs.on_request_id("req-local");
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
        if (cbs.on_text_delta) cbs.on_text_delta("Done.");
        if (cbs.on_done) cbs.on_done(true, "Done.", "");
        return true;
      }
      bool cancel_request(const std::string&, std::string*) const override { return true; }
    };

    auto tts_l = std::make_shared<RecordingTts>();
    auto arb_l = std::make_shared<SlowAnswerArbiter>();
    auto stt_l = std::make_shared<DummyStt>();
    const auto db_l = std::filesystem::temp_directory_path() / "intercom_local_ack.db";
    std::filesystem::remove(db_l);
    auto sessions_l = std::make_shared<intercom::SessionStore>(db_l.string());
    CHECK(sessions_l->open(&err));
    intercom::Config cfg;
    cfg.fast_path = false;
    cfg.filler.enabled = true;
    cfg.filler.instant_ack_ms = 40;
    cfg.filler.tool_ack_ms = 250;
    cfg.early_flush_words = 0;
    auto filler = std::make_shared<intercom::FillerClient>(cfg.filler);
    intercom::TurnPipeline pipe(cfg, stt_l, tts_l, arb_l, sessions_l, filler);
    CollectingSink sink_l;
    const auto r = pipe.run_text_utterance("dev-l", "a slow question", sink_l);
    CHECK(r.ok);
    const auto texts_l = tts_l->snapshot();
    CHECK(texts_l.size() >= 2);
    if (!texts_l.empty()) {
      const auto phrases = intercom::FillerClient::instant_ack_phrases();
      bool cached = false;
      for (const auto& p : phrases) {
        if (texts_l[0] == p) cached = true;
      }
      CHECK(cached);
    }
    std::filesystem::remove(db_l);
  }

  CHECK(intercom::FillerClient::tool_ack("web_search") == "Of course.");
  CHECK(intercom::FillerClient::tool_ack("mem_read") == "Yes, sir.");
  CHECK(intercom::FillerClient::tool_ack("exec") == "Certainly.");

  const auto local = intercom::FillerClient::instant_ack_phrases();
  CHECK(!local.empty());
  for (const auto& p : local) {
    CHECK(p != "Right.");
    CHECK(p.find("see") == std::string::npos);
    CHECK(p.find("look") == std::string::npos);
    CHECK(p.find("check") == std::string::npos);
    CHECK(p.find("think") == std::string::npos);
  }
  const auto cached = intercom::FillerClient::cached_ack_phrases();
  CHECK(cached.size() >= local.size());

  {
    auto tts_off = std::make_shared<RecordingTts>();
    auto arbiter_off = std::make_shared<StreamingArbiter>(tts_off);
    auto stt_off = std::make_shared<DummyStt>();
    const auto db_off = std::filesystem::temp_directory_path() / "intercom_warm_off.db";
    std::filesystem::remove(db_off);
    auto sessions_off = std::make_shared<intercom::SessionStore>(db_off.string());
    CHECK(sessions_off->open(&err));
    intercom::Config cfg_off;
    cfg_off.fast_path = false;
    cfg_off.filler.enabled = false;
    cfg_off.warm_prefix = false;
    cfg_off.devices["speaker-1"] = "tok";
    intercom::TurnPipeline pipe_off(cfg_off, stt_off, tts_off, arbiter_off, sessions_off,
                                    nullptr);
    pipe_off.warm_prefix();
    CHECK(arbiter_off->last_message.empty());
    std::filesystem::remove(db_off);
  }

  {
    auto tts_w = std::make_shared<RecordingTts>();
    auto arbiter_w = std::make_shared<StreamingArbiter>(tts_w);
    auto stt_w = std::make_shared<DummyStt>();
    const auto db_w = std::filesystem::temp_directory_path() / "intercom_warm.db";
    std::filesystem::remove(db_w);
    auto sessions_w = std::make_shared<intercom::SessionStore>(db_w.string());
    CHECK(sessions_w->open(&err));
    intercom::Config cfg_w;
    cfg_w.fast_path = false;
    cfg_w.filler.enabled = false;
    cfg_w.warm_prefix = true;
    cfg_w.devices["speaker-1"] = "tok";
    intercom::TurnPipeline pipe_w(cfg_w, stt_w, tts_w, arbiter_w, sessions_w, nullptr);
    pipe_w.warm_prefix();
    CHECK(arbiter_w->last_message == intercom::kPrefixWarmMessage);
    auto sess = sessions_w->get("speaker-1");
    CHECK(sess.has_value());
    if (sess) CHECK(sess->conversation_id == 42);
    std::filesystem::remove(db_w);
  }

  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_sentence_tts ok\n";
  return 0;
}

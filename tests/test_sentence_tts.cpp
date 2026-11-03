#include "intercom/arbiter_client.hpp"
#include "intercom/filler_client.hpp"
#include "intercom/session_store.hpp"
#include "intercom/stt.hpp"
#include "intercom/tts.hpp"
#include "intercom/turn_pipeline.hpp"
#include "intercom/warm.hpp"

#include <sqlite3.h>

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <future>
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
  const auto spoken_session = sessions->get("dev-1");
  CHECK(spoken_session.has_value());
  if (spoken_session) {
    CHECK(spoken_session->last_spoken == "Hello. How are you?");
  }

  std::filesystem::remove(db_path);

  {
    auto tts_fp = std::make_shared<RecordingTts>();
    auto arbiter_fp = std::make_shared<StreamingArbiter>(tts_fp);
    auto stt_fp = std::make_shared<DummyStt>();
    const auto db_fp =
        std::filesystem::temp_directory_path() / "intercom_fast_conversation.db";
    std::filesystem::remove(db_fp);
    auto sessions_fp = std::make_shared<intercom::SessionStore>(db_fp.string());
    CHECK(sessions_fp->open(&err));
    intercom::Config cfg_fp;
    cfg_fp.fast_path = true;
    cfg_fp.filler.enabled = false;
    intercom::TurnPipeline pipe_fp(
        cfg_fp, stt_fp, tts_fp, arbiter_fp, sessions_fp, nullptr);
    CollectingSink sink_fp;
    const auto fast =
        pipe_fp.run_text_utterance("dev-fast", "echo hello", sink_fp);
    CHECK(fast.ok);
    CHECK(fast.used_fast_path);
    CHECK(fast.conversation_id == 42);
    const auto fast_session = sessions_fp->get("dev-fast");
    CHECK(fast_session.has_value());
    if (fast_session) {
      CHECK(fast_session->conversation_id == 42);
      CHECK(fast_session->last_turn_id == fast.turn_id);
      CHECK(fast_session->last_user == "echo hello");
      CHECK(fast_session->last_spoken == "hello");
      CHECK(fast_session->last_fast_path_kind == "echo");
      CHECK(fast_session->last_fast_path_request == "echo hello");
    }
    const auto repeated = pipe_fp.run_text_utterance(
        "dev-fast", "say that again", sink_fp);
    CHECK(repeated.ok);
    CHECK(repeated.used_fast_path);
    CHECK(repeated.fast_path_kind == "echo");
    const auto repeated_text = tts_fp->snapshot();
    CHECK(repeated_text.size() == 2);
    if (repeated_text.size() == 2) {
      CHECK(repeated_text[0] == "hello.");
      CHECK(repeated_text[1] == "hello.");
    }
    CHECK(arbiter_fp->last_message.empty());

    const auto clock = pipe_fp.run_text_utterance(
        "dev-context", "what time is it", sink_fp);
    CHECK(clock.ok);
    CHECK(clock.used_fast_path);
    const auto clock_session = sessions_fp->get("dev-context");
    CHECK(clock_session.has_value());
    const auto followup = pipe_fp.run_text_utterance(
        "dev-context", "what about tomorrow?", sink_fp);
    CHECK(followup.ok);
    CHECK(!followup.used_fast_path);
    CHECK(arbiter_fp->last_message.find("VOICE CONTEXT") != std::string::npos);
    CHECK(arbiter_fp->last_message.find(
              "Previous user request: what time is it") != std::string::npos);
    if (clock_session) {
      CHECK(arbiter_fp->last_message.find(clock_session->last_spoken) !=
            std::string::npos);
    }
    CHECK(arbiter_fp->last_message.find(
              "[CURRENT USER REQUEST]\nwhat about tomorrow?") !=
          std::string::npos);

    const auto separate_clock = pipe_fp.run_text_utterance(
        "dev-no-context", "what time is it", sink_fp);
    CHECK(separate_clock.ok);
    CHECK(separate_clock.used_fast_path);
    const auto unrelated = pipe_fp.run_text_utterance(
        "dev-no-context", "tell me a joke", sink_fp);
    CHECK(unrelated.ok);
    CHECK(!unrelated.used_fast_path);
    CHECK(arbiter_fp->last_message == "tell me a joke");
    std::filesystem::remove(db_fp);
  }

  {
    auto tts_actions = std::make_shared<RecordingTts>();
    auto arbiter_actions = std::make_shared<StreamingArbiter>(tts_actions);
    auto stt_actions = std::make_shared<DummyStt>();
    const auto db_actions =
        std::filesystem::temp_directory_path() / "intercom_action_followups.db";
    std::filesystem::remove(db_actions);
    auto sessions_actions =
        std::make_shared<intercom::SessionStore>(db_actions.string());
    CHECK(sessions_actions->open(&err));
    intercom::Config cfg_actions;
    cfg_actions.fast_path = true;
    cfg_actions.filler.enabled = false;
    cfg_actions.home.ha_base_url = "http://127.0.0.1:9";
    cfg_actions.home.ha_token = "test";
    cfg_actions.home.lights["kitchen"] = "light.kitchen";
    cfg_actions.home.lights["hallway"] = "light.hallway";
    cfg_actions.home.media_player = "media_player.kitchen";
    intercom::TurnPipeline pipe_actions(
        cfg_actions, stt_actions, tts_actions, arbiter_actions,
        sessions_actions, nullptr);
    CollectingSink sink_actions;

    auto seed_action = [&](const std::string& device, const std::string& kind,
                           const std::string& request) {
      intercom::DeviceSession seeded;
      seeded.device_id = device;
      seeded.conversation_id = 42;
      seeded.last_user = request;
      seeded.last_spoken = "Done.";
      seeded.last_fast_path_kind = kind;
      seeded.last_fast_path_request = request;
      CHECK(sessions_actions->upsert(seeded, &err));
    };

    seed_action("dev-pronoun", "light_on", "turn on kitchen lights");
    const auto pronoun = pipe_actions.run_text_utterance(
        "dev-pronoun", "turn it off", sink_actions);
    CHECK(pronoun.ok);
    CHECK(pronoun.used_fast_path);
    CHECK(pronoun.fast_path_kind == "light_off");
    const auto failed_action = sessions_actions->get("dev-pronoun");
    CHECK(failed_action.has_value());
    if (failed_action) {
      CHECK(failed_action->last_fast_path_kind.empty());
      CHECK(failed_action->last_fast_path_request.empty());
    }

    seed_action("dev-chain", "light_on", "turn on kitchen lights");
    const auto chained = pipe_actions.run_text_utterance(
        "dev-chain", "and the hallway", sink_actions);
    CHECK(chained.ok);
    CHECK(chained.used_fast_path);
    CHECK(chained.fast_path_kind == "light_on");

    seed_action("dev-undo", "light_on", "turn on kitchen lights");
    const auto undone = pipe_actions.run_text_utterance(
        "dev-undo", "undo that", sink_actions);
    CHECK(undone.ok);
    CHECK(undone.used_fast_path);
    CHECK(undone.fast_path_kind == "light_off");

    seed_action("dev-again", "volume_up", "turn the volume up");
    const auto again = pipe_actions.run_text_utterance(
        "dev-again", "do that again", sink_actions);
    CHECK(again.ok);
    CHECK(again.used_fast_path);
    CHECK(again.fast_path_kind == "volume_up");

    CHECK(arbiter_actions->last_message.empty());
    std::filesystem::remove(db_actions);
  }

  {
    auto tts_clarify = std::make_shared<RecordingTts>();
    auto arbiter_clarify = std::make_shared<StreamingArbiter>(tts_clarify);
    auto stt_clarify = std::make_shared<DummyStt>();
    const auto db_clarify =
        std::filesystem::temp_directory_path() / "intercom_timer_clarify.db";
    std::filesystem::remove(db_clarify);
    auto sessions_clarify =
        std::make_shared<intercom::SessionStore>(db_clarify.string());
    CHECK(sessions_clarify->open(&err));
    intercom::Config cfg_clarify;
    cfg_clarify.fast_path = true;
    cfg_clarify.filler.enabled = false;
    cfg_clarify.home.ha_base_url = "http://127.0.0.1:9";
    cfg_clarify.home.ha_token = "test";
    cfg_clarify.home.timer_entity = "timer.kitchen";
    intercom::TurnPipeline pipe_clarify(
        cfg_clarify, stt_clarify, tts_clarify, arbiter_clarify,
        sessions_clarify, nullptr);
    CollectingSink sink_clarify;
    const auto prompt = pipe_clarify.run_text_utterance(
        "dev-clarify", "set a timer", sink_clarify);
    CHECK(prompt.ok);
    CHECK(prompt.used_fast_path);
    auto pending = sessions_clarify->get("dev-clarify");
    CHECK(pending.has_value());
    if (pending) CHECK(pending->pending_intent == "timer_duration");

    const auto completed = pipe_clarify.run_text_utterance(
        "dev-clarify", "five minutes", sink_clarify);
    CHECK(completed.ok);
    CHECK(completed.used_fast_path);
    CHECK(completed.fast_path_kind == "timer");
    pending = sessions_clarify->get("dev-clarify");
    CHECK(pending.has_value());
    if (pending) CHECK(pending->pending_intent.empty());
    CHECK(arbiter_clarify->last_message.empty());
    std::filesystem::remove(db_clarify);
  }

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
      CHECK(texts_e[0].back() == ',');
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
    cfg.filler.followup_silence_ms = 40;
    cfg.filler.max_followups = 1;
    cfg.early_flush_words = 0;
    auto filler = std::make_shared<intercom::FillerClient>(cfg.filler);
    intercom::TurnPipeline pipe(cfg, stt_f, tts_f, arb_f, sessions_f, filler);
    CollectingSink sink_f;
    const auto r = pipe.run_text_utterance("dev-f", "look this up please", sink_f);
    CHECK(r.ok);
    const auto texts_f = tts_f->snapshot();
    CHECK(texts_f.size() >= 3);
    if (texts_f.size() >= 3) {
      CHECK(texts_f[0] == "Of course.");
      CHECK(texts_f[1] == "Still with you.");
      CHECK(texts_f[2].find("Here you go") != std::string::npos);
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
  CHECK(intercom::FillerClient::tool_ack("mem_read") == "All right.");
  CHECK(intercom::FillerClient::tool_ack("exec") == "Certainly.");
  CHECK(intercom::FillerClient::progress_ack() == "Still with you.");

  const auto local = intercom::FillerClient::instant_ack_phrases();
  CHECK(!local.empty());
  for (const auto& p : local) {
    CHECK(p != "Right.");
    CHECK(p.find("sir") == std::string::npos);
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

  {
    class SlowStt : public intercom::SttProvider {
     public:
      std::string transcribe(const std::vector<std::uint8_t>&, int, int,
                             std::string*) override {
        entered.store(true);
        while (!release.load()) {
          std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
        return "transcribed";
      }
      bool ready(std::string*) const override { return true; }
      std::atomic<bool> entered{false};
      std::atomic<bool> release{false};
    };

    auto tts_c = std::make_shared<RecordingTts>();
    auto arbiter_c = std::make_shared<StreamingArbiter>(tts_c);
    auto stt_c = std::make_shared<SlowStt>();
    const auto db_c = std::filesystem::temp_directory_path() / "intercom_stt_cancel.db";
    std::filesystem::remove(db_c);
    auto sessions_c = std::make_shared<intercom::SessionStore>(db_c.string());
    CHECK(sessions_c->open(&err));
    intercom::Config cfg_c;
    cfg_c.fast_path = false;
    cfg_c.filler.enabled = false;
    intercom::TurnPipeline pipe_c(cfg_c, stt_c, tts_c, arbiter_c, sessions_c, nullptr);
    CollectingSink sink_c;
    auto turn = std::async(std::launch::async, [&]() {
      return pipe_c.run_utterance(
          "dev-c", std::vector<std::uint8_t>{1, 2}, 24000, 1, sink_c, "stt-cancel");
    });
    for (int i = 0; i < 100 && !stt_c->entered.load(); ++i) {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    CHECK(stt_c->entered.load());
    std::string cancel_err;
    CHECK(pipe_c.cancel_turn("stt-cancel", &cancel_err));
    stt_c->release.store(true);
    const auto canceled = turn.get();
    CHECK(!canceled.ok);
    CHECK(canceled.error == "canceled");
    CHECK(tts_c->count() == 0);
    std::filesystem::remove(db_c);
  }

  {
    const auto db_migrate =
        std::filesystem::temp_directory_path() / "intercom_session_migrate.db";
    std::filesystem::remove(db_migrate);
    sqlite3* raw = nullptr;
    CHECK(sqlite3_open(db_migrate.c_str(), &raw) == SQLITE_OK);
    const char* legacy_sql =
        "CREATE TABLE device_sessions ("
        "device_id TEXT PRIMARY KEY NOT NULL,"
        "conversation_id INTEGER NOT NULL,"
        "last_turn_id TEXT NOT NULL DEFAULT '',"
        "updated_at INTEGER NOT NULL);";
    CHECK(sqlite3_exec(raw, legacy_sql, nullptr, nullptr, nullptr) == SQLITE_OK);
    sqlite3_close(raw);

    intercom::SessionStore migrated(db_migrate.string());
    CHECK(migrated.open(&err));
    intercom::DeviceSession session;
    session.device_id = "legacy-device";
    session.conversation_id = 77;
    session.last_turn_id = "turn-77";
    session.last_user = "turn on the kitchen light";
    session.last_spoken = "The kitchen light is on.";
    session.last_fast_path_kind = "light_on";
    session.last_fast_path_request = "turn on the kitchen light";
    session.pending_intent = "timer_duration";
    session.pending_at = 123;
    CHECK(migrated.upsert(session, &err));
    const auto restored = migrated.get("legacy-device");
    CHECK(restored.has_value());
    if (restored) {
      CHECK(restored->last_user == session.last_user);
      CHECK(restored->last_spoken == session.last_spoken);
      CHECK(restored->last_fast_path_kind == session.last_fast_path_kind);
      CHECK(restored->last_fast_path_request ==
            session.last_fast_path_request);
      CHECK(restored->pending_intent == session.pending_intent);
      CHECK(restored->pending_at == session.pending_at);
    }
    std::filesystem::remove(db_migrate);
  }

  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_sentence_tts ok\n";
  return 0;
}

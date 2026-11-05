#include "intercom/arbiter_client.hpp"
#include "intercom/filler_client.hpp"
#include "intercom/session_store.hpp"
#include "intercom/stt.hpp"
#include "intercom/tts.hpp"
#include "intercom/turn_pipeline.hpp"
#include "intercom/warm.hpp"

#include <httplib.h>
#include <nlohmann/json.hpp>
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

    const auto compound_lights = pipe_actions.run_text_utterance(
        "dev-compound-lights",
        "turn off the kitchen lights and the hallway", sink_actions);
    CHECK(compound_lights.ok);
    CHECK(compound_lights.used_fast_path);
    CHECK(compound_lights.fast_path_kind == "light_off+light_off");
    std::filesystem::remove(db_actions);
  }

  {
    auto tts_compound = std::make_shared<RecordingTts>();
    auto arbiter_compound = std::make_shared<StreamingArbiter>(tts_compound);
    auto stt_compound = std::make_shared<DummyStt>();
    const auto db_compound =
        std::filesystem::temp_directory_path() / "intercom_compound_turns.db";
    std::filesystem::remove(db_compound);
    auto sessions_compound =
        std::make_shared<intercom::SessionStore>(db_compound.string());
    CHECK(sessions_compound->open(&err));
    intercom::Config cfg_compound;
    cfg_compound.fast_path = true;
    cfg_compound.filler.enabled = false;
    cfg_compound.markets.quote_base = "http://127.0.0.1:9";
    cfg_compound.markets.timeout_ms = 400;
    intercom::TurnPipeline pipe_compound(
        cfg_compound, stt_compound, tts_compound, arbiter_compound,
        sessions_compound, nullptr);
    CollectingSink sink_compound;

    const auto spoken = pipe_compound.run_text_utterance(
        "dev-compound", "what time is it and echo hello", sink_compound);
    CHECK(spoken.ok);
    CHECK(spoken.used_fast_path);
    CHECK(spoken.fast_path_kind == "clock+echo");
    const auto spoken_text = tts_compound->snapshot();
    CHECK(spoken_text.size() == 2);
    if (spoken_text.size() == 2) CHECK(spoken_text[1] == "hello.");
    const auto spoken_session = sessions_compound->get("dev-compound");
    CHECK(spoken_session.has_value());
    if (spoken_session) {
      CHECK(spoken_session->last_user == "what time is it and echo hello");
      CHECK(spoken_session->last_fast_path_kind == "echo");
      CHECK(spoken_session->last_fast_path_request == "echo hello");
      CHECK(spoken_session->last_spoken.find("hello") != std::string::npos);
    }

    const auto shorthand = pipe_compound.run_text_utterance(
        "dev-shorthand", "what time is it and the date", sink_compound);
    CHECK(shorthand.ok);
    CHECK(shorthand.used_fast_path);
    CHECK(shorthand.fast_path_kind == "clock+clock");

    const auto mixed = pipe_compound.run_text_utterance(
        "dev-mixed", "tell me a joke and what time is it", sink_compound);
    CHECK(mixed.ok);
    CHECK(!mixed.used_fast_path);
    CHECK(arbiter_compound->last_message ==
          "tell me a joke and what time is it");

    const auto quotes = pipe_compound.run_text_utterance(
        "dev-quotes", "what's bitcoin and ethereum doing", sink_compound);
    CHECK(quotes.ok);
    CHECK(!quotes.used_fast_path);
    CHECK(arbiter_compound->last_message ==
          "what's bitcoin and ethereum doing");

    const auto too_many = pipe_compound.run_text_utterance(
        "dev-too-many", "what time is it and echo one and echo two and echo three",
        sink_compound);
    CHECK(too_many.ok);
    CHECK(!too_many.used_fast_path);
    CHECK(arbiter_compound->last_message.find("echo three") != std::string::npos);
    std::filesystem::remove(db_compound);
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
    session.last_card = "{\"active\":\"news\"}";
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
      CHECK(restored->last_card == session.last_card);
      CHECK(restored->pending_intent == session.pending_intent);
      CHECK(restored->pending_at == session.pending_at);
    }
    CHECK(migrated.remember_conversation("legacy-device", 77, &err));
    CHECK(migrated.owns_conversation("legacy-device", 77));
    CHECK(!migrated.owns_conversation("legacy-device", 78));
    CHECK(!migrated.owns_conversation("other-device", 77));
    CHECK(migrated.remember_conversation("legacy-device", 78, &err));
    CHECK(migrated.owns_conversation("legacy-device", 78));
    CHECK(migrated.remember_conversation("legacy-device", 77, &err));
    std::filesystem::remove(db_migrate);
  }

  {
    std::string light_entity;
    std::string light_service;
    httplib::Server ha;
    ha.Post(R"(/api/services/([A-Za-z0-9_]+)/([A-Za-z0-9_]+))",
            [&](const httplib::Request& req, httplib::Response& res) {
              if (req.matches.size() >= 3) {
                light_service = req.matches[2];
              }
              try {
                const auto body = nlohmann::json::parse(req.body);
                light_entity = body.value("entity_id", "");
              } catch (...) {
                light_entity = "";
              }
              res.set_content("[]", "application/json");
            });
    ha.Get(R"(/v1/search)", [](const httplib::Request&, httplib::Response& res) {
      res.set_content(
          R"({"results":[{"name":"Tokyo","country":"Japan","latitude":35.7,"longitude":139.7}]})",
          "application/json");
    });
    ha.Get(R"(/v1/forecast)", [](const httplib::Request&, httplib::Response& res) {
      res.set_content(R"({
        "current": {
          "time": "2026-09-22T15:00",
          "temperature_2m": 18,
          "apparent_temperature": 17,
          "relative_humidity_2m": 40,
          "weather_code": 1,
          "wind_speed_10m": 5,
          "is_day": 1
        },
        "current_units": {"temperature_2m": "°C", "wind_speed_10m": "km/h"},
        "hourly": {"time": ["2026-09-22T15:00"], "temperature_2m": [18], "weather_code": [1]},
        "daily": {
          "time": ["2026-09-22"],
          "weather_code": [1],
          "temperature_2m_max": [20],
          "temperature_2m_min": [12]
        }
      })",
                      "application/json");
    });
    const int port = ha.bind_to_any_port("127.0.0.1");
    CHECK(port > 0);
    std::thread ha_thread([&ha] { ha.listen_after_bind(); });
    for (int i = 0; i < 50 && !ha.is_running(); ++i) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }

    auto tts_repair = std::make_shared<RecordingTts>();
    auto arbiter_repair = std::make_shared<StreamingArbiter>(tts_repair);
    auto stt_repair = std::make_shared<DummyStt>();
    const auto db_repair =
        std::filesystem::temp_directory_path() / "intercom_repairs.db";
    std::filesystem::remove(db_repair);
    auto sessions_repair =
        std::make_shared<intercom::SessionStore>(db_repair.string());
    CHECK(sessions_repair->open(&err));
    intercom::Config cfg_repair;
    cfg_repair.fast_path = true;
    cfg_repair.filler.enabled = false;
    cfg_repair.home.ha_base_url = "http://127.0.0.1:" + std::to_string(port);
    cfg_repair.home.ha_token = "test";
    cfg_repair.home.timeout_ms = 800;
    cfg_repair.home.lights["kitchen"] = "light.kitchen";
    cfg_repair.home.lights["hallway"] = "light.hallway";
    cfg_repair.home.lights["bedroom"] = "light.bedroom";
    cfg_repair.home.media_player = "media_player.house";
    cfg_repair.news.google_news_rss = "http://127.0.0.1:9/rss";
    cfg_repair.news.timeout_ms = 400;
    cfg_repair.markets.quote_base = "http://127.0.0.1:9";
    cfg_repair.markets.timeout_ms = 400;
    cfg_repair.weather.geocode_base = cfg_repair.home.ha_base_url;
    cfg_repair.weather.forecast_base = cfg_repair.home.ha_base_url;
    cfg_repair.weather.timeout_ms = 800;
    intercom::TurnPipeline pipe_repair(
        cfg_repair, stt_repair, tts_repair, arbiter_repair, sessions_repair,
        nullptr);
    CollectingSink sink_repair;

    auto seed = [&](const std::string& device, const std::string& kind,
                    const std::string& request, const std::string& spoken) {
      intercom::DeviceSession seeded;
      seeded.device_id = device;
      seeded.conversation_id = 42;
      seeded.last_user = request;
      seeded.last_spoken = spoken;
      seeded.last_fast_path_kind = kind;
      seeded.last_fast_path_request = request;
      CHECK(sessions_repair->upsert(seeded, &err));
    };

    seed("dev-room", "light_on", "turn on the hallway lights", "On.");
    light_entity.clear();
    const auto bedroom = pipe_repair.run_text_utterance(
        "dev-room", "no, the bedroom", sink_repair);
    CHECK(bedroom.ok);
    CHECK(bedroom.used_fast_path);
    CHECK(bedroom.fast_path_kind == "light_on");
    CHECK(light_entity == "light.bedroom");
    CHECK(light_service == "turn_on");
    CHECK(arbiter_repair->last_message.empty());
    const auto bedroom_said = tts_repair->snapshot();
    CHECK(!bedroom_said.empty());
    if (!bedroom_said.empty()) {
      CHECK(bedroom_said.back().find("bedroom") != std::string::npos);
    }

    seed("dev-meant", "light_off", "turn off the kitchen lights", "Off.");
    light_entity.clear();
    const auto hallway = pipe_repair.run_text_utterance(
        "dev-meant", "I meant the hallway", sink_repair);
    CHECK(hallway.ok);
    CHECK(hallway.used_fast_path);
    CHECK(hallway.fast_path_kind == "light_off");
    CHECK(light_entity == "light.hallway");
    CHECK(light_service == "turn_off");

    seed("dev-not-room", "light_on", "turn on the hallway lights", "On.");
    light_entity.clear();
    const auto kitchen = pipe_repair.run_text_utterance(
        "dev-not-room", "not the kitchen", sink_repair);
    CHECK(kitchen.ok);
    CHECK(kitchen.used_fast_path);
    CHECK(kitchen.fast_path_kind == "light_on");
    CHECK(light_entity == "light.kitchen");

    seed("dev-joke", "light_on", "turn on the kitchen lights", "On.");
    const auto joke = pipe_repair.run_text_utterance(
        "dev-joke", "tell me a joke", sink_repair);
    CHECK(joke.ok);
    CHECK(!joke.used_fast_path);
    CHECK(arbiter_repair->last_message == "tell me a joke");

    intercom::DeviceSession failed;
    failed.device_id = "dev-failed";
    failed.conversation_id = 42;
    failed.last_user = "turn on the kitchen light";
    failed.last_spoken = "I couldn't do that, sir.";
    failed.last_fast_path_kind = "";
    failed.last_fast_path_request = "";
    CHECK(sessions_repair->upsert(failed, &err));
    const auto not_referent = pipe_repair.run_text_utterance(
        "dev-failed", "no, the bedroom", sink_repair);
    CHECK(not_referent.ok);
    CHECK(!not_referent.used_fast_path);
    CHECK(arbiter_repair->last_message == "no, the bedroom");

    seed("dev-clock", "clock", "what time is it", "It is four.");
    const auto tomorrow = pipe_repair.run_text_utterance(
        "dev-clock", "I meant tomorrow", sink_repair);
    CHECK(tomorrow.ok);
    CHECK(!tomorrow.used_fast_path);
    CHECK(arbiter_repair->last_message.find("never quote") != std::string::npos);
    CHECK(arbiter_repair->last_message.find("It is four.") != std::string::npos);
    CHECK(arbiter_repair->last_message.find("what time is it tomorrow") !=
          std::string::npos);
    CHECK(arbiter_repair->last_message.find("quote the") == std::string::npos);

    seed("dev-news", "news", "what's in the news", "A short bulletin.");
    const auto news_scope = pipe_repair.run_text_utterance(
        "dev-news", "no, tomorrow", sink_repair);
    CHECK(news_scope.ok);
    CHECK(!news_scope.used_fast_path);
    CHECK(arbiter_repair->last_message.find("news tomorrow") != std::string::npos);
    CHECK(arbiter_repair->last_message.find("A short bulletin.") !=
          std::string::npos);
    CHECK(arbiter_repair->last_message.find("[CURRENT USER REQUEST]") !=
          std::string::npos);

    seed("dev-wx", "weather", "what's the weather in Tokyo", "Mild.");
    const std::size_t surfaces_before = sink_repair.events.size();
    const auto wx = pipe_repair.run_text_utterance(
        "dev-wx", "no, tomorrow", sink_repair);
    CHECK(wx.ok);
    CHECK(wx.used_fast_path);
    CHECK(wx.fast_path_kind == "weather");
    bool saw_surface = false;
    for (std::size_t i = surfaces_before; i < sink_repair.events.size(); ++i) {
      if (sink_repair.events[i].first == "surface") saw_surface = true;
    }
    CHECK(saw_surface);
    CHECK(arbiter_repair->last_message.find("Mild.") == std::string::npos);

    seed("dev-ambiguous", "light_on", "turn on the kitchen lights", "On.");
    const auto ambiguous = pipe_repair.run_text_utterance(
        "dev-ambiguous", "the other one", sink_repair);
    CHECK(ambiguous.ok);
    CHECK(!ambiguous.used_fast_path);
    CHECK(arbiter_repair->last_message.find("the other one") != std::string::npos);
    CHECK(arbiter_repair->last_message.find("turn on the kitchen lights") !=
          std::string::npos);
    CHECK(arbiter_repair->last_message.find("never quote") != std::string::npos);

    ha.stop();
    if (ha_thread.joinable()) ha_thread.join();
    std::filesystem::remove(db_repair);
  }

  {
    auto tts_other = std::make_shared<RecordingTts>();
    auto arbiter_other = std::make_shared<StreamingArbiter>(tts_other);
    auto stt_other = std::make_shared<DummyStt>();
    const auto db_other =
        std::filesystem::temp_directory_path() / "intercom_repair_other.db";
    std::filesystem::remove(db_other);
    auto sessions_other =
        std::make_shared<intercom::SessionStore>(db_other.string());
    CHECK(sessions_other->open(&err));
    std::string other_entity;
    httplib::Server ha_other;
    ha_other.Post("/api/services/light/turn_on",
                  [&](const httplib::Request& req, httplib::Response& res) {
                    try {
                      other_entity =
                          nlohmann::json::parse(req.body).value("entity_id", "");
                    } catch (...) {
                      other_entity.clear();
                    }
                    res.set_content("[]", "application/json");
                  });
    ha_other.Post("/api/services/media_player/volume_down",
                  [](const httplib::Request&, httplib::Response& res) {
                    res.set_content("[]", "application/json");
                  });
    const int port = ha_other.bind_to_any_port("127.0.0.1");
    CHECK(port > 0);
    std::thread ha_thread([&ha_other] { ha_other.listen_after_bind(); });
    for (int i = 0; i < 50 && !ha_other.is_running(); ++i) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    intercom::Config cfg_other;
    cfg_other.fast_path = true;
    cfg_other.filler.enabled = false;
    cfg_other.home.ha_base_url = "http://127.0.0.1:" + std::to_string(port);
    cfg_other.home.ha_token = "test";
    cfg_other.home.lights["bedroom"] = "light.bedroom";
    cfg_other.home.lights["kitchen"] = "light.kitchen";
    cfg_other.home.media_player = "media_player.house";
    intercom::TurnPipeline pipe_other(
        cfg_other, stt_other, tts_other, arbiter_other, sessions_other, nullptr);
    CollectingSink sink_other;
    intercom::DeviceSession light;
    light.device_id = "dev-pair";
    light.conversation_id = 42;
    light.last_user = "turn on the kitchen lights";
    light.last_spoken = "On.";
    light.last_fast_path_kind = "light_on";
    light.last_fast_path_request = "turn on the kitchen lights";
    CHECK(sessions_other->upsert(light, &err));
    const auto other = pipe_other.run_text_utterance(
        "dev-pair", "not that one", sink_other);
    CHECK(other.ok);
    CHECK(other.used_fast_path);
    CHECK(other.fast_path_kind == "light_on");
    CHECK(other_entity == "light.bedroom");
    CHECK(arbiter_other->last_message.empty());

    intercom::DeviceSession volume;
    volume.device_id = "dev-vol";
    volume.conversation_id = 42;
    volume.last_user = "turn the volume up";
    volume.last_spoken = "Louder.";
    volume.last_fast_path_kind = "volume_up";
    volume.last_fast_path_request = "turn the volume up";
    CHECK(sessions_other->upsert(volume, &err));
    const auto quieter = pipe_other.run_text_utterance(
        "dev-vol", "the other one", sink_other);
    CHECK(quieter.ok);
    CHECK(quieter.used_fast_path);
    CHECK(quieter.fast_path_kind == "volume_down");
    const auto quieter_said = tts_other->snapshot();
    CHECK(!quieter_said.empty());
    if (!quieter_said.empty()) {
      CHECK(quieter_said.back().find("uieter") != std::string::npos);
    }

    ha_other.stop();
    if (ha_thread.joinable()) ha_thread.join();
    std::filesystem::remove(db_other);
  }

  {
    auto tts_brief = std::make_shared<RecordingTts>();
    auto arbiter_brief = std::make_shared<StreamingArbiter>(tts_brief);
    auto stt_brief = std::make_shared<DummyStt>();
    const auto db_brief =
        std::filesystem::temp_directory_path() / "intercom_briefing_fail.db";
    std::filesystem::remove(db_brief);
    auto sessions_brief =
        std::make_shared<intercom::SessionStore>(db_brief.string());
    CHECK(sessions_brief->open(&err));
    intercom::Config cfg_brief;
    cfg_brief.fast_path = true;
    cfg_brief.filler.enabled = false;
    cfg_brief.news.google_news_rss = "http://127.0.0.1:9/rss";
    cfg_brief.news.timeout_ms = 400;
    cfg_brief.markets.quote_base = "http://127.0.0.1:9";
    cfg_brief.markets.timeout_ms = 400;
    cfg_brief.weather.geocode_base = "http://127.0.0.1:9";
    cfg_brief.weather.forecast_base = "http://127.0.0.1:9";
    cfg_brief.weather.timeout_ms = 400;
    cfg_brief.weather.default_place = "London";
    intercom::TurnPipeline pipe_brief(
        cfg_brief, stt_brief, tts_brief, arbiter_brief, sessions_brief, nullptr);
    CollectingSink sink_brief;

    auto expect_local_brief = [&](const std::string& device, const std::string& phrase) {
      const auto before = tts_brief->snapshot().size();
      const auto turn = pipe_brief.run_text_utterance(device, phrase, sink_brief);
      CHECK(turn.ok);
      CHECK(turn.used_fast_path);
      CHECK(turn.fast_path_kind == "briefing");
      const auto said = tts_brief->snapshot();
      CHECK(said.size() >= before + 4);
      bool clock = false;
      bool weather_gap = false;
      bool news_gap = false;
      bool market_gap = false;
      for (std::size_t i = before; i < said.size(); ++i) {
        if (said[i].find("It's ") == 0) clock = true;
        if (said[i].find("No weather") != std::string::npos) weather_gap = true;
        if (said[i].find("No headlines") != std::string::npos) news_gap = true;
        if (said[i].find("No market") != std::string::npos) market_gap = true;
      }
      CHECK(clock);
      CHECK(weather_gap);
      CHECK(news_gap);
      CHECK(market_gap);
      const auto saved = sessions_brief->get(device);
      CHECK(saved.has_value());
      if (saved) {
        CHECK(saved->last_fast_path_kind == "briefing");
        CHECK(saved->last_spoken.find("It's ") != std::string::npos);
      }
    };
    expect_local_brief("dev-brief", "brief me");
    expect_local_brief("dev-morning", "morning briefing");
    expect_local_brief("dev-whats", "what's the briefing");
    CHECK(arbiter_brief->last_message.empty());

    const auto news_only = pipe_brief.run_text_utterance(
        "dev-news-only", "what's in the news", sink_brief);
    CHECK(news_only.ok);
    CHECK(!news_only.used_fast_path);
    CHECK(arbiter_brief->last_message == "what's in the news");

    const auto topical = pipe_brief.run_text_utterance(
        "dev-topical", "brief me on the harbour", sink_brief);
    CHECK(topical.ok);
    CHECK(!topical.used_fast_path);
    CHECK(arbiter_brief->last_message == "brief me on the harbour");
    std::filesystem::remove(db_brief);
  }

  {
    const char* rss = R"(<?xml version="1.0"?>
<rss><channel><item>
  <title>Harbour lights</title>
  <link>https://example.com/harbour</link>
  <description>The harbour authority switched the navigation lights back on after the storm.</description>
</item></channel></rss>)";
    const char* quotes = R"({
      "quoteResponse": {"result": [{
        "symbol": "^GSPC",
        "shortName": "S&P 500",
        "regularMarketPrice": 5700,
        "regularMarketChange": 12,
        "regularMarketChangePercent": 0.2,
        "currency": "USD"
      }]}
    })";
    httplib::Server brief;
    brief.Get("/rss", [rss](const httplib::Request&, httplib::Response& res) {
      res.set_content(rss, "application/rss+xml");
    });
    brief.Get("/v7/finance/quote", [quotes](const httplib::Request&, httplib::Response& res) {
      res.set_content(quotes, "application/json");
    });
    brief.Get("/v1/search", [](const httplib::Request&, httplib::Response& res) {
      res.set_content(
          R"({"results":[{"name":"London","country":"United Kingdom","latitude":51.5,"longitude":-0.12}]})",
          "application/json");
    });
    brief.Get("/v1/forecast", [](const httplib::Request&, httplib::Response& res) {
      res.set_content(R"({
        "current": {
          "time": "2026-09-22T15:00",
          "temperature_2m": 14,
          "weather_code": 3,
          "is_day": 1
        },
        "current_units": {"temperature_2m": "°C"},
        "hourly": {"time": ["2026-09-22T15:00"], "temperature_2m": [14], "weather_code": [3]},
        "daily": {
          "time": ["2026-09-22"],
          "weather_code": [3],
          "temperature_2m_max": [16],
          "temperature_2m_min": [9]
        }
      })",
                      "application/json");
    });
    const int port = brief.bind_to_any_port("127.0.0.1");
    CHECK(port > 0);
    std::thread brief_thread([&brief] { brief.listen_after_bind(); });
    for (int i = 0; i < 50 && !brief.is_running(); ++i) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    const std::string base = "http://127.0.0.1:" + std::to_string(port);

    auto tts_cards = std::make_shared<RecordingTts>();
    auto arbiter_cards = std::make_shared<StreamingArbiter>(tts_cards);
    auto stt_cards = std::make_shared<DummyStt>();
    const auto db_cards =
        std::filesystem::temp_directory_path() / "intercom_briefing_cards.db";
    std::filesystem::remove(db_cards);
    auto sessions_cards =
        std::make_shared<intercom::SessionStore>(db_cards.string());
    CHECK(sessions_cards->open(&err));
    intercom::Config cfg_cards;
    cfg_cards.fast_path = true;
    cfg_cards.filler.enabled = false;
    cfg_cards.news.google_news_rss = base + "/rss";
    cfg_cards.news.timeout_ms = 800;
    cfg_cards.markets.quote_base = base;
    cfg_cards.markets.timeout_ms = 800;
    cfg_cards.weather.geocode_base = base;
    cfg_cards.weather.forecast_base = base;
    cfg_cards.weather.timeout_ms = 800;
    cfg_cards.weather.default_place = "London";
    intercom::TurnPipeline pipe_cards(
        cfg_cards, stt_cards, tts_cards, arbiter_cards, sessions_cards, nullptr);
    CollectingSink sink_cards;
    const auto turn = pipe_cards.run_text_utterance(
        "dev-cards", "brief me", sink_cards);
    CHECK(turn.ok);
    CHECK(turn.used_fast_path);
    CHECK(turn.fast_path_kind == "briefing");
    CHECK(arbiter_cards->last_message.empty());
    bool weather_card = false;
    bool news_card = false;
    bool market_card = false;
    for (const auto& event : sink_cards.events) {
      if (event.first != "surface") continue;
      if (event.second.find("\"weather\"") != std::string::npos) weather_card = true;
      if (event.second.find("\"news\"") != std::string::npos) news_card = true;
      if (event.second.find("\"markets\"") != std::string::npos) market_card = true;
    }
    CHECK(weather_card);
    CHECK(news_card);
    CHECK(market_card);
    const auto kept_cards = sessions_cards->get("dev-cards");
    CHECK(kept_cards.has_value());
    if (kept_cards) {
      CHECK(kept_cards->last_card.find("Harbour lights") != std::string::npos);
      CHECK(kept_cards->last_card.find("navigation lights back on") !=
            std::string::npos);
    }
    const auto said = tts_cards->snapshot();
    CHECK(said.size() >= 4);
    if (!said.empty()) CHECK(said.front().find("It's ") == 0);
    bool headlines = false;
    for (const auto& line : said) {
      if (line.find("headlines") != std::string::npos) headlines = true;
      CHECK(line.find("sir") == std::string::npos);
    }
    CHECK(headlines);

    brief.stop();
    if (brief_thread.joinable()) brief_thread.join();
    std::filesystem::remove(db_cards);
  }

  {
    auto tts_card = std::make_shared<RecordingTts>();
    auto arbiter_card = std::make_shared<StreamingArbiter>(tts_card);
    auto stt_card = std::make_shared<DummyStt>();
    const auto db_card =
        std::filesystem::temp_directory_path() / "intercom_card_reference.db";
    std::filesystem::remove(db_card);
    auto sessions_card = std::make_shared<intercom::SessionStore>(db_card.string());
    CHECK(sessions_card->open(&err));
    intercom::Config cfg_card;
    cfg_card.fast_path = true;
    cfg_card.filler.enabled = false;
    intercom::TurnPipeline pipe_card(
        cfg_card, stt_card, tts_card, arbiter_card, sessions_card, nullptr);
    CollectingSink sink_card;
    const std::string card_json =
        "{\"active\":\"news\",\"news\":["
        "{\"label\":\"Fed holds rates\",\"detail\":\"Reuters\"},"
        "{\"label\":\"Markets rally\",\"detail\":\"BBC\"}"
        "],\"markets\":["
        "{\"label\":\"Apple\",\"detail\":\"one hundred ninety two, up two percent\"},"
        "{\"label\":\"Microsoft\",\"detail\":\"four hundred, down one percent\"}"
        "]}";
    intercom::DeviceSession seeded;
    seeded.device_id = "dev-card";
    seeded.conversation_id = 42;
    seeded.last_user = "what's in the news";
    seeded.last_spoken = "Here are the top headlines.";
    seeded.last_fast_path_kind = "news";
    seeded.last_card = card_json;
    CHECK(sessions_card->upsert(seeded, &err));

    const auto second = pipe_card.run_text_utterance(
        "dev-card", "the second one", sink_card);
    CHECK(second.ok);
    CHECK(second.used_fast_path);
    CHECK(second.fast_path_kind == "card");
    const auto second_text = tts_card->snapshot();
    CHECK(!second_text.empty());
    if (!second_text.empty()) {
      CHECK(second_text.back() ==
            "The second headline is Markets rally, from BBC.");
    }

    const auto quote = pipe_card.run_text_utterance(
        "dev-card", "the second quote", sink_card);
    CHECK(quote.ok);
    CHECK(quote.used_fast_path);
    const auto quote_text = tts_card->snapshot();
    CHECK(!quote_text.empty());
    if (!quote_text.empty()) {
      CHECK(quote_text.back() ==
            "Microsoft is four hundred, down one percent.");
    }

    const auto missing = pipe_card.run_text_utterance(
        "dev-card", "the fifth headline", sink_card);
    CHECK(missing.ok);
    CHECK(missing.used_fast_path);
    const auto missing_text = tts_card->snapshot();
    CHECK(!missing_text.empty());
    if (!missing_text.empty()) {
      CHECK(missing_text.back() == "There isn't a fifth headline.");
    }

    const auto clock = pipe_card.run_text_utterance(
        "dev-card", "what time is it", sink_card);
    CHECK(clock.ok);
    CHECK(clock.used_fast_path);
    const auto kept = sessions_card->get("dev-card");
    CHECK(kept.has_value());
    if (kept) {
      CHECK(kept->last_card.find("Fed holds rates") != std::string::npos);
      CHECK(kept->last_card.find("Microsoft") != std::string::npos);
    }

    const auto joke = pipe_card.run_text_utterance(
        "dev-card", "tell me a joke", sink_card);
    CHECK(joke.ok);
    CHECK(!joke.used_fast_path);
    CHECK(arbiter_card->last_message == "tell me a joke");
    std::filesystem::remove(db_card);
  }

  {
    auto tts_deep = std::make_shared<RecordingTts>();
    auto arbiter_deep = std::make_shared<StreamingArbiter>(tts_deep);
    auto stt_deep = std::make_shared<DummyStt>();
    const auto db_deep =
        std::filesystem::temp_directory_path() / "intercom_card_depth.db";
    std::filesystem::remove(db_deep);
    auto sessions_deep = std::make_shared<intercom::SessionStore>(db_deep.string());
    CHECK(sessions_deep->open(&err));
    intercom::Config cfg_deep;
    cfg_deep.fast_path = true;
    cfg_deep.filler.enabled = false;
    intercom::TurnPipeline pipe_deep(
        cfg_deep, stt_deep, tts_deep, arbiter_deep, sessions_deep, nullptr);
    CollectingSink sink_deep;
    const std::string deep_json =
        "{\"active\":\"news\",\"news\":["
        "{\"label\":\"Fed holds rates\",\"detail\":\"Reuters\","
        "\"summary\":\"The Federal Reserve left rates unchanged and signalled patience.\"},"
        "{\"label\":\"Markets rally\",\"detail\":\"BBC\","
        "\"summary\":\"Shares rose into the close after a quiet morning.\"},"
        "{\"label\":\"Port strike ends\",\"detail\":\"AP\","
        "\"summary\":\"Dock workers agreed a new contract overnight.\"},"
        "{\"label\":\"Oil slips\",\"detail\":\"FT\","
        "\"summary\":\"Crude fell on a surprise stockpile build.\"},"
        "{\"label\":\"Chip demand\",\"detail\":\"Nikkei\","
        "\"summary\":\"Orders for factory tools stayed strong through the quarter.\"}"
        "],\"markets\":["
        "{\"label\":\"Apple\",\"detail\":\"one hundred ninety two, up two percent\"},"
        "{\"label\":\"Microsoft\",\"detail\":\"four hundred, down one percent\"}"
        "]}";
    intercom::DeviceSession seeded_deep;
    seeded_deep.device_id = "dev-deep";
    seeded_deep.conversation_id = 42;
    seeded_deep.last_user = "what's in the news";
    seeded_deep.last_spoken = "Here are the top headlines.";
    seeded_deep.last_fast_path_kind = "news";
    seeded_deep.last_card = deep_json;
    CHECK(sessions_deep->upsert(seeded_deep, &err));

    const auto pointed = pipe_deep.run_text_utterance(
        "dev-deep", "the second one", sink_deep);
    CHECK(pointed.ok);
    CHECK(pointed.used_fast_path);
    const auto pointed_text = tts_deep->snapshot();
    CHECK(!pointed_text.empty());
    if (!pointed_text.empty()) {
      CHECK(pointed_text.back() ==
            "The second headline is Markets rally, from BBC.");
    }

    const auto more = pipe_deep.run_text_utterance(
        "dev-deep", "tell me more", sink_deep);
    CHECK(more.ok);
    CHECK(more.used_fast_path);
    const auto more_text = tts_deep->snapshot();
    CHECK(!more_text.empty());
    if (!more_text.empty()) {
      CHECK(more_text.back().find(
                "Shares rose into the close after a quiet morning.") !=
            std::string::npos);
    }
    CHECK(arbiter_deep->last_message.empty());

    const auto deeper = pipe_deep.run_text_utterance("dev-deep", "go on", sink_deep);
    CHECK(deeper.ok);
    CHECK(!deeper.used_fast_path);
    CHECK(arbiter_deep->last_message.find("CARD CONTEXT") != std::string::npos);
    CHECK(arbiter_deep->last_message.find("Markets rally") != std::string::npos);
    CHECK(arbiter_deep->last_message.find(
              "Shares rose into the close after a quiet morning.") !=
          std::string::npos);
    CHECK(arbiter_deep->last_message.find("Go further") != std::string::npos);
    CHECK(arbiter_deep->last_message.find("[CURRENT USER REQUEST]\ngo on") !=
          std::string::npos);

    const auto named = pipe_deep.run_text_utterance(
        "dev-deep", "the one about the fed", sink_deep);
    CHECK(named.ok);
    CHECK(named.used_fast_path);
    const auto named_text = tts_deep->snapshot();
    CHECK(!named_text.empty());
    if (!named_text.empty()) {
      CHECK(named_text.back() ==
            "The first headline is Fed holds rates, from Reuters.");
    }

    const auto rest = pipe_deep.run_text_utterance("dev-deep", "what else", sink_deep);
    CHECK(rest.ok);
    CHECK(rest.used_fast_path);
    const auto rest_text = tts_deep->snapshot();
    CHECK(!rest_text.empty());
    if (!rest_text.empty()) {
      CHECK(rest_text.back().find("The fourth headline is Oil slips, from FT.") !=
            std::string::npos);
      CHECK(rest_text.back().find(
                "The fifth headline is Chip demand, from Nikkei.") !=
            std::string::npos);
    }

    const auto done = pipe_deep.run_text_utterance("dev-deep", "what else", sink_deep);
    CHECK(done.ok);
    CHECK(done.used_fast_path);
    const auto done_text = tts_deep->snapshot();
    CHECK(!done_text.empty());
    if (!done_text.empty()) CHECK(done_text.back() == "That is the list.");

    const auto quote_more = pipe_deep.run_text_utterance(
        "dev-deep", "more on the second quote", sink_deep);
    CHECK(quote_more.ok);
    CHECK(!quote_more.used_fast_path);
    CHECK(arbiter_deep->last_message.find("Microsoft") != std::string::npos);
    CHECK(arbiter_deep->last_message.find("four hundred, down one percent") !=
          std::string::npos);
    CHECK(arbiter_deep->last_message.find("CARD CONTEXT") != std::string::npos);

    const auto aside = pipe_deep.run_text_utterance(
        "dev-deep", "tell me a joke", sink_deep);
    CHECK(aside.ok);
    CHECK(!aside.used_fast_path);
    CHECK(arbiter_deep->last_message == "tell me a joke");
    std::filesystem::remove(db_deep);
  }

  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_sentence_tts ok\n";
  return 0;
}

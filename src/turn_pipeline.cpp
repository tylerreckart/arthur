#include "intercom/turn_pipeline.hpp"
#include "intercom/home_client.hpp"
#include "intercom/speakable.hpp"
#include "intercom/util.hpp"
#include "intercom/warm.hpp"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <future>
#include <iostream>
#include <optional>
#include <set>
#include <string_view>
#include <thread>
#include <vector>

namespace intercom {
namespace {

std::int64_t now_unix() {
  return std::chrono::duration_cast<std::chrono::seconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

void sleep_ms(int ms) {
  if (ms <= 0) return;
  std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

struct ArbiterRunState {
  std::atomic<bool> got_first_delta{false};
  std::atomic<bool> started_answer{false};
  std::atomic<bool> saw_tool{false};
  std::atomic<int> tool_started_ms{-1};
  std::atomic<bool> done{false};
  bool streamed = false;
  bool done_ok = false;
  std::string done_err;
  std::string full_content;
  std::string stream_err;
  std::string speak_buf;
  std::string tool_name;
  int last_forming_ms = -1000;
  std::mutex speak_mu;
};

std::size_t non_space_count(std::string_view s) {
  std::size_t n = 0;
  for (char c : s) {
    if (!std::isspace(static_cast<unsigned char>(c))) ++n;
  }
  return n;
}

std::size_t early_flush_words(const Config& config) {
  return config.early_flush_words > 0
             ? static_cast<std::size_t>(config.early_flush_words)
             : 0;
}

}  // namespace

TurnPipeline::TurnPipeline(Config config,
                           std::shared_ptr<SttProvider> stt,
                           std::shared_ptr<TtsProvider> tts,
                           std::shared_ptr<ArbiterClient> arbiter,
                           std::shared_ptr<SessionStore> sessions,
                           std::shared_ptr<FillerClient> filler)
    : config_(std::move(config)),
      stt_(std::move(stt)),
      tts_(std::move(tts)),
      arbiter_(std::move(arbiter)),
      sessions_(std::move(sessions)),
      filler_(std::move(filler)),
      fast_path_(config_.fast_path, config_.home,
                 std::make_shared<HomeClient>(config_.home)) {}

void TurnPipeline::register_turn(std::shared_ptr<TurnHandle> h) {
  std::lock_guard<std::mutex> lk(turns_mu_);
  turns_[h->turn_id] = std::move(h);
}

void TurnPipeline::unregister_turn(const std::string& turn_id) {
  std::lock_guard<std::mutex> lk(turns_mu_);
  turns_.erase(turn_id);
}

std::shared_ptr<TurnHandle> TurnPipeline::find_turn(const std::string& turn_id) {
  std::lock_guard<std::mutex> lk(turns_mu_);
  auto it = turns_.find(turn_id);
  if (it == turns_.end()) return nullptr;
  return it->second;
}

std::optional<DeviceSession> TurnPipeline::session_for(const std::string& device_id) const {
  return sessions_->get(device_id);
}

void TurnPipeline::warm_prefix() {
  if (!config_.warm_prefix) return;

  std::set<std::string> ids;
  for (const auto& kv : config_.devices) {
    if (!kv.first.empty()) ids.insert(kv.first);
  }
  for (const auto& s : sessions_->list()) {
    if (!s.device_id.empty()) ids.insert(s.device_id);
  }
  if (ids.empty()) ids.insert("intercom-host");

  int ok = 0;
  int total = 0;
  for (const auto& id : ids) {
    ++total;
    std::string err;
    const auto conv = ensure_conversation(id, &err);
    if (conv <= 0) {
      std::cerr << "intercom warm: " << id << ": "
                << (err.empty() ? "no conversation" : err) << std::endl;
      continue;
    }
    std::atomic<bool> cancel{false};
    const std::string key = "warm-" + id + "-" + make_turn_id();
    if (!arbiter_->send_message(conv, kPrefixWarmMessage, key, ArbiterStreamCallbacks{},
                                &cancel, &err)) {
      std::cerr << "intercom warm: " << id << ": "
                << (err.empty() ? "send failed" : err) << std::endl;
      continue;
    }
    ++ok;
  }
  std::cout << "intercom warm: " << ok << "/" << total << std::endl;
}

std::int64_t TurnPipeline::ensure_conversation(const std::string& device_id, std::string* err) {
  if (auto existing = sessions_->get(device_id)) {
    if (existing->conversation_id > 0) {
      return existing->conversation_id;
    }
  }
  auto id = arbiter_->create_conversation("intercom:" + device_id, err);
  if (!id || *id <= 0) {
    if (err && err->empty()) *err = "conversation create failed";
    return 0;
  }
  DeviceSession s;
  s.device_id = device_id;
  s.conversation_id = *id;
  s.updated_at = now_unix();
  if (!sessions_->upsert(s, err)) return 0;
  return *id;
}

bool TurnPipeline::cancel_turn(const std::string& turn_id, std::string* err) {
  auto h = find_turn(turn_id);
  if (!h) {
    if (err) *err = "turn not found";
    return false;
  }
  h->cancel.store(true);
  std::string rid;
  {
    std::lock_guard<std::mutex> lk(h->mu);
    rid = h->arbiter_request_id;
  }
  if (!rid.empty()) {
    return arbiter_->cancel_request(rid, err);
  }
  return true;
}

TurnResult TurnPipeline::run_utterance(const std::string& device_id,
                                       const std::vector<std::uint8_t>& pcm,
                                       int sample_rate,
                                       int channels,
                                       AudioSink& sink,
                                       std::string turn_id) {
  std::string err;
  const auto stt_t0 = std::chrono::steady_clock::now();
  const std::string transcript = stt_->transcribe(pcm, sample_rate, channels, &err);
  const int stt_ms = static_cast<int>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - stt_t0)
          .count());
  if (turn_id.empty()) turn_id = make_turn_id();
  if (transcript.empty()) {
    TurnResult result;
    result.turn_id = std::move(turn_id);
    result.error = err.empty() ? "stt failed" : err;
    std::cerr << "intercom latency turn=" << result.turn_id << " stt_ms=" << stt_ms
              << " error=" << result.error << std::endl;
    return result;
  }
  return run_text_utterance(device_id, transcript, sink, std::move(turn_id), stt_ms);
}

TurnResult TurnPipeline::run_text_utterance(const std::string& device_id,
                                            const std::string& transcript,
                                            AudioSink& sink,
                                            std::string turn_id,
                                            int stt_ms) {
  TurnResult result;
  result.turn_id = turn_id.empty() ? make_turn_id() : std::move(turn_id);
  result.transcript = transcript;
  if (!transcript.empty()) {
    // Desk clients need the user line before Arbiter / TTS so voice turns
    // cluster like typed ones. Whisper is still one-shot at `end`.
    sink.event("heard", transcript);
  }
  auto handle = std::make_shared<TurnHandle>();
  handle->turn_id = result.turn_id;
  register_turn(handle);

  const auto turn_start = std::chrono::steady_clock::now();
  int ttfa_ms = -1;
  int kokoro_first_ms = -1;
  int kokoro_total_ms = 0;
  int conv_ms = -1;
  int first_sentence_ms = -1;
  int first_answer_ms = -1;
  std::atomic<int> arbiter_ttft_ms{-1};
  const char* ttfa_kind = "";
  const char* pending_kind = "answer";
  const char* path_name = "arbiter";

  auto elapsed_now = [&]() -> int {
    return static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::steady_clock::now() - turn_start)
                                .count());
  };

  auto finish = [&](TurnResult r) {
    unregister_turn(result.turn_id);
    std::cerr << "intercom latency turn=" << result.turn_id << " path=" << path_name
              << " stt_ms=" << stt_ms << " conv_ms=" << conv_ms
              << " arbiter_ttft_ms=" << arbiter_ttft_ms.load()
              << " first_sentence_ms=" << first_sentence_ms
              << " kokoro_ms=" << kokoro_first_ms << " kokoro_total_ms=" << kokoro_total_ms
              << " ttfa_ms=" << ttfa_ms << " ttfa_kind=" << (ttfa_kind[0] ? ttfa_kind : "-")
              << " first_answer_ms=" << first_answer_ms;
    if (!r.error.empty()) std::cerr << " error=" << r.error;
    std::cerr << std::endl;
    return r;
  };

  if (handle->cancel.load()) {
    result.error = "canceled";
    return finish(result);
  }

  std::string err;
  auto speak = [&](const std::string& text) -> bool {
    const std::string spoken = to_speakable(text);
    if (spoken.empty()) return true;
    sink.event("said", spoken);
    const auto t0 = std::chrono::steady_clock::now();
    const bool ok = tts_->synthesize(
        spoken,
        [&](const std::uint8_t* data, std::size_t len) {
          if (handle->cancel.load()) return false;
          if (ttfa_ms < 0) {
            ttfa_ms = elapsed_now();
            ttfa_kind = pending_kind;
          }
          return sink.write(data, len);
        },
        &err);
    const int dt = static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                        std::chrono::steady_clock::now() - t0)
                                        .count());
    if (kokoro_first_ms < 0) kokoro_first_ms = dt;
    kokoro_total_ms += dt;
    return ok;
  };

  if (auto fp = fast_path_.try_handle(result.transcript)) {
    result.used_fast_path = true;
    result.fast_path_kind = fp->kind;
    path_name = "fast";
    pending_kind = "fast";
    if (auto existing = sessions_->get(device_id)) {
      result.conversation_id = existing->conversation_id;
    }
    if (!speak(fp->reply)) {
      result.error = err.empty() ? "tts failed" : err;
      return finish(result);
    }
    result.ok = true;
    if (result.conversation_id > 0) {
      DeviceSession s;
      s.device_id = device_id;
      s.conversation_id = result.conversation_id;
      s.last_turn_id = result.turn_id;
      s.updated_at = now_unix();
      sessions_->upsert(s, &err);
    }
    return finish(result);
  }

  const bool filler_enabled =
      filler_ && config_.filler.enabled &&
      !withholds_fillers(result.transcript);

  std::future<std::string> initial_filler_future;
  if (filler_enabled && config_.filler.instant_ack_ms <= 0) {
    initial_filler_future = std::async(std::launch::async, [&, transcript]() {
      std::string filler_err;
      const std::string phrase = filler_->generate(
          transcript, FillerStage::Initial, "", &handle->cancel, &filler_err);
      if (!filler_err.empty()) {
        std::cerr << "intercom filler: " << filler_err << std::endl;
      } else if (!phrase.empty()) {
        std::cerr << "intercom filler: generated \"" << phrase << "\"" << std::endl;
      } else if (!handle->cancel.load()) {
        std::cerr << "intercom filler: empty phrase" << std::endl;
      }
      return phrase;
    });
  }

  std::string conv_err;
  auto conv_future = std::async(std::launch::async, [&]() {
    return ensure_conversation(device_id, &conv_err);
  });

  const std::int64_t conv = conv_future.get();
  conv_ms = elapsed_now();
  if (conv == 0) {
    result.error = conv_err.empty() ? "conversation create failed" : conv_err;
    return finish(result);
  }
  result.conversation_id = conv;
  sink.event("status", "thinking");

  ArbiterRunState arb_state;
  std::string spoken_filler;
  bool instant_spoken = false;
  bool contextual_spoken = false;
  int followups_spoken = 0;
  std::optional<std::chrono::steady_clock::time_point> next_followup_at;
  std::future<std::string> followup_future;

  ArbiterStreamCallbacks cbs;
  cbs.on_request_id = [&](const std::string& rid) {
    std::lock_guard<std::mutex> lk(handle->mu);
    handle->arbiter_request_id = rid;
  };
  cbs.on_text_delta = [&](const std::string& delta) {
    if (handle->cancel.load()) return;
    if (!arb_state.got_first_delta.load()) {
      arbiter_ttft_ms.store(elapsed_now());
    }
    arb_state.got_first_delta.store(true);
    std::lock_guard<std::mutex> lk(arb_state.speak_mu);
    arb_state.speak_buf += delta;
    const int now_ms = elapsed_now();
    if (now_ms - arb_state.last_forming_ms >= 80) {
      arb_state.last_forming_ms = now_ms;
      // After the first `said`, speak_buf is the unspoken remainder — send
      // the prefix so the Mac can stitch it onto the last bubble. Before
      // that, the latest tokens are a better "writing" preview.
      std::string preview = arb_state.speak_buf;
      constexpr std::size_t kFormingCap = 400;
      if (preview.size() > kFormingCap) {
        if (arb_state.started_answer.load()) {
          preview = preview.substr(0, kFormingCap);
        } else {
          preview = preview.substr(preview.size() - kFormingCap);
        }
      }
      sink.event("forming", preview);
    }
  };
  cbs.on_tool_call = [&](const std::string& tool) {
    {
      std::lock_guard<std::mutex> lk(arb_state.speak_mu);
      arb_state.tool_name = tool;
    }
    arb_state.tool_started_ms.store(elapsed_now());
    arb_state.saw_tool.store(true);
    sink.event("working", tool);
  };
  cbs.on_done = [&](bool ok, const std::string& content, const std::string& error) {
    arb_state.done_ok = ok;
    arb_state.full_content = content;
    arb_state.done_err = error;
    arb_state.done.store(true);
  };

  auto arbiter_future = std::async(std::launch::async, [&]() {
    std::string stream_err;
    const bool streamed = arbiter_->send_message(
        conv, result.transcript, result.turn_id, cbs, &handle->cancel, &stream_err);
    arb_state.streamed = streamed;
    arb_state.stream_err = std::move(stream_err);
    arb_state.done.store(true);
    return streamed;
  });

  auto sentence_ready = [&]() -> bool {
    std::lock_guard<std::mutex> lk(arb_state.speak_mu);
    std::string copy = arb_state.speak_buf;
    return !flush_sentences(copy, false, early_flush_words(config_)).empty();
  };

  // Drain completed sentences (and ~N-word prefixes) from speak_buf.
  // Spoken sentences are not re-spoken on done: final_flush only emits the
  // leftover tail, and full_content is a fallback when nothing was spoken.
  auto drain_and_speak = [&](bool final_flush) -> bool {
    std::vector<std::string> sentences;
    {
      std::lock_guard<std::mutex> lk(arb_state.speak_mu);
      sentences = flush_sentences(arb_state.speak_buf, final_flush,
                                  early_flush_words(config_));
    }
    for (const auto& raw : coalesce_speech_sentences(sentences)) {
      if (handle->cancel.load()) return false;
      if (non_space_count(raw) < 3) continue;
      if (first_sentence_ms < 0) first_sentence_ms = elapsed_now();
      pending_kind = "answer";
      if (!speak(raw)) return false;
      if (first_answer_ms < 0) first_answer_ms = elapsed_now();
      arb_state.started_answer.store(true);
    }
    return true;
  };

  auto maybe_speak_filler = [&](const std::string& phrase, bool is_instant = false) -> bool {
    if (phrase.empty() || handle->cancel.load() || arb_state.done.load()) {
      return true;
    }
    if (arb_state.started_answer.load()) return true;
    if (arb_state.got_first_delta.load() && sentence_ready()) return true;
    if (!is_instant && phrase == spoken_filler) return true;
    std::cerr << "intercom filler: speaking \"" << phrase << "\"" << std::endl;
    spoken_filler = phrase;
    pending_kind = is_instant ? "ack" : "filler";
    if (config_.filler.max_followups > 0) {
      next_followup_at = std::chrono::steady_clock::now() +
                         std::chrono::milliseconds(config_.filler.followup_silence_ms);
    }
    const bool ok = speak(phrase);
    pending_kind = "answer";
    return ok;
  };

  while (!arb_state.done.load()) {
    if (handle->cancel.load()) break;

    if (arb_state.got_first_delta.load()) {
      if (!drain_and_speak(false)) {
        result.error = err.empty() ? "tts failed" : err;
        handle->cancel.store(true);
        break;
      }
    }

    const bool hold_local_ack =
        arb_state.got_first_delta.load() || arb_state.started_answer.load();
    const bool hold_llm_fillers =
        hold_local_ack || !arb_state.saw_tool.load();

    const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::steady_clock::now() - turn_start)
                                .count();

    const int tool_started_ms = arb_state.tool_started_ms.load();
    if (filler_enabled && !hold_local_ack && !instant_spoken && spoken_filler.empty() &&
        tool_started_ms >= 0 &&
        elapsed_ms - tool_started_ms >= std::max(0, config_.filler.tool_ack_ms)) {
      instant_spoken = true;
      std::string tool_name;
      {
        std::lock_guard<std::mutex> lk(arb_state.speak_mu);
        tool_name = arb_state.tool_name;
      }
      if (!maybe_speak_filler(FillerClient::tool_ack(tool_name), true)) {
        result.error = err.empty() ? "tts failed" : err;
        handle->cancel.store(true);
        break;
      }
    }

    if (filler_enabled && !hold_local_ack && !instant_spoken && spoken_filler.empty() &&
        config_.filler.instant_ack_ms > 0 &&
        elapsed_ms >= config_.filler.instant_ack_ms) {
      instant_spoken = true;
      if (!maybe_speak_filler(FillerClient::instant_ack(), true)) {
        result.error = err.empty() ? "tts failed" : err;
        handle->cancel.store(true);
        break;
      }
    }

    if (!hold_llm_fillers && filler_enabled && !contextual_spoken &&
        !instant_spoken && initial_filler_future.valid() &&
        elapsed_ms >= config_.filler.min_silence_ms &&
        initial_filler_future.wait_for(std::chrono::milliseconds(0)) ==
            std::future_status::ready) {
      contextual_spoken = true;
      if (!maybe_speak_filler(initial_filler_future.get())) {
        result.error = err.empty() ? "tts failed" : err;
        handle->cancel.store(true);
        break;
      }
    }

    if (!hold_llm_fillers && filler_enabled && !arb_state.saw_tool.load() && next_followup_at &&
        followups_spoken < config_.filler.max_followups &&
        std::chrono::steady_clock::now() >= *next_followup_at) {
      next_followup_at.reset();
      if (!followup_future.valid()) {
        followup_future = std::async(std::launch::async, [&, transcript]() {
          std::string filler_err;
          return filler_->generate(transcript, FillerStage::FollowUp, spoken_filler,
                                  &handle->cancel, &filler_err);
        });
      }
    }

    if (!hold_llm_fillers && followup_future.valid() &&
        followup_future.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready) {
      ++followups_spoken;
      const std::string followup = followup_future.get();
      followup_future = {};
      if (!followup.empty() && followup != spoken_filler && !arb_state.saw_tool.load()) {
        if (!maybe_speak_filler(followup)) {
          result.error = err.empty() ? "tts failed" : err;
          handle->cancel.store(true);
          break;
        }
      }
    }

    sleep_ms(20);
  }

  arbiter_future.get();

  if (handle->cancel.load()) {
    result.error = "canceled";
    return finish(result);
  }

  if (!drain_and_speak(true)) {
    result.error = err.empty() ? "tts failed" : err;
    return finish(result);
  }
  if (!arb_state.started_answer.load() && !arb_state.full_content.empty()) {
    if (!speak(arb_state.full_content)) {
      result.error = err.empty() ? "tts failed" : err;
      return finish(result);
    }
    arb_state.started_answer.store(true);
  }

  DeviceSession s;
  s.device_id = device_id;
  s.conversation_id = conv;
  s.last_turn_id = result.turn_id;
  s.updated_at = now_unix();
  sessions_->upsert(s, &err);

  if (!arb_state.streamed) {
    result.error =
        arb_state.stream_err.empty() ? "arbiter stream failed" : arb_state.stream_err;
    return finish(result);
  }

  result.ok = arb_state.done_ok;
  if (!arb_state.done_ok) {
    result.error = arb_state.done_err.empty() ? "arbiter done ok=false" : arb_state.done_err;
  }
  return finish(result);
}

}  // namespace intercom

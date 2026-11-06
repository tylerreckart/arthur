#include "intercom/arbiter_client.hpp"
#include "intercom/device_hub.hpp"
#include "intercom/morning.hpp"
#include "intercom/session_store.hpp"
#include "intercom/speakback.hpp"
#include "intercom/tts.hpp"
#include "intercom/ws.hpp"

#include <sys/socket.h>
#include <unistd.h>

#include <ctime>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>
#include <string_view>
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

std::string read_available(int fd) {
  std::string buf;
  char tmp[4096];
  for (;;) {
    const ssize_t n = ::recv(fd, tmp, sizeof(tmp), MSG_DONTWAIT);
    if (n <= 0) break;
    buf.append(tmp, static_cast<std::size_t>(n));
  }
  return buf;
}

bool frames_contain(std::string raw, const std::string& needle) {
  std::string_view view(raw);
  while (!view.empty()) {
    std::size_t consumed = 0;
    const auto frame = intercom::decode_ws_frame(view, &consumed);
    if (!frame || consumed == 0) break;
    view.remove_prefix(consumed);
    if (frame->payload.find(needle) != std::string::npos) return true;
  }
  return false;
}

class SilentTts : public intercom::TtsProvider {
 public:
  bool synthesize(const std::string& text, PcmChunkFn on_chunk, std::string*) override {
    last = text;
    ++calls;
    const std::uint8_t pcm[4] = {1, 2, 3, 4};
    if (on_chunk) on_chunk(pcm, sizeof(pcm));
    return true;
  }
  bool ready(std::string*) const override { return true; }
  std::string last;
  int calls = 0;
};

class FakeArbiter : public intercom::ArbiterClient {
 public:
  FakeArbiter() : ArbiterClient("http://127.0.0.1:9", "", "arthur") {}

  std::optional<intercom::ScheduleInfo> get_schedule(std::int64_t task_id,
                                                     std::string*) const override {
    ++lookups;
    last_task = task_id;
    intercom::ScheduleInfo info;
    info.id = task_id;
    info.conversation_id = conversation_id;
    info.agent_id = agent_id;
    info.message = "remind me";
    return info;
  }

  mutable int lookups = 0;
  mutable std::int64_t last_task = 0;
  std::int64_t conversation_id = 7;
  std::string agent_id = "arthur";
};

}  // namespace

int main() {
  {
    const auto ev = intercom::parse_notification_json(
        R"({"kind":"run.completed","task_id":17,"run_id":42,"agent_id":"arthur",)"
        R"("status":"succeeded","started_at":100,"completed_at":110,)"
        R"("result_summary":"Time to leave, sir."})");
    CHECK(ev.kind == "run.completed");
    CHECK(ev.task_id == 17);
    CHECK(ev.run_id == 42);
    CHECK(ev.agent_id == "arthur");
    auto spoken = intercom::speak_text_for(ev, false);
    CHECK(spoken.has_value());
    if (spoken) CHECK(*spoken == "Time to leave, sir.");
  }

  {
    const auto started = intercom::parse_notification_json(
        R"({"kind":"run.started","task_id":1,"run_id":2,"status":"running"})");
    CHECK(!intercom::speak_text_for(started, false).has_value());
    CHECK(!intercom::speak_text_for(started, true).has_value());
  }

  {
    const auto failed = intercom::parse_notification_json(
        R"({"kind":"run.failed","task_id":1,"run_id":3,"status":"failed",)"
        R"("error_message":"boom"})");
    CHECK(!intercom::speak_text_for(failed, false).has_value());
    auto courtesy = intercom::speak_text_for(failed, true);
    CHECK(courtesy.has_value());
    if (courtesy) {
      CHECK(courtesy->find("sir") != std::string::npos);
      CHECK(courtesy->find("boom") == std::string::npos);
    }
  }

  {
    const auto run = intercom::parse_notification_json(
        R"({"id":9,"task_id":4,"status":"succeeded","result_summary":"Done."})");
    CHECK(run.run_id == 9);
    CHECK(run.kind == "run.completed");
    auto spoken = intercom::speak_text_for(run, false);
    CHECK(spoken.has_value());
    if (spoken) CHECK(*spoken == "Done.");
  }

  {
    const auto info = intercom::parse_schedule_json(
        R"({"scheduled_task":{"id":17,"conversation_id":7,"agent_id":"arthur",)"
        R"("message":"nudge me"}})");
    CHECK(info.id == 17);
    CHECK(info.conversation_id == 7);
    CHECK(info.agent_id == "arthur");
  }

  {
    std::vector<intercom::DeviceSession> sessions;
    intercom::DeviceSession a;
    a.device_id = "speaker-1";
    a.conversation_id = 7;
    sessions.push_back(a);
    auto hit = intercom::devices_for_conversation(sessions, 7);
    CHECK(hit.size() == 1);
    if (!hit.empty()) CHECK(hit[0] == "speaker-1");
    CHECK(intercom::devices_for_conversation(sessions, 99).empty());
    auto unscoped = intercom::devices_for_conversation(sessions, 0);
    CHECK(unscoped.size() == 1);
    intercom::DeviceSession b;
    b.device_id = "speaker-2";
    b.conversation_id = 8;
    sessions.push_back(b);
    CHECK(intercom::devices_for_conversation(sessions, 0).empty());
  }

  {
    auto tts = std::make_shared<SilentTts>();
    auto hub = std::make_shared<intercom::DeviceHub>(tts, 4);
    CHECK(hub->speak("speaker-1", "Time to leave, sir.", "schedule", 42));
    CHECK(hub->queued("speaker-1") == 1);
    CHECK(!hub->online("speaker-1"));
    CHECK(tts->calls == 0);

    CHECK(hub->speak("speaker-1", "Second.", "schedule", 43));
    CHECK(hub->speak("speaker-1", "Third.", "schedule", 44));
    CHECK(hub->speak("speaker-1", "Fourth.", "schedule", 45));
    CHECK(hub->speak("speaker-1", "Fifth.", "schedule", 46));
    CHECK(hub->queued("speaker-1") == 4);
  }

  {
    const auto db = std::filesystem::temp_directory_path() / "intercom_speakback.db";
    std::filesystem::remove(db);
    auto sessions = std::make_shared<intercom::SessionStore>(db.string());
    std::string err;
    CHECK(sessions->open(&err));
    intercom::DeviceSession row;
    row.device_id = "speaker-1";
    row.conversation_id = 7;
    CHECK(sessions->upsert(row, &err));

    auto tts = std::make_shared<SilentTts>();
    auto hub = std::make_shared<intercom::DeviceHub>(tts, 4);
    auto arbiter = std::make_shared<FakeArbiter>();
    intercom::SpeakbackConfig cfg;
    cfg.enabled = true;
    intercom::Speakback speakback(cfg, "arthur", arbiter, sessions, hub);

    intercom::NotificationEvent started;
    started.kind = "run.started";
    started.task_id = 17;
    started.run_id = 42;
    started.status = "running";
    started.agent_id = "arthur";
    speakback.handle_event(started);
    CHECK(hub->queued("speaker-1") == 0);

    intercom::NotificationEvent done;
    done.kind = "run.completed";
    done.task_id = 17;
    done.run_id = 42;
    done.status = "succeeded";
    done.agent_id = "arthur";
    done.result_summary = "Time to leave, sir.";
    done.started_at = 100;
    speakback.handle_event(done);
    CHECK(arbiter->lookups == 1);
    CHECK(arbiter->last_task == 17);
    CHECK(hub->queued("speaker-1") == 1);

    speakback.handle_event(done);
    CHECK(hub->queued("speaker-1") == 1);
    CHECK(arbiter->lookups == 1);

    intercom::NotificationEvent other;
    other.kind = "run.completed";
    other.task_id = 18;
    other.run_id = 99;
    other.status = "succeeded";
    other.agent_id = "vera";
    other.result_summary = "PR summary.";
    arbiter->conversation_id = 0;
    speakback.handle_event(other);
    CHECK(hub->queued("speaker-1") == 1);

    intercom::NotificationEvent ours;
    ours.kind = "run.completed";
    ours.task_id = 19;
    ours.run_id = 100;
    ours.status = "succeeded";
    ours.agent_id = "arthur";
    ours.result_summary = "Unscoped nudge.";
    speakback.handle_event(ours);
    CHECK(hub->queued("speaker-1") == 2);

    std::filesystem::remove(db);
  }

  {
    const auto db =
        std::filesystem::temp_directory_path() / "intercom_speakback_durable.db";
    std::filesystem::remove(db);
    {
      auto sessions = std::make_shared<intercom::SessionStore>(db.string());
      std::string err;
      CHECK(sessions->open(&err));
      intercom::DeviceSession row;
      row.device_id = "speaker-1";
      row.conversation_id = 7;
      CHECK(sessions->upsert(row, &err));

      auto tts = std::make_shared<SilentTts>();
      auto hub = std::make_shared<intercom::DeviceHub>(tts, 2, sessions);
      CHECK(hub->speak("speaker-1", "one", "schedule", 0));
      CHECK(hub->speak("speaker-1", "two", "schedule", 0));
      CHECK(hub->speak("speaker-1", "three", "schedule", 0));
      CHECK(hub->queued("speaker-1") == 2);
      const auto kept = sessions->list_speakback("speaker-1");
      CHECK(kept.size() == 2);
      if (kept.size() == 2) {
        CHECK(kept[0].text == "two");
        CHECK(kept[1].text == "three");
      }
      sessions->remove_speakback(kept[0].id, &err);
      sessions->remove_speakback(kept[1].id, &err);

      auto arbiter = std::make_shared<FakeArbiter>();
      intercom::SpeakbackConfig cfg;
      cfg.enabled = true;
      intercom::Speakback speakback(cfg, "arthur", arbiter, sessions, hub);
      intercom::NotificationEvent done;
      done.kind = "run.completed";
      done.task_id = 17;
      done.run_id = 42;
      done.status = "succeeded";
      done.agent_id = "arthur";
      done.result_summary = "Time to leave, sir.";
      done.started_at = 100;
      speakback.handle_event(done);
      CHECK(hub->queued("speaker-1") == 1);
      CHECK(sessions->has_spoken_run(42));
      speakback.handle_event(done);
      CHECK(hub->queued("speaker-1") == 1);
    }

    auto sessions = std::make_shared<intercom::SessionStore>(db.string());
    std::string err;
    CHECK(sessions->open(&err));
    CHECK(sessions->has_spoken_run(42));
    CHECK(sessions->count_speakback("speaker-1") == 1);
    const auto queued = sessions->list_speakback("speaker-1");
    CHECK(queued.size() == 1);
    if (!queued.empty()) {
      CHECK(queued[0].text == "Time to leave, sir.");
      CHECK(queued[0].run_id == 42);
    }

    auto tts = std::make_shared<SilentTts>();
    auto hub = std::make_shared<intercom::DeviceHub>(tts, 4, sessions);
    CHECK(hub->queued("speaker-1") == 1);
    int fds[2] = {-1, -1};
    CHECK(::socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
    hub->attach("speaker-1", fds[0]);
    const std::string raw = read_available(fds[1]);
    CHECK(frames_contain(raw, "Time to leave, sir."));
    CHECK(tts->calls == 1);
    CHECK(hub->queued("speaker-1") == 0);

    auto arbiter = std::make_shared<FakeArbiter>();
    intercom::SpeakbackConfig cfg;
    cfg.enabled = true;
    intercom::Speakback again(cfg, "arthur", arbiter, sessions, hub);
    intercom::NotificationEvent done;
    done.kind = "run.completed";
    done.task_id = 17;
    done.run_id = 42;
    done.status = "succeeded";
    done.agent_id = "arthur";
    done.result_summary = "Time to leave, sir.";
    again.handle_event(done);
    CHECK(hub->queued("speaker-1") == 0);
    CHECK(tts->calls == 1);

    if (fds[0] >= 0) ::close(fds[0]);
    if (fds[1] >= 0) ::close(fds[1]);
    std::filesystem::remove(db);
  }

  {
    const auto db = std::filesystem::temp_directory_path() / "intercom_speak_quiet.db";
    std::filesystem::remove(db);
    auto sessions = std::make_shared<intercom::SessionStore>(db.string());
    std::string err;
    CHECK(sessions->open(&err));
    auto tts = std::make_shared<SilentTts>();
    auto hub = std::make_shared<intercom::DeviceHub>(tts, 4, sessions);
    const std::time_t now = std::time(nullptr);
    const int minute = intercom::minute_of_day(now);
    int quiet_end = minute + 30;
    if (quiet_end >= 24 * 60) quiet_end -= 24 * 60;
    hub->set_quiet(true, minute, quiet_end);
    int fds[2] = {-1, -1};
    CHECK(::socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
    hub->attach("desk", fds[0]);
    CHECK(hub->speak("desk", "Someone is at the door.", "doorbell", 0));
    CHECK(tts->calls == 0);
    CHECK(hub->queued("desk") == 1);
    const auto held = sessions->list_speakback("desk");
    CHECK(held.size() == 1);
    if (!held.empty()) CHECK(held[0].expires_at > held[0].created_at);

    hub->set_quiet(false, 0, 0);
    hub->nudge();
    const std::string raw = read_available(fds[1]);
    CHECK(frames_contain(raw, "Someone is at the door."));
    CHECK(tts->calls == 1);
    CHECK(hub->queued("desk") == 0);

    CHECK(sessions->enqueue_speakback("desk", "late", "doorbell", 0, 4, &err, 1) > 0);
    hub->nudge();
    CHECK(hub->queued("desk") == 0);
    CHECK(tts->calls == 1);

    hub->set_dnd("desk", true);
    CHECK(hub->speak("desk", "Held for Focus.", "schedule", 0));
    CHECK(tts->calls == 1);
    CHECK(hub->queued("desk") == 1);
    hub->set_dnd("desk", false);
    CHECK(tts->calls == 2);
    CHECK(hub->queued("desk") == 0);

    if (fds[0] >= 0) ::close(fds[0]);
    if (fds[1] >= 0) ::close(fds[1]);
    std::filesystem::remove(db);
  }

  {
    const auto db = std::filesystem::temp_directory_path() / "intercom_morning.db";
    std::filesystem::remove(db);
    const std::time_t now = std::time(nullptr);
    const int minute = intercom::minute_of_day(now);
    const int day = intercom::civil_day(now);
    auto sessions = std::make_shared<intercom::SessionStore>(db.string());
    std::string err;
    CHECK(sessions->open(&err));
    intercom::DeviceSession row;
    row.device_id = "desk";
    row.conversation_id = 3;
    CHECK(sessions->upsert(row, &err));
    auto tts = std::make_shared<SilentTts>();
    auto hub = std::make_shared<intercom::DeviceHub>(tts, 4, sessions);
    intercom::SpeakbackConfig cfg;
    cfg.briefing = true;
    cfg.briefing_minute = minute;
    cfg.briefing_grace_minutes = 20;
    cfg.quiet_hours = false;
    intercom::MorningBriefing briefing(hub, sessions, cfg, []() { return "Good morning."; });
    CHECK(briefing.tick(static_cast<std::int64_t>(now), minute, day));
    CHECK(hub->queued("desk") == 1);
    CHECK(sessions->marked_day("briefing") == day);
    const auto queued = sessions->list_speakback("desk");
    CHECK(queued.size() == 1);
    if (!queued.empty()) {
      CHECK(queued[0].text == "Good morning.");
      CHECK(queued[0].kind == "briefing");
    }
    CHECK(!briefing.tick(static_cast<std::int64_t>(now), minute, day));
    CHECK(hub->queued("desk") == 1);

    hub->set_dnd("desk", true);
    sessions->mark_day("briefing", day - 1, &err);
    CHECK(!briefing.tick(static_cast<std::int64_t>(now), minute, day));
    CHECK(hub->queued("desk") == 1);
    hub->set_dnd("desk", false);
  }

  {
    const auto db = std::filesystem::temp_directory_path() / "intercom_morning.db";
    const std::time_t now = std::time(nullptr);
    const int minute = intercom::minute_of_day(now);
    const int day = intercom::civil_day(now);
    auto sessions = std::make_shared<intercom::SessionStore>(db.string());
    std::string err;
    CHECK(sessions->open(&err));
    CHECK(sessions->marked_day("briefing") == day - 1);
    auto tts = std::make_shared<SilentTts>();
    auto hub = std::make_shared<intercom::DeviceHub>(tts, 4, sessions);
    intercom::SpeakbackConfig cfg;
    cfg.briefing = true;
    cfg.briefing_minute = minute;
    cfg.briefing_grace_minutes = 20;
    cfg.quiet_hours = false;
    intercom::MorningBriefing restarted(hub, sessions, cfg, []() { return "Good morning."; });
    CHECK(restarted.tick(static_cast<std::int64_t>(now), minute, day));
    CHECK(hub->queued("desk") == 2);
    CHECK(sessions->marked_day("briefing") == day);
    CHECK(!restarted.tick(static_cast<std::int64_t>(now), minute, day));
    CHECK(hub->queued("desk") == 2);
    std::filesystem::remove(db);
  }

  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_speakback ok\n";
  return 0;
}

#include "intercom/speak_queue.hpp"

#include <iostream>
#include <string>

namespace {

int g_fails = 0;

void expect(bool cond, const char* expr, const char* file, int line) {
  if (!cond) {
    std::cerr << "FAIL " << file << ":" << line << " " << expr << "\n";
    ++g_fails;
  }
}

#define CHECK(cond) expect((cond), #cond, __FILE__, __LINE__)

}  // namespace

int main() {
  using namespace intercom;

  CHECK(speak_ttl_seconds("doorbell") == 180);
  CHECK(speak_ttl_seconds("timer") == 600);
  CHECK(speak_ttl_seconds("briefing") == 2 * 60 * 60);
  CHECK(speak_ttl_seconds("schedule") == 6 * 60 * 60);

  CHECK(in_quiet_hours(23 * 60, 22 * 60, 7 * 60));
  CHECK(in_quiet_hours(6 * 60, 22 * 60, 7 * 60));
  CHECK(!in_quiet_hours(12 * 60, 22 * 60, 7 * 60));
  CHECK(!in_quiet_hours(7 * 60, 22 * 60, 7 * 60));
  CHECK(!in_quiet_hours(10 * 60, 10 * 60, 10 * 60));

  const std::int64_t now = 1'000'000;
  SpeakPolicy open;
  SpeakCandidate fresh;
  fresh.kind = "schedule";
  fresh.created_at = now;
  fresh.expires_at = now + 60;
  CHECK(decide_speak(fresh, now, 12 * 60, open) == SpeakAction::Speak);

  SpeakPolicy quiet;
  quiet.quiet_enabled = true;
  quiet.quiet_start_minute = 22 * 60;
  quiet.quiet_end_minute = 7 * 60;
  SpeakCandidate bell;
  bell.kind = "doorbell";
  bell.created_at = now;
  bell.expires_at = now + 180;
  CHECK(decide_speak(bell, now, 23 * 60, quiet) == SpeakAction::Hold);
  CHECK(decide_speak(bell, now + 181, 23 * 60, quiet) == SpeakAction::Drop);

  SpeakPolicy focus = open;
  focus.dnd = true;
  CHECK(decide_speak(fresh, now, 12 * 60, focus) == SpeakAction::Hold);

  SpeakCandidate legacy;
  legacy.kind = "doorbell";
  legacy.created_at = now;
  CHECK(decide_speak(legacy, now + 179, 12 * 60, open) == SpeakAction::Speak);
  CHECK(decide_speak(legacy, now + 180, 12 * 60, open) == SpeakAction::Drop);

  BriefingSchedule morning;
  CHECK(briefing_due(7 * 60 + 30, 20261106, 20261105, morning, open));
  CHECK(briefing_due(7 * 60 + 49, 20261106, 20261105, morning, open));
  CHECK(!briefing_due(7 * 60 + 50, 20261106, 20261105, morning, open));
  CHECK(!briefing_due(12 * 60, 20261106, 20261105, morning, open));
  CHECK(!briefing_due(7 * 60 + 30, 20261106, 20261106, morning, open));
  CHECK(!briefing_due(7 * 60 + 30, 20261106, 20261105, morning, focus));
  SpeakPolicy covering = open;
  covering.quiet_enabled = true;
  covering.quiet_start_minute = 7 * 60;
  covering.quiet_end_minute = 8 * 60;
  CHECK(!briefing_due(7 * 60 + 30, 20261106, 20261105, morning, covering));
  CHECK(briefing_due(7 * 60 + 30, 20261106, 20261105, morning, quiet));

  CHECK(morning_briefing_line("It's 7:30 in the morning.", "Rain.", "", "Markets are up.") ==
        "It's 7:30 in the morning. Rain. Markets are up.");
  CHECK(morning_briefing_line("", "", "", "").empty());

  CHECK(!partial_due(1000, 0, false));
  CHECK(partial_due(12000, 0, false));
  CHECK(!partial_due(12000, 0, true));
  CHECK(!partial_due(20000, 12000, false));
  CHECK(partial_due(12000 + 19200, 12000, false));

  const auto door = home_alert_from_json(nlohmann::json::parse(R"({"kind":"doorbell"})"));
  CHECK(door.has_value());
  if (door) {
    CHECK(door->kind == "doorbell");
    CHECK(door->text == "Someone is at the door.");
  }
  const auto pie = home_alert_from_json(
      nlohmann::json::parse(R"({"kind":"timer_done","name":"pie"})"));
  CHECK(pie.has_value());
  if (pie) {
    CHECK(pie->kind == "timer");
    CHECK(pie->text == "The pie timer is done.");
  }
  const auto messy = home_alert_from_json(
      nlohmann::json::parse(R"({"kind":"timer_done","name":"pie\n<script>"})"));
  CHECK(messy.has_value());
  if (messy) CHECK(messy->text == "The pie timer is done.");

  const auto ha_door = home_alert_from_json(nlohmann::json::parse(
      R"({"event_type":"state_changed","data":{"entity_id":"binary_sensor.front_doorbell",)"
      R"("new_state":{"state":"on"}}})"));
  CHECK(ha_door.has_value());
  if (ha_door) CHECK(ha_door->kind == "doorbell");
  const auto ha_off = home_alert_from_json(nlohmann::json::parse(
      R"({"event_type":"state_changed","data":{"entity_id":"binary_sensor.front_doorbell",)"
      R"("new_state":{"state":"off"}}})"));
  CHECK(!ha_off.has_value());

  const auto ha_timer = home_alert_from_json(nlohmann::json::parse(
      R"({"event_type":"timer.finished","data":{"entity_id":"timer.pie"}})"));
  CHECK(ha_timer.has_value());
  if (ha_timer) CHECK(ha_timer->text == "The pie timer is done.");
  const auto ha_idle = home_alert_from_json(nlohmann::json::parse(
      R"({"event_type":"state_changed","data":{"entity_id":"timer.oven",)"
      R"("old_state":{"state":"active"},"new_state":{"state":"idle"}}})"));
  CHECK(ha_idle.has_value());
  if (ha_idle) CHECK(ha_idle->text == "The oven timer is done.");
  const auto ha_idle_unknown = home_alert_from_json(nlohmann::json::parse(
      R"({"event_type":"state_changed","data":{"entity_id":"timer.oven",)"
      R"("new_state":{"state":"idle"}}})"));
  CHECK(!ha_idle_unknown.has_value());
  CHECK(!home_alert_from_json(nlohmann::json::parse(R"({"type":"weather"})")).has_value());

  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_speak_queue ok\n";
  return 0;
}

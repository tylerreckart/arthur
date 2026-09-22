#include "intercom/fast_path.hpp"
#include "intercom/clock.hpp"
#include "intercom/home_client.hpp"
#include "intercom/surface.hpp"

#include <iostream>
#include <memory>
#include <string>
#include <string_view>

namespace {

int g_fails = 0;

void expect(bool cond, const char* expr, const char* file, int line) {
  if (!cond) {
    std::cerr << "FAIL " << file << ":" << line << " " << expr << "\n";
    ++g_fails;
  }
}

#define CHECK(cond) expect((cond), #cond, __FILE__, __LINE__)

bool contains(const std::string& s, const char* needle) {
  return s.find(needle) != std::string::npos;
}

}  // namespace

int main() {
  intercom::FastPath off(false);
  CHECK(!off.try_handle("hello").has_value());

  intercom::FastPath on(true);
  CHECK(!on.try_handle("what's the weather").has_value());
  CHECK(!on.try_handle("good morning, what's the weather").has_value());

  auto morning = on.try_handle("good morning");
  CHECK(morning.has_value());
  if (morning) {
    CHECK(contains(morning->reply, "sir"));
    CHECK(contains(morning->reply, "orning"));
    CHECK(morning->reply.find('?') != std::string::npos);
    CHECK(!contains(morning->reply, "Arthur here"));
  }

  auto punct = on.try_handle("Good morning, Arthur.");
  CHECK(punct.has_value());
  if (punct) {
    CHECK(contains(punct->reply, "sir"));
    CHECK(punct->reply.find('?') != std::string::npos);
  }

  auto hi = on.try_handle("hey");
  CHECK(hi.has_value());
  if (hi) {
    CHECK(contains(hi->reply, "sir"));
    CHECK(hi->reply.find('?') != std::string::npos);
    CHECK(!contains(hi->reply, "Arthur here"));
  }

  auto how = on.try_handle("how are you");
  CHECK(how.has_value());
  if (how) {
    CHECK(contains(how->reply, "sir"));
    CHECK(how->reply.find('?') != std::string::npos);
  }

  auto night = on.try_handle("good night");
  CHECK(night.has_value());
  if (night) {
    CHECK(contains(night->reply, "sir"));
    CHECK(night->reply.find('?') == std::string::npos);
  }

  auto status = on.try_handle("are you there");
  CHECK(status.has_value());
  if (status) {
    CHECK(contains(status->reply, "sir"));
    CHECK(!contains(status->reply, "Speech bridge"));
  }

  auto echo = on.try_handle("echo hello there");
  CHECK(echo.has_value());
  if (echo) {
    CHECK(echo->reply == "hello there");
    CHECK(echo->kind == "echo");
  }

  auto clock = on.try_handle("what time is it");
  CHECK(clock.has_value());
  if (clock) {
    CHECK(contains(clock->reply, "It's "));
    CHECK(contains(clock->reply, "sir"));
    CHECK(!contains(clock->reply, "AM"));
    CHECK(!contains(clock->reply, "PM"));
    CHECK(clock->kind == "clock");
  }

  auto how_long = on.try_handle("set a timer");
  CHECK(how_long.has_value());
  if (how_long) {
    CHECK(how_long->reply == "How long, sir?");
    CHECK(how_long->kind == "timer");
  }
  CHECK(!on.try_handle("set a timer for 5 minutes").has_value());
  CHECK(!on.try_handle("turn on the kitchen lights").has_value());

  auto date = on.try_handle("what's the date");
  CHECK(date.has_value());
  if (date) {
    CHECK(contains(date->reply, "It's "));
    CHECK(contains(date->reply, "sir"));
  }

  CHECK(intercom::is_social_turn("good morning"));
  CHECK(intercom::is_social_turn("Good morning, Arthur."));
  CHECK(intercom::withholds_fillers("good morning"));
  CHECK(intercom::withholds_fillers("what time is it"));
  CHECK(intercom::withholds_fillers("what's the weather"));
  CHECK(intercom::withholds_fillers("set a timer for 5 minutes"));
  CHECK(!intercom::withholds_fillers("what's the weather in Tokyo"));
  CHECK(!intercom::is_clock_query("what time is it in Tokyo"));

  class FakeHome : public intercom::HomeClient {
   public:
    FakeHome() : HomeClient(intercom::HomeConfig{}) {}
    bool configured() const override { return true; }
    intercom::HomeAction run(const intercom::HomeIntent& intent, std::string*) const override {
      intercom::HomeAction out;
      if (intent.kind == intercom::HomeIntentKind::Timer) {
        out.reply = intercom::spoken_duration(intent.timer_seconds) + ", sir.";
        return out;
      }
      if (intent.kind == intercom::HomeIntentKind::Weather) {
        auto extracted = intercom::weather_from_ha_state(std::string_view{R"({
          "state": "cloudy",
          "attributes": {
            "temperature": 12,
            "temperature_unit": "°C",
            "friendly_name": "Home"
          }
        })"});
        out.reply = extracted.ok ? extracted.spoken : "It's twelve degrees and cloudy, sir.";
        if (extracted.ok) out.surface = intercom::surface_to_json(extracted.surface);
        return out;
      }
      if (intent.kind == intercom::HomeIntentKind::LightOn) {
        out.reply = "I've switched on the kitchen lights, sir.";
        return out;
      }
      out.reply = "ok";
      return out;
    }
  };

  intercom::FastPath ha(true, intercom::HomeConfig{}, std::make_shared<FakeHome>());
  auto timed = ha.try_handle("set a timer for 5 minutes");
  CHECK(timed.has_value());
  if (timed) {
    CHECK(contains(timed->reply, "five minutes"));
    CHECK(timed->kind == "timer");
  }
  auto wx = ha.try_handle("what's the weather");
  CHECK(wx.has_value());
  if (wx) {
    CHECK(contains(wx->reply, "cloudy") || contains(wx->reply, "Cloudy"));
    CHECK(wx->kind == "weather");
    CHECK(wx->surface.is_object());
    if (wx->surface.is_object()) {
      CHECK(wx->surface.value("kind", "") == "weather");
      CHECK(wx->surface.value("version", 0) == intercom::kSurfaceVersion);
      CHECK(wx->surface.contains("payload"));
      CHECK(wx->surface["payload"].value("temperature", 0) == 12);
    }
  }
  CHECK(!ha.try_handle("what's the weather in Tokyo").has_value());
  auto lights = ha.try_handle("turn on the kitchen lights");
  CHECK(lights.has_value());
  if (lights) CHECK(lights->kind == "light_on");

  const std::string rule = intercom::local_clock_rule();
  CHECK(contains(rule, "CURRENT LOCAL DATETIME:"));
  CHECK(contains(rule, "never look it up"));

  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_fast_path ok\n";
  return 0;
}

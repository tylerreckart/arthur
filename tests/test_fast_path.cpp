#include "intercom/fast_path.hpp"
#include "intercom/briefing.hpp"
#include "intercom/clock.hpp"
#include "intercom/home_client.hpp"
#include "intercom/markets_client.hpp"
#include "intercom/news_client.hpp"
#include "intercom/surface.hpp"
#include "intercom/weather_client.hpp"

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
  CHECK(intercom::withholds_fillers("what's the weather in Tokyo"));
  CHECK(intercom::withholds_fillers("what's in the news"));
  CHECK(intercom::withholds_fillers("how's the market"));
  CHECK(!intercom::withholds_fillers("tell me a joke"));
  CHECK(!intercom::is_clock_query("what time is it in Tokyo"));
  CHECK(!on.try_handle("what's in the news").has_value());
  CHECK(!on.try_handle("how's the market").has_value());

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

  class FakeWeather : public intercom::WeatherClient {
   public:
    intercom::WeatherExtract lookup_place(const std::string& place,
                                          std::string*) const override {
      auto extracted = intercom::weather_from_open_meteo(
          std::string_view{R"({"results":[{"name":"Tokyo","country":"Japan",
            "latitude":35.7,"longitude":139.7}]})"},
          std::string_view{R"({
            "current": {
              "time": "2026-09-22T15:00",
              "temperature_2m": 22.2,
              "apparent_temperature": 21.0,
              "relative_humidity_2m": 55,
              "weather_code": 2,
              "wind_speed_10m": 8,
              "is_day": 1
            },
            "current_units": {"temperature_2m": "°C", "wind_speed_10m": "km/h"},
            "hourly": {
              "time": ["2026-09-22T15:00", "2026-09-22T16:00"],
              "temperature_2m": [22.2, 21.4],
              "weather_code": [2, 3]
            },
            "daily": {
              "time": ["2026-09-22", "2026-09-23"],
              "weather_code": [2, 61],
              "temperature_2m_max": [24, 20],
              "temperature_2m_min": [16, 14]
            }
          })"});
      if (extracted.ok && extracted.surface.title.find("Tokyo") == std::string::npos) {
        extracted.surface.title = place;
      }
      return extracted;
    }
  };

  intercom::FastPath place_wx(true, intercom::HomeConfig{}, nullptr,
                              std::make_shared<FakeWeather>());
  auto tokyo = place_wx.try_handle("what's the weather in Tokyo");
  CHECK(tokyo.has_value());
  if (tokyo) {
    CHECK(tokyo->kind == "weather");
    CHECK(contains(tokyo->reply, "Tokyo") || contains(tokyo->reply, "tokyo"));
    CHECK(tokyo->surface.is_object());
    if (tokyo->surface.is_object()) {
      CHECK(tokyo->surface.value("kind", "") == "weather");
      CHECK(tokyo->surface.value("version", 0) == intercom::kSurfaceVersion);
      CHECK(contains(tokyo->surface.value("title", ""), "Tokyo"));
      CHECK(tokyo->surface["payload"].value("temperature", 0) == 22);
    }
  }
  CHECK(!place_wx.try_handle("what's the weather").has_value());

  class FakeNews : public intercom::NewsClient {
   public:
    intercom::NewsExtract fetch(const std::string& topic, std::string*) const override {
      const char* rss = R"(<rss><channel><item>
        <title>Headline one - Wire</title>
        <link>https://example.com/1</link>
        <source>Wire</source>
      </item></channel></rss>)";
      return intercom::news_from_rss(std::string_view{rss}, topic, 8);
    }
  };

  class FakeMarkets : public intercom::MarketsClient {
   public:
    intercom::MarketsExtract fetch(const std::vector<std::string>& symbols,
                                   std::string*) const override {
      std::string symbol = symbols.empty() ? "AAPL" : symbols[0];
      if (symbol == "^GSPC") symbol = "AAPL";
      nlohmann::json row = {{"symbol", symbol},
                            {"shortName", "Apple Inc."},
                            {"regularMarketPrice", 230},
                            {"regularMarketChange", 1.2},
                            {"regularMarketChangePercent", 0.5},
                            {"currency", "USD"}};
      nlohmann::json body;
      body["quoteResponse"]["result"] = nlohmann::json::array({row});
      return intercom::markets_from_yahoo_quote(body);
    }
  };

  intercom::FastPath news_fp(true, intercom::HomeConfig{}, nullptr, nullptr,
                             std::make_shared<FakeNews>(), nullptr);
  auto news = news_fp.try_handle("what's in the news");
  CHECK(news.has_value());
  if (news) {
    CHECK(news->kind == "news");
    CHECK(contains(news->reply, "headlines") || contains(news->reply, "latest"));
    CHECK(news->surface.is_object());
    if (news->surface.is_object()) {
      CHECK(news->surface.value("kind", "") == "news");
      CHECK(news->surface["payload"].contains("items"));
    }
  }
  auto tesla_news = news_fp.try_handle("news about Tesla");
  CHECK(tesla_news.has_value());
  if (tesla_news) {
    CHECK(tesla_news->kind == "news");
    CHECK(contains(tesla_news->surface.value("title", ""), "Tesla") ||
          tesla_news->surface["payload"].value("topic", "") == "tesla");
  }
  auto social = news_fp.try_handle("hello");
  CHECK(social.has_value());
  if (social) CHECK(social->kind == "social");
  CHECK(!news_fp.try_handle("what's the weather").has_value());

  intercom::FastPath mkt_fp(true, intercom::HomeConfig{}, nullptr, nullptr, nullptr,
                            std::make_shared<FakeMarkets>());
  auto mkt = mkt_fp.try_handle("how's the market");
  CHECK(mkt.has_value());
  if (mkt) {
    CHECK(mkt->kind == "markets");
    CHECK(mkt->surface.is_object());
    if (mkt->surface.is_object()) {
      CHECK(mkt->surface.value("kind", "") == "markets");
      CHECK(mkt->surface["payload"].contains("instruments"));
    }
  }
  auto aapl = mkt_fp.try_handle("what's AAPL doing");
  CHECK(aapl.has_value());
  if (aapl) {
    CHECK(aapl->kind == "markets");
    CHECK(aapl->surface["payload"]["instruments"][0].value("symbol", "") == "AAPL");
  }
  CHECK(!mkt_fp.try_handle("turn on the kitchen lights").has_value());

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

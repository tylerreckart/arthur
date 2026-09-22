#include "intercom/briefing.hpp"
#include "intercom/home.hpp"

#include <iostream>
#include <string>
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

bool has_symbol(const std::vector<std::string>& symbols, const char* want) {
  for (const auto& s : symbols) {
    if (s == want) return true;
  }
  return false;
}

}  // namespace

int main() {
  CHECK(!intercom::parse_briefing_intent("hello").has_value());
  CHECK(!intercom::parse_briefing_intent("what time is it").has_value());
  CHECK(!intercom::parse_briefing_intent("what's the weather").has_value());
  CHECK(!intercom::parse_briefing_intent("what's the weather in Tokyo").has_value());
  CHECK(!intercom::parse_briefing_intent("turn on the kitchen lights").has_value());
  CHECK(!intercom::parse_briefing_intent("I have news for you").has_value());
  CHECK(!intercom::parse_briefing_intent("stock up on milk").has_value());
  CHECK(!intercom::parse_briefing_intent("what's apple").has_value());

  auto top = intercom::parse_briefing_intent("what's in the news");
  CHECK(top.has_value());
  if (top) {
    CHECK(top->kind == intercom::BriefingKind::News);
    CHECK(top->confidence == intercom::BriefingConfidence::High);
    CHECK(top->topic.empty());
  }

  auto headlines = intercom::parse_briefing_intent("top headlines");
  CHECK(headlines.has_value());
  if (headlines) CHECK(headlines->kind == intercom::BriefingKind::News);

  auto tesla_news = intercom::parse_briefing_intent("news about Tesla");
  CHECK(tesla_news.has_value());
  if (tesla_news) {
    CHECK(tesla_news->kind == intercom::BriefingKind::News);
    CHECK(tesla_news->topic == "tesla");
  }

  auto weather_news = intercom::parse_briefing_intent("news about the weather");
  CHECK(weather_news.has_value());
  if (weather_news) {
    CHECK(weather_news->kind == intercom::BriefingKind::News);
    CHECK(weather_news->topic == "weather");
  }
  CHECK(!intercom::parse_home_intent("news about the weather").has_value());

  CHECK(intercom::extract_news_topic("what's in the news").empty());
  CHECK(intercom::extract_news_topic("news about Ukraine") == "ukraine");
  CHECK(intercom::extract_news_topic("headlines on climate change") == "climate change");

  auto market = intercom::parse_briefing_intent("how's the market");
  CHECK(market.has_value());
  if (market) {
    CHECK(market->kind == intercom::BriefingKind::Markets);
    CHECK(market->confidence == intercom::BriefingConfidence::High);
    CHECK(market->symbols.empty());
  }

  auto aapl = intercom::parse_briefing_intent("what's AAPL doing");
  CHECK(aapl.has_value());
  if (aapl) {
    CHECK(aapl->kind == intercom::BriefingKind::Markets);
    CHECK(has_symbol(aapl->symbols, "AAPL"));
  }

  auto btc = intercom::parse_briefing_intent("bitcoin price");
  CHECK(btc.has_value());
  if (btc) {
    CHECK(btc->kind == intercom::BriefingKind::Markets);
    CHECK(has_symbol(btc->symbols, "BTC-USD"));
  }

  auto apple_stock = intercom::parse_briefing_intent("how's apple stock");
  CHECK(apple_stock.has_value());
  if (apple_stock) {
    CHECK(apple_stock->kind == intercom::BriefingKind::Markets);
    CHECK(has_symbol(apple_stock->symbols, "AAPL"));
  }

  auto tesla_how = intercom::parse_briefing_intent("how's Tesla");
  CHECK(tesla_how.has_value());
  if (tesla_how) {
    CHECK(tesla_how->kind == intercom::BriefingKind::Markets);
    CHECK(has_symbol(tesla_how->symbols, "TSLA"));
  }

  auto both = intercom::extract_market_symbols("apple and tesla stock");
  CHECK(has_symbol(both, "AAPL"));
  CHECK(has_symbol(both, "TSLA"));

  CHECK(std::string(intercom::briefing_kind_name(intercom::BriefingKind::News)) == "news");
  CHECK(std::string(intercom::briefing_kind_name(intercom::BriefingKind::Markets)) ==
        "markets");

  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_briefing_intent ok\n";
  return 0;
}

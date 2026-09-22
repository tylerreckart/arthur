#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace intercom {

struct NewsFeed {
  std::string name;
  std::string url;
};

struct NewsConfig {
  int timeout_ms = 2500;
  int max_items = 8;
  // Base for topic search (`{base}/search?q=…`). Default is Google News RSS.
  std::string google_news_rss = "https://news.google.com/rss";
  // Used when the utterance has no topic ("what's in the news").
  std::vector<NewsFeed> feeds;
};

struct MarketsConfig {
  int timeout_ms = 2500;
  // Yahoo-style public quote JSON host. Override in tests or to point at a proxy.
  std::string quote_base = "https://query1.finance.yahoo.com";
  std::vector<std::string> default_symbols{"^GSPC", "^DJI", "^IXIC", "BTC-USD"};
};

enum class BriefingKind {
  News,
  Markets,
};

enum class BriefingConfidence {
  High,
  Medium,
};

struct BriefingIntent {
  BriefingKind kind = BriefingKind::News;
  BriefingConfidence confidence = BriefingConfidence::High;
  std::string topic;                 // news topic; empty = top stories
  std::vector<std::string> symbols;  // Yahoo symbols; empty = default basket
};

const char* briefing_kind_name(BriefingKind kind);

// News / markets hallway router. Does not fetch. Null when the turn is
// neither — weather, lights, greetings stay with their own parsers.
std::optional<BriefingIntent> parse_briefing_intent(std::string_view transcript);

std::string extract_news_topic(std::string_view transcript);
std::vector<std::string> extract_market_symbols(std::string_view transcript);

}  // namespace intercom

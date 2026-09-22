#include "intercom/briefing.hpp"
#include "intercom/home.hpp"
#include "intercom/util.hpp"

#include <algorithm>
#include <cctype>
#include <vector>

namespace intercom {
namespace {

bool is_word_char(char c) {
  return std::isalnum(static_cast<unsigned char>(c)) != 0;
}

bool has_word(std::string_view t, std::string_view word) {
  std::size_t pos = 0;
  while (pos <= t.size()) {
    const auto found = t.find(word, pos);
    if (found == std::string_view::npos) return false;
    const bool left = found == 0 || !is_word_char(t[found - 1]);
    const bool right =
        found + word.size() == t.size() || !is_word_char(t[found + word.size()]);
    if (left && right) return true;
    pos = found + 1;
  }
  return false;
}

bool has_any(std::string_view t, std::initializer_list<const char*> words) {
  for (const char* w : words) {
    if (has_word(t, w)) return true;
  }
  return false;
}

std::vector<std::string> tokens(std::string_view t) {
  std::vector<std::string> out;
  std::string cur;
  for (char c : t) {
    if (c == ' ') {
      if (!cur.empty()) {
        out.push_back(cur);
        cur.clear();
      }
    } else {
      cur.push_back(c);
    }
  }
  if (!cur.empty()) out.push_back(cur);
  return out;
}

std::string take_after_prep(std::string_view t, std::string_view prep) {
  const std::string needle = " " + std::string(prep) + " ";
  auto pos = t.find(needle);
  std::size_t start = std::string_view::npos;
  if (pos != std::string_view::npos) {
    start = pos + needle.size();
  } else if (t.size() > prep.size() + 1 && t.substr(0, prep.size()) == prep &&
             t[prep.size()] == ' ') {
    start = prep.size() + 1;
  }
  if (start == std::string_view::npos || start >= t.size()) return {};
  return trim(std::string(t.substr(start)));
}

struct InstrumentAlias {
  const char* spoken;
  const char* symbol;
  bool unambiguous;
};

// Spoken forms after fold_phatic (lowercase, light punctuation stripped).
const InstrumentAlias kInstruments[] = {
    {"aapl", "AAPL", true},
    {"apple", "AAPL", false},
    {"msft", "MSFT", true},
    {"microsoft", "MSFT", true},
    {"googl", "GOOGL", true},
    {"goog", "GOOG", true},
    {"google", "GOOGL", false},
    {"amzn", "AMZN", true},
    {"amazon", "AMZN", false},
    {"tsla", "TSLA", true},
    {"tesla", "TSLA", true},
    {"nvda", "NVDA", true},
    {"nvidia", "NVDA", true},
    {"meta", "META", false},
    {"facebook", "META", true},
    {"nflx", "NFLX", true},
    {"netflix", "NFLX", true},
    {"amd", "AMD", true},
    {"intc", "INTC", true},
    {"intel", "INTC", true},
    {"ibm", "IBM", true},
    {"orcl", "ORCL", true},
    {"oracle", "ORCL", true},
    {"spy", "SPY", true},
    {"qqq", "QQQ", true},
    {"bitcoin", "BTC-USD", true},
    {"btc", "BTC-USD", true},
    {"ethereum", "ETH-USD", true},
    {"eth", "ETH-USD", true},
    {"dogecoin", "DOGE-USD", true},
    {"doge", "DOGE-USD", true},
    {"s and p", "^GSPC", true},
    {"s p 500", "^GSPC", true},
    {"sp500", "^GSPC", true},
    {"s&p", "^GSPC", true},
    {"dow jones", "^DJI", true},
    {"dow", "^DJI", true},
    {"nasdaq", "^IXIC", true},
};

bool has_instrument_named(std::string_view t, const InstrumentAlias& alias) {
  if (std::string_view(alias.spoken).find(' ') != std::string_view::npos ||
      std::string_view(alias.spoken).find('&') != std::string_view::npos) {
    return t.find(alias.spoken) != std::string_view::npos;
  }
  return has_word(t, alias.spoken);
}

bool has_unambiguous_instrument(std::string_view t) {
  for (const auto& a : kInstruments) {
    if (a.unambiguous && has_instrument_named(t, a)) return true;
  }
  return false;
}

bool has_ambiguous_instrument(std::string_view t) {
  for (const auto& a : kInstruments) {
    if (!a.unambiguous && has_instrument_named(t, a)) return true;
  }
  return false;
}

bool has_any_instrument(std::string_view t) {
  return has_unambiguous_instrument(t) || has_ambiguous_instrument(t);
}

bool looks_like_news(std::string_view t) {
  if (has_any(t, {"headlines", "headline"})) return true;
  if (has_word(t, "stories") && has_any(t, {"top", "latest", "breaking"})) return true;
  if (!has_word(t, "news")) return false;
  // Do not steal "I have news" / "good news".
  if (has_any(t, {"what", "whats", "any", "latest", "top", "show", "give", "tell",
                  "get", "read", "brief", "briefing", "in", "about", "on"})) {
    return true;
  }
  if (t == "news" || t.rfind("news ", 0) == 0) return true;
  return false;
}

bool looks_like_markets(std::string_view t) {
  if (has_any(t, {"weather", "forecast", "temperature", "raining", "snowing"})) {
    return false;
  }
  if (has_any(t, {"bitcoin", "btc", "ethereum", "eth", "crypto", "cryptocurrency",
                  "dogecoin", "doge"})) {
    return true;
  }
  if (has_any(t, {"nasdaq", "dow"})) return true;
  if (t.find("s&p") != std::string_view::npos || has_word(t, "sp500")) return true;
  if (has_word(t, "s") && has_word(t, "p") && has_word(t, "500")) return true;
  if (has_any(t, {"stocks", "tickers", "ticker"})) return true;
  if (has_word(t, "stock") &&
      (has_any(t, {"price", "prices", "market", "markets", "quote", "share", "shares",
                   "doing", "today"}) ||
       has_any_instrument(t))) {
    return true;
  }
  if (has_word(t, "share") && has_any(t, {"price", "prices"})) return true;
  if (has_word(t, "quote") && has_any_instrument(t)) return true;
  if (has_any(t, {"market", "markets"})) {
    if (has_any(t, {"how", "hows", "whats", "what", "stock", "today", "doing",
                    "close", "the"})) {
      return true;
    }
    if (t == "market" || t == "markets") return true;
  }
  if (has_unambiguous_instrument(t) &&
      has_any(t, {"how", "hows", "whats", "what", "price", "worth", "trading",
                  "doing"})) {
    return true;
  }
  if (has_ambiguous_instrument(t) &&
      has_any(t, {"stock", "stocks", "share", "shares", "ticker", "quote", "price",
                  "trading"})) {
    return true;
  }
  return false;
}

bool is_empty_news_topic(std::string_view topic) {
  return topic.empty() || topic == "the news" || topic == "news" ||
         topic == "the headlines" || topic == "headlines" || topic == "me" ||
         topic == "us" || topic == "it" || topic == "them";
}

}  // namespace

const char* briefing_kind_name(BriefingKind kind) {
  switch (kind) {
    case BriefingKind::News:
      return "news";
    case BriefingKind::Markets:
      return "markets";
  }
  return "briefing";
}

std::string extract_news_topic(std::string_view transcript) {
  const std::string t = fold_phatic(transcript);
  if (t.empty() || !looks_like_news(t)) return {};

  std::string topic = take_after_prep(t, "about");
  if (topic.empty()) topic = take_after_prep(t, "regarding");
  if (topic.empty()) topic = take_after_prep(t, "on");
  if (topic.empty()) topic = take_after_prep(t, "for");
  topic = trim(topic);
  if (topic.rfind("the ", 0) == 0) topic = trim(topic.substr(4));
  if (is_empty_news_topic(topic)) return {};
  return topic;
}

std::vector<std::string> extract_market_symbols(std::string_view transcript) {
  const std::string t = fold_phatic(transcript);
  std::vector<std::string> out;
  auto add = [&](const char* symbol) {
    for (const auto& existing : out) {
      if (existing == symbol) return;
    }
    out.emplace_back(symbol);
  };

  // Longer spoken forms first so "dow jones" beats "dow", "s and p" beats "s".
  std::vector<const InstrumentAlias*> aliases;
  for (const auto& a : kInstruments) aliases.push_back(&a);
  std::sort(aliases.begin(), aliases.end(), [](const InstrumentAlias* a,
                                               const InstrumentAlias* b) {
    return std::string_view(a->spoken).size() > std::string_view(b->spoken).size();
  });

  std::string consumed = t;
  for (const auto* a : aliases) {
    if (!has_instrument_named(consumed, *a)) continue;
    add(a->symbol);
    // Avoid matching "apple" inside a leftover after we already took AAPL.
    const std::string needle = a->spoken;
    auto pos = consumed.find(needle);
    if (pos != std::string::npos) {
      consumed.replace(pos, needle.size(), " ");
    }
  }
  return out;
}

std::optional<BriefingIntent> parse_briefing_intent(std::string_view transcript) {
  const std::string t = fold_phatic(transcript);
  if (t.empty()) return std::nullopt;

  // Home weather / lights / timers own those turns.
  if (auto home = parse_home_intent(transcript)) {
    if (home->kind != HomeIntentKind::Weather ||
        !has_any(t, {"news", "headlines", "headline"})) {
      return std::nullopt;
    }
  }

  const bool news = looks_like_news(t);
  const bool markets = looks_like_markets(t);
  if (news && markets) {
    // "tesla news" / "stock market news" is a headlines ask.
    BriefingIntent in;
    in.kind = BriefingKind::News;
    in.confidence = BriefingConfidence::High;
    in.topic = extract_news_topic(transcript);
    if (in.topic.empty() && has_any_instrument(t)) {
      auto symbols = extract_market_symbols(transcript);
      if (!symbols.empty()) in.topic = symbols[0];
    }
    return in;
  }
  if (news) {
    BriefingIntent in;
    in.kind = BriefingKind::News;
    in.confidence = BriefingConfidence::High;
    in.topic = extract_news_topic(transcript);
    return in;
  }
  if (markets) {
    BriefingIntent in;
    in.kind = BriefingKind::Markets;
    in.confidence = BriefingConfidence::High;
    in.symbols = extract_market_symbols(transcript);
    return in;
  }

  // Medium: a known ticker/name is present with a weak "how is X" cue, but
  // no explicit finance/news word. Used for a sidecar card only.
  if (has_unambiguous_instrument(t) &&
      has_any(t, {"how", "hows", "whats", "what"}) &&
      !has_any(t, {"weather", "lights", "timer", "alarm", "volume"})) {
    BriefingIntent in;
    in.kind = BriefingKind::Markets;
    in.confidence = BriefingConfidence::Medium;
    in.symbols = extract_market_symbols(transcript);
    return in;
  }

  return std::nullopt;
}

}  // namespace intercom

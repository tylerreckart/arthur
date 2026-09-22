#pragma once

#include "intercom/home.hpp"
#include "intercom/home_client.hpp"
#include "intercom/markets_client.hpp"
#include "intercom/news_client.hpp"
#include "intercom/weather_client.hpp"

#include <nlohmann/json.hpp>

#include <memory>
#include <optional>
#include <string>
#include <string_view>

namespace intercom {

struct FastPathResult {
  std::string reply;
  std::string kind = "social";
  // Versioned desk card (null when the turn is speech-only).
  nlohmann::json surface = nullptr;
};

// Social greetings, thanks, and presence checks — not a reason to "look something up".
bool is_social_turn(std::string_view transcript);
// Time or date questions that should use the local clock, not tools.
bool is_clock_query(std::string_view transcript);
// True when fillers would talk over a greeting or a clock answer.
bool withholds_fillers(std::string_view transcript);

class FastPath {
 public:
  explicit FastPath(bool enabled);
  FastPath(bool enabled, HomeConfig home, std::shared_ptr<HomeClient> home_client,
           std::shared_ptr<WeatherClient> weather_client = nullptr,
           std::shared_ptr<NewsClient> news_client = nullptr,
           std::shared_ptr<MarketsClient> markets_client = nullptr);

  // Returns a local reply when the utterance should skip Arbiter.
  std::optional<FastPathResult> try_handle(const std::string& transcript) const;

 private:
  bool enabled_ = false;
  HomeConfig home_;
  std::shared_ptr<HomeClient> home_client_;
  std::shared_ptr<WeatherClient> weather_client_;
  std::shared_ptr<NewsClient> news_client_;
  std::shared_ptr<MarketsClient> markets_client_;
};

}  // namespace intercom

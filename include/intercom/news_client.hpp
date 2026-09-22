#pragma once

#include "intercom/briefing.hpp"
#include "intercom/surface.hpp"

#include <string>

namespace intercom {

// Headlines for desk news cards. Default implementation is Google News RSS
// plus configurable feeds (no API key). Tests inject a fake or point the
// RSS base at a mock HTTP server.
class NewsClient {
 public:
  NewsClient() = default;
  explicit NewsClient(NewsConfig cfg);
  virtual ~NewsClient() = default;

  virtual NewsExtract fetch(const std::string& topic, std::string* err) const;

 private:
  NewsConfig cfg_;
};

}  // namespace intercom

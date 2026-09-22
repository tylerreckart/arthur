#pragma once

#include "intercom/briefing.hpp"
#include "intercom/surface.hpp"

#include <string>
#include <vector>

namespace intercom {

// Quotes for desk markets cards. Default implementation is Yahoo Finance's
// unofficial public v7 quote JSON (no API key). Tests inject a fake or
// point quote_base at a mock HTTP server.
class MarketsClient {
 public:
  MarketsClient() = default;
  explicit MarketsClient(MarketsConfig cfg);
  virtual ~MarketsClient() = default;

  virtual MarketsExtract fetch(const std::vector<std::string>& symbols,
                               std::string* err) const;

 private:
  MarketsConfig cfg_;
};

}  // namespace intercom

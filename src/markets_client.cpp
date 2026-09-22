#include "intercom/markets_client.hpp"
#include "intercom/http_fetch.hpp"
#include "intercom/util.hpp"

namespace intercom {

MarketsClient::MarketsClient(MarketsConfig cfg) : cfg_(std::move(cfg)) {}

MarketsExtract MarketsClient::fetch(const std::vector<std::string>& symbols,
                                    std::string* err) const {
  std::vector<std::string> want = symbols;
  if (want.empty()) want = cfg_.default_symbols;
  if (want.empty()) {
    if (err) *err = "no market symbols";
    return {};
  }

  std::string joined;
  for (const auto& s : want) {
    const std::string t = trim(s);
    if (t.empty()) continue;
    if (!joined.empty()) joined.push_back(',');
    joined += url_query_encode(t);
  }
  if (joined.empty()) {
    if (err) *err = "no market symbols";
    return {};
  }

  const std::string base =
      cfg_.quote_base.empty() ? std::string("https://query1.finance.yahoo.com")
                              : cfg_.quote_base;
  std::string url = base;
  if (!url.empty() && url.back() == '/') url.pop_back();
  url += "/v7/finance/quote?symbols=" + joined;

  const std::string raw =
      http_get_url(url, cfg_.timeout_ms, err,
                   "Mozilla/5.0 (compatible; Arthur-Intercom/0.1)");
  if (raw.empty()) {
    if (err && err->empty()) *err = "quote lookup failed";
    return {};
  }
  auto extracted = markets_from_yahoo_quote(std::string_view{raw});
  if (!extracted.ok) {
    if (err) *err = "quote response missing instruments";
    return {};
  }
  return extracted;
}

}  // namespace intercom

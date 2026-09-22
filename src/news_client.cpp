#include "intercom/news_client.hpp"
#include "intercom/http_fetch.hpp"
#include "intercom/util.hpp"

namespace intercom {
namespace {

std::string default_top_feed(const NewsConfig& cfg) {
  if (!cfg.feeds.empty() && !cfg.feeds[0].url.empty()) return cfg.feeds[0].url;
  const std::string base = cfg.google_news_rss.empty()
                               ? std::string("https://news.google.com/rss")
                               : cfg.google_news_rss;
  if (base.find('?') != std::string::npos) return base;
  return base + "?hl=en-US&gl=US&ceid=US:en";
}

std::string search_url(const NewsConfig& cfg, const std::string& topic) {
  const std::string base = cfg.google_news_rss.empty()
                               ? std::string("https://news.google.com/rss")
                               : cfg.google_news_rss;
  return base + "/search?q=" + url_query_encode(topic) + "&hl=en-US&gl=US&ceid=US:en";
}

}  // namespace

NewsClient::NewsClient(NewsConfig cfg) : cfg_(std::move(cfg)) {}

NewsExtract NewsClient::fetch(const std::string& topic, std::string* err) const {
  const std::string q = trim(topic);
  const std::string url = q.empty() ? default_top_feed(cfg_) : search_url(cfg_, q);
  const std::string raw = http_get_url(url, cfg_.timeout_ms, err, "Arthur-Intercom/0.1");
  if (raw.empty()) {
    if (err && err->empty()) *err = "news feed empty";
    return {};
  }
  auto extracted = news_from_rss(raw, q, cfg_.max_items);
  if (!extracted.ok) {
    if (err) *err = "news feed had no headlines";
    return {};
  }
  if (!cfg_.feeds.empty() && !cfg_.feeds[0].name.empty() && q.empty()) {
    extracted.surface.title = cfg_.feeds[0].name;
  }
  return extracted;
}

}  // namespace intercom

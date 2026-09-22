#include "intercom/http_fetch.hpp"
#include "intercom/util.hpp"

#include <httplib.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <memory>
#include <sstream>

namespace intercom {
namespace {

void apply_timeouts(httplib::Client* cli, int timeout_ms) {
  if (!cli) return;
  const int sec = std::max(1, timeout_ms / 1000);
  const int usec = (timeout_ms % 1000) * 1000;
  cli->set_connection_timeout(sec, usec);
  cli->set_read_timeout(sec, usec);
  cli->set_write_timeout(sec, usec);
}

std::unique_ptr<httplib::Client> make_client(const ParsedHttpUrl& u, std::string* err) {
#ifndef CPPHTTPLIB_OPENSSL_SUPPORT
  if (u.https) {
    if (err) *err = "HTTPS requires OpenSSL";
    return nullptr;
  }
#endif
  std::ostringstream url;
  url << (u.https ? "https://" : "http://") << u.host;
  if ((u.https && u.port != 443) || (!u.https && u.port != 80)) {
    url << ':' << u.port;
  }
  return std::make_unique<httplib::Client>(url.str());
}

}  // namespace

std::string url_query_encode(std::string_view s) {
  std::string out;
  out.reserve(s.size() * 3);
  for (unsigned char c : s) {
    if (std::isalnum(c) || c == '-' || c == '.' || c == '_' || c == '~') {
      out.push_back(static_cast<char>(c));
    } else if (c == ' ') {
      out += "%20";
    } else {
      char buf[8];
      std::snprintf(buf, sizeof(buf), "%%%02X", c);
      out += buf;
    }
  }
  return out;
}

std::string http_get_url(const std::string& url, int timeout_ms, std::string* err,
                         std::string_view user_agent) {
  auto parsed = parse_http_url(url);
  if (!parsed) {
    if (err) *err = "invalid URL";
    return {};
  }
  auto cli = make_client(*parsed, err);
  if (!cli) return {};
  apply_timeouts(cli.get(), timeout_ms);
  std::string path = parsed->path.empty() ? "/" : parsed->path;
  httplib::Headers headers;
  if (!user_agent.empty()) {
    headers.emplace("User-Agent", std::string(user_agent));
  }
  auto res = headers.empty() ? cli->Get(path.c_str()) : cli->Get(path.c_str(), headers);
  if (!res) {
    if (err) *err = "provider unreachable";
    return {};
  }
  if (res->status != 200) {
    if (err) *err = "HTTP " + std::to_string(res->status);
    return {};
  }
  return res->body;
}

}  // namespace intercom

#pragma once

#include <cctype>
#include <string>
#include <string_view>

namespace intercom {

// The desk may read and change memory, schedules, and todos. Nothing else
// on Arbiter is reachable through the device token.
inline bool desk_proxy_allowed(std::string_view method, std::string_view path) {
  const auto query = path.find('?');
  const auto bare = path.substr(0, query);
  if (bare.empty() || bare.front() != '/') return false;
  if (bare.find("..") != std::string_view::npos) return false;

  auto digits_after = [&](std::string_view prefix) {
    if (bare.size() <= prefix.size() || bare.compare(0, prefix.size(), prefix) != 0) {
      return false;
    }
    const auto rest = bare.substr(prefix.size());
    if (rest.empty()) return false;
    for (unsigned char c : rest) {
      if (!std::isdigit(c)) return false;
    }
    return true;
  };

  if (method == "GET" && (bare == "/v1/memory/entries" || bare == "/v1/schedules" ||
                          bare == "/v1/todos")) {
    return true;
  }
  if (method == "POST" && (bare == "/v1/memory/entries" || bare == "/v1/schedules")) {
    return true;
  }
  if (method == "PATCH" &&
      (digits_after("/v1/memory/entries/") || digits_after("/v1/schedules/") ||
       digits_after("/v1/todos/"))) {
    return true;
  }
  if (method == "DELETE" && digits_after("/v1/memory/entries/")) return true;
  return false;
}

}  // namespace intercom

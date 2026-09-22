#pragma once

#include <string>
#include <string_view>

namespace intercom {

// Absolute-URL GET. Empty body on failure (err set). Optional User-Agent
// for providers that reject the default httplib header (Yahoo quote).
std::string http_get_url(const std::string& url, int timeout_ms, std::string* err,
                         std::string_view user_agent = {});

std::string url_query_encode(std::string_view s);

}  // namespace intercom

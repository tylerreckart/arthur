#pragma once

#include <nlohmann/json.hpp>

#include <string>
#include <string_view>
#include <vector>

namespace intercom {

// Desk metadata for one turn. The Mac sends it; the pipeline prepends it to
// the Arbiter message and never stores it as the user line.
struct ClientContext {
  struct Source {
    std::string name;
    std::string text;
  };
  std::vector<Source> sources;
};

// `context` is the object under the WS `context` field: `{sources:[{name,text}]}`.
// Unknown shapes yield an empty context. Sources are capped and sanitized.
ClientContext client_context_from_json(const nlohmann::json& context);

// Prepend a private block. The user message is unchanged at the end.
// Empty context returns `message` as-is.
std::string with_local_context(const ClientContext& context, std::string_view message);

}  // namespace intercom

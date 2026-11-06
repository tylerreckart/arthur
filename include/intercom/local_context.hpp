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
  struct Image {
    std::string media_type;
    std::string data;
  };
  std::vector<Source> sources;
  // One-shot pictures the user dropped or asked Arthur to look at.
  // They ride on this turn only and are never stored on the session.
  std::vector<Image> images;

  bool empty() const { return sources.empty() && images.empty(); }
};

// `context` is the object under the WS `context` field: `{sources:[{name,text}]}`.
// Unknown shapes yield an empty context. Sources are capped and sanitized.
ClientContext client_context_from_json(const nlohmann::json& context);

// Prepend a private block. The user message is unchanged at the end.
// Empty context returns `message` as-is. Images are not copied into the text.
std::string with_local_context(const ClientContext& context, std::string_view message);

// A string when there is no image. With images, Arbiter content parts:
// one text part, then image parts. The text part is `with_local_context`.
nlohmann::json user_message_json(const ClientContext& context, std::string_view message);

}  // namespace intercom

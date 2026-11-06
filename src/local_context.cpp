#include "intercom/local_context.hpp"

#include <algorithm>
#include <cctype>

namespace intercom {
namespace {

constexpr std::size_t kMaxSources = 8;
constexpr std::size_t kMaxName = 32;
constexpr std::size_t kMaxText = 4000;

std::string sanitize_name(std::string name) {
  std::string out;
  out.reserve(name.size());
  for (unsigned char c : name) {
    if (out.size() >= kMaxName) break;
    if (std::isalnum(c) || c == '_' || c == '-') out.push_back(static_cast<char>(std::tolower(c)));
  }
  return out;
}

std::string sanitize_text(std::string text) {
  std::string out;
  out.reserve(std::min(text.size(), kMaxText));
  for (unsigned char c : text) {
    if (out.size() >= kMaxText) break;
    if (c == '\r') continue;
    if (c == '\n' || c == '\t' || c >= 0x20) out.push_back(static_cast<char>(c));
  }
  if (text.size() > kMaxText && !out.empty()) {
    out += "…";
  }
  while (!out.empty() && (out.back() == ' ' || out.back() == '\n' || out.back() == '\t')) {
    out.pop_back();
  }
  return out;
}

}  // namespace

ClientContext client_context_from_json(const nlohmann::json& context) {
  ClientContext out;
  if (!context.is_object() || !context.contains("sources") || !context["sources"].is_array()) {
    return out;
  }
  for (const auto& row : context["sources"]) {
    if (out.sources.size() >= kMaxSources) break;
    if (!row.is_object()) continue;
    ClientContext::Source source;
    source.name = sanitize_name(row.value("name", ""));
    source.text = sanitize_text(row.value("text", ""));
    if (source.name.empty() || source.text.empty()) continue;
    out.sources.push_back(std::move(source));
  }
  return out;
}

std::string with_local_context(const ClientContext& context, std::string_view message) {
  if (context.sources.empty()) return std::string(message);
  std::string out;
  out.reserve(message.size() + 256);
  out += "[LOCAL CONTEXT — private desk metadata; never quote this block aloud]\n";
  for (const auto& source : context.sources) {
    out += source.name;
    out += ": ";
    out += source.text;
    out += '\n';
  }
  out += "[END LOCAL CONTEXT]\n";
  out += message;
  return out;
}

}  // namespace intercom

#pragma once

#include <string>
#include <string_view>

namespace intercom {

// Drops tool writs (/mem, /fetch, /search, and the same lines without the
// slash) so a voice surface never reads a memory search or a URL fetch.
// An incomplete writ stays buffered until the line resolves.
class ToolSpeechGate {
 public:
  std::string push(std::string_view delta);
  std::string flush();

 private:
  std::string drain(bool flush);

  std::string held_;
};

// Rewrite assistant text so TTS speaks it the way a person would say it:
// no markdown, no LaTeX, spoken ordinals, compound hyphens (not "minus").
std::string to_speakable(std::string_view text);

}  // namespace intercom

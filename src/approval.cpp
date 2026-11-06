#include "intercom/approval.hpp"

#include <cctype>
#include <string>

namespace intercom {
namespace {

std::string normalize(std::string_view text) {
  std::string out;
  out.reserve(text.size());
  bool space = false;
  for (unsigned char c : text) {
    if (c == '\'' ) continue;
    if (std::isspace(c) || std::ispunct(c)) {
      space = !out.empty();
      continue;
    }
    if (space) {
      out.push_back(' ');
      space = false;
    }
    out.push_back(static_cast<char>(std::tolower(c)));
  }
  return out;
}

bool one_of(const std::string& text, std::initializer_list<const char*> words) {
  for (const char* word : words) {
    if (text == word) return true;
  }
  return false;
}

}  // namespace

ApprovalDecision classify_approval(std::string_view text) {
  const std::string folded = normalize(text);
  if (folded.empty()) return ApprovalDecision::Other;
  if (one_of(folded, {"yes", "yeah", "yep", "yup", "sure", "ok", "okay", "do it",
                      "go ahead", "please do", "yes please", "yes do it", "approve",
                      "approved", "go on", "do that"})) {
    return ApprovalDecision::Yes;
  }
  if (one_of(folded, {"no", "nope", "nah", "dont", "do not", "cancel", "never mind",
                      "nevermind", "stop", "dismiss", "no thanks", "no thank you",
                      "dont do it"})) {
    return ApprovalDecision::No;
  }
  return ApprovalDecision::Other;
}

bool is_approval_intent(std::string_view pending) {
  return pending.size() > 9 && pending.substr(0, 9) == "approval:";
}

std::string approval_id_from_intent(std::string_view pending) {
  if (!is_approval_intent(pending)) return {};
  return std::string(pending.substr(9));
}

std::string make_approval_intent(std::string_view id) {
  std::string intent = "approval:";
  intent.append(id.data(), id.size());
  return intent;
}

}  // namespace intercom

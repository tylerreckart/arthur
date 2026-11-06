#pragma once

#include <string>
#include <string_view>

namespace intercom {

enum class ApprovalDecision { Yes, No, Other };

// Whole-utterance yes / no. Anything else leaves the prompt and the turn alone.
ApprovalDecision classify_approval(std::string_view text);

bool is_approval_intent(std::string_view pending);
std::string approval_id_from_intent(std::string_view pending);
std::string make_approval_intent(std::string_view id);

}  // namespace intercom

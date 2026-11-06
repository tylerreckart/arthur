#include "intercom/approval.hpp"

#include <iostream>
#include <string>

namespace {

int failed = 0;

void check(bool ok, const char* name) {
  if (ok) return;
  std::cerr << "FAIL " << name << std::endl;
  ++failed;
}

}  // namespace

int main() {
  using intercom::ApprovalDecision;
  check(intercom::classify_approval("Yes.") == ApprovalDecision::Yes, "yes");
  check(intercom::classify_approval("yeah!") == ApprovalDecision::Yes, "yeah");
  check(intercom::classify_approval("yes please") == ApprovalDecision::Yes, "yes please");
  check(intercom::classify_approval("No, thanks") == ApprovalDecision::No, "no thanks");
  check(intercom::classify_approval("don't") == ApprovalDecision::No, "dont");
  check(intercom::classify_approval("never mind") == ApprovalDecision::No, "never mind");
  check(intercom::classify_approval("move it to four") == ApprovalDecision::Other, "other");
  check(intercom::classify_approval("yesterday") == ApprovalDecision::Other, "yesterday");

  const std::string intent = intercom::make_approval_intent("abc-1");
  check(intercom::is_approval_intent(intent), "intent");
  check(intercom::approval_id_from_intent(intent) == "abc-1", "id");
  check(!intercom::is_approval_intent("timer_duration"), "timer");

  if (failed) return 1;
  std::cout << "test_approval ok" << std::endl;
  return 0;
}

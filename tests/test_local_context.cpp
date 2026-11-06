#include "intercom/local_context.hpp"

#include <iostream>
#include <string>

namespace {

int g_fails = 0;

void expect(bool cond, const char* expr, const char* file, int line) {
  if (!cond) {
    std::cerr << "FAIL " << file << ":" << line << " " << expr << "\n";
    ++g_fails;
  }
}

#define CHECK(cond) expect((cond), #cond, __FILE__, __LINE__)

}  // namespace

int main() {
  const auto empty = intercom::client_context_from_json(nlohmann::json::object());
  CHECK(empty.sources.empty());
  CHECK(intercom::with_local_context(empty, "what's on my afternoon") ==
        "what's on my afternoon");

  const auto bad = intercom::client_context_from_json(nlohmann::json{
      {"sources", "nope"},
  });
  CHECK(bad.sources.empty());

  const auto parsed = intercom::client_context_from_json(nlohmann::json{
      {"sources",
       nlohmann::json::array({
           nlohmann::json{{"name", "Calendar"}, {"text", "Today:\n- 3 PM Review"}},
           nlohmann::json{{"name", ""}, {"text", "skip"}},
           "skip",
           nlohmann::json{{"name", "calendar"}, {"text", "   "}},
       })},
  });
  CHECK(parsed.sources.size() == 1);
  if (!parsed.sources.empty()) {
    CHECK(parsed.sources[0].name == "calendar");
    CHECK(parsed.sources[0].text == "Today:\n- 3 PM Review");
  }

  const std::string user = "what's on my afternoon";
  const auto wrapped = intercom::with_local_context(parsed, user);
  CHECK(wrapped.find("[LOCAL CONTEXT") == 0);
  CHECK(wrapped.find("never quote this block aloud") != std::string::npos);
  CHECK(wrapped.find("[END LOCAL CONTEXT]\n" + user) != std::string::npos);
  CHECK(wrapped.size() >= user.size());
  CHECK(wrapped.compare(wrapped.size() - user.size(), user.size(), user) == 0);
  CHECK(wrapped.find(user) != 0);

  std::string huge(5000, 'a');
  const auto capped = intercom::client_context_from_json(nlohmann::json{
      {"sources", nlohmann::json::array({nlohmann::json{{"name", "calendar"}, {"text", huge}}})},
  });
  CHECK(capped.sources.size() == 1);
  if (!capped.sources.empty()) {
    CHECK(capped.sources[0].text.size() < huge.size());
    CHECK(capped.sources[0].text.find("…") != std::string::npos);
  }

  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_local_context ok\n";
  return 0;
}

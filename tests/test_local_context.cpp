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

  const auto pictured = intercom::client_context_from_json(nlohmann::json{
      {"sources", nlohmann::json::array({nlohmann::json{{"name", "screen"}, {"text", "A screenshot is attached."}}})},
      {"images",
       nlohmann::json::array({
           nlohmann::json{{"media_type", "image/jpeg"}, {"data", "aGVsbG8="}},
           nlohmann::json{{"media_type", "text/plain"}, {"data", "aGVsbG8="}},
           nlohmann::json{{"media_type", "image/png"}, {"data", "not base64!!!"}},
           "skip",
       })},
  });
  CHECK(pictured.sources.size() == 1);
  CHECK(pictured.images.size() == 1);
  if (!pictured.images.empty()) {
    CHECK(pictured.images[0].media_type == "image/jpeg");
    CHECK(pictured.images[0].data == "aGVsbG8=");
  }
  const auto parts = intercom::user_message_json(pictured, user);
  CHECK(parts.is_array());
  CHECK(parts.size() == 2);
  if (parts.is_array() && parts.size() == 2) {
    CHECK(parts[0].value("type", "") == "text");
    const std::string text = parts[0].value("text", "");
    CHECK(text.find("[LOCAL CONTEXT") == 0);
    CHECK(text.find("aGVsbG8=") == std::string::npos);
    CHECK(text.compare(text.size() - user.size(), user.size(), user) == 0);
    CHECK(parts[1].value("type", "") == "image");
    CHECK(parts[1]["source"].value("media_type", "") == "image/jpeg");
    CHECK(parts[1]["source"].value("data", "") == "aGVsbG8=");
  }
  const auto words_only = intercom::user_message_json(parsed, user);
  CHECK(words_only.is_string());
  CHECK(words_only.get<std::string>() == wrapped);

  const auto images_only = intercom::client_context_from_json(nlohmann::json{
      {"images", nlohmann::json::array({nlohmann::json{{"media_type", "IMAGE/PNG"}, {"data", "YWI="}}})},
  });
  CHECK(images_only.sources.empty());
  CHECK(!images_only.empty());
  CHECK(images_only.images.size() == 1);
  if (!images_only.images.empty()) CHECK(images_only.images[0].media_type == "image/png");

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

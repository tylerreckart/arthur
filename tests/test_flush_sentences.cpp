#include "intercom/util.hpp"

#include <iostream>
#include <string>
#include <vector>

namespace {

int g_fails = 0;

void expect(bool cond, const char* expr, const char* file, int line) {
  if (!cond) {
    std::cerr << "FAIL " << file << ":" << line << " " << expr << "\n";
    ++g_fails;
  }
}

void expect_eq(const std::string& a, const std::string& b, const char* file, int line) {
  if (a != b) {
    std::cerr << "FAIL " << file << ":" << line << " \"" << a << "\" != \"" << b << "\"\n";
    ++g_fails;
  }
}

void expect_size(const std::vector<std::string>& v, std::size_t n, const char* file, int line) {
  if (v.size() != n) {
    std::cerr << "FAIL " << file << ":" << line << " size " << v.size() << " != " << n << "\n";
    ++g_fails;
  }
}

#define CHECK(cond) expect((cond), #cond, __FILE__, __LINE__)
#define CHECK_EQ(a, b) expect_eq((a), (b), __FILE__, __LINE__)
#define CHECK_SIZE(v, n) expect_size((v), (n), __FILE__, __LINE__)

void test_incremental_then_final() {
  std::string buf = "Hello. How";
  auto first = intercom::flush_sentences(buf, false);
  CHECK_SIZE(first, 1);
  CHECK_EQ(first[0], "Hello.");
  CHECK_EQ(buf, "How");

  buf += " are you?";
  auto second = intercom::flush_sentences(buf, true);
  CHECK_SIZE(second, 1);
  CHECK_EQ(second[0], "How are you?");
  CHECK(buf.empty());
}

void test_no_emit_until_boundary() {
  std::string buf = "Hello there";
  auto none = intercom::flush_sentences(buf, false);
  CHECK(none.empty());
  CHECK_EQ(buf, "Hello there");
}

void test_final_flush_unpunctuated() {
  std::string buf = "no period yet";
  auto rest = intercom::flush_sentences(buf, true);
  CHECK_SIZE(rest, 1);
  CHECK_EQ(rest[0], "no period yet");
  CHECK(buf.empty());
}

void test_multiple_sentences() {
  std::string buf = "One. Two! Three? leftover";
  auto s = intercom::flush_sentences(buf, false);
  CHECK_SIZE(s, 3);
  CHECK_EQ(s[0], "One.");
  CHECK_EQ(s[1], "Two!");
  CHECK_EQ(s[2], "Three?");
  CHECK_EQ(buf, "leftover");
}

void test_early_words() {
  std::string growing = "one two three four five six sev";
  auto none = intercom::flush_sentences(growing, false, 7);
  CHECK(none.empty());
  CHECK_EQ(growing, "one two three four five six sev");

  std::string seven = "one two three four five six seven ";
  auto chunk = intercom::flush_sentences(seven, false, 7);
  CHECK_SIZE(chunk, 1);
  CHECK_EQ(chunk[0], "one two three four five six seven");
  CHECK(seven.empty());

  std::string mixed = "Hello. one two three four five six seven leftover";
  auto both = intercom::flush_sentences(mixed, false, 7);
  CHECK_SIZE(both, 2);
  CHECK_EQ(both[0], "Hello.");
  CHECK_EQ(both[1], "one two three four five six seven");
  CHECK_EQ(mixed, "leftover");

  std::string short_buf = "Hello there";
  auto still = intercom::flush_sentences(short_buf, false, 7);
  CHECK(still.empty());
  CHECK_EQ(short_buf, "Hello there");
}

void test_early_words_does_not_leave_leading_comma() {
  std::string buf =
      "Let me dig up what's recent, sir, and given the Lucy on your shelf";
  auto first = intercom::flush_sentences(buf, false, 7);
  CHECK_SIZE(first, 1);
  CHECK_EQ(first[0], "Let me dig up what's recent, sir");
  CHECK_EQ(buf.substr(0, 3), "and");
  CHECK(buf.empty() || buf.front() != ',');

  // Comma arrives in a later token after the 7-word cut (streaming).
  std::string late = "Let me dig up what's recent, sir ";
  auto cut = intercom::flush_sentences(late, false, 7);
  CHECK_SIZE(cut, 1);
  CHECK_EQ(cut[0], "Let me dig up what's recent, sir");
  CHECK(late.empty());

  std::string rest =
      ", and given the Lucy on your shelf, I'll lean toward human origins.";
  auto second = intercom::flush_sentences(rest, false, 7);
  CHECK_SIZE(second, 1);
  CHECK_EQ(second[0],
           "and given the Lucy on your shelf, I'll lean toward human origins.");
  CHECK(rest.empty());
  CHECK(second[0].front() != ',');
}

}  // namespace

int main() {
  test_incremental_then_final();
  test_no_emit_until_boundary();
  test_final_flush_unpunctuated();
  test_multiple_sentences();
  test_early_words();
  test_early_words_does_not_leave_leading_comma();
  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_flush_sentences ok\n";
  return 0;
}

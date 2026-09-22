#include "intercom/util.hpp"

#include <cctype>
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

std::string fold_words(const std::string& s) {
  std::string out;
  bool space = true;
  for (unsigned char c : s) {
    if (std::isalnum(c)) {
      if (space && !out.empty()) out.push_back(' ');
      out.push_back(static_cast<char>(std::tolower(c)));
      space = false;
    } else {
      space = true;
    }
  }
  return out;
}

bool words_in_order(const std::string& original, const std::string& rebuilt) {
  const auto split = [](const std::string& s) {
    std::vector<std::string> w;
    std::string cur;
    for (char c : fold_words(s)) {
      if (c == ' ') {
        if (!cur.empty()) w.push_back(cur);
        cur.clear();
      } else {
        cur.push_back(c);
      }
    }
    if (!cur.empty()) w.push_back(cur);
    return w;
  };
  const auto want = split(original);
  const auto got = split(rebuilt);
  std::size_t k = 0;
  for (const auto& word : want) {
    while (k < got.size() && got[k] != word) ++k;
    if (k == got.size()) return false;
    ++k;
  }
  return true;
}

void test_early_flush_preserves_all_words() {
  const std::string original =
      "Let me dig up what's recent, sir, and given the Lucy on your shelf, "
      "I'll lean toward human origins. Let me try a couple of angles, sir.";
  std::string buf;
  std::string rebuilt;
  auto take = [&](const std::vector<std::string>& chunks) {
    for (const auto& c : chunks) {
      if (!rebuilt.empty()) rebuilt.push_back(' ');
      rebuilt += c;
    }
  };
  for (char c : original) {
    buf.push_back(c);
    take(intercom::flush_sentences(buf, false, 7));
  }
  take(intercom::flush_sentences(buf, true, 7));
  CHECK(buf.empty());
  CHECK(words_in_order(original, rebuilt));
  CHECK(fold_words(rebuilt).find("lucy") != std::string::npos);
  CHECK(fold_words(rebuilt).find("origins") != std::string::npos);
  CHECK(fold_words(rebuilt).find("angles") != std::string::npos);
}

void test_strip_after_early_cut_keeps_substantive_words() {
  std::string buf = "one two three four five six seven: leftover words stay here";
  auto first = intercom::flush_sentences(buf, false, 7);
  CHECK_SIZE(first, 1);
  CHECK_EQ(first[0], "one two three four five six seven");
  CHECK(buf.find("leftover") != std::string::npos);
  CHECK(buf.find("stay") != std::string::npos);
  CHECK(words_in_order("leftover words stay here", buf));

  std::string comma =
      "Let me dig up what's recent, sir, and given the Lucy on your shelf";
  auto cut = intercom::flush_sentences(comma, false, 7);
  CHECK_SIZE(cut, 1);
  CHECK(words_in_order("and given the Lucy on your shelf", comma));
  CHECK(comma.find("and") == 0);
}

void test_multiple_said_chunks_rebuild_reply() {
  std::string buf =
      "Let me dig up what's recent, sir, and given the Lucy on your shelf, "
      "I'll lean toward human origins. Let me try a couple of angles, sir.";
  std::vector<std::string> saids;
  auto first = intercom::flush_sentences(buf, false, 7);
  saids.insert(saids.end(), first.begin(), first.end());
  auto more = intercom::flush_sentences(buf, false, 7);
  saids.insert(saids.end(), more.begin(), more.end());
  auto rest = intercom::flush_sentences(buf, true, 7);
  saids.insert(saids.end(), rest.begin(), rest.end());
  CHECK(saids.size() >= 2);
  std::string rebuilt;
  for (const auto& s : saids) {
    if (!rebuilt.empty()) rebuilt.push_back(' ');
    rebuilt += s;
  }
  CHECK(words_in_order(
      "Let me dig up what's recent sir and given the Lucy on your shelf "
      "I'll lean toward human origins Let me try a couple of angles sir",
      rebuilt));
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
  test_early_flush_preserves_all_words();
  test_strip_after_early_cut_keeps_substantive_words();
  test_multiple_said_chunks_rebuild_reply();
  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_flush_sentences ok\n";
  return 0;
}

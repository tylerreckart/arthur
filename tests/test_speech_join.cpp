// Mirrors macos/Arthur/Sources/Notebook.swift `ArthurProseJoin`.
// Keep these cases in sync when the Mac stitch rules change.

#include <cctype>
#include <iostream>
#include <set>
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

#define CHECK(cond) expect((cond), #cond, __FILE__, __LINE__)
#define CHECK_EQ(a, b) expect_eq((a), (b), __FILE__, __LINE__)

std::string fold(const std::string& text) {
  std::string out;
  bool space = true;
  for (unsigned char c : text) {
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

bool already_spoken(const std::string& previous, const std::string& incoming) {
  const std::string h = fold(previous);
  const std::string n = fold(incoming);
  if (n.empty()) return true;
  return h == n || h.rfind(n + " ", 0) == 0;
}

bool is_growing_prefix(const std::string& previous, const std::string& incoming) {
  const std::string h = fold(previous);
  const std::string n = fold(incoming);
  if (h.empty() || n.size() <= h.size()) return false;
  return n.rfind(h + " ", 0) == 0;
}

bool ends_sentence(const std::string& text) {
  std::string t = text;
  while (!t.empty() && std::isspace(static_cast<unsigned char>(t.back()))) t.pop_back();
  if (t.empty()) return false;
  const char c = t.back();
  return c == '.' || c == '!' || c == '?';
}

bool starts_clause_punct(const std::string& text) {
  std::size_t i = 0;
  while (i < text.size() && std::isspace(static_cast<unsigned char>(text[i]))) ++i;
  if (i >= text.size()) return false;
  return text[i] == ',' || text[i] == ';' || text[i] == ':';
}

std::string strip_leading_clause(std::string s) {
  std::size_t i = 0;
  while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;
  while (i < s.size() && (s[i] == ',' || s[i] == ';' || s[i] == ':')) {
    ++i;
    while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;
  }
  return s.substr(i);
}

const std::set<std::string> kCont = {
    "and", "but", "or", "so", "yet", "nor", "then", "though",
    "because", "while", "plus", "also",
};

std::string first_word(const std::string& s) {
  std::string w;
  for (unsigned char c : s) {
    if (std::isspace(c)) break;
    w.push_back(static_cast<char>(std::tolower(c)));
  }
  return w;
}

bool is_continuation(const std::string& left, const std::string& right) {
  const std::string bare = strip_leading_clause(right);
  const std::string w = first_word(bare);
  if (!kCont.count(w)) return false;
  if (starts_clause_punct(right)) return true;
  if (!ends_sentence(left)) return true;
  return !bare.empty() && std::islower(static_cast<unsigned char>(bare.front()));
}

std::string stitch(const std::string& left, const std::string& right) {
  const std::string right_bare = strip_leading_clause(right);
  if (is_continuation(left, right)) {
    std::string stem = left;
    if (ends_sentence(stem)) {
      stem.pop_back();
      while (!stem.empty() && std::isspace(static_cast<unsigned char>(stem.back()))) {
        stem.pop_back();
      }
    }
    return stem + ", " + right_bare;
  }
  return left + " " + (starts_clause_punct(right) ? right_bare : right);
}

std::string join(const std::string& previous, const std::string& incoming) {
  std::string left = previous;
  std::string right = incoming;
  while (!left.empty() && std::isspace(static_cast<unsigned char>(left.front()))) {
    left.erase(left.begin());
  }
  while (!right.empty() && std::isspace(static_cast<unsigned char>(right.front()))) {
    right.erase(right.begin());
  }
  if (left.empty()) return right;
  if (right.empty()) return left;
  if (already_spoken(left, right)) return left;
  if (is_growing_prefix(left, right)) return right;
  return stitch(left, right);
}

bool has_word(const std::string& text, const std::string& word) {
  return fold(text).find(word) != std::string::npos;
}

void test_screenshot_fragments_keep_every_word() {
  const std::string a = "Let me dig up what's recent, sir.";
  const std::string b = ", and given the Lucy on your shelf, I'll lean toward human origins.";
  const std::string c = "Let me try a couple of angles, sir.";
  const std::string joined = join(join(a, b), c);
  CHECK(has_word(joined, "dig"));
  CHECK(has_word(joined, "lucy"));
  CHECK(has_word(joined, "origins"));
  CHECK(has_word(joined, "angles"));
  CHECK(joined.find(", and given") != std::string::npos);
}

void test_multiple_said_same_turn_no_drop() {
  std::string acc;
  const std::vector<std::string> saids = {
      "Let me look over the latest notes from the dig.",
      "There is a new paper on the Laetoli prints.",
      "I can pull a couple of angles if you want.",
  };
  for (const auto& s : saids) acc = join(acc, s);
  CHECK(has_word(acc, "latest"));
  CHECK(has_word(acc, "laetoli"));
  CHECK(has_word(acc, "angles"));
}

void test_forming_tail_does_not_replace_said() {
  const std::string said = "Let me dig up what's recent, sir.";
  const std::string tail = "origins. Let me try a couple of angles, sir.";
  CHECK(!is_growing_prefix(said, tail));
  CHECK(!already_spoken(said, tail));
  const std::string shown = join(said, tail);
  CHECK(has_word(shown, "dig"));
  CHECK(has_word(shown, "recent"));
  CHECK(has_word(shown, "angles"));
}

void test_suffix_sir_is_not_already_spoken() {
  const std::string said = "Let me dig up what's recent, sir.";
  const std::string next = "I'll lean toward human origins, sir.";
  CHECK(!already_spoken(said, next));
  const std::string shown = join(said, next);
  CHECK(has_word(shown, "dig"));
  CHECK(has_word(shown, "origins"));
}

void test_growing_prefix_keeps_new_words() {
  const std::string said = "Let me dig up what's recent";
  const std::string forming =
      "Let me dig up what's recent, sir, and given the Lucy on your shelf";
  CHECK(is_growing_prefix(said, forming));
  const std::string shown = join(said, forming);
  CHECK(has_word(shown, "lucy"));
  CHECK_EQ(fold(shown), fold(forming));
}

void test_duplicate_said_does_not_drop_earlier_unique_words() {
  const std::string acc =
      "Let me dig up what's recent, sir, and given the Lucy on your shelf.";
  const std::string dup = "Let me dig up what's recent, sir.";
  CHECK(already_spoken(acc, dup));
  const std::string shown = join(acc, dup);
  CHECK(has_word(shown, "lucy"));
}

}  // namespace

int main() {
  test_screenshot_fragments_keep_every_word();
  test_multiple_said_same_turn_no_drop();
  test_forming_tail_does_not_replace_said();
  test_suffix_sir_is_not_already_spoken();
  test_growing_prefix_keeps_new_words();
  test_duplicate_said_does_not_drop_earlier_unique_words();
  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_speech_join ok\n";
  return 0;
}

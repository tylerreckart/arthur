#include "intercom/speakable.hpp"

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

void expect_eq(const std::string& a, const std::string& b, const char* file, int line) {
  if (a != b) {
    std::cerr << "FAIL " << file << ":" << line << " \"" << a << "\" != \"" << b << "\"\n";
    ++g_fails;
  }
}

#define CHECK(cond) expect((cond), #cond, __FILE__, __LINE__)
#define CHECK_EQ(a, b) expect_eq((a), (b), __FILE__, __LINE__)

bool contains(const std::string& s, const char* needle) {
  return s.find(needle) != std::string::npos;
}

}  // namespace

int main() {
  CHECK_EQ(intercom::to_speakable("well-known"), "well known.");
  CHECK(!contains(intercom::to_speakable("well-known"), "minus"));
  CHECK(!contains(intercom::to_speakable("state-of-the-art"), "minus"));
  CHECK_EQ(intercom::to_speakable("It's the 14th."), "It's the fourteenth.");
  CHECK_EQ(intercom::to_speakable("the 1st, 2nd, 3rd and 21st"),
           "the first, second, third and twenty first.");
  CHECK_EQ(intercom::to_speakable("14th"), "fourteenth.");
  CHECK_EQ(intercom::to_speakable("14 th"), "fourteenth.");
  CHECK(!contains(intercom::to_speakable("On the 14th of August"), "14"));
  CHECK(contains(intercom::to_speakable("On the 14th of August"), "fourteenth"));
  CHECK_EQ(intercom::to_speakable("rooms 14-16"), "rooms 14 to 16.");
  CHECK(contains(intercom::to_speakable("2 - 3"), "minus"));
  CHECK(contains(intercom::to_speakable("-5"), "negative"));
  CHECK(contains(intercom::to_speakable("Hello — world"), ","));
  CHECK(!contains(intercom::to_speakable("Hello — world"), "minus"));
  CHECK_EQ(intercom::to_speakable("Wait... okay"), "Wait, okay.");
  CHECK(contains(intercom::to_speakable("2 * 3"), "times"));
  CHECK(contains(intercom::to_speakable("2/3"), "over"));

  const char* kMemoryTurn =
      "/mem search market headlines\n"
      "/search stock market today November 4 2026 reaction midterms top=5\n"
      "One moment while I pull the market picture, sir.\n"
      "/fetch https://www.cnbc.com/markets\n"
      "/fetch https://finance.yahoo.com/markets\n";
  const std::string spoken = intercom::to_speakable(kMemoryTurn);
  CHECK_EQ(spoken, "One moment while I pull the market picture, sir.");
  CHECK(!contains(spoken, "mem"));
  CHECK(!contains(spoken, "cnbc"));
  CHECK(!contains(spoken, "yahoo"));

  const char* kOneLine =
      "mem search market headlines search stock market today November 4 2026 "
      "reaction midterms top=5 One moment while I pull the market picture, sir. "
      "fetch https://www.cnbc.com/markets fetch https://finance.yahoo.com/markets";
  CHECK_EQ(intercom::to_speakable(kOneLine),
           "One moment while I pull the market picture, sir.");
  CHECK_EQ(intercom::to_speakable("/mem search coffee"), "");
  CHECK_EQ(intercom::to_speakable("Search the latest headlines."),
           "Search the latest headlines.");
  CHECK_EQ(intercom::to_speakable("I'll fetch the report."), "I'll fetch the report.");
  CHECK_EQ(intercom::to_speakable("Hello. /mem search coffee"), "Hello.");

  intercom::ToolSpeechGate gate;
  CHECK_EQ(gate.push("/mem sea"), "");
  CHECK_EQ(gate.push("rch coffee\nHello."), "Hello.");
  CHECK_EQ(gate.flush(), "");

  // The model invented a weather pseudo-writ and ran its prose straight
  // into it. The writ drops, the seam gets its space back, and the
  // model's "sir ," spacing is tightened.
  const char* kWeatherTurn =
      "One moment, sir , fetching the Philadelphia forecast. "
      "weather Philadelphia forecastThe national weather service is being "
      "stubborn, sir , I'll try the open forecast service instead.";
  const std::string weather = intercom::to_speakable(kWeatherTurn);
  CHECK(!contains(weather, "weather Philadelphia"));
  CHECK(contains(weather, "forecast. The national weather service"));
  CHECK(!contains(weather, " ,"));
  CHECK(contains(weather, "sir, I'll try"));

  // Prose keeps its shape: mid-sentence weather, lowercase continuation,
  // and domains are untouched by the writ gate and seam repair.
  CHECK_EQ(intercom::to_speakable("The weather Tuesday will be cold, sir."),
           "The weather Tuesday will be cold, sir.");
  CHECK_EQ(intercom::to_speakable("Weather in Philadelphia looks grim, sir."),
           "Weather in Philadelphia looks grim, sir.");
  CHECK(contains(intercom::to_speakable("see www.cnbc.com/markets"), "www.cnbc.com"));
  CHECK_EQ(intercom::to_speakable("/weather Philadelphia forecast"), "");

  // Paragraph breaks survive to the transcript; single newlines do not.
  const std::string para = intercom::to_speakable("First topic done.\n\nSecond topic here.");
  CHECK_EQ(para, "First topic done.\n\nSecond topic here.");
  CHECK_EQ(intercom::to_speakable("one line\nnext line"), "one line next line.");

  // Routing chrome from a /parallel fan-out is not speech, even when the
  // arrow arrives split across deltas.
  const std::string delegated = intercom::to_speakable(
      "One moment.\n\xE2\x86\x92 delegating: /parallel (2 children)\n"
      "Paris and Berlin.");
  CHECK(!contains(delegated, "delegating"));
  CHECK(!contains(delegated, "parallel"));
  CHECK(contains(delegated, "One moment."));
  CHECK(contains(delegated, "Paris and Berlin."));

  intercom::ToolSpeechGate route;
  CHECK_EQ(route.push("Right.\n\xE2\x86"), "Right.\n");
  CHECK_EQ(route.push("\x92 delegating: /agent scout tides\nThe tide is in."),
           "The tide is in.");
  CHECK_EQ(route.flush(), "");

  intercom::DelegationRoster roster;
  roster.start(0, 0);
  CHECK(roster.open() == 0);
  roster.start(1, 1);
  roster.start(2, 1);
  roster.start(1, 1);
  CHECK(roster.open() == 2);
  roster.end(1, 1);
  CHECK(roster.open() == 1);
  roster.end(0, 0);
  CHECK(roster.open() == 1);
  roster.end(2, 1);
  CHECK(roster.open() == 0);
  roster.start(3, 2);
  roster.end(3, -1);
  CHECK(roster.open() == 0);

  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_speakable ok\n";
  return 0;
}

#include "intercom/desk_proxy.hpp"

#include <iostream>

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
  using intercom::desk_proxy_allowed;
  CHECK(desk_proxy_allowed("GET", "/v1/memory/entries"));
  CHECK(desk_proxy_allowed("GET", "/v1/memory/entries?q=kitchen"));
  CHECK(desk_proxy_allowed("POST", "/v1/memory/entries"));
  CHECK(desk_proxy_allowed("PATCH", "/v1/memory/entries/42"));
  CHECK(desk_proxy_allowed("DELETE", "/v1/memory/entries/42"));
  CHECK(desk_proxy_allowed("GET", "/v1/schedules"));
  CHECK(desk_proxy_allowed("GET", "/v1/schedules?status=active"));
  CHECK(desk_proxy_allowed("POST", "/v1/schedules"));
  CHECK(desk_proxy_allowed("PATCH", "/v1/schedules/17"));
  CHECK(desk_proxy_allowed("GET", "/v1/todos"));
  CHECK(desk_proxy_allowed("PATCH", "/v1/todos/14"));

  CHECK(!desk_proxy_allowed("GET", "/v1/conversations"));
  CHECK(!desk_proxy_allowed("DELETE", "/v1/schedules/17"));
  CHECK(!desk_proxy_allowed("POST", "/v1/todos"));
  CHECK(!desk_proxy_allowed("PATCH", "/v1/memory/entries/"));
  CHECK(!desk_proxy_allowed("PATCH", "/v1/memory/entries/42/invalidate"));
  CHECK(!desk_proxy_allowed("GET", "/v1/memory/entries/../admin"));
  CHECK(!desk_proxy_allowed("GET", "/v1/memory/entries/42"));

  if (g_fails) {
    std::cerr << g_fails << " failed\n";
    return 1;
  }
  std::cout << "ok\n";
  return 0;
}

#include "intercom/arbiter_client.hpp"
#include "intercom/device_hub.hpp"
#include "intercom/session_store.hpp"
#include "intercom/stt.hpp"
#include "intercom/tts.hpp"
#include "intercom/turn_pipeline.hpp"
#include "intercom/ws.hpp"

#include <nlohmann/json.hpp>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {

int g_fails = 0;

void expect(bool cond, const char* expr, const char* file, int line) {
  if (!cond) {
    std::cerr << "FAIL " << file << ":" << line << " " << expr << "\n";
    ++g_fails;
  }
}

#define CHECK(cond) expect((cond), #cond, __FILE__, __LINE__)

class DummyStt : public intercom::SttProvider {
 public:
  std::string transcribe(const std::vector<std::uint8_t>& pcm, int, int, std::string*) override {
    last_pcm = pcm;
    return pcm.empty() ? std::string() : std::string("status");
  }
  bool ready(std::string*) const override { return true; }
  std::vector<std::uint8_t> last_pcm;
};

class RecordingTts : public intercom::TtsProvider {
 public:
  bool synthesize(const std::string& text, PcmChunkFn on_chunk, std::string*) override {
    last = text;
    const std::uint8_t pcm[4] = {1, 2, 3, 4};
    if (on_chunk) on_chunk(pcm, sizeof(pcm));
    return true;
  }
  bool ready(std::string*) const override { return true; }
  std::string last;
};

class DummyArbiter : public intercom::ArbiterClient {
 public:
  DummyArbiter() : ArbiterClient("http://127.0.0.1:9", "", "arthur") {}
  std::optional<std::int64_t> create_conversation(const std::string&,
                                                  std::string*) const override {
    return 1;
  }
  bool send_message(std::int64_t, const std::string&, const std::string&,
                    intercom::ArbiterStreamCallbacks cbs, std::atomic<bool>*,
                    std::string*) const override {
    if (cbs.on_done) cbs.on_done(true, "ok", "");
    return true;
  }
  bool cancel_request(const std::string&, std::string*) const override { return true; }
};

bool send_all(int fd, const void* data, std::size_t len) {
  const auto* p = static_cast<const std::uint8_t*>(data);
  std::size_t sent = 0;
  while (sent < len) {
    const ssize_t n = ::send(fd, p + sent, len - sent, 0);
    if (n <= 0) return false;
    sent += static_cast<std::size_t>(n);
  }
  return true;
}

std::string recv_some(int fd, int timeout_ms) {
  std::string out;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  char buf[2048];
  while (std::chrono::steady_clock::now() < deadline) {
    const ssize_t n = ::recv(fd, buf, sizeof(buf), MSG_DONTWAIT);
    if (n > 0) {
      out.append(buf, static_cast<std::size_t>(n));
      if (out.find("\r\n\r\n") != std::string::npos || out.size() > 16) return out;
    } else {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
  }
  return out;
}

int connect_ws(int port, const std::string& extra_headers, std::string* handshake) {
  const int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(static_cast<std::uint16_t>(port));
  ::inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
  if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    ::close(fd);
    return -1;
  }
  std::string req =
      "GET /v1/stream HTTP/1.1\r\n"
      "Host: 127.0.0.1\r\n"
      "Upgrade: websocket\r\n"
      "Connection: Upgrade\r\n"
      "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
      "Sec-WebSocket-Version: 13\r\n";
  req += extra_headers;
  req += "\r\n";
  if (!send_all(fd, req.data(), req.size())) {
    ::close(fd);
    return -1;
  }
  *handshake = recv_some(fd, 2000);
  return fd;
}

}  // namespace

int main() {
  CHECK(intercom::ws_accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");

  {
    intercom::WsFrame f;
    f.opcode = intercom::WsOpcode::Text;
    f.payload = "Hello";
    const std::string raw = intercom::encode_ws_frame(f, true);
    std::size_t used = 0;
    auto back = intercom::decode_ws_frame(raw, &used);
    CHECK(back.has_value());
    if (back) {
      CHECK(back->payload == "Hello");
      CHECK(back->opcode == intercom::WsOpcode::Text);
    }
    CHECK(used == raw.size());
  }

  auto tts = std::make_shared<RecordingTts>();
  auto arbiter = std::make_shared<DummyArbiter>();
  auto stt = std::make_shared<DummyStt>();
  const auto db = std::filesystem::temp_directory_path() / "intercom_ws.db";
  std::filesystem::remove(db);
  auto sessions = std::make_shared<intercom::SessionStore>(db.string());
  std::string err;
  CHECK(sessions->open(&err));

  intercom::Config config;
  config.listen_host = "127.0.0.1";
  config.device_token = "dev-device-secret-change-me";
  config.fast_path = true;
  config.filler.enabled = false;
  config.sample_rate = 24000;

  auto pipeline = std::make_shared<intercom::TurnPipeline>(config, stt, tts, arbiter, sessions,
                                                           nullptr);
  auto hub = std::make_shared<intercom::DeviceHub>(tts, 4);
  intercom::ServerDeps deps;
  deps.config = config;
  deps.pipeline = pipeline;
  deps.hub = hub;

  intercom::WsServer ws(deps);
  CHECK(ws.listen("127.0.0.1", 0));
  CHECK(ws.port() > 0);

  std::string hs;
  const int bad = connect_ws(ws.port(), "X-Device-Id: speaker-1\r\nAuthorization: Bearer nope\r\n",
                             &hs);
  CHECK(bad >= 0);
  if (bad >= 0) {
    CHECK(hs.find("401") != std::string::npos);
    ::close(bad);
  }

  hs.clear();
  const int fd = connect_ws(ws.port(),
                            "X-Device-Id: speaker-1\r\n"
                            "Authorization: Bearer dev-device-secret-change-me\r\n",
                            &hs);
  CHECK(fd >= 0);
  CHECK(hs.find("101") != std::string::npos);
  CHECK(hs.find("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != std::string::npos);

  if (fd >= 0) {
    intercom::WsFrame text;
    text.opcode = intercom::WsOpcode::Text;
    text.payload = R"({"type":"text","text":"status"})";
    const std::string framed = intercom::encode_ws_frame(text, true);
    CHECK(send_all(fd, framed.data(), framed.size()));

    std::string incoming;
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(3000);
    bool got_done = false;
    bool got_binary = false;
    while (std::chrono::steady_clock::now() < deadline && !got_done) {
      char buf[4096];
      const ssize_t n = ::recv(fd, buf, sizeof(buf), MSG_DONTWAIT);
      if (n > 0) incoming.append(buf, static_cast<std::size_t>(n));
      while (true) {
        std::size_t used = 0;
        auto frame = intercom::decode_ws_frame(incoming, &used);
        if (!frame) break;
        incoming.erase(0, used);
        if (frame->opcode == intercom::WsOpcode::Binary && !frame->payload.empty()) {
          got_binary = true;
        }
        if (frame->opcode == intercom::WsOpcode::Text) {
          try {
            auto j = nlohmann::json::parse(frame->payload);
            if (j.value("type", "") == "accept") {
              CHECK(!j.value("turn_id", "").empty());
            }
            if (j.value("type", "") == "done") {
              CHECK(j.value("ok", false));
              got_done = true;
            }
          } catch (...) {
          }
        }
      }
      if (!got_done) std::this_thread::sleep_for(std::chrono::milliseconds(15));
    }
    CHECK(got_binary);
    CHECK(got_done);
    CHECK(tts->last.find("sir") != std::string::npos);

    CHECK(hub->online("speaker-1"));
    CHECK(hub->speak("speaker-1", "Time to leave, sir.", "schedule", 42));

    incoming.clear();
    bool got_speak = false;
    bool speak_binary = false;
    bool speak_done = false;
    std::int64_t speak_run = 0;
    const auto speak_deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(2000);
    while (std::chrono::steady_clock::now() < speak_deadline && !speak_done) {
      char buf[4096];
      const ssize_t n = ::recv(fd, buf, sizeof(buf), MSG_DONTWAIT);
      if (n > 0) incoming.append(buf, static_cast<std::size_t>(n));
      while (true) {
        std::size_t used = 0;
        auto frame = intercom::decode_ws_frame(incoming, &used);
        if (!frame) break;
        incoming.erase(0, used);
        if (frame->opcode == intercom::WsOpcode::Binary && !frame->payload.empty()) {
          speak_binary = true;
        }
        if (frame->opcode == intercom::WsOpcode::Text) {
          try {
            auto j = nlohmann::json::parse(frame->payload);
            const auto type = j.value("type", "");
            if (type == "speak") {
              got_speak = true;
              CHECK(j.value("kind", "") == "schedule");
              speak_run = j.value("run_id", 0);
            }
            if (type == "done" && j.value("kind", "") == "schedule") {
              CHECK(j.value("ok", false));
              speak_done = true;
            }
          } catch (...) {
          }
        }
      }
      if (!speak_done) std::this_thread::sleep_for(std::chrono::milliseconds(15));
    }
    CHECK(got_speak);
    CHECK(speak_binary);
    CHECK(speak_done);
    CHECK(speak_run == 42);
    CHECK(tts->last.find("Time to leave") != std::string::npos);

    // Stream PCM in several binary frames while PTT is held, then end.
    const std::string chunk_a(4, 'A');
    const std::string chunk_b(6, 'B');
    const std::string chunk_c(8, 'C');
    for (const auto& chunk : {chunk_a, chunk_b, chunk_c}) {
      intercom::WsFrame pcm_f;
      pcm_f.opcode = intercom::WsOpcode::Binary;
      pcm_f.payload = chunk;
      const std::string pcm_raw = intercom::encode_ws_frame(pcm_f, true);
      CHECK(send_all(fd, pcm_raw.data(), pcm_raw.size()));
    }
    intercom::WsFrame end;
    end.opcode = intercom::WsOpcode::Text;
    end.payload = R"({"type":"end"})";
    const std::string end_raw = intercom::encode_ws_frame(end, true);
    CHECK(send_all(fd, end_raw.data(), end_raw.size()));

    incoming.clear();
    got_done = false;
    bool got_accept = false;
    std::string accept_id;
    std::string turn_id;
    const auto end_deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(3000);
    while (std::chrono::steady_clock::now() < end_deadline && !got_done) {
      char buf[4096];
      const ssize_t n = ::recv(fd, buf, sizeof(buf), MSG_DONTWAIT);
      if (n > 0) incoming.append(buf, static_cast<std::size_t>(n));
      while (true) {
        std::size_t used = 0;
        auto frame = intercom::decode_ws_frame(incoming, &used);
        if (!frame) break;
        incoming.erase(0, used);
        if (frame->opcode == intercom::WsOpcode::Text) {
          try {
            auto j = nlohmann::json::parse(frame->payload);
            const auto type = j.value("type", "");
            if (type == "accept") {
              got_accept = true;
              accept_id = j.value("turn_id", "");
            }
            if (type == "turn") turn_id = j.value("turn_id", "");
            if (type == "done") got_done = true;
          } catch (...) {
          }
        }
      }
      if (!got_done) std::this_thread::sleep_for(std::chrono::milliseconds(15));
    }
    CHECK(got_done);
    CHECK(got_accept);
    CHECK(!accept_id.empty());
    CHECK(accept_id == turn_id);
    CHECK(stt->last_pcm.size() == chunk_a.size() + chunk_b.size() + chunk_c.size());
    CHECK(std::string(stt->last_pcm.begin(), stt->last_pcm.end()) == chunk_a + chunk_b + chunk_c);
    ::close(fd);
  }

  ws.stop();
  std::filesystem::remove(db);

  if (g_fails != 0) {
    std::cerr << g_fails << " failure(s)\n";
    return 1;
  }
  std::cout << "test_ws_stream ok\n";
  return 0;
}

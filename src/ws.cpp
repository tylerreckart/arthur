#include "intercom/ws.hpp"
#include "intercom/device_hub.hpp"
#include "intercom/util.hpp"

#include <nlohmann/json.hpp>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstring>
#include <iostream>
#include <sstream>

namespace intercom {
namespace {

constexpr const char* kWsMagic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
constexpr const char* kWsPath = "/v1/stream";
constexpr auto kWsPingEvery = std::chrono::seconds(20);
constexpr auto kWsPongWait = std::chrono::seconds(10);

std::uint32_t rol(std::uint32_t v, int n) { return (v << n) | (v >> (32 - n)); }

std::string sha1(std::string_view data) {
  std::uint32_t h0 = 0x67452301u;
  std::uint32_t h1 = 0xEFCDAB89u;
  std::uint32_t h2 = 0x98BADCFEu;
  std::uint32_t h3 = 0x10325476u;
  std::uint32_t h4 = 0xC3D2E1F0u;

  std::vector<std::uint8_t> msg(data.begin(), data.end());
  const std::uint64_t bit_len = static_cast<std::uint64_t>(msg.size()) * 8;
  msg.push_back(0x80);
  while ((msg.size() % 64) != 56) msg.push_back(0);
  for (int i = 7; i >= 0; --i) {
    msg.push_back(static_cast<std::uint8_t>((bit_len >> (i * 8)) & 0xff));
  }

  for (std::size_t off = 0; off < msg.size(); off += 64) {
    std::uint32_t w[80];
    for (int i = 0; i < 16; ++i) {
      w[i] = (static_cast<std::uint32_t>(msg[off + i * 4]) << 24) |
             (static_cast<std::uint32_t>(msg[off + i * 4 + 1]) << 16) |
             (static_cast<std::uint32_t>(msg[off + i * 4 + 2]) << 8) |
             static_cast<std::uint32_t>(msg[off + i * 4 + 3]);
    }
    for (int i = 16; i < 80; ++i) {
      w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    std::uint32_t a = h0, b = h1, c = h2, d = h3, e = h4;
    for (int i = 0; i < 80; ++i) {
      std::uint32_t f, k;
      if (i < 20) {
        f = (b & c) | ((~b) & d);
        k = 0x5A827999u;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1u;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDCu;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6u;
      }
      const std::uint32_t temp = rol(a, 5) + f + e + k + w[i];
      e = d;
      d = c;
      c = rol(b, 30);
      b = a;
      a = temp;
    }
    h0 += a;
    h1 += b;
    h2 += c;
    h3 += d;
    h4 += e;
  }

  std::string out(20, '\0');
  const std::uint32_t hs[5] = {h0, h1, h2, h3, h4};
  for (int i = 0; i < 5; ++i) {
    out[i * 4] = static_cast<char>((hs[i] >> 24) & 0xff);
    out[i * 4 + 1] = static_cast<char>((hs[i] >> 16) & 0xff);
    out[i * 4 + 2] = static_cast<char>((hs[i] >> 8) & 0xff);
    out[i * 4 + 3] = static_cast<char>(hs[i] & 0xff);
  }
  return out;
}

std::string b64_encode(std::string_view raw) {
  static const char* tbl =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((raw.size() + 2) / 3) * 4);
  std::size_t i = 0;
  while (i < raw.size()) {
    const std::uint32_t n = static_cast<std::uint8_t>(raw[i]) << 16 |
                            (i + 1 < raw.size() ? static_cast<std::uint8_t>(raw[i + 1]) << 8
                                                : 0) |
                            (i + 2 < raw.size() ? static_cast<std::uint8_t>(raw[i + 2]) : 0);
    out.push_back(tbl[(n >> 18) & 63]);
    out.push_back(tbl[(n >> 12) & 63]);
    out.push_back(i + 1 < raw.size() ? tbl[(n >> 6) & 63] : '=');
    out.push_back(i + 2 < raw.size() ? tbl[n & 63] : '=');
    i += 3;
  }
  return out;
}

bool send_all(int fd, const void* data, std::size_t len) {
  const auto* p = static_cast<const std::uint8_t*>(data);
  std::size_t sent = 0;
  while (sent < len) {
    const ssize_t n = ::send(fd, p + sent, len - sent, 0);
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    if (n == 0) return false;
    sent += static_cast<std::size_t>(n);
  }
  return true;
}

bool send_frame(int fd, WsOpcode op, std::string_view payload) {
  WsFrame f;
  f.opcode = op;
  f.payload.assign(payload.begin(), payload.end());
  const std::string raw = encode_ws_frame(f, false);
  return send_all(fd, raw.data(), raw.size());
}

bool send_json(int fd, const nlohmann::json& j) { return send_frame(fd, WsOpcode::Text, j.dump()); }

std::string header_value(const std::string& headers, const std::string& name) {
  const std::string key = name + ":";
  auto pos = headers.find(key);
  if (pos == std::string::npos) {
    std::string lower = to_lower(headers);
    pos = lower.find(to_lower(key));
    if (pos == std::string::npos) return {};
  }
  pos += key.size();
  while (pos < headers.size() && (headers[pos] == ' ' || headers[pos] == '\t')) ++pos;
  auto end = headers.find("\r\n", pos);
  if (end == std::string::npos) end = headers.size();
  return trim(headers.substr(pos, end - pos));
}

std::string query_param(const std::string& target, const std::string& key) {
  const auto q = target.find('?');
  if (q == std::string::npos) return {};
  std::string qs = target.substr(q + 1);
  std::istringstream iss(qs);
  std::string part;
  while (std::getline(iss, part, '&')) {
    const auto eq = part.find('=');
    if (eq == std::string::npos) continue;
    if (part.substr(0, eq) == key) return part.substr(eq + 1);
  }
  return {};
}

std::string path_only(const std::string& target) {
  const auto q = target.find('?');
  return q == std::string::npos ? target : target.substr(0, q);
}

std::string bearer_from_auth(const std::string& auth) {
  constexpr std::string_view prefix = "Bearer ";
  if (auth.size() > prefix.size() && auth.compare(0, prefix.size(), prefix) == 0) {
    return auth.substr(prefix.size());
  }
  return {};
}

bool read_http_upgrade(int fd, std::string* request, std::string* rest) {
  request->clear();
  if (rest) rest->clear();
  char buf[1024];
  while (request->find("\r\n\r\n") == std::string::npos) {
    const ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return false;
    request->append(buf, static_cast<std::size_t>(n));
    if (request->size() > 16384) return false;
  }
  const auto pos = request->find("\r\n\r\n");
  if (rest && pos != std::string::npos) {
    *rest = request->substr(pos + 4);
    request->erase(pos + 4);
  }
  return true;
}

class SocketAudioSink : public AudioSink {
 public:
  SocketAudioSink(int fd, DeviceHub* hub, std::string device_id)
      : fd_(fd), hub_(hub), device_id_(std::move(device_id)) {}
  bool write(const std::uint8_t* data, std::size_t len) override {
    if (hub_) {
      return hub_->send_binary(device_id_, data, len);
    }
    return send_frame(fd_, WsOpcode::Binary,
                      std::string_view(reinterpret_cast<const char*>(data), len));
  }
  void event(const char* type, const std::string& value) override {
    nlohmann::json j = {{"type", type ? type : ""}};
    const std::string t = type ? type : "";
    if (t == "working") {
      j["tool"] = value;
    } else if (t == "status") {
      j["phase"] = value;
    } else if (!value.empty()) {
      j["text"] = value;
    }
    if (hub_) {
      hub_->send_json(device_id_, j);
      return;
    }
    send_json(fd_, j);
  }

 private:
  int fd_;
  DeviceHub* hub_;
  std::string device_id_;
};

}  // namespace

std::string ws_accept_key(std::string_view client_key) {
  return b64_encode(sha1(std::string(client_key) + kWsMagic));
}

std::string encode_ws_frame(const WsFrame& frame, bool mask) {
  std::string out;
  out.push_back(static_cast<char>((frame.fin ? 0x80 : 0) | (static_cast<unsigned>(frame.opcode) & 0x0f)));
  const std::uint64_t len = frame.payload.size();
  if (len < 126) {
    out.push_back(static_cast<char>((mask ? 0x80 : 0) | static_cast<unsigned>(len)));
  } else if (len <= 0xffff) {
    out.push_back(static_cast<char>((mask ? 0x80 : 0) | 126));
    out.push_back(static_cast<char>((len >> 8) & 0xff));
    out.push_back(static_cast<char>(len & 0xff));
  } else {
    out.push_back(static_cast<char>((mask ? 0x80 : 0) | 127));
    for (int i = 7; i >= 0; --i) {
      out.push_back(static_cast<char>((len >> (i * 8)) & 0xff));
    }
  }
  std::uint8_t key[4] = {0x12, 0x34, 0x56, 0x78};
  if (mask) {
    out.append(reinterpret_cast<const char*>(key), 4);
    for (std::size_t i = 0; i < frame.payload.size(); ++i) {
      out.push_back(static_cast<char>(static_cast<std::uint8_t>(frame.payload[i]) ^ key[i % 4]));
    }
  } else {
    out += frame.payload;
  }
  return out;
}

std::optional<WsFrame> decode_ws_frame(std::string_view data, std::size_t* consumed) {
  if (consumed) *consumed = 0;
  if (data.size() < 2) return std::nullopt;
  const auto b0 = static_cast<std::uint8_t>(data[0]);
  const auto b1 = static_cast<std::uint8_t>(data[1]);
  const bool masked = (b1 & 0x80) != 0;
  std::uint64_t len = b1 & 0x7f;
  std::size_t off = 2;
  if (len == 126) {
    if (data.size() < 4) return std::nullopt;
    len = (static_cast<std::uint64_t>(static_cast<std::uint8_t>(data[2])) << 8) |
          static_cast<std::uint8_t>(data[3]);
    off = 4;
  } else if (len == 127) {
    if (data.size() < 10) return std::nullopt;
    len = 0;
    for (int i = 0; i < 8; ++i) {
      len = (len << 8) | static_cast<std::uint8_t>(data[2 + i]);
    }
    off = 10;
  }
  if (masked) {
    if (data.size() < off + 4) return std::nullopt;
  }
  const std::size_t mask_off = off;
  if (masked) off += 4;
  if (data.size() < off + len) return std::nullopt;
  WsFrame f;
  f.fin = (b0 & 0x80) != 0;
  f.opcode = static_cast<WsOpcode>(b0 & 0x0f);
  f.payload.resize(static_cast<std::size_t>(len));
  for (std::uint64_t i = 0; i < len; ++i) {
    auto c = static_cast<std::uint8_t>(data[off + i]);
    if (masked) c ^= static_cast<std::uint8_t>(data[mask_off + (i % 4)]);
    f.payload[static_cast<std::size_t>(i)] = static_cast<char>(c);
  }
  if (consumed) *consumed = off + static_cast<std::size_t>(len);
  return f;
}

WsServer::WsServer(ServerDeps deps) : deps_(std::move(deps)) {}

WsServer::~WsServer() { stop(); }

bool WsServer::listen(const std::string& host, int port) {
  stop();
  listen_fd_ = ::socket(AF_INET, SOCK_STREAM, 0);
  if (listen_fd_ < 0) return false;
  int yes = 1;
  ::setsockopt(listen_fd_, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(static_cast<std::uint16_t>(port));
  if (host == "0.0.0.0" || host.empty()) {
    addr.sin_addr.s_addr = INADDR_ANY;
  } else if (::inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
    ::close(listen_fd_);
    listen_fd_ = -1;
    return false;
  }
  if (::bind(listen_fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    ::close(listen_fd_);
    listen_fd_ = -1;
    return false;
  }
  if (::listen(listen_fd_, 16) != 0) {
    ::close(listen_fd_);
    listen_fd_ = -1;
    return false;
  }
  sockaddr_in bound{};
  socklen_t blen = sizeof(bound);
  if (::getsockname(listen_fd_, reinterpret_cast<sockaddr*>(&bound), &blen) == 0) {
    port_ = ntohs(bound.sin_port);
  } else {
    port_ = port;
  }
  stop_.store(false);
  accept_thread_ = std::thread([this] { accept_loop(); });
  return true;
}

void WsServer::stop() {
  stop_.store(true);
  if (listen_fd_ >= 0) {
    ::shutdown(listen_fd_, SHUT_RDWR);
    ::close(listen_fd_);
    listen_fd_ = -1;
  }
  if (accept_thread_.joinable()) accept_thread_.join();
  port_ = 0;
}

void WsServer::accept_loop() {
  while (!stop_.load()) {
    pollfd pfd{};
    pfd.fd = listen_fd_;
    pfd.events = POLLIN;
    const int pr = ::poll(&pfd, 1, 200);
    if (pr <= 0) continue;
    const int fd = ::accept(listen_fd_, nullptr, nullptr);
    if (fd < 0) continue;
    int one = 1;
    ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    std::thread([this, fd] { handle_client(fd); }).detach();
  }
}

void WsServer::handle_client(int fd) {
  std::string req;
  std::string buf;
  if (!read_http_upgrade(fd, &req, &buf)) {
    ::close(fd);
    return;
  }
  const auto line_end = req.find("\r\n");
  if (line_end == std::string::npos) {
    ::close(fd);
    return;
  }
  std::istringstream first(req.substr(0, line_end));
  std::string method, target, ver;
  first >> method >> target >> ver;
  if (method != "GET" || path_only(target) != kWsPath) {
    const char* resp = "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n";
    send_all(fd, resp, std::strlen(resp));
    ::close(fd);
    return;
  }

  const std::string key = header_value(req, "Sec-WebSocket-Key");
  std::string device_id = header_value(req, "X-Device-Id");
  if (device_id.empty()) device_id = query_param(target, "device_id");
  std::string token = bearer_from_auth(header_value(req, "Authorization"));
  if (token.empty()) token = query_param(target, "token");

  if (key.empty() || device_id.empty() ||
      !deps_.config.authorize_device(device_id, token)) {
    const char* resp = "HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n";
    send_all(fd, resp, std::strlen(resp));
    ::close(fd);
    return;
  }

  const std::string accept = ws_accept_key(key);
  std::ostringstream up;
  up << "HTTP/1.1 101 Switching Protocols\r\n"
     << "Upgrade: websocket\r\n"
     << "Connection: Upgrade\r\n"
     << "Sec-WebSocket-Accept: " << accept << "\r\n\r\n";
  const std::string up_s = up.str();
  if (!send_all(fd, up_s.data(), up_s.size())) {
    ::close(fd);
    return;
  }

  struct FdGuard {
    int fd = -1;
    ~FdGuard() {
      if (fd >= 0) ::close(fd);
    }
  } fd_guard{fd};

  auto* hub = deps_.hub.get();
  auto send_text = [&](const nlohmann::json& j) {
    if (hub) return hub->send_json(device_id, j);
    return send_json(fd, j);
  };
  auto send_op = [&](WsOpcode op, std::string_view payload) {
    if (hub) {
      return hub->send_opcode(device_id, static_cast<std::uint8_t>(op), payload);
    }
    return send_frame(fd, op, payload);
  };

  // Ready must land before attach so pending speak-back cannot race the
  // firmware's waitReady() handshake.
  if (!send_json(fd, {{"type", "ready"},
                      {"sample_rate", deps_.config.sample_rate},
                      {"device_id", device_id}})) {
    return;
  }
  if (hub) hub->attach(device_id, fd);

  struct HubGuard {
    DeviceHub* hub = nullptr;
    std::string device_id;
    int fd = -1;
    ~HubGuard() {
      if (hub) hub->detach(device_id, fd);
    }
  } guard{hub, device_id, fd};

  std::vector<std::uint8_t> pcm;
  std::string active_turn;
  bool ptt_busy = false;
  auto set_busy = [&](bool busy) {
    if (!hub) return;
    ptt_busy = busy;
    hub->set_busy(device_id, busy);
  };
  using clock = std::chrono::steady_clock;
  auto last_rx = clock::now();
  auto ping_sent = clock::time_point{};
  bool awaiting_pong = false;
  // Bytes read with the HTTP upgrade are already a websocket frame.
  bool buffered = !buf.empty();
  while (!stop_.load()) {
    if (!buffered) {
      pollfd pfd{};
      pfd.fd = fd;
      pfd.events = POLLIN;
      const int pr = ::poll(&pfd, 1, 200);
      if (pr < 0) {
        if (errno == EINTR) continue;
        break;
      }
      if (pr == 0) {
        const auto now = clock::now();
        if (awaiting_pong && now - ping_sent > kWsPongWait) break;
        if (!awaiting_pong && !ptt_busy && now - last_rx > kWsPingEvery) {
          if (!send_op(WsOpcode::Ping, "hi")) break;
          awaiting_pong = true;
          ping_sent = now;
        }
        continue;
      }
      char tmp[4096];
      const ssize_t n = ::recv(fd, tmp, sizeof(tmp), 0);
      if (n < 0) {
        if (errno == EINTR) continue;
        break;
      }
      if (n == 0) break;
      buf.append(tmp, static_cast<std::size_t>(n));
    }
    buffered = false;

    while (true) {
      std::size_t used = 0;
      auto frame = decode_ws_frame(buf, &used);
      if (!frame) break;
      buf.erase(0, used);

      last_rx = clock::now();
      awaiting_pong = false;

      if (frame->opcode == WsOpcode::Close) {
        send_op(WsOpcode::Close, {});
        return;
      }
      if (frame->opcode == WsOpcode::Ping) {
        send_op(WsOpcode::Pong, frame->payload);
        continue;
      }
      if (frame->opcode == WsOpcode::Pong) continue;
      if (frame->opcode == WsOpcode::Binary) {
        if (!ptt_busy && pcm.empty() && active_turn.empty()) set_busy(true);
        pcm.insert(pcm.end(), frame->payload.begin(), frame->payload.end());
        continue;
      }
      if (frame->opcode != WsOpcode::Text) continue;

      nlohmann::json j;
      try {
        j = nlohmann::json::parse(frame->payload.empty() ? "{}" : frame->payload);
      } catch (...) {
        send_text({{"type", "error"}, {"error", "invalid json"}});
        continue;
      }
      const std::string type = j.value("type", "");
      if (type == "cancel") {
        if (!active_turn.empty()) {
          std::string err;
          deps_.pipeline->cancel_turn(active_turn, &err);
        }
        continue;
      }
      if (type == "end" || type == "text") {
        set_busy(true);
        SocketAudioSink sink(fd, hub, device_id);
        TurnResult result;
        if (type == "text") {
          const std::string text = j.value("text", "");
          if (text.empty()) {
            send_text({{"type", "error"}, {"error", "missing text"}});
            set_busy(false);
            continue;
          }
          const std::string turn_id = make_turn_id();
          active_turn = turn_id;
          send_text({{"type", "accept"}, {"turn_id", turn_id}});
          result = deps_.pipeline->run_text_utterance(device_id, text, sink, turn_id, -1);
        } else {
          if (pcm.empty()) {
            send_text({{"type", "error"}, {"error", "empty pcm"}});
            set_busy(false);
            continue;
          }
          active_turn = make_turn_id();
          send_text({{"type", "accept"}, {"turn_id", active_turn}});
          result = deps_.pipeline->run_utterance(device_id, pcm, deps_.config.sample_rate,
                                                 deps_.config.channels, sink, active_turn);
          if (result.turn_id.empty()) result.turn_id = active_turn;
        }
        pcm.clear();
        active_turn.clear();
        send_text({{"type", "turn"},
                   {"turn_id", result.turn_id},
                   {"transcript", result.transcript},
                   {"conversation_id", result.conversation_id},
                   {"ok", result.ok},
                   {"fast_path", result.used_fast_path}});
        send_text({{"type", "done"},
                   {"ok", result.ok},
                   {"error", result.error},
                   {"turn_id", result.turn_id}});
        set_busy(false);
      }
    }
  }
}

}  // namespace intercom

#include "intercom/device_hub.hpp"
#include "intercom/speakable.hpp"
#include "intercom/ws.hpp"

#include <sys/socket.h>

#include <cerrno>
#include <cstring>
#include <iostream>

namespace intercom {
namespace {

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

}  // namespace

DeviceHub::DeviceHub(std::shared_ptr<TtsProvider> tts, int max_queued,
                     std::shared_ptr<SessionStore> sessions)
    : tts_(std::move(tts)),
      sessions_(std::move(sessions)),
      max_queued_(max_queued > 0 ? max_queued : 4) {}

std::shared_ptr<DeviceHub::Conn> DeviceHub::get(const std::string& device_id) const {
  std::lock_guard<std::mutex> lk(mu_);
  auto it = conns_.find(device_id);
  if (it == conns_.end()) return nullptr;
  return it->second;
}

void DeviceHub::attach(const std::string& device_id, int fd) {
  int replaced = -1;
  std::shared_ptr<Conn> c;
  {
    std::lock_guard<std::mutex> lk(mu_);
    auto it = conns_.find(device_id);
    if (it != conns_.end() && it->second) {
      c = it->second;
      if (c->fd >= 0 && c->fd != fd) replaced = c->fd;
      c->fd = fd;
    } else {
      c = std::make_shared<Conn>();
      c->fd = fd;
      conns_[device_id] = c;
    }
  }
  if (replaced >= 0) ::shutdown(replaced, SHUT_RDWR);
  std::cerr << "intercom speakback: device " << device_id << " online" << std::endl;
  flush_pending(device_id, c);
}

void DeviceHub::detach(const std::string& device_id, int fd) {
  std::lock_guard<std::mutex> lk(mu_);
  auto it = conns_.find(device_id);
  if (it == conns_.end() || !it->second) return;
  if (it->second->fd != fd) return;
  it->second->fd = -1;
  std::cerr << "intercom speakback: device " << device_id << " offline" << std::endl;
}

void DeviceHub::set_busy(const std::string& device_id, bool busy) {
  auto c = get(device_id);
  if (!c) return;
  c->busy.store(busy);
  if (!busy) flush_pending(device_id, c);
}

bool DeviceHub::online(const std::string& device_id) const {
  auto c = get(device_id);
  return c && c->fd >= 0;
}

bool DeviceHub::busy(const std::string& device_id) const {
  auto c = get(device_id);
  return c && c->busy.load();
}

std::size_t DeviceHub::queued(const std::string& device_id) const {
  if (sessions_) return sessions_->count_speakback(device_id);
  auto c = get(device_id);
  if (!c) return 0;
  std::lock_guard<std::mutex> lk(c->pending_mu);
  return c->pending.size();
}

bool DeviceHub::write_frame(const std::shared_ptr<Conn>& c, std::uint8_t opcode,
                            std::string_view payload) {
  if (!c) return false;
  std::lock_guard<std::mutex> lk(c->write_mu);
  if (c->fd < 0) return false;
  WsFrame f;
  f.opcode = static_cast<WsOpcode>(opcode);
  f.payload.assign(payload.begin(), payload.end());
  const std::string raw = encode_ws_frame(f, false);
  return send_all(c->fd, raw.data(), raw.size());
}

bool DeviceHub::send_json(const std::string& device_id, const nlohmann::json& j) {
  return write_frame(get(device_id), static_cast<std::uint8_t>(WsOpcode::Text), j.dump());
}

bool DeviceHub::send_binary(const std::string& device_id, const std::uint8_t* data,
                            std::size_t len) {
  return write_frame(get(device_id), static_cast<std::uint8_t>(WsOpcode::Binary),
                     std::string_view(reinterpret_cast<const char*>(data), len));
}

bool DeviceHub::send_opcode(const std::string& device_id, std::uint8_t opcode,
                            std::string_view payload) {
  return write_frame(get(device_id), opcode, payload);
}

bool DeviceHub::speak_on(const std::shared_ptr<Conn>& c, const std::string& text,
                         const std::string& kind, std::int64_t run_id) {
  if (!c || !tts_) return false;
  const std::string spoken = to_speakable(text);
  if (spoken.empty()) return true;
  nlohmann::json start = {{"type", "speak"}, {"kind", kind}, {"text", spoken}};
  if (run_id > 0) start["run_id"] = run_id;
  if (!write_frame(c, static_cast<std::uint8_t>(WsOpcode::Text), start.dump())) {
    return false;
  }
  nlohmann::json said = {{"type", "said"}, {"text", spoken}};
  write_frame(c, static_cast<std::uint8_t>(WsOpcode::Text), said.dump());
  std::string err;
  const bool ok = tts_->synthesize(
      spoken,
      [&](const std::uint8_t* data, std::size_t len) {
        return write_frame(c, static_cast<std::uint8_t>(WsOpcode::Binary),
                           std::string_view(reinterpret_cast<const char*>(data), len));
      },
      &err);
  nlohmann::json done = {{"type", "done"}, {"ok", ok}, {"kind", kind}};
  if (!err.empty()) done["error"] = err;
  write_frame(c, static_cast<std::uint8_t>(WsOpcode::Text), done.dump());
  return ok;
}

void DeviceHub::flush_pending(const std::string& device_id,
                              const std::shared_ptr<Conn>& c) {
  if (!c || c->fd < 0 || c->busy.load()) return;
  bool idle = false;
  if (!c->flushing.compare_exchange_strong(idle, true)) return;
  struct ClearFlush {
    Conn* conn;
    ~ClearFlush() { conn->flushing.store(false); }
  } clear{c.get()};

  if (sessions_) {
    for (;;) {
      const auto items = sessions_->list_speakback(device_id);
      if (items.empty()) return;
      const auto& item = items.front();
      std::cerr << "intercom speakback: flush queued for " << device_id << std::endl;
      if (!speak_on(c, item.text, item.kind, item.run_id)) return;
      std::string err;
      if (!sessions_->remove_speakback(item.id, &err) && !err.empty()) {
        std::cerr << "intercom speakback: drop queued failed: " << err << std::endl;
        return;
      }
    }
  }

  for (;;) {
    PendingSpeak item;
    {
      std::lock_guard<std::mutex> lk(c->pending_mu);
      if (c->pending.empty()) return;
      item = std::move(c->pending.front());
      c->pending.pop_front();
    }
    std::cerr << "intercom speakback: flush queued for " << device_id << std::endl;
    if (!speak_on(c, item.text, item.kind, item.run_id)) {
      std::lock_guard<std::mutex> lk(c->pending_mu);
      c->pending.push_front(std::move(item));
      return;
    }
  }
}

bool DeviceHub::speak(const std::string& device_id, const std::string& text,
                      const std::string& kind, std::int64_t run_id) {
  if (text.empty()) return true;
  auto c = get(device_id);
  if (c && c->fd >= 0 && !c->busy.load() && !c->flushing.load()) {
    if (speak_on(c, text, kind, run_id)) return true;
  }
  if (!c) {
    std::lock_guard<std::mutex> lk(mu_);
    auto it = conns_.find(device_id);
    if (it == conns_.end()) {
      c = std::make_shared<Conn>();
      conns_[device_id] = c;
    } else {
      c = it->second;
    }
  }
  if (sessions_) {
    std::string err;
    const auto id = sessions_->enqueue_speakback(
        device_id, text, kind, run_id, max_queued_, &err);
    if (id <= 0) {
      std::cerr << "intercom speakback: queue failed for " << device_id << ": "
                << err << std::endl;
      return false;
    }
    std::cerr << "intercom speakback: queued for " << device_id
              << " (offline or busy, n=" << sessions_->count_speakback(device_id)
              << ")" << std::endl;
    return true;
  }
  std::lock_guard<std::mutex> lk(c->pending_mu);
  c->pending.push_back(PendingSpeak{text, kind, run_id});
  while (static_cast<int>(c->pending.size()) > max_queued_) c->pending.pop_front();
  std::cerr << "intercom speakback: queued for " << device_id
            << " (offline or busy, n=" << c->pending.size() << ")" << std::endl;
  return true;
}

}  // namespace intercom

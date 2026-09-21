#pragma once

#include "intercom/tts.hpp"

#include <atomic>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include <nlohmann/json.hpp>

namespace intercom {

// Live WebSocket connections keyed by device_id, plus a tiny in-memory
// queue for speak-back while the device is offline or mid-PTT.
class DeviceHub {
 public:
  explicit DeviceHub(std::shared_ptr<TtsProvider> tts, int max_queued = 4);

  void attach(const std::string& device_id, int fd);
  void detach(const std::string& device_id, int fd);
  void set_busy(const std::string& device_id, bool busy);

  bool online(const std::string& device_id) const;
  bool busy(const std::string& device_id) const;
  std::size_t queued(const std::string& device_id) const;

  // Speak now if the socket is idle; otherwise queue (drop oldest past max).
  // Offline devices are queued and flushed on the next attach.
  bool speak(const std::string& device_id, const std::string& text,
             const std::string& kind, std::int64_t run_id);

  bool send_json(const std::string& device_id, const nlohmann::json& j);
  bool send_binary(const std::string& device_id, const std::uint8_t* data,
                   std::size_t len);
  bool send_opcode(const std::string& device_id, std::uint8_t opcode,
                   std::string_view payload);

 private:
  struct Conn {
    int fd = -1;
    std::atomic<bool> busy{false};
    std::mutex write_mu;
    std::deque<std::string> pending;
    std::mutex pending_mu;
  };

  std::shared_ptr<Conn> get(const std::string& device_id) const;
  bool write_frame(const std::shared_ptr<Conn>& c, std::uint8_t opcode,
                   std::string_view payload);
  bool speak_on(const std::shared_ptr<Conn>& c, const std::string& text,
                const std::string& kind, std::int64_t run_id);
  void flush_pending(const std::string& device_id, const std::shared_ptr<Conn>& c);

  std::shared_ptr<TtsProvider> tts_;
  int max_queued_ = 4;
  mutable std::mutex mu_;
  std::unordered_map<std::string, std::shared_ptr<Conn>> conns_;
};

}  // namespace intercom

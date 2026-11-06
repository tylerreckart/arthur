#pragma once

#include "intercom/session_store.hpp"
#include "intercom/speak_queue.hpp"
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

// Live WebSocket connections keyed by device_id, plus a speak-back queue
// for while the device is offline or mid-PTT. When a SessionStore is
// attached the queue is durable across process restarts.
class DeviceHub {
 public:
  explicit DeviceHub(std::shared_ptr<TtsProvider> tts, int max_queued = 4,
                     std::shared_ptr<SessionStore> sessions = nullptr);

  void attach(const std::string& device_id, int fd);
  void detach(const std::string& device_id, int fd);
  void set_busy(const std::string& device_id, bool busy);

  bool online(const std::string& device_id) const;
  bool busy(const std::string& device_id) const;
  std::size_t queued(const std::string& device_id) const;

  // Speak now if the socket is idle and the utterance is still due.
  // Quiet hours and Do Not Disturb hold it. An expired one is dropped.
  // Offline devices are queued and flushed on the next attach.
  bool speak(const std::string& device_id, const std::string& text,
             const std::string& kind, std::int64_t run_id);

  // Mac Focus. Held utterances stay queued until this clears, if they
  // have not expired.
  void set_dnd(const std::string& device_id, bool on);
  bool dnd(const std::string& device_id) const;

  // Quiet hours apply to every device. Disabled until the process sets them,
  // so a test run at night still speaks.
  void set_quiet(bool enabled, int start_minute, int end_minute);

  // Speak anything that was held and is now due.
  void nudge();

  bool send_json(const std::string& device_id, const nlohmann::json& j);
  bool send_binary(const std::string& device_id, const std::uint8_t* data,
                   std::size_t len);
  bool send_opcode(const std::string& device_id, std::uint8_t opcode,
                   std::string_view payload);

 private:
  struct PendingSpeak {
    std::string text;
    std::string kind;
    std::int64_t run_id = 0;
    std::int64_t created_at = 0;
    std::int64_t expires_at = 0;
  };

  struct Conn {
    int fd = -1;
    std::atomic<bool> busy{false};
    std::atomic<bool> flushing{false};
    std::mutex write_mu;
    std::deque<PendingSpeak> pending;
    std::mutex pending_mu;
  };

  std::shared_ptr<Conn> get(const std::string& device_id) const;
  bool write_frame(const std::shared_ptr<Conn>& c, std::uint8_t opcode,
                   std::string_view payload);
  bool speak_on(const std::shared_ptr<Conn>& c, const std::string& text,
                const std::string& kind, std::int64_t run_id);
  void flush_pending(const std::string& device_id, const std::shared_ptr<Conn>& c);
  SpeakAction action_for(const std::string& device_id, const std::string& kind,
                         std::int64_t created_at, std::int64_t expires_at) const;

  std::shared_ptr<TtsProvider> tts_;
  std::shared_ptr<SessionStore> sessions_;
  int max_queued_ = 4;
  SpeakPolicy quiet_;
  std::unordered_map<std::string, bool> dnd_;
  mutable std::mutex mu_;
  std::unordered_map<std::string, std::shared_ptr<Conn>> conns_;
};

}  // namespace intercom

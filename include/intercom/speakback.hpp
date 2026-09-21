#pragma once

#include "intercom/arbiter_client.hpp"
#include "intercom/config.hpp"
#include "intercom/device_hub.hpp"
#include "intercom/session_store.hpp"

#include <atomic>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace intercom {

std::optional<std::string> speak_text_for(const NotificationEvent& ev,
                                          bool speak_failures);
// conversation_id > 0 matches SessionStore rows. 0 (unscoped schedule) maps
// to the sole device when Intercom only knows one session.
std::vector<std::string> devices_for_conversation(
    const std::vector<DeviceSession>& sessions, std::int64_t conversation_id);

// Subscribe to Arbiter schedule-run notifications and speak results on the
// matching Intercom device.
class Speakback {
 public:
  Speakback(SpeakbackConfig config, std::string agent,
            std::shared_ptr<ArbiterClient> arbiter,
            std::shared_ptr<SessionStore> sessions,
            std::shared_ptr<DeviceHub> hub);
  ~Speakback();

  Speakback(const Speakback&) = delete;
  Speakback& operator=(const Speakback&) = delete;

  void start();
  void stop();

  // Test hook: one notification, no SSE.
  void handle_event(NotificationEvent ev);

  bool running() const { return running_.load(); }

 private:
  void loop();
  bool replay_since(std::int64_t since);
  std::int64_t conversation_for(const NotificationEvent& ev);
  bool already_spoken(std::int64_t run_id);
  void mark_spoken(std::int64_t run_id);

  SpeakbackConfig config_;
  std::string agent_;
  std::shared_ptr<ArbiterClient> arbiter_;
  std::shared_ptr<SessionStore> sessions_;
  std::shared_ptr<DeviceHub> hub_;
  std::atomic<bool> stop_{false};
  std::atomic<bool> running_{false};
  std::thread thread_;
  std::mutex mu_;
  std::unordered_set<std::int64_t> spoken_runs_;
  std::deque<std::int64_t> spoken_order_;
  std::unordered_map<std::int64_t, std::int64_t> task_conversations_;
  std::int64_t last_started_at_ = 0;
};

}  // namespace intercom

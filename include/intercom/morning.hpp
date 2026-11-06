#pragma once

#include "intercom/config.hpp"
#include "intercom/device_hub.hpp"
#include "intercom/speak_queue.hpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <ctime>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>

namespace intercom {

// Wakes on the clock, not an in-memory timer, so a restart during the
// morning still speaks. The spoken text is built at fire time.
class MorningBriefing {
 public:
  using Compose = std::function<std::string()>;

  MorningBriefing(std::shared_ptr<DeviceHub> hub,
                  std::shared_ptr<SessionStore> sessions,
                  SpeakbackConfig config,
                  Compose compose)
      : hub_(std::move(hub)),
        sessions_(std::move(sessions)),
        config_(std::move(config)),
        compose_(std::move(compose)) {}

  MorningBriefing(const MorningBriefing&) = delete;
  MorningBriefing& operator=(const MorningBriefing&) = delete;

  ~MorningBriefing() { stop(); }

  void start() {
    if (thread_.joinable() || !config_.briefing) return;
    stop_.store(false);
    thread_ = std::thread([this] {
      while (!stop_.load()) {
        const std::time_t now = std::time(nullptr);
        tick(static_cast<std::int64_t>(now), minute_of_day(now), civil_day(now));
        if (hub_) hub_->nudge();
        std::unique_lock<std::mutex> lock(wait_mu_);
        wait_.wait_for(lock, std::chrono::seconds(15), [this] { return stop_.load(); });
      }
    });
  }

  void stop() {
    stop_.store(true);
    wait_.notify_all();
    if (thread_.joinable()) thread_.join();
  }

  // One check. Returns true when at least one device was given the line.
  bool tick(std::int64_t now, int minute, int day) {
    if (!hub_ || !sessions_ || !config_.briefing || day <= 0) return false;
    const int last = sessions_->marked_day("briefing");
    if (day == last) return false;
    const auto devices = sessions_->list();
    if (devices.empty()) return false;

    BriefingSchedule schedule;
    schedule.enabled = config_.briefing;
    schedule.minute = config_.briefing_minute;
    schedule.grace_minutes = config_.briefing_grace_minutes;

    bool any_due = false;
    for (const auto& device : devices) {
      if (briefing_due(minute, day, last, schedule, policy_for(device.device_id))) {
        any_due = true;
        break;
      }
    }
    if (!any_due) return false;

    std::string text = compose_ ? compose_() : std::string();
    if (text.empty()) text = morning_clock_line(static_cast<std::time_t>(now));
    if (text.empty()) return false;

    bool spoke = false;
    for (const auto& device : devices) {
      if (!briefing_due(minute, day, last, schedule, policy_for(device.device_id))) continue;
      if (hub_->speak(device.device_id, text, "briefing", 0)) spoke = true;
    }
    if (spoke) sessions_->mark_day("briefing", day, nullptr);
    return spoke;
  }

 private:
  SpeakPolicy policy_for(const std::string& device_id) const {
    SpeakPolicy policy;
    policy.quiet_enabled = config_.quiet_hours;
    policy.quiet_start_minute = config_.quiet_start_minute;
    policy.quiet_end_minute = config_.quiet_end_minute;
    policy.dnd = hub_ && hub_->dnd(device_id);
    return policy;
  }

  std::shared_ptr<DeviceHub> hub_;
  std::shared_ptr<SessionStore> sessions_;
  SpeakbackConfig config_;
  Compose compose_;
  std::atomic<bool> stop_{false};
  std::mutex wait_mu_;
  std::condition_variable wait_;
  std::thread thread_;
};

}  // namespace intercom

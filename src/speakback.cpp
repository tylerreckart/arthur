#include "intercom/speakback.hpp"
#include "intercom/util.hpp"

#include <chrono>
#include <iostream>

namespace intercom {

std::optional<std::string> speak_text_for(const NotificationEvent& ev,
                                          bool speak_failures) {
  if (ev.kind == "run.completed" || ev.status == "succeeded" ||
      ev.status == "completed") {
    const std::string text = trim(ev.result_summary);
    if (text.empty()) return std::nullopt;
    return text;
  }
  if (speak_failures &&
      (ev.kind == "run.failed" || ev.status == "failed")) {
    return std::string("That reminder didn't come through, sir.");
  }
  return std::nullopt;
}

std::vector<std::string> devices_for_conversation(
    const std::vector<DeviceSession>& sessions, std::int64_t conversation_id) {
  std::vector<std::string> out;
  if (conversation_id > 0) {
    for (const auto& s : sessions) {
      if (s.conversation_id == conversation_id && !s.device_id.empty()) {
        out.push_back(s.device_id);
      }
    }
    return out;
  }
  if (sessions.size() == 1 && !sessions[0].device_id.empty()) {
    out.push_back(sessions[0].device_id);
  }
  return out;
}

Speakback::Speakback(SpeakbackConfig config, std::string agent,
                     std::shared_ptr<ArbiterClient> arbiter,
                     std::shared_ptr<SessionStore> sessions,
                     std::shared_ptr<DeviceHub> hub)
    : config_(std::move(config)),
      agent_(std::move(agent)),
      arbiter_(std::move(arbiter)),
      sessions_(std::move(sessions)),
      hub_(std::move(hub)) {}

Speakback::~Speakback() { stop(); }

void Speakback::start() {
  if (!config_.enabled || !arbiter_ || !sessions_ || !hub_) return;
  bool was = running_.exchange(true);
  if (was) return;
  stop_.store(false);
  thread_ = std::thread([this] { loop(); });
  std::cerr << "intercom speakback: listening for schedule notifications"
            << std::endl;
}

void Speakback::stop() {
  stop_.store(true);
  if (thread_.joinable()) thread_.join();
  running_.store(false);
}

bool Speakback::already_spoken(std::int64_t run_id) {
  if (run_id <= 0) return false;
  std::lock_guard<std::mutex> lk(mu_);
  return spoken_runs_.count(run_id) != 0;
}

void Speakback::mark_spoken(std::int64_t run_id) {
  if (run_id <= 0) return;
  std::lock_guard<std::mutex> lk(mu_);
  if (!spoken_runs_.insert(run_id).second) return;
  spoken_order_.push_back(run_id);
  while (spoken_order_.size() > 256) {
    spoken_runs_.erase(spoken_order_.front());
    spoken_order_.pop_front();
  }
}

std::int64_t Speakback::conversation_for(const NotificationEvent& ev) {
  if (ev.conversation_id > 0) return ev.conversation_id;
  if (ev.task_id <= 0) return 0;
  {
    std::lock_guard<std::mutex> lk(mu_);
    auto it = task_conversations_.find(ev.task_id);
    if (it != task_conversations_.end()) return it->second;
  }
  std::string err;
  auto info = arbiter_->get_schedule(ev.task_id, &err);
  if (!info) {
    if (!err.empty()) {
      std::cerr << "intercom speakback: schedule " << ev.task_id << ": " << err
                << std::endl;
    }
    return 0;
  }
  std::lock_guard<std::mutex> lk(mu_);
  task_conversations_[ev.task_id] = info->conversation_id;
  return info->conversation_id;
}

void Speakback::handle_event(NotificationEvent ev) {
  if (ev.started_at > last_started_at_) last_started_at_ = ev.started_at;

  auto text = speak_text_for(ev, config_.speak_failures);
  if (!text) return;
  if (already_spoken(ev.run_id)) return;

  const auto conv = conversation_for(ev);
  // Unscoped schedules (conversation_id 0) only hit the sole device when the
  // run is for this Intercom agent (or index). Conversation-pinned runs speak
  // whenever we own that conversation, regardless of agent_id.
  if (conv == 0 && !agent_.empty() && !ev.agent_id.empty() &&
      ev.agent_id != agent_ && ev.agent_id != "index") {
    return;
  }

  auto devices = devices_for_conversation(sessions_->list(), conv);
  if (devices.empty()) {
    std::cerr << "intercom speakback: no device for run " << ev.run_id
              << " conv=" << conv << " task=" << ev.task_id << std::endl;
    return;
  }
  mark_spoken(ev.run_id);
  for (const auto& device_id : devices) {
    std::cerr << "intercom speakback: speaking run " << ev.run_id << " to "
              << device_id << std::endl;
    hub_->speak(device_id, *text, "schedule", ev.run_id);
  }
}

bool Speakback::replay_since(std::int64_t since) {
  std::string err;
  auto runs = arbiter_->list_runs_since(since, &err);
  if (!err.empty()) {
    std::cerr << "intercom speakback: runs poll: " << err << std::endl;
    return false;
  }
  for (auto& ev : runs) handle_event(std::move(ev));
  return true;
}

void Speakback::loop() {
  while (!stop_.load()) {
    if (last_started_at_ > 0) replay_since(last_started_at_);
    std::string err;
    const bool ok = arbiter_->stream_notifications(
        [this](const NotificationEvent& ev) { handle_event(ev); }, &stop_, &err);
    if (stop_.load()) break;
    if (!ok && !err.empty()) {
      std::cerr << "intercom speakback: " << err << std::endl;
    }
    const int wait = config_.reconnect_ms > 0 ? config_.reconnect_ms : 2000;
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(wait);
    while (!stop_.load() && std::chrono::steady_clock::now() < deadline) {
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
  }
}

}  // namespace intercom

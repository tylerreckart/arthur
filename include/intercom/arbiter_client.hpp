#pragma once

#include <nlohmann/json.hpp>

#include <atomic>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace intercom {

struct ArbiterStreamCallbacks {
  // Fires once when request_received yields a request_id.
  std::function<void(const std::string& request_id)> on_request_id;
  // Master (depth 0) text deltas only.
  std::function<void(const std::string& delta)> on_text_delta;
  // Master (depth 0) tool_call — name only; do not speak it.
  std::function<void(const std::string& tool)> on_tool_call;
  // How many delegated or JIT streams are open. Fires when the count
  // changes, including back to 0 once the last child closes.
  std::function<void(int open_workers)> on_workers;
  // Terminal done content (full reply) and ok flag.
  std::function<void(bool ok, const std::string& content, const std::string& error)> on_done;
};

struct NotificationEvent {
  std::string kind;
  std::int64_t task_id = 0;
  std::int64_t run_id = 0;
  std::int64_t conversation_id = 0;
  std::int64_t started_at = 0;
  std::int64_t completed_at = 0;
  std::string agent_id;
  std::string status;
  std::string result_summary;
  std::string error_message;
};

struct ScheduleInfo {
  std::int64_t id = 0;
  std::int64_t conversation_id = 0;
  std::string agent_id;
  std::string message;
};

// A forwarded Arbiter response. The desk proxy never logs the body.
struct ArbiterHttpResult {
  int status = 0;
  std::string body;
};

NotificationEvent parse_notification_json(std::string_view data);
ScheduleInfo parse_schedule_json(std::string_view body);

class ArbiterClient {
 public:
  ArbiterClient(std::string base_url, std::string token, std::string agent,
                std::string agent_def_json = "");
  virtual ~ArbiterClient() = default;

  // Create a conversation; returns id or nullopt.
  virtual std::optional<std::int64_t> create_conversation(const std::string& title,
                                                          std::string* err) const;

  // Stream a user message. idempotency_key maps to Idempotency-Key header.
  // cancel_flag: when set, client stops reading and returns early.
  virtual bool send_message(std::int64_t conversation_id,
                            const std::string& message,
                            const std::string& idempotency_key,
                            ArbiterStreamCallbacks cbs,
                            std::atomic<bool>* cancel_flag,
                            std::string* err) const;

  // Same call when `message` is a content-parts array (text plus images).
  // Text-only turns keep using send_message so existing test doubles are unchanged.
  bool send_user_message(std::int64_t conversation_id,
                         const nlohmann::json& message,
                         const std::string& idempotency_key,
                         ArbiterStreamCallbacks cbs,
                         std::atomic<bool>* cancel_flag,
                         std::string* err) const;

  virtual bool cancel_request(const std::string& request_id, std::string* err) const;

  virtual std::optional<ScheduleInfo> get_schedule(std::int64_t task_id,
                                                   std::string* err) const;
  virtual std::vector<NotificationEvent> list_runs_since(std::int64_t since_epoch,
                                                         std::string* err) const;
  // Long-lived SSE. Returns false on disconnect/error (caller reconnects).
  virtual bool stream_notifications(
      const std::function<void(const NotificationEvent&)>& on_event,
      std::atomic<bool>* cancel_flag, std::string* err) const;

  bool health_reachable(std::string* detail) const;

  // Device-token routes call this. The path must pass desk_proxy_allowed.
  ArbiterHttpResult exchange(const std::string& method, const std::string& path_and_query,
                             const std::string& body) const;

 private:
  bool post_turn(std::int64_t conversation_id,
                 const nlohmann::json& message,
                 const std::string& idempotency_key,
                 ArbiterStreamCallbacks cbs,
                 std::atomic<bool>* cancel_flag,
                 std::string* err) const;

  std::string base_url_;
  std::string token_;
  std::string agent_;
  std::string agent_def_json_;
};

}  // namespace intercom

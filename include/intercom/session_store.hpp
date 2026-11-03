#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

struct sqlite3;

namespace intercom {

struct DeviceSession {
  std::string device_id;
  std::int64_t conversation_id = 0;
  std::string last_turn_id;
  std::string last_spoken;
  std::string pending_intent;
  std::int64_t pending_at = 0;
  std::int64_t updated_at = 0;
};

class SessionStore {
 public:
  explicit SessionStore(std::string db_path);
  ~SessionStore();

  SessionStore(const SessionStore&) = delete;
  SessionStore& operator=(const SessionStore&) = delete;

  bool open(std::string* err);

  std::optional<DeviceSession> get(const std::string& device_id) const;
  std::vector<DeviceSession> list() const;
  bool upsert(const DeviceSession& session, std::string* err);

 private:
  std::string db_path_;
  sqlite3* db_ = nullptr;
};

}  // namespace intercom

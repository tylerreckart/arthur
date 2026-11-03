#include "intercom/session_store.hpp"
#include "intercom/util.hpp"

#include <chrono>
#include <filesystem>
#include <sqlite3.h>

namespace intercom {
namespace {

std::int64_t now_unix() {
  return std::chrono::duration_cast<std::chrono::seconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

}  // namespace

SessionStore::SessionStore(std::string db_path) : db_path_(std::move(db_path)) {}

SessionStore::~SessionStore() {
  if (db_) {
    sqlite3_close(db_);
    db_ = nullptr;
  }
}

bool SessionStore::open(std::string* err) {
  try {
    std::filesystem::path p(db_path_);
    if (p.has_parent_path()) {
      std::filesystem::create_directories(p.parent_path());
    }
  } catch (const std::exception& e) {
    if (err) *err = std::string("session db mkdir: ") + e.what();
    return false;
  }

  if (sqlite3_open(db_path_.c_str(), &db_) != SQLITE_OK) {
    if (err) *err = db_ ? sqlite3_errmsg(db_) : "sqlite3_open failed";
    if (db_) {
      sqlite3_close(db_);
      db_ = nullptr;
    }
    return false;
  }

  const char* sql =
      "CREATE TABLE IF NOT EXISTS device_sessions ("
      "  device_id TEXT PRIMARY KEY NOT NULL,"
      "  conversation_id INTEGER NOT NULL,"
      "  last_turn_id TEXT NOT NULL DEFAULT '',"
      "  last_user TEXT NOT NULL DEFAULT '',"
      "  last_spoken TEXT NOT NULL DEFAULT '',"
      "  last_fast_path_kind TEXT NOT NULL DEFAULT '',"
      "  last_fast_path_request TEXT NOT NULL DEFAULT '',"
      "  pending_intent TEXT NOT NULL DEFAULT '',"
      "  pending_at INTEGER NOT NULL DEFAULT 0,"
      "  updated_at INTEGER NOT NULL"
      ");";
  char* errmsg = nullptr;
  if (sqlite3_exec(db_, sql, nullptr, nullptr, &errmsg) != SQLITE_OK) {
    if (err) *err = errmsg ? errmsg : "create table failed";
    sqlite3_free(errmsg);
    return false;
  }
  // Existing installations may predate clarification and local-action state.
  // SQLite has no `ADD COLUMN IF NOT EXISTS`, so duplicate-column is the
  // successful migration outcome on already-upgraded databases.
  for (const char* migration : {
           "ALTER TABLE device_sessions ADD COLUMN "
           "last_user TEXT NOT NULL DEFAULT '';",
           "ALTER TABLE device_sessions ADD COLUMN "
           "last_spoken TEXT NOT NULL DEFAULT '';",
           "ALTER TABLE device_sessions ADD COLUMN "
           "last_fast_path_kind TEXT NOT NULL DEFAULT '';",
           "ALTER TABLE device_sessions ADD COLUMN "
           "last_fast_path_request TEXT NOT NULL DEFAULT '';",
           "ALTER TABLE device_sessions ADD COLUMN "
           "pending_intent TEXT NOT NULL DEFAULT '';",
           "ALTER TABLE device_sessions ADD COLUMN "
           "pending_at INTEGER NOT NULL DEFAULT 0;",
       }) {
    errmsg = nullptr;
    if (sqlite3_exec(db_, migration, nullptr, nullptr, &errmsg) != SQLITE_OK) {
      const std::string detail = errmsg ? errmsg : "session migration failed";
      sqlite3_free(errmsg);
      if (detail.find("duplicate column name") == std::string::npos) {
        if (err) *err = detail;
        return false;
      }
    }
  }
  return true;
}

std::optional<DeviceSession> SessionStore::get(const std::string& device_id) const {
  if (!db_) return std::nullopt;
  sqlite3_stmt* stmt = nullptr;
  const char* sql =
      "SELECT device_id, conversation_id, last_turn_id, last_user, last_spoken, "
      "last_fast_path_kind, last_fast_path_request, pending_intent, pending_at, updated_at "
      "FROM device_sessions WHERE device_id = ?";
  if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
    return std::nullopt;
  }
  sqlite3_bind_text(stmt, 1, device_id.c_str(), -1, SQLITE_TRANSIENT);
  std::optional<DeviceSession> out;
  if (sqlite3_step(stmt) == SQLITE_ROW) {
    DeviceSession s;
    s.device_id = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
    s.conversation_id = sqlite3_column_int64(stmt, 1);
    const unsigned char* turn = sqlite3_column_text(stmt, 2);
    s.last_turn_id = turn ? reinterpret_cast<const char*>(turn) : "";
    const unsigned char* user = sqlite3_column_text(stmt, 3);
    s.last_user = user ? reinterpret_cast<const char*>(user) : "";
    const unsigned char* spoken = sqlite3_column_text(stmt, 4);
    s.last_spoken = spoken ? reinterpret_cast<const char*>(spoken) : "";
    const unsigned char* kind = sqlite3_column_text(stmt, 5);
    s.last_fast_path_kind = kind ? reinterpret_cast<const char*>(kind) : "";
    const unsigned char* request = sqlite3_column_text(stmt, 6);
    s.last_fast_path_request = request ? reinterpret_cast<const char*>(request) : "";
    const unsigned char* pending = sqlite3_column_text(stmt, 7);
    s.pending_intent = pending ? reinterpret_cast<const char*>(pending) : "";
    s.pending_at = sqlite3_column_int64(stmt, 8);
    s.updated_at = sqlite3_column_int64(stmt, 9);
    out = std::move(s);
  }
  sqlite3_finalize(stmt);
  return out;
}

std::vector<DeviceSession> SessionStore::list() const {
  std::vector<DeviceSession> out;
  if (!db_) return out;
  sqlite3_stmt* stmt = nullptr;
  const char* sql =
      "SELECT device_id, conversation_id, last_turn_id, last_user, last_spoken, "
      "last_fast_path_kind, last_fast_path_request, pending_intent, pending_at, updated_at "
      "FROM device_sessions ORDER BY device_id";
  if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
    return out;
  }
  while (sqlite3_step(stmt) == SQLITE_ROW) {
    DeviceSession s;
    s.device_id = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 0));
    s.conversation_id = sqlite3_column_int64(stmt, 1);
    const unsigned char* turn = sqlite3_column_text(stmt, 2);
    s.last_turn_id = turn ? reinterpret_cast<const char*>(turn) : "";
    const unsigned char* user = sqlite3_column_text(stmt, 3);
    s.last_user = user ? reinterpret_cast<const char*>(user) : "";
    const unsigned char* spoken = sqlite3_column_text(stmt, 4);
    s.last_spoken = spoken ? reinterpret_cast<const char*>(spoken) : "";
    const unsigned char* kind = sqlite3_column_text(stmt, 5);
    s.last_fast_path_kind = kind ? reinterpret_cast<const char*>(kind) : "";
    const unsigned char* request = sqlite3_column_text(stmt, 6);
    s.last_fast_path_request = request ? reinterpret_cast<const char*>(request) : "";
    const unsigned char* pending = sqlite3_column_text(stmt, 7);
    s.pending_intent = pending ? reinterpret_cast<const char*>(pending) : "";
    s.pending_at = sqlite3_column_int64(stmt, 8);
    s.updated_at = sqlite3_column_int64(stmt, 9);
    out.push_back(std::move(s));
  }
  sqlite3_finalize(stmt);
  return out;
}

bool SessionStore::upsert(const DeviceSession& session, std::string* err) {
  if (!db_) {
    if (err) *err = "session store not open";
    return false;
  }
  sqlite3_stmt* stmt = nullptr;
  const char* sql =
      "INSERT INTO device_sessions(device_id, conversation_id, last_turn_id, "
      "last_user, last_spoken, last_fast_path_kind, last_fast_path_request, "
      "pending_intent, pending_at, updated_at) "
      "VALUES(?,?,?,?,?,?,?,?,?,?) "
      "ON CONFLICT(device_id) DO UPDATE SET "
      "conversation_id=excluded.conversation_id, "
      "last_turn_id=excluded.last_turn_id, "
      "last_user=excluded.last_user, "
      "last_spoken=excluded.last_spoken, "
      "last_fast_path_kind=excluded.last_fast_path_kind, "
      "last_fast_path_request=excluded.last_fast_path_request, "
      "pending_intent=excluded.pending_intent, "
      "pending_at=excluded.pending_at, "
      "updated_at=excluded.updated_at";
  if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
    if (err) *err = sqlite3_errmsg(db_);
    return false;
  }
  const std::int64_t ts = session.updated_at > 0 ? session.updated_at : now_unix();
  sqlite3_bind_text(stmt, 1, session.device_id.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_int64(stmt, 2, session.conversation_id);
  sqlite3_bind_text(stmt, 3, session.last_turn_id.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 4, session.last_user.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 5, session.last_spoken.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(
      stmt, 6, session.last_fast_path_kind.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(
      stmt, 7, session.last_fast_path_request.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 8, session.pending_intent.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_int64(stmt, 9, session.pending_at);
  sqlite3_bind_int64(stmt, 10, ts);
  const int rc = sqlite3_step(stmt);
  sqlite3_finalize(stmt);
  if (rc != SQLITE_DONE) {
    if (err) *err = sqlite3_errmsg(db_);
    return false;
  }
  return true;
}

}  // namespace intercom

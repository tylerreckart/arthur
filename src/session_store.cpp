#include "intercom/session_store.hpp"
#include "intercom/speak_queue.hpp"
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
  std::lock_guard<std::mutex> lk(mu_);
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
  sqlite3_busy_timeout(db_, 2000);

  const char* sql =
      "CREATE TABLE IF NOT EXISTS device_sessions ("
      "  device_id TEXT PRIMARY KEY NOT NULL,"
      "  conversation_id INTEGER NOT NULL,"
      "  last_turn_id TEXT NOT NULL DEFAULT '',"
      "  last_user TEXT NOT NULL DEFAULT '',"
      "  last_spoken TEXT NOT NULL DEFAULT '',"
      "  last_fast_path_kind TEXT NOT NULL DEFAULT '',"
      "  last_fast_path_request TEXT NOT NULL DEFAULT '',"
      "  last_card TEXT NOT NULL DEFAULT '',"
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
           "last_card TEXT NOT NULL DEFAULT '';",
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
  const char* owned_sql =
      "CREATE TABLE IF NOT EXISTS device_conversations ("
      "  device_id TEXT NOT NULL,"
      "  conversation_id INTEGER NOT NULL,"
      "  created_at INTEGER NOT NULL,"
      "  PRIMARY KEY (device_id, conversation_id)"
      ");";
  errmsg = nullptr;
  if (sqlite3_exec(db_, owned_sql, nullptr, nullptr, &errmsg) != SQLITE_OK) {
    if (err) *err = errmsg ? errmsg : "create device_conversations failed";
    sqlite3_free(errmsg);
    return false;
  }
  const char* speak_sql =
      "CREATE TABLE IF NOT EXISTS speakback_queue ("
      "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
      "  device_id TEXT NOT NULL,"
      "  text TEXT NOT NULL,"
      "  kind TEXT NOT NULL DEFAULT 'schedule',"
      "  run_id INTEGER NOT NULL DEFAULT 0,"
      "  created_at INTEGER NOT NULL"
      ");"
      "CREATE INDEX IF NOT EXISTS speakback_queue_device "
      "  ON speakback_queue(device_id, id);"
      "CREATE TABLE IF NOT EXISTS spoken_runs ("
      "  run_id INTEGER PRIMARY KEY,"
      "  spoken_at INTEGER NOT NULL"
      ");"
      "CREATE TABLE IF NOT EXISTS proactive_marks ("
      "  key TEXT PRIMARY KEY,"
      "  day INTEGER NOT NULL"
      ");";
  errmsg = nullptr;
  if (sqlite3_exec(db_, speak_sql, nullptr, nullptr, &errmsg) != SQLITE_OK) {
    if (err) *err = errmsg ? errmsg : "create speakback tables failed";
    sqlite3_free(errmsg);
    return false;
  }
  errmsg = nullptr;
  if (sqlite3_exec(db_,
                   "ALTER TABLE speakback_queue ADD COLUMN "
                   "expires_at INTEGER NOT NULL DEFAULT 0;",
                   nullptr, nullptr, &errmsg) != SQLITE_OK) {
    const std::string detail = errmsg ? errmsg : "speakback migration failed";
    sqlite3_free(errmsg);
    if (detail.find("duplicate column name") == std::string::npos) {
      if (err) *err = detail;
      return false;
    }
  }
  return true;
}

std::optional<DeviceSession> SessionStore::get(const std::string& device_id) const {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) return std::nullopt;
  sqlite3_stmt* stmt = nullptr;
  const char* sql =
      "SELECT device_id, conversation_id, last_turn_id, last_user, last_spoken, "
      "last_fast_path_kind, last_fast_path_request, last_card, pending_intent, "
      "pending_at, updated_at FROM device_sessions WHERE device_id = ?";
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
    const unsigned char* card = sqlite3_column_text(stmt, 7);
    s.last_card = card ? reinterpret_cast<const char*>(card) : "";
    const unsigned char* pending = sqlite3_column_text(stmt, 8);
    s.pending_intent = pending ? reinterpret_cast<const char*>(pending) : "";
    s.pending_at = sqlite3_column_int64(stmt, 9);
    s.updated_at = sqlite3_column_int64(stmt, 10);
    out = std::move(s);
  }
  sqlite3_finalize(stmt);
  return out;
}

std::vector<DeviceSession> SessionStore::list() const {
  std::lock_guard<std::mutex> lk(mu_);
  std::vector<DeviceSession> out;
  if (!db_) return out;
  sqlite3_stmt* stmt = nullptr;
  const char* sql =
      "SELECT device_id, conversation_id, last_turn_id, last_user, last_spoken, "
      "last_fast_path_kind, last_fast_path_request, last_card, pending_intent, "
      "pending_at, updated_at FROM device_sessions ORDER BY device_id";
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
    const unsigned char* card = sqlite3_column_text(stmt, 7);
    s.last_card = card ? reinterpret_cast<const char*>(card) : "";
    const unsigned char* pending = sqlite3_column_text(stmt, 8);
    s.pending_intent = pending ? reinterpret_cast<const char*>(pending) : "";
    s.pending_at = sqlite3_column_int64(stmt, 9);
    s.updated_at = sqlite3_column_int64(stmt, 10);
    out.push_back(std::move(s));
  }
  sqlite3_finalize(stmt);
  return out;
}

bool SessionStore::upsert(const DeviceSession& session, std::string* err) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) {
    if (err) *err = "session store not open";
    return false;
  }
  sqlite3_stmt* stmt = nullptr;
  const char* sql =
      "INSERT INTO device_sessions(device_id, conversation_id, last_turn_id, "
      "last_user, last_spoken, last_fast_path_kind, last_fast_path_request, "
      "last_card, pending_intent, pending_at, updated_at) "
      "VALUES(?,?,?,?,?,?,?,?,?,?,?) "
      "ON CONFLICT(device_id) DO UPDATE SET "
      "conversation_id=excluded.conversation_id, "
      "last_turn_id=excluded.last_turn_id, "
      "last_user=excluded.last_user, "
      "last_spoken=excluded.last_spoken, "
      "last_fast_path_kind=excluded.last_fast_path_kind, "
      "last_fast_path_request=excluded.last_fast_path_request, "
      "last_card=excluded.last_card, "
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
  sqlite3_bind_text(stmt, 8, session.last_card.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 9, session.pending_intent.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_int64(stmt, 10, session.pending_at);
  sqlite3_bind_int64(stmt, 11, ts);
  const int rc = sqlite3_step(stmt);
  sqlite3_finalize(stmt);
  if (rc != SQLITE_DONE) {
    if (err) *err = sqlite3_errmsg(db_);
    return false;
  }
  return true;
}

bool SessionStore::remember_conversation(const std::string& device_id,
                                         std::int64_t conversation_id,
                                         std::string* err) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) {
    if (err) *err = "session store not open";
    return false;
  }
  if (device_id.empty() || conversation_id <= 0) {
    if (err) *err = "missing conversation";
    return false;
  }
  sqlite3_stmt* stmt = nullptr;
  const char* sql =
      "INSERT OR IGNORE INTO device_conversations"
      "(device_id, conversation_id, created_at) VALUES(?,?,?)";
  if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
    if (err) *err = sqlite3_errmsg(db_);
    return false;
  }
  sqlite3_bind_text(stmt, 1, device_id.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_int64(stmt, 2, conversation_id);
  sqlite3_bind_int64(stmt, 3, now_unix());
  const int rc = sqlite3_step(stmt);
  sqlite3_finalize(stmt);
  if (rc != SQLITE_DONE) {
    if (err) *err = sqlite3_errmsg(db_);
    return false;
  }
  return true;
}

bool SessionStore::owns_conversation(const std::string& device_id,
                                     std::int64_t conversation_id) const {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_ || device_id.empty() || conversation_id <= 0) return false;
  sqlite3_stmt* stmt = nullptr;
  const char* sql =
      "SELECT 1 FROM device_conversations "
      "WHERE device_id = ? AND conversation_id = ?";
  if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
    return false;
  }
  sqlite3_bind_text(stmt, 1, device_id.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_int64(stmt, 2, conversation_id);
  const bool owned = sqlite3_step(stmt) == SQLITE_ROW;
  sqlite3_finalize(stmt);
  return owned;
}

namespace {

const char* column_text(sqlite3_stmt* stmt, int index) {
  const auto* text = sqlite3_column_text(stmt, index);
  return text ? reinterpret_cast<const char*>(text) : "";
}

}  // namespace

bool SessionStore::has_spoken_run(std::int64_t run_id) const {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_ || run_id <= 0) return false;
  sqlite3_stmt* stmt = nullptr;
  const char* sql = "SELECT 1 FROM spoken_runs WHERE run_id = ?";
  if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) return false;
  sqlite3_bind_int64(stmt, 1, run_id);
  const bool found = sqlite3_step(stmt) == SQLITE_ROW;
  sqlite3_finalize(stmt);
  return found;
}

bool SessionStore::mark_spoken_run(std::int64_t run_id, std::string* err) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) {
    if (err) *err = "session store not open";
    return false;
  }
  if (run_id <= 0) return true;
  sqlite3_stmt* stmt = nullptr;
  const char* sql =
      "INSERT OR IGNORE INTO spoken_runs(run_id, spoken_at) VALUES(?,?)";
  if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
    if (err) *err = sqlite3_errmsg(db_);
    return false;
  }
  sqlite3_bind_int64(stmt, 1, run_id);
  sqlite3_bind_int64(stmt, 2, now_unix());
  const int rc = sqlite3_step(stmt);
  const int inserted = sqlite3_changes(db_);
  sqlite3_finalize(stmt);
  if (rc != SQLITE_DONE) {
    if (err) *err = sqlite3_errmsg(db_);
    return false;
  }
  char* errmsg = nullptr;
  const char* trim =
      "DELETE FROM spoken_runs WHERE run_id NOT IN ("
      "  SELECT run_id FROM spoken_runs ORDER BY spoken_at DESC, run_id DESC LIMIT 256"
      ")";
  if (sqlite3_exec(db_, trim, nullptr, nullptr, &errmsg) != SQLITE_OK) {
    if (err) *err = errmsg ? errmsg : "spoken run trim failed";
    sqlite3_free(errmsg);
    return false;
  }
  return inserted == 1;
}

std::int64_t SessionStore::enqueue_speakback(const std::string& device_id,
                                             const std::string& text,
                                             const std::string& kind,
                                             std::int64_t run_id,
                                             int max_queued,
                                             std::string* err,
                                             std::int64_t expires_at) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) {
    if (err) *err = "session store not open";
    return 0;
  }
  if (device_id.empty() || text.empty()) {
    if (err) *err = "missing speakback utterance";
    return 0;
  }
  const int cap = max_queued > 0 ? max_queued : 4;
  char* errmsg = nullptr;
  if (sqlite3_exec(db_, "BEGIN IMMEDIATE", nullptr, nullptr, &errmsg) != SQLITE_OK) {
    if (err) *err = errmsg ? errmsg : "speakback begin failed";
    sqlite3_free(errmsg);
    return 0;
  }
  sqlite3_stmt* stmt = nullptr;
  const char* sql =
      "INSERT INTO speakback_queue(device_id, text, kind, run_id, created_at, expires_at) "
      "VALUES(?,?,?,?,?,?)";
  if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
    if (err) *err = sqlite3_errmsg(db_);
    sqlite3_exec(db_, "ROLLBACK", nullptr, nullptr, nullptr);
    return 0;
  }
  const std::string stored_kind = kind.empty() ? "schedule" : kind;
  const std::int64_t created = now_unix();
  const std::int64_t expires =
      expires_at > 0 ? expires_at : created + speak_ttl_seconds(stored_kind);
  sqlite3_bind_text(stmt, 1, device_id.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 2, text.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(stmt, 3, stored_kind.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_int64(stmt, 4, run_id);
  sqlite3_bind_int64(stmt, 5, created);
  sqlite3_bind_int64(stmt, 6, expires);
  const int rc = sqlite3_step(stmt);
  const std::int64_t id = sqlite3_last_insert_rowid(db_);
  sqlite3_finalize(stmt);
  if (rc != SQLITE_DONE) {
    if (err) *err = sqlite3_errmsg(db_);
    sqlite3_exec(db_, "ROLLBACK", nullptr, nullptr, nullptr);
    return 0;
  }
  sqlite3_stmt* trim = nullptr;
  const char* trim_sql =
      "DELETE FROM speakback_queue WHERE device_id = ? AND id NOT IN ("
      "  SELECT id FROM speakback_queue WHERE device_id = ? ORDER BY id DESC LIMIT ?"
      ")";
  if (sqlite3_prepare_v2(db_, trim_sql, -1, &trim, nullptr) != SQLITE_OK) {
    if (err) *err = sqlite3_errmsg(db_);
    sqlite3_exec(db_, "ROLLBACK", nullptr, nullptr, nullptr);
    return 0;
  }
  sqlite3_bind_text(trim, 1, device_id.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_text(trim, 2, device_id.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_int(trim, 3, cap);
  const int trim_rc = sqlite3_step(trim);
  sqlite3_finalize(trim);
  if (trim_rc != SQLITE_DONE) {
    if (err) *err = sqlite3_errmsg(db_);
    sqlite3_exec(db_, "ROLLBACK", nullptr, nullptr, nullptr);
    return 0;
  }
  if (sqlite3_exec(db_, "COMMIT", nullptr, nullptr, &errmsg) != SQLITE_OK) {
    if (err) *err = errmsg ? errmsg : "speakback commit failed";
    sqlite3_free(errmsg);
    sqlite3_exec(db_, "ROLLBACK", nullptr, nullptr, nullptr);
    return 0;
  }
  return id;
}

std::vector<SpeakbackItem> SessionStore::list_speakback(
    const std::string& device_id) const {
  std::lock_guard<std::mutex> lk(mu_);
  std::vector<SpeakbackItem> out;
  if (!db_ || device_id.empty()) return out;
  sqlite3_stmt* stmt = nullptr;
  const char* sql =
      "SELECT id, device_id, text, kind, run_id, created_at, expires_at "
      "FROM speakback_queue WHERE device_id = ? ORDER BY id ASC";
  if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) return out;
  sqlite3_bind_text(stmt, 1, device_id.c_str(), -1, SQLITE_TRANSIENT);
  while (sqlite3_step(stmt) == SQLITE_ROW) {
    SpeakbackItem item;
    item.id = sqlite3_column_int64(stmt, 0);
    item.device_id = column_text(stmt, 1);
    item.text = column_text(stmt, 2);
    item.kind = column_text(stmt, 3);
    item.run_id = sqlite3_column_int64(stmt, 4);
    item.created_at = sqlite3_column_int64(stmt, 5);
    item.expires_at = sqlite3_column_int64(stmt, 6);
    out.push_back(std::move(item));
  }
  sqlite3_finalize(stmt);
  return out;
}

std::size_t SessionStore::count_speakback(const std::string& device_id) const {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_ || device_id.empty()) return 0;
  sqlite3_stmt* stmt = nullptr;
  const char* sql = "SELECT COUNT(*) FROM speakback_queue WHERE device_id = ?";
  if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) return 0;
  sqlite3_bind_text(stmt, 1, device_id.c_str(), -1, SQLITE_TRANSIENT);
  std::size_t count = 0;
  if (sqlite3_step(stmt) == SQLITE_ROW) {
    count = static_cast<std::size_t>(sqlite3_column_int64(stmt, 0));
  }
  sqlite3_finalize(stmt);
  return count;
}

bool SessionStore::remove_speakback(std::int64_t id, std::string* err) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) {
    if (err) *err = "session store not open";
    return false;
  }
  if (id <= 0) return false;
  sqlite3_stmt* stmt = nullptr;
  const char* sql = "DELETE FROM speakback_queue WHERE id = ?";
  if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
    if (err) *err = sqlite3_errmsg(db_);
    return false;
  }
  sqlite3_bind_int64(stmt, 1, id);
  const int rc = sqlite3_step(stmt);
  sqlite3_finalize(stmt);
  if (rc != SQLITE_DONE) {
    if (err) *err = sqlite3_errmsg(db_);
    return false;
  }
  return true;
}

bool SessionStore::mark_day(const std::string& key, int day, std::string* err) {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_) {
    if (err) *err = "session store not open";
    return false;
  }
  if (key.empty() || day <= 0) return false;
  sqlite3_stmt* stmt = nullptr;
  const char* sql =
      "INSERT INTO proactive_marks(key, day) VALUES(?, ?) "
      "ON CONFLICT(key) DO UPDATE SET day = excluded.day";
  if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
    if (err) *err = sqlite3_errmsg(db_);
    return false;
  }
  sqlite3_bind_text(stmt, 1, key.c_str(), -1, SQLITE_TRANSIENT);
  sqlite3_bind_int(stmt, 2, day);
  const int rc = sqlite3_step(stmt);
  sqlite3_finalize(stmt);
  if (rc != SQLITE_DONE) {
    if (err) *err = sqlite3_errmsg(db_);
    return false;
  }
  return true;
}

int SessionStore::marked_day(const std::string& key) const {
  std::lock_guard<std::mutex> lk(mu_);
  if (!db_ || key.empty()) return 0;
  sqlite3_stmt* stmt = nullptr;
  const char* sql = "SELECT day FROM proactive_marks WHERE key = ?";
  if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) return 0;
  sqlite3_bind_text(stmt, 1, key.c_str(), -1, SQLITE_TRANSIENT);
  int day = 0;
  if (sqlite3_step(stmt) == SQLITE_ROW) day = sqlite3_column_int(stmt, 0);
  sqlite3_finalize(stmt);
  return day;
}

}  // namespace intercom

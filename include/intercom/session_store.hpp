#pragma once

#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

struct sqlite3;

namespace intercom {

struct DeviceSession {
  std::string device_id;
  std::int64_t conversation_id = 0;
  std::string last_turn_id;
  std::string last_user;
  std::string last_spoken;
  std::string last_fast_path_kind;
  std::string last_fast_path_request;
  // Compact news/markets lists from the latest cards, so "the second one"
  // can be resolved without another fetch.
  std::string last_card;
  std::string pending_intent;
  std::int64_t pending_at = 0;
  std::int64_t updated_at = 0;
  // Who spoke last. Empty is the household. Follow-up memory for a person
  // lives in person scope, not in these household fields.
  std::string person_id;
};

struct HouseholdPerson {
  std::string person_id;
  std::string name;
  std::string calendar;
  int phrases = 0;
};

// Per-person follow-up memory. The device row stays the household session.
struct PersonScope {
  std::string device_id;
  std::string person_id;
  std::string last_user;
  std::string last_spoken;
  std::string last_card;
  std::string last_fast_path_kind;
  std::string last_fast_path_request;
};

struct StoredVoice {
  std::string person_id;
  std::string name;
  int phrase = 0;
  std::vector<float> embedding;
};

// One unsent speak-back utterance. `id` is the SQLite row.
struct SpeakbackItem {
  std::int64_t id = 0;
  std::string device_id;
  std::string text;
  std::string kind;
  std::int64_t run_id = 0;
  std::int64_t created_at = 0;
  // 0 means "created_at plus the kind's lifetime" for rows written before
  // this column existed.
  std::int64_t expires_at = 0;
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

  // Conversations this device has opened. Resume refuses any other id.
  bool remember_conversation(const std::string& device_id,
                             std::int64_t conversation_id,
                             std::string* err);
  bool owns_conversation(const std::string& device_id,
                         std::int64_t conversation_id) const;

  // Speak-back survives process restart. `mark_spoken_run` returns false when
  // this run was already recorded (including by a previous process). The queue
  // keeps utterances that could not be spoken because the device was offline
  // or busy; oldest rows past `max_queued` are dropped.
  bool has_spoken_run(std::int64_t run_id) const;
  bool mark_spoken_run(std::int64_t run_id, std::string* err);
  // expires_at == 0 stores created_at plus the lifetime for `kind`.
  std::int64_t enqueue_speakback(const std::string& device_id,
                                 const std::string& text,
                                 const std::string& kind,
                                 std::int64_t run_id,
                                 int max_queued,
                                 std::string* err,
                                 std::int64_t expires_at = 0);

  // Civil day (YYYYMMDD) a proactive utterance was spoken. 0 if never.
  bool mark_day(const std::string& key, int day, std::string* err);
  int marked_day(const std::string& key) const;

  // Enrollment stores a name and voiceprints, never the audio.
  std::optional<HouseholdPerson> enroll_person(const std::string& person_id,
                                               const std::string& name,
                                               const std::string& calendar,
                                               std::string* err);
  std::vector<HouseholdPerson> list_people() const;
  bool remove_person(const std::string& person_id, std::string* err);
  bool put_voiceprint(const std::string& person_id, int phrase,
                      const float* embedding, int dims, std::string* err);
  std::vector<StoredVoice> list_voices() const;

  std::optional<PersonScope> get_scope(const std::string& device_id,
                                       const std::string& person_id) const;
  bool upsert_scope(const PersonScope& scope, std::string* err);
  std::vector<SpeakbackItem> list_speakback(const std::string& device_id) const;
  std::size_t count_speakback(const std::string& device_id) const;
  bool remove_speakback(std::int64_t id, std::string* err);

 private:
  std::string db_path_;
  sqlite3* db_ = nullptr;
  mutable std::mutex mu_;
};

}  // namespace intercom

#include "intercom/session_store.hpp"
#include "intercom/voiceprint.hpp"

#include <cmath>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <string>
#include <vector>

namespace {

int g_fails = 0;

void expect(bool cond, const char* expr, const char* file, int line) {
  if (!cond) {
    std::cerr << "FAIL " << file << ":" << line << " " << expr << "\n";
    ++g_fails;
  }
}

#define CHECK(cond) expect((cond), #cond, __FILE__, __LINE__)

std::vector<std::uint8_t> tone(int rate, double seconds, std::vector<double> freqs) {
  const int n = static_cast<int>(rate * seconds);
  std::vector<std::uint8_t> pcm(static_cast<std::size_t>(n) * 2);
  for (int i = 0; i < n; ++i) {
    double sample = 0;
    for (double freq : freqs) {
      sample += std::sin(2.0 * 3.1415926535 * freq * i / rate);
    }
    sample /= static_cast<double>(freqs.size());
    int value = static_cast<int>(sample * 12000.0);
    if (value > 32767) value = 32767;
    if (value < -32768) value = -32768;
    pcm[static_cast<std::size_t>(i) * 2] = static_cast<std::uint8_t>(value & 0xff);
    pcm[static_cast<std::size_t>(i) * 2 + 1] = static_cast<std::uint8_t>((value >> 8) & 0xff);
  }
  return pcm;
}

intercom::EnrolledSpeaker enrolled(std::string id, std::string name,
                                   const intercom::Voiceprint& print) {
  intercom::EnrolledSpeaker speaker;
  speaker.person_id = std::move(id);
  speaker.name = std::move(name);
  speaker.prints = {print, print, print};
  return speaker;
}

}  // namespace

int main() {
  using namespace intercom;
  const int rate = 16000;
  const auto ada = tone(rate, 1.2, {150, 700});
  const auto ben = tone(rate, 1.2, {220, 1800});
  const auto stranger = tone(rate, 1.2, {100, 3000});
  const auto ada_print = embed_pcm(ada.data(), ada.size(), rate, 1);
  const auto ben_print = embed_pcm(ben.data(), ben.size(), rate, 1);
  const auto stranger_print = embed_pcm(stranger.data(), stranger.size(), rate, 1);

  CHECK(voice_cosine(ada_print, ada_print) > 0.99f);
  CHECK(voice_cosine(ada_print, ben_print) < kSpeakerMinScore);

  std::vector<EnrolledSpeaker> roster = {
      enrolled("padaaaaa", "Ada", ada_print),
      enrolled("pbenbbbb", "Ben", ben_print),
  };
  const auto ada_id = identify_speaker(roster, ada_print);
  const auto ben_id = identify_speaker(roster, ben_print);
  const auto stranger_id = identify_speaker(roster, stranger_print);
  CHECK(ada_id.confident);
  CHECK(ada_id.person_id == "padaaaaa");
  CHECK(ada_id.name == "Ada");
  CHECK(ben_id.confident);
  CHECK(ben_id.person_id == "pbenbbbb");
  CHECK(!stranger_id.confident);
  CHECK(stranger_id.name.empty());

  std::vector<std::uint8_t> silence(rate * 2, 0);
  const auto quiet = identify_speaker(roster, embed_pcm(silence.data(), silence.size(), rate, 1));
  CHECK(!quiet.confident);

  std::vector<std::uint8_t> short_clip(rate / 4, 0);
  CHECK(!identify_speaker(roster, embed_pcm(short_clip.data(), short_clip.size(), rate, 1))
             .confident);

  EnrolledSpeaker partial = enrolled("padaaaaa", "Ada", ada_print);
  partial.prints.pop_back();
  CHECK(!identify_speaker({partial}, ada_print).confident);
  CHECK(!identify_speaker({}, ada_print).confident);

  ClientContext both;
  both.sources.push_back({"calendar", "household day"});
  both.sources.push_back({"cal-padaaaaa", "ada day"});
  both.sources.push_back({"cal-pbenbbbb", "ben day"});
  both.sources.push_back({"front", "Mail"});
  const auto adas = context_for_speaker(both, ada_id);
  CHECK(adas.sources.size() == 2);
  CHECK(adas.sources[0].name == "cal-padaaaaa");
  CHECK(adas.sources[1].name == "front");
  SpeakerIdentity unknown;
  const auto house = context_for_speaker(both, unknown);
  CHECK(house.sources.size() == 2);
  CHECK(house.sources[0].name == "calendar");
  CHECK(house.sources[1].name == "front");

  SpeakerIdentity named = ada_id;
  named.confident = false;
  CHECK(speaker_note(named).find("Do not greet") != std::string::npos);
  CHECK(speaker_note(named).find("Ada") == std::string::npos);
  CHECK(speaker_note(ada_id).find("Ada") != std::string::npos);
  CHECK(speaker_note(ada_id).find("person padaaaaa") != std::string::npos);
  CHECK(speaker_note(ada_id).find("You may greet") != std::string::npos);

  const auto db = std::filesystem::temp_directory_path() / "arthur-phase5-voice.db";
  std::filesystem::remove(db);
  SessionStore store(db.string());
  std::string err;
  CHECK(store.open(&err));
  auto person = store.enroll_person("padaaaaa", "Ada", "Ada", &err);
  CHECK(person.has_value());
  CHECK(store.put_voiceprint("padaaaaa", 0, ada_print.v, kVoiceDims, &err));
  CHECK(store.put_voiceprint("padaaaaa", 1, ada_print.v, kVoiceDims, &err));
  CHECK(store.put_voiceprint("padaaaaa", 2, ada_print.v, kVoiceDims, &err));
  const auto voices = store.list_voices();
  CHECK(voices.size() == 3);
  CHECK(voices[0].embedding.size() == static_cast<std::size_t>(kVoiceDims));
  const auto people = store.list_people();
  CHECK(people.size() == 1);
  CHECK(people[0].phrases == 3);

  PersonScope ada_scope;
  ada_scope.device_id = "desk";
  ada_scope.person_id = "padaaaaa";
  ada_scope.last_card = "ada card";
  CHECK(store.upsert_scope(ada_scope, &err));
  PersonScope ben_scope;
  ben_scope.device_id = "desk";
  ben_scope.person_id = "pbenbbbb";
  ben_scope.last_card = "ben card";
  CHECK(store.upsert_scope(ben_scope, &err));
  const auto ada_saved = store.get_scope("desk", "padaaaaa");
  const auto ben_saved = store.get_scope("desk", "pbenbbbb");
  CHECK(ada_saved && ada_saved->last_card == "ada card");
  CHECK(ben_saved && ben_saved->last_card == "ben card");

  DeviceSession session;
  session.device_id = "desk";
  session.person_id = "padaaaaa";
  session.last_user = "household line";
  CHECK(store.upsert(session, &err));
  const auto loaded = store.get("desk");
  CHECK(loaded && loaded->person_id == "padaaaaa");
  CHECK(loaded->last_user == "household line");

  std::filesystem::remove(db);
  if (g_fails) {
    std::cerr << g_fails << " failed\n";
    return 1;
  }
  std::cout << "ok\n";
  return 0;
}

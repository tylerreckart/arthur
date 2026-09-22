#pragma once

#include "intercom/home.hpp"

#include <nlohmann/json.hpp>

#include <string>

namespace intercom {

// Spoken confirmation plus an optional versioned desk surface (weather).
struct HomeAction {
  std::string reply;
  nlohmann::json surface = nullptr;
};

// Home Assistant REST. Empty config → configured() is false and run() fails.
class HomeClient {
 public:
  explicit HomeClient(HomeConfig cfg);
  virtual ~HomeClient() = default;

  virtual bool configured() const;
  // Spoken confirmation, or empty reply with err set.
  virtual HomeAction run(const HomeIntent& intent, std::string* err) const;

 private:
  bool call_service(const std::string& domain, const std::string& service,
                    const std::string& entity_id, const std::string& extra_json,
                    std::string* err) const;
  std::string get_state_json(const std::string& entity_id, std::string* err) const;
  std::string resolve_light(const std::string& room, std::string* err) const;

  HomeConfig cfg_;
};

}  // namespace intercom

#pragma once

#include "intercom/turn_pipeline.hpp"
#include "intercom/device_hub.hpp"

#include <memory>
#include <string>

namespace intercom {

class WhisperStt;

struct ServerDeps {
  Config config;
  std::shared_ptr<TurnPipeline> pipeline;
  std::shared_ptr<DeviceHub> hub;
};

void run_http_server(ServerDeps deps);

}  // namespace intercom

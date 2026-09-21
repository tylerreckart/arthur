#include "intercom/arbiter_client.hpp"
#include "intercom/clock.hpp"
#include "intercom/util.hpp"

#include <httplib.h>
#include <nlohmann/json.hpp>

#include <memory>
#include <optional>
#include <sstream>

namespace intercom {
namespace {

struct ParsedUrl {
  std::string host;
  int port = 80;
  std::string path_prefix;
  bool https = false;
};

std::optional<ParsedUrl> parse_base_url(const std::string& base) {
  std::string u = base;
  while (!u.empty() && u.back() == '/') u.pop_back();
  ParsedUrl out;
  if (u.rfind("https://", 0) == 0) {
    out.https = true;
    out.port = 443;
    u = u.substr(8);
  } else if (u.rfind("http://", 0) == 0) {
    out.https = false;
    out.port = 80;
    u = u.substr(7);
  } else {
    return std::nullopt;
  }
  const auto slash = u.find('/');
  std::string hostport = slash == std::string::npos ? u : u.substr(0, slash);
  out.path_prefix = slash == std::string::npos ? "" : u.substr(slash);
  const auto colon = hostport.find(':');
  if (colon == std::string::npos) {
    out.host = hostport;
  } else {
    out.host = hostport.substr(0, colon);
    out.port = std::stoi(hostport.substr(colon + 1));
  }
  if (out.host.empty()) return std::nullopt;
  return out;
}

std::unique_ptr<httplib::Client> make_client(const ParsedUrl& u) {
  auto cli = std::make_unique<httplib::Client>(u.host, u.port);
  cli->set_connection_timeout(10, 0);
  cli->set_read_timeout(600, 0);
  cli->set_write_timeout(30, 0);
  return cli;
}

void parse_sse_buffer(std::string& buf,
                      std::string& event_name,
                      const ArbiterStreamCallbacks& cbs,
                      std::string* request_id_out,
                      bool* got_done) {
  for (;;) {
    const auto pos = buf.find("\n\n");
    if (pos == std::string::npos) break;
    std::string frame = buf.substr(0, pos);
    buf.erase(0, pos + 2);

    std::string data;
    std::istringstream iss(frame);
    std::string line;
    while (std::getline(iss, line)) {
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (line.rfind("event:", 0) == 0) {
        event_name = line.substr(6);
        while (!event_name.empty() && event_name.front() == ' ') event_name.erase(event_name.begin());
      } else if (line.rfind("data:", 0) == 0) {
        std::string d = line.substr(5);
        while (!d.empty() && d.front() == ' ') d.erase(d.begin());
        if (!data.empty()) data.push_back('\n');
        data += d;
      }
    }
    if (data.empty()) continue;

    nlohmann::json j;
    try {
      j = nlohmann::json::parse(data);
    } catch (...) {
      event_name.clear();
      continue;
    }

    if (event_name == "request_received" ||
        (event_name.empty() && j.contains("request_id"))) {
      // request_id often arrives on done; some deployments put it early — also check.
    }

    auto event_depth = [&]() -> int {
      if (j.contains("depth") && j["depth"].is_number_integer()) {
        return j["depth"].get<int>();
      }
      return 0;
    };

    if (event_name == "text" && cbs.on_text_delta) {
      if (event_depth() == 0 && j.contains("delta") && j["delta"].is_string()) {
        cbs.on_text_delta(j["delta"].get<std::string>());
      }
    } else if (event_name == "tool_call" && cbs.on_tool_call) {
      if (event_depth() == 0) {
        std::string tool;
        if (j.contains("tool") && j["tool"].is_string()) {
          tool = j["tool"].get<std::string>();
        }
        cbs.on_tool_call(tool);
      }
    } else if (event_name == "done") {
      *got_done = true;
      bool ok = j.value("ok", false);
      std::string content = j.value("content", "");
      std::string error = j.value("error", "");
      if (j.contains("request_id") && j["request_id"].is_string()) {
        const std::string rid = j["request_id"].get<std::string>();
        if (request_id_out && request_id_out->empty()) {
          *request_id_out = rid;
        }
        if (cbs.on_request_id && !rid.empty()) cbs.on_request_id(rid);
      }
      if (cbs.on_done) cbs.on_done(ok, content, error);
    } else if (event_name == "request_received") {
      if (j.contains("request_id") && j["request_id"].is_string()) {
        const std::string rid = j["request_id"].get<std::string>();
        if (request_id_out && request_id_out->empty()) *request_id_out = rid;
        if (cbs.on_request_id && !rid.empty()) cbs.on_request_id(rid);
      }
    }
    event_name.clear();
  }
}

nlohmann::json agent_def_with_clock(const std::string& agent_def_json) {
  if (agent_def_json.empty()) return {};
  nlohmann::json def;
  try {
    def = nlohmann::json::parse(agent_def_json);
  } catch (...) {
    return {};
  }
  if (!def.is_object()) return {};
  nlohmann::json next = nlohmann::json::array();
  next.push_back(local_clock_rule());
  if (def.contains("rules") && def["rules"].is_array()) {
    for (const auto& r : def["rules"]) {
      if (r.is_string()) {
        const std::string s = r.get<std::string>();
        if (s.rfind("CURRENT LOCAL DATETIME:", 0) == 0) continue;
      }
      next.push_back(r);
    }
  }
  def["rules"] = std::move(next);
  return def;
}

}  // namespace

ArbiterClient::ArbiterClient(std::string base_url, std::string token, std::string agent,
                             std::string agent_def_json)
    : base_url_(std::move(base_url)),
      token_(std::move(token)),
      agent_(std::move(agent)),
      agent_def_json_(std::move(agent_def_json)) {}

std::optional<std::int64_t> ArbiterClient::create_conversation(const std::string& title,
                                                               std::string* err) const {
  auto parsed = parse_base_url(base_url_);
  if (!parsed) {
    if (err) *err = "invalid arbiter_base_url";
    return std::nullopt;
  }
  auto cli = make_client(*parsed);
  nlohmann::json body = {{"title", title}, {"agent_id", agent_}};
  if (!agent_def_json_.empty()) {
    body["agent_def"] = nlohmann::json::parse(agent_def_json_);
  }
  httplib::Headers headers = {
      {"Authorization", "Bearer " + token_},
      {"Content-Type", "application/json"},
  };
  const std::string path = parsed->path_prefix + "/v1/conversations";
  auto res = cli->Post(path.c_str(), headers, body.dump(), "application/json");
  if (!res) {
    if (err) *err = "arbiter create conversation: connection failed";
    return std::nullopt;
  }
  if (res->status != 200 && res->status != 201) {
    if (err) *err = "arbiter create conversation HTTP " + std::to_string(res->status) +
                    ": " + res->body;
    return std::nullopt;
  }
  try {
    auto j = nlohmann::json::parse(res->body);
    if (!j.contains("id")) {
      if (err) *err = "arbiter create conversation: missing id";
      return std::nullopt;
    }
    return j["id"].get<std::int64_t>();
  } catch (const std::exception& e) {
    if (err) *err = std::string("arbiter create conversation parse: ") + e.what();
    return std::nullopt;
  }
}

bool ArbiterClient::send_message(std::int64_t conversation_id,
                                 const std::string& message,
                                 const std::string& idempotency_key,
                                 ArbiterStreamCallbacks cbs,
                                 std::atomic<bool>* cancel_flag,
                                 std::string* err) const {
  auto parsed = parse_base_url(base_url_);
  if (!parsed) {
    if (err) *err = "invalid arbiter_base_url";
    return false;
  }
  auto cli = make_client(*parsed);
  nlohmann::json body = {
      {"message", message},
      {"channel", "voice"},
  };
  if (auto def = agent_def_with_clock(agent_def_json_); !def.empty()) {
    body["agent_def"] = std::move(def);
  }

  httplib::Request req;
  req.method = "POST";
  req.path = parsed->path_prefix + "/v1/conversations/" +
             std::to_string(conversation_id) + "/messages";
  req.set_header("Authorization", "Bearer " + token_);
  req.set_header("Content-Type", "application/json");
  req.set_header("Accept", "text/event-stream");
  if (!idempotency_key.empty()) {
    req.set_header("Idempotency-Key", idempotency_key);
  }
  req.body = body.dump();

  std::string sse_buf;
  std::string event_name;
  std::string request_id;
  bool got_done = false;
  bool aborted = false;

  req.content_receiver = [&](const char* data, size_t len, uint64_t, uint64_t) {
    if (cancel_flag && cancel_flag->load()) {
      aborted = true;
      return false;
    }
    sse_buf.append(data, len);
    for (std::size_t i = 0; i + 1 < sse_buf.size(); ++i) {
      if (sse_buf[i] == '\r' && sse_buf[i + 1] == '\n') {
        sse_buf.erase(i, 1);
      }
    }
    parse_sse_buffer(sse_buf, event_name, cbs, &request_id, &got_done);
    return !got_done;
  };

  auto res = cli->send(req);

  // content_receiver returns false on `done` so httplib reports Canceled.
  if (got_done) return true;

  if (aborted) {
    if (!request_id.empty()) {
      std::string cancel_err;
      cancel_request(request_id, &cancel_err);
    }
    if (err) *err = "canceled";
    return false;
  }
  if (!res) {
    if (err) {
      const auto why = httplib::to_string(res.error());
      *err = std::string("arbiter send_message: ") +
             (why == "Connection" ? "connection failed" : why);
    }
    return false;
  }
  if (res->status != 200) {
    if (err) {
      *err = "arbiter send_message HTTP " + std::to_string(res->status) + ": " +
             res->body;
    }
    return false;
  }
  if (!got_done) {
    parse_sse_buffer(sse_buf, event_name, cbs, &request_id, &got_done);
    if (!sse_buf.empty()) {
      sse_buf.append("\n\n");
      parse_sse_buffer(sse_buf, event_name, cbs, &request_id, &got_done);
    }
  }
  return got_done;
}

bool ArbiterClient::cancel_request(const std::string& request_id, std::string* err) const {
  if (request_id.empty()) {
    if (err) *err = "empty request_id";
    return false;
  }
  auto parsed = parse_base_url(base_url_);
  if (!parsed) {
    if (err) *err = "invalid arbiter_base_url";
    return false;
  }
  auto cli = make_client(*parsed);
  httplib::Headers headers = {{"Authorization", "Bearer " + token_}};
  const std::string path = parsed->path_prefix + "/v1/requests/" + request_id + "/cancel";
  auto res = cli->Post(path.c_str(), headers, "", "application/json");
  if (!res) {
    if (err) *err = "arbiter cancel: connection failed";
    return false;
  }
  if (res->status != 200 && res->status != 204) {
    if (err) *err = "arbiter cancel HTTP " + std::to_string(res->status) + ": " + res->body;
    return false;
  }
  return true;
}

namespace {

std::int64_t json_i64(const nlohmann::json& j, const char* key) {
  if (!j.contains(key) || j[key].is_null()) return 0;
  if (j[key].is_number_integer()) return j[key].get<std::int64_t>();
  if (j[key].is_number()) return static_cast<std::int64_t>(j[key].get<double>());
  if (j[key].is_string()) {
    try {
      return std::stoll(j[key].get<std::string>());
    } catch (...) {
      return 0;
    }
  }
  return 0;
}

std::string json_str(const nlohmann::json& j, const char* key) {
  if (!j.contains(key) || j[key].is_null()) return {};
  if (j[key].is_string()) return j[key].get<std::string>();
  return {};
}

NotificationEvent notification_from_json(const nlohmann::json& j) {
  NotificationEvent ev;
  ev.kind = json_str(j, "kind");
  ev.task_id = json_i64(j, "task_id");
  ev.run_id = json_i64(j, "run_id");
  if (ev.run_id == 0) ev.run_id = json_i64(j, "id");
  ev.conversation_id = json_i64(j, "conversation_id");
  ev.started_at = json_i64(j, "started_at");
  ev.completed_at = json_i64(j, "completed_at");
  ev.agent_id = json_str(j, "agent_id");
  ev.status = json_str(j, "status");
  ev.result_summary = json_str(j, "result_summary");
  ev.error_message = json_str(j, "error_message");
  if (ev.kind.empty()) {
    if (ev.status == "succeeded" || ev.status == "completed") ev.kind = "run.completed";
    else if (ev.status == "failed") ev.kind = "run.failed";
    else if (ev.status == "running") ev.kind = "run.started";
  }
  return ev;
}

}  // namespace

NotificationEvent parse_notification_json(std::string_view data) {
  try {
    return notification_from_json(nlohmann::json::parse(data));
  } catch (...) {
    return {};
  }
}

ScheduleInfo parse_schedule_json(std::string_view body) {
  ScheduleInfo out;
  try {
    auto j = nlohmann::json::parse(body);
    const nlohmann::json* row = &j;
    if (j.contains("scheduled_task") && j["scheduled_task"].is_object()) {
      row = &j["scheduled_task"];
    } else if (j.contains("schedule") && j["schedule"].is_object()) {
      row = &j["schedule"];
    }
    out.id = json_i64(*row, "id");
    out.conversation_id = json_i64(*row, "conversation_id");
    out.agent_id = json_str(*row, "agent_id");
    out.message = json_str(*row, "message");
  } catch (...) {
  }
  return out;
}

std::optional<ScheduleInfo> ArbiterClient::get_schedule(std::int64_t task_id,
                                                        std::string* err) const {
  auto parsed = parse_base_url(base_url_);
  if (!parsed) {
    if (err) *err = "invalid arbiter_base_url";
    return std::nullopt;
  }
  auto cli = make_client(*parsed);
  httplib::Headers headers = {{"Authorization", "Bearer " + token_}};
  const std::string path =
      parsed->path_prefix + "/v1/schedules/" + std::to_string(task_id);
  auto res = cli->Get(path.c_str(), headers);
  if (!res) {
    if (err) *err = "arbiter get_schedule: connection failed";
    return std::nullopt;
  }
  if (res->status != 200) {
    if (err) {
      *err = "arbiter get_schedule HTTP " + std::to_string(res->status);
    }
    return std::nullopt;
  }
  auto info = parse_schedule_json(res->body);
  if (info.id == 0) info.id = task_id;
  return info;
}

std::vector<NotificationEvent> ArbiterClient::list_runs_since(std::int64_t since_epoch,
                                                              std::string* err) const {
  auto parsed = parse_base_url(base_url_);
  if (!parsed) {
    if (err) *err = "invalid arbiter_base_url";
    return {};
  }
  auto cli = make_client(*parsed);
  httplib::Headers headers = {{"Authorization", "Bearer " + token_}};
  std::string path = parsed->path_prefix + "/v1/runs";
  if (since_epoch > 0) path += "?since=" + std::to_string(since_epoch);
  auto res = cli->Get(path.c_str(), headers);
  if (!res) {
    if (err) *err = "arbiter list_runs: connection failed";
    return {};
  }
  if (res->status != 200) {
    if (err) *err = "arbiter list_runs HTTP " + std::to_string(res->status);
    return {};
  }
  std::vector<NotificationEvent> out;
  try {
    auto j = nlohmann::json::parse(res->body);
    const nlohmann::json* rows = &j;
    if (j.contains("runs") && j["runs"].is_array()) rows = &j["runs"];
    if (!rows->is_array()) return out;
    for (const auto& row : *rows) {
      if (!row.is_object()) continue;
      out.push_back(notification_from_json(row));
    }
  } catch (const std::exception& e) {
    if (err) *err = std::string("arbiter list_runs parse: ") + e.what();
  }
  return out;
}

bool ArbiterClient::stream_notifications(
    const std::function<void(const NotificationEvent&)>& on_event,
    std::atomic<bool>* cancel_flag, std::string* err) const {
  auto parsed = parse_base_url(base_url_);
  if (!parsed) {
    if (err) *err = "invalid arbiter_base_url";
    return false;
  }
  auto cli = make_client(*parsed);
  cli->set_read_timeout(45, 0);

  httplib::Request req;
  req.method = "GET";
  req.path = parsed->path_prefix + "/v1/notifications/stream";
  req.set_header("Authorization", "Bearer " + token_);
  req.set_header("Accept", "text/event-stream");

  std::string sse_buf;
  std::string event_name;
  bool aborted = false;

  auto drain = [&]() {
    for (;;) {
      const auto pos = sse_buf.find("\n\n");
      if (pos == std::string::npos) break;
      std::string frame = sse_buf.substr(0, pos);
      sse_buf.erase(0, pos + 2);
      std::string data;
      std::istringstream iss(frame);
      std::string line;
      while (std::getline(iss, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.rfind("event:", 0) == 0) {
          event_name = trim(line.substr(6));
        } else if (line.rfind("data:", 0) == 0) {
          std::string d = line.substr(5);
          while (!d.empty() && d.front() == ' ') d.erase(d.begin());
          if (!data.empty()) data.push_back('\n');
          data += d;
        }
      }
      if (event_name == "notification" && !data.empty() && on_event) {
        on_event(parse_notification_json(data));
      }
      event_name.clear();
    }
  };

  req.content_receiver = [&](const char* data, size_t len, uint64_t, uint64_t) {
    if (cancel_flag && cancel_flag->load()) {
      aborted = true;
      return false;
    }
    sse_buf.append(data, len);
    for (std::size_t i = 0; i + 1 < sse_buf.size(); ++i) {
      if (sse_buf[i] == '\r' && sse_buf[i + 1] == '\n') {
        sse_buf.erase(i, 1);
      }
    }
    drain();
    return true;
  };

  auto res = cli->send(req);
  if (aborted) return false;
  if (!res) {
    if (err) *err = "arbiter notifications: connection failed";
    return false;
  }
  if (res->status != 200) {
    if (err) {
      *err = "arbiter notifications HTTP " + std::to_string(res->status);
    }
    return false;
  }
  return true;
}

bool ArbiterClient::health_reachable(std::string* detail) const {
  auto parsed = parse_base_url(base_url_);
  if (!parsed) {
    if (detail) *detail = "invalid arbiter_base_url";
    return false;
  }
  auto cli = make_client(*parsed);
  cli->set_connection_timeout(2, 0);
  cli->set_read_timeout(2, 0);
  const std::string path = parsed->path_prefix + "/v1/health";
  auto res = cli->Get(path.c_str());
  if (!res) {
    if (detail) *detail = "unreachable";
    return false;
  }
  if (detail) *detail = "HTTP " + std::to_string(res->status);
  return res->status == 200;
}

}  // namespace intercom

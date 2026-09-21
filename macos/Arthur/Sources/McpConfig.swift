import Foundation

/// One MCP server in Arbiter's `~/.arbiter/mcp_servers.json` registry.
/// Arthur connects to a remote URL itself. The registry still records that URL as
/// `npx -y mcp-remote <url> [--header "Name: value"]` because Arbiter launches stdio.
struct McpRemoteCommand: Equatable {
  var url: String
  var headers: [String: String]
  var extra: [String]
}

struct McpServer: Identifiable, Equatable {
  var name: String
  var enabled: Bool
  var command: String
  var args: [String]
  var env: [String: String]
  var initTimeoutMs: Int?
  var callTimeoutMs: Int?

  var id: String { name }

  var isHosted: Bool {
    command == "npx" && args.contains("mcp-remote")
  }

  var remoteCommand: McpRemoteCommand? {
    guard isHosted else { return nil }
    return Self.parseRemote(args)
  }

  var hostedURL: String { remoteCommand?.url ?? "" }

  var httpHeaders: [String: String] { remoteCommand?.headers ?? [:] }

  var remoteExtra: [String] { remoteCommand?.extra ?? [] }

  var transportLabel: String {
    isHosted ? "Remote" : "Local"
  }

  var endpointLine: String {
    if isHosted {
      let link = hostedURL
      return link.isEmpty ? "Remote server" : link
    }
    let line = ([command] + args).filter { !$0.isEmpty }.joined(separator: " ")
    return line.isEmpty ? "Local command" : line
  }

  var argsLine: String {
    args.joined(separator: " ")
  }

  static func stdio(name: String, command: String, args: [String] = [], env: [String: String] = [:]) -> McpServer {
    McpServer(
      name: Self.canonicalName(name),
      enabled: true,
      command: command,
      args: args,
      env: env,
      initTimeoutMs: nil,
      callTimeoutMs: nil
    )
  }

  static func hosted(
    name: String,
    url: String,
    headers: [String: String] = [:],
    extra: [String] = [],
    env: [String: String] = [:]
  ) -> McpServer {
    var args = ["-y", "mcp-remote", url.trimmingCharacters(in: .whitespacesAndNewlines)]
    for key in headers.keys.sorted() {
      args.append("--header")
      args.append("\(key): \(headers[key] ?? "")")
    }
    args.append(contentsOf: extra)
    return McpServer(
      name: Self.canonicalName(name),
      enabled: true,
      command: "npx",
      args: args,
      env: env,
      initTimeoutMs: 90_000,
      callTimeoutMs: nil
    )
  }

  static func parseRemote(_ args: [String]) -> McpRemoteCommand? {
    guard let idx = args.firstIndex(of: "mcp-remote"), idx + 1 < args.count else { return nil }
    var headers: [String: String] = [:]
    var extra: [String] = []
    var index = idx + 2
    while index < args.count {
      if args[index] == "--header", index + 1 < args.count {
        let pair = args[index + 1]
        if let colon = pair.firstIndex(of: ":") {
          let key = pair[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
          let value = pair[pair.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
          if !key.isEmpty { headers[String(key)] = String(value) }
        }
        index += 2
      } else {
        extra.append(args[index])
        index += 1
      }
    }
    return McpRemoteCommand(url: args[idx + 1], headers: headers, extra: extra)
  }

  static func playwright() -> McpServer {
    McpServer(
      name: "playwright",
      enabled: true,
      command: "npx",
      args: ["-y", "@playwright/mcp@latest", "--headless"],
      env: [:],
      initTimeoutMs: 90_000,
      callTimeoutMs: nil
    )
  }

  static func canonicalName(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  static func parseArgs(_ line: String) -> [String] {
    line.split(whereSeparator: \.isWhitespace).map(String.init)
  }
}

enum McpRegistryStore {
  static let defaultTimeoutInit = 60_000
  static let defaultTimeoutCall = 30_000

  static var defaultPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".arbiter", isDirectory: true)
      .appendingPathComponent("mcp_servers.json")
      .path
  }

  static func load(from path: String) -> [McpServer] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [] }

    var out: [McpServer] = []
    out.append(contentsOf: parseGroup(obj["servers"], enabled: true))
    out.append(contentsOf: parseGroup(obj["disabled"], enabled: false))
    out.sort { $0.name < $1.name }
    return out
  }

  static func save(_ servers: [McpServer], to path: String) throws {
    var enabled: [String: Any] = [:]
    var disabled: [String: Any] = [:]
    for server in servers.sorted(by: { $0.name < $1.name }) {
      let name = McpServer.canonicalName(server.name)
      guard !name.isEmpty, !server.command.isEmpty else { continue }
      let entry = encode(server)
      if server.enabled {
        enabled[name] = entry
      } else {
        disabled[name] = entry
      }
    }

    var root: [String: Any] = ["servers": enabled]
    if !disabled.isEmpty { root["disabled"] = disabled }
    let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])

    let url = URL(fileURLWithPath: path)
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tmp = url.appendingPathExtension("tmp")
    try data.write(to: tmp, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  }

  private static func parseGroup(_ raw: Any?, enabled: Bool) -> [McpServer] {
    guard let map = raw as? [String: Any] else { return [] }
    var out: [McpServer] = []
    for (name, value) in map {
      guard let entry = value as? [String: Any] else { continue }
      let command = entry["command"] as? String ?? ""
      guard !command.isEmpty else { continue }
      var args: [String] = []
      if let list = entry["args"] as? [String] {
        args = list
      } else if let list = entry["args"] as? [Any] {
        args = list.compactMap { $0 as? String }
      }
      var env: [String: String] = [:]
      if let obj = entry["env"] as? [String: Any] {
        for (key, val) in obj {
          if let text = val as? String { env[key] = text }
        }
      }
      let initMs = intValue(entry["init_timeout_ms"])
      let callMs = intValue(entry["call_timeout_ms"])
      out.append(
        McpServer(
          name: McpServer.canonicalName(name),
          enabled: enabled,
          command: command,
          args: args,
          env: env,
          initTimeoutMs: initMs == defaultTimeoutInit ? nil : initMs,
          callTimeoutMs: callMs == defaultTimeoutCall ? nil : callMs
        )
      )
    }
    return out
  }

  private static func encode(_ server: McpServer) -> [String: Any] {
    var entry: [String: Any] = ["command": server.command]
    if !server.args.isEmpty { entry["args"] = server.args }
    if !server.env.isEmpty { entry["env"] = server.env }
    if let ms = server.initTimeoutMs, ms != defaultTimeoutInit {
      entry["init_timeout_ms"] = ms
    }
    if let ms = server.callTimeoutMs, ms != defaultTimeoutCall {
      entry["call_timeout_ms"] = ms
    }
    return entry
  }

  private static func intValue(_ raw: Any?) -> Int? {
    if let n = raw as? Int { return n }
    if let n = raw as? NSNumber { return n.intValue }
    return nil
  }
}

import Foundation
import Network
import Security

/// Loopback MCP endpoint Arbiter reaches with `mcp-remote`. Calendar reads
/// happen in this process so the permission stays with Arthur.
final class LocalMcpServer {
  static let preferredPort: UInt16 = 8094

  private let token: String
  private let tools: LocalToolHost
  private let queue = DispatchQueue(label: "run.intercom.arthur.local-mcp")
  private var listener: NWListener?
  private(set) var port: UInt16?

  init(token: String, tools: LocalToolHost) {
    self.token = token
    self.tools = tools
  }

  func start(onReady: @escaping (UInt16) -> Void) {
    do {
      let parameters = NWParameters.tcp
      parameters.allowLocalEndpointReuse = true
      guard let nwPort = NWEndpoint.Port(rawValue: Self.preferredPort) else { return }
      let listener = try NWListener(using: parameters, on: nwPort)
      listener.stateUpdateHandler = { state in
        if case .ready = state {
          let ready = listener.port?.rawValue ?? Self.preferredPort
          self.port = ready
          onReady(ready)
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.serve(connection)
      }
      self.listener = listener
      listener.start(queue: queue)
    } catch {
      NSLog("Arthur local calendar tool did not start: \(error.localizedDescription)")
    }
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(connection, buffer: Data())
  }

  private func receive(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buf = buffer
      if let data { buf.append(data) }
      if let request = HTTPMessage.parse(&buf) {
        let response = self.reply(request)
        connection.send(content: response, completion: .contentProcessed { _ in
          connection.cancel()
        })
        return
      }
      if isComplete || error != nil {
        connection.cancel()
        return
      }
      self.receive(connection, buffer: buf)
    }
  }

  private func reply(_ request: HTTPMessage) -> Data {
    guard request.method == "POST", request.path == "/mcp" else {
      return HTTPMessage.response(status: 404, body: Data("not found".utf8))
    }
    guard authorized(request.header("authorization")) else {
      return HTTPMessage.response(status: 401, body: Data("unauthorized".utf8))
    }
    guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
      return HTTPMessage.response(status: 400, body: Data("invalid json".utf8))
    }
    guard let result = tools.respond(to: object) else {
      return HTTPMessage.response(status: 202, body: Data())
    }
    guard let body = try? JSONSerialization.data(withJSONObject: result) else {
      return HTTPMessage.response(status: 500, body: Data())
    }
    return HTTPMessage.response(status: 200, json: body)
  }

  private func authorized(_ header: String?) -> Bool {
    guard let header else { return false }
    return header.trimmingCharacters(in: .whitespacesAndNewlines) == "Bearer \(token)"
  }
}

enum LocalMcpToken {
  static func load() -> String {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Arthur", isDirectory: true)
    let url = dir.appendingPathComponent("local-mcp-token")
    if let existing = try? String(contentsOf: url, encoding: .utf8) {
      let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.count >= 32 { return trimmed }
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let token = bytes.map { String(format: "%02x", $0) }.joined()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? Data(token.utf8).write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return token
  }
}

private struct HTTPMessage {
  var method: String
  var path: String
  var headers: [String: String]
  var body: Data

  func header(_ name: String) -> String? {
    headers[name.lowercased()]
  }

  static func parse(_ buffer: inout Data) -> HTTPMessage? {
    guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(data: buffer.subdata(in: 0..<headerEnd.lowerBound), encoding: .utf8) ?? ""
    let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
    guard let request = lines.first else { return nil }
    let parts = request.split(separator: " ")
    guard parts.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[key] = String(value)
    }
    let length = Int(headers["content-length"] ?? "0") ?? 0
    let bodyStart = headerEnd.upperBound
    guard buffer.count >= bodyStart + length else { return nil }
    let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
    buffer.removeSubrange(0..<(bodyStart + length))
    let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? "/"
    return HTTPMessage(method: String(parts[0]), path: path, headers: headers, body: body)
  }

  static func response(status: Int, body: Data) -> Data {
    var data = Data("HTTP/1.1 \(status) \(reason(status))\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
    data.append(body)
    return data
  }

  static func response(status: Int, json: Data) -> Data {
    var data = Data("HTTP/1.1 \(status) \(reason(status))\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
    data.append(json)
    return data
  }

  private static func reason(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 202: return "Accepted"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 404: return "Not Found"
    default: return "Error"
    }
  }
}

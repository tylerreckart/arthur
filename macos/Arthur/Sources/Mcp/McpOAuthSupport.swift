import AppKit
import CryptoKit
import Foundation
import Network

struct McpToken: Sendable {
  var accessToken: String
  var tokenType: String
  var refreshToken: String?
  var expiresAt: Date?
  var clientID: String
  var clientSecret: String?
  var tokenEndpoint: String
  var resource: String

  var authorizationValue: String {
    let type = tokenType.trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(type.isEmpty ? "Bearer" : type) \(accessToken)"
  }
}

struct OAuthMetadata {
  var resource: String
  var authorize: URL
  var tokenEndpoint: URL
  var registration: URL?
  var scope: String
}

struct OAuthClient {
  var id: String
  var secret: String?
}

enum McpPKCE {
  static func verifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    for index in bytes.indices {
      bytes[index] = UInt8.random(in: .min ... .max)
    }
    return base64url(Data(bytes))
  }

  static func challenge(_ verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return base64url(Data(digest))
  }

  private static func base64url(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

enum McpOAuthStore {
  struct FileBody: Codable {
    var tokens: [String: Token]
  }

  struct Token: Codable {
    var accessToken: String
    var tokenType: String
    var refreshToken: String?
    var expiresAt: Date?
    var clientID: String
    var clientSecret: String?
    var tokenEndpoint: String
    var resource: String
  }

  static func load(resource: URL, from url: URL) -> Token? {
    guard let data = try? Data(contentsOf: url),
          let body = try? JSONDecoder().decode(FileBody.self, from: data)
    else { return nil }
    return body.tokens[resource.absoluteString]
  }

  static func save(_ token: McpToken, for resource: URL, to url: URL) {
    var body = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(FileBody.self, from: $0) }
      ?? FileBody(tokens: [:])
    body.tokens[resource.absoluteString] = Token(
      accessToken: token.accessToken,
      tokenType: token.tokenType,
      refreshToken: token.refreshToken,
      expiresAt: token.expiresAt,
      clientID: token.clientID,
      clientSecret: token.clientSecret,
      tokenEndpoint: token.tokenEndpoint,
      resource: token.resource
    )
    guard let data = try? JSONEncoder().encode(body) else { return }
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = url.appendingPathExtension("tmp")
    try? data.write(to: temporary, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    _ = try? FileManager.default.replaceItemAt(url, withItemAt: temporary)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

final class LoopbackCallback {
  private var listener: NWListener?
  private let lock = NSLock()
  private var waiter: CheckedContinuation<String, Error>?
  private var result: Result<String, Error>?
  private var expectedState = ""
  private var delivered = false

  func start() async throws -> UInt16 {
    let listener = try Self.makeListener()
    self.listener = listener
    return try await withCheckedThrowingContinuation { continuation in
      let box = ResumeBox(continuation)
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          box.resume(.success(listener.port?.rawValue ?? 0))
        case .failed(let error):
          box.resume(.failure(error))
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection)
      }
      listener.start(queue: .global(qos: .userInitiated))
    }
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }

  func prepare(state: String) {
    expectedState = state
  }

  func waitForCode(timeout: TimeInterval) async throws -> String {
    return try await withThrowingTaskGroup(of: String.self) { group in
      group.addTask { try await self.wait() }
      group.addTask {
        try await Task.sleep(for: .seconds(timeout))
        throw McpClientError.signIn("The sign-in window timed out. Connect again to reopen it.")
      }
      do {
        guard let code = try await group.next() else {
          throw McpClientError.signIn("The sign-in window timed out. Connect again to reopen it.")
        }
        group.cancelAll()
        return code
      } catch {
        finishWaiting(.failure(error))
        group.cancelAll()
        throw error
      }
    }
  }

  private func wait() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let result {
        self.result = nil
        lock.unlock()
        continuation.resume(with: result)
        return
      }
      waiter = continuation
      lock.unlock()
    }
  }

  func finishWaiting(_ result: Result<String, Error>) {
    lock.lock()
    guard !delivered else {
      lock.unlock()
      return
    }
    delivered = true
    let waiter = self.waiter
    self.waiter = nil
    if waiter == nil { self.result = result }
    lock.unlock()
    waiter?.resume(with: result)
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: .global(qos: .userInitiated))
    read(connection, buffer: Data())
  }

  private func read(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
      guard let self else {
        connection.cancel()
        return
      }
      var next = buffer
      if let data { next.append(data) }
      let ready = next.range(of: Data("\r\n\r\n".utf8)) != nil || isComplete || next.count > 65_536 || error != nil
      if ready {
        self.respond(connection, request: next)
        return
      }
      self.read(connection, buffer: next)
    }
  }

  private func respond(_ connection: NWConnection, request: Data) {
    let text = String(data: request, encoding: .utf8) ?? ""
    let requestLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    let parts = requestLine.split(separator: " ")
    let target = parts.count >= 2 ? String(parts[1]) : "/"
    guard target.hasPrefix("/callback") else {
      send(connection, status: "404 Not Found", html: "")
      return
    }
    let components = URLComponents(string: "http://127.0.0.1" + target)
    let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    let state = query["state"] ?? ""
    if state != expectedState {
      send(connection, status: "400 Bad Request", html: page("Arthur did not get approval. You can close this window."))
      finishWaiting(.failure(McpClientError.signIn("The sign-in response did not match this attempt.")))
      return
    }
    if let error = query["error"], !error.isEmpty {
      let denied = error == "access_denied"
      send(connection, status: "200 OK", html: page("Arthur did not get approval. You can close this window."))
      finishWaiting(.failure(McpClientError.signIn(denied ? "The sign-in was cancelled." : "The sign-in service returned \(error).")))
      return
    }
    guard let code = query["code"], !code.isEmpty else {
      send(connection, status: "400 Bad Request", html: page("Arthur did not get approval. You can close this window."))
      finishWaiting(.failure(McpClientError.signIn("The sign-in response did not include an approval code.")))
      return
    }
    send(connection, status: "200 OK", html: page("Arthur has the approval. You can close this window."))
    finishWaiting(.success(code))
  }

  private func page(_ message: String) -> String {
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>Arthur</title></head><body style=\"font-family:-apple-system;padding:2rem;\"><p>\(message)</p></body></html>"
  }

  private func send(_ connection: NWConnection, status: String, html: String) {
    let body = Data(html.utf8)
    var bytes = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
    bytes.append(body)
    connection.send(content: bytes, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private static func makeListener() throws -> NWListener {
    let params = NWParameters.tcp
    params.requiredInterfaceType = .loopback
    return try NWListener(using: params, on: .any)
  }
}

final class ResumeBox: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<UInt16, Error>?

  init(_ continuation: CheckedContinuation<UInt16, Error>) {
    self.continuation = continuation
  }

  func resume(_ result: Result<UInt16, Error>) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}

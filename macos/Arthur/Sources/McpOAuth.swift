import AppKit
import CryptoKit
import Foundation
import Network

/// MCP OAuth for a remote server (protected-resource metadata, PKCE, loopback redirect).
enum McpOAuth {
  static var storeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".arbiter", isDirectory: true)
    .appendingPathComponent("mcp_oauth.json")

  /// Opens the authorization page. Tests replace this so they can complete the redirect themselves.
  static var openURL: (URL) async -> Bool = { url in
    await MainActor.run {
      NSWorkspace.shared.open(url)
    }
  }

  static func refresh(resource: URL) async -> McpToken? {
    guard let saved = McpOAuthStore.load(resource: resource, from: storeURL),
          let refreshToken = saved.refreshToken, !refreshToken.isEmpty,
          let endpoint = URL(string: saved.tokenEndpoint)
    else { return nil }
    var fields = [
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
      "client_id": saved.clientID,
      "resource": saved.resource,
    ]
    if let secret = saved.clientSecret, !secret.isEmpty {
      fields["client_secret"] = secret
    }
    guard let token = try? await redeem(endpoint: endpoint, fields: fields, clientID: saved.clientID, clientSecret: saved.clientSecret, resource: saved.resource, previousRefresh: refreshToken) else {
      return nil
    }
    McpOAuthStore.save(token, for: resource, to: storeURL)
    return token
  }

  static func signIn(
    resource: URL,
    challenge: McpAuthChallenge,
    notify: (String) async -> Void
  ) async throws -> McpToken {
    try Task.checkCancellation()
    await notify("Looking up the sign-in page…")
    let metadata = try await discover(resource: resource, challenge: challenge)
    let callback = LoopbackCallback()
    let port = try await callback.start()
    guard port != 0 else {
      throw McpClientError.signIn("Could not open a local sign-in callback.")
    }
    defer { callback.stop() }
    let redirect = "http://127.0.0.1:\(port)/callback"
    let client = try await register(metadata: metadata, redirect: redirect)
    let verifier = McpPKCE.verifier()
    let state = McpPKCE.verifier()
    let authorize = try authorizeURL(
      metadata: metadata,
      clientID: client.id,
      redirect: redirect,
      verifier: verifier,
      state: state
    )
    callback.prepare(state: state)
    let pending = Task { try await callback.waitForCode(timeout: 180) }
    await notify("Opening your browser to approve access…")
    let opened = await openURL(authorize.url)
    guard opened else {
      callback.finishWaiting(.failure(McpClientError.signIn("Could not open the browser.")))
      throw McpClientError.signIn("Could not open the browser.")
    }
    await notify("Waiting for approval in the browser…")
    let code = try await pending.value
    var fields = [
      "grant_type": "authorization_code",
      "code": code,
      "redirect_uri": redirect,
      "client_id": client.id,
      "code_verifier": verifier,
      "resource": metadata.resource,
    ]
    if let secret = client.secret { fields["client_secret"] = secret }
    let token = try await redeem(
      endpoint: metadata.tokenEndpoint,
      fields: fields,
      clientID: client.id,
      clientSecret: client.secret,
      resource: metadata.resource,
      previousRefresh: nil
    )
    McpOAuthStore.save(token, for: resource, to: storeURL)
    return token
  }

  private static func discover(resource: URL, challenge: McpAuthChallenge) async throws -> OAuthMetadata {
    var document: [String: Any]?
    for url in protectedResourceURLs(resource: resource, challenge: challenge) {
      if let json = try? await getJSON(url), json["authorization_servers"] != nil || json["resource"] != nil {
        document = json
        break
      }
    }
    guard let document else {
      throw McpClientError.signIn("The server asked for authorization, but it did not publish a sign-in page.")
    }
    let canonical = (document["resource"] as? String).flatMap(URL.init(string:)) ?? resource
    let issuers = stringList(document["authorization_servers"]).compactMap(normalizedHTTP)
    guard let issuer = issuers.first else {
      throw McpClientError.signIn("The server asked for authorization, but it did not name a sign-in service.")
    }
    var server: [String: Any]?
    for url in authorizationServerURLs(issuer: issuer) {
      if let json = try? await getJSON(url),
         json["authorization_endpoint"] != nil,
         json["token_endpoint"] != nil {
        server = json
        break
      }
    }
    guard let server,
          let authorize = (server["authorization_endpoint"] as? String).flatMap(normalizedHTTP),
          let token = (server["token_endpoint"] as? String).flatMap(normalizedHTTP)
    else {
      throw McpClientError.signIn("The server asked for authorization, but its sign-in service did not answer.")
    }
    let methods = stringList(server["code_challenge_methods_supported"])
    if !methods.isEmpty, !methods.contains("S256") {
      throw McpClientError.signIn("This server does not support a secure sign-in challenge.")
    }
    let registration = (server["registration_endpoint"] as? String).flatMap(normalizedHTTP)
    let headerScope = wwwParameters(challenge.wwwAuthenticate)["scope"] ?? ""
    let supported = stringList(document["scopes_supported"])
    let scope = headerScope.isEmpty ? (supported.count <= 8 ? supported.joined(separator: " ") : "") : headerScope
    return OAuthMetadata(
      resource: canonical.absoluteString,
      authorize: authorize,
      tokenEndpoint: token,
      registration: registration,
      scope: scope.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  private static func register(metadata: OAuthMetadata, redirect: String) async throws -> OAuthClient {
    guard let registration = metadata.registration else {
      throw McpClientError.signIn("This server wants a sign-in, but it does not let Arthur register for one.")
    }
    let body: [String: Any] = [
      "client_name": "Arthur",
      "redirect_uris": [redirect],
      "grant_types": ["authorization_code", "refresh_token"],
      "response_types": ["code"],
      "token_endpoint_auth_method": "none",
      "application_type": "native",
    ]
    let json = try await postJSON(registration, body: body)
    guard let id = json["client_id"] as? String, !id.isEmpty else {
      let message = (json["error_description"] as? String) ?? (json["error"] as? String)
      throw McpClientError.signIn(message ?? "The sign-in service refused to register Arthur.")
    }
    let secret = json["client_secret"] as? String
    return OAuthClient(id: id, secret: secret.flatMap { $0.isEmpty ? nil : $0 })
  }

  private static func authorizeURL(
    metadata: OAuthMetadata,
    clientID: String,
    redirect: String,
    verifier: String,
    state: String
  ) throws -> (url: URL, state: String) {
    guard var parts = URLComponents(url: metadata.authorize, resolvingAgainstBaseURL: false) else {
      throw McpClientError.signIn("The sign-in address was not usable.")
    }
    var items = parts.queryItems ?? []
    items.append(contentsOf: [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirect),
      URLQueryItem(name: "code_challenge", value: McpPKCE.challenge(verifier)),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "resource", value: metadata.resource),
    ])
    if !metadata.scope.isEmpty {
      items.append(URLQueryItem(name: "scope", value: metadata.scope))
    }
    parts.queryItems = items
    guard let url = parts.url else {
      throw McpClientError.signIn("The sign-in address was not usable.")
    }
    return (url, state)
  }

  private static func redeem(
    endpoint: URL,
    fields: [String: String],
    clientID: String,
    clientSecret: String?,
    resource: String,
    previousRefresh: String?
  ) async throws -> McpToken {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = form(fields)
    let (data, response) = try await session.data(for: request)
    let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      let message = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "The sign-in service rejected the approval."
      throw McpClientError.signIn(message)
    }
    guard let access = json["access_token"] as? String, !access.isEmpty else {
      throw McpClientError.signIn("The sign-in service did not return an access token.")
    }
    let refresh = (json["refresh_token"] as? String) ?? previousRefresh
    let expires = (json["expires_in"] as? NSNumber)?.doubleValue
    return McpToken(
      accessToken: access,
      tokenType: (json["token_type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Bearer",
      refreshToken: refresh.flatMap { $0.isEmpty ? nil : $0 },
      expiresAt: expires.map { Date().addingTimeInterval($0) },
      clientID: clientID,
      clientSecret: clientSecret,
      tokenEndpoint: endpoint.absoluteString,
      resource: resource
    )
  }

  static func wwwParameters(_ header: String) -> [String: String] {
    var rest = Substring(header)
    if let space = rest.firstIndex(where: \.isWhitespace) {
      let scheme = rest[..<space].lowercased()
      if scheme == "bearer" {
        rest = rest[rest.index(after: space)...].drop(while: \.isWhitespace)
      }
    }
    var params: [String: String] = [:]
    while !rest.isEmpty {
      guard let eq = rest.firstIndex(of: "=") else { break }
      let key = rest[..<eq].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      rest = rest[rest.index(after: eq)...]
      let value: String
      if rest.first == "\"" {
        rest = rest.dropFirst()
        var built = ""
        while let character = rest.first {
          rest = rest.dropFirst()
          if character == "\\", let next = rest.first {
            built.append(next)
            rest = rest.dropFirst()
            continue
          }
          if character == "\"" { break }
          built.append(character)
        }
        value = built
      } else {
        let end = rest.firstIndex(of: ",") ?? rest.endIndex
        value = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        rest = rest[end...]
      }
      if !key.isEmpty { params[key] = value }
      if rest.first == "," { rest = rest.dropFirst() }
      rest = rest.drop(while: \.isWhitespace)
    }
    return params
  }

  private static func protectedResourceURLs(resource: URL, challenge: McpAuthChallenge) -> [URL] {
    var urls: [URL] = []
    let metadata = wwwParameters(challenge.wwwAuthenticate)["resource_metadata"] ?? ""
    if let url = URL(string: metadata, relativeTo: resource)?.absoluteURL, isHTTP(url) {
      urls.append(url)
    }
    if let inserted = insertWellKnown(resource, name: "oauth-protected-resource") {
      urls.append(inserted)
    }
    if let origin = originURL(resource)?.appendingPathComponent(".well-known/oauth-protected-resource") {
      urls.append(origin)
    }
    return unique(urls)
  }

  private static func authorizationServerURLs(issuer: URL) -> [URL] {
    guard let origin = originURL(issuer) else { return [] }
    let path = issuer.path == "/" ? "" : issuer.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let originText = origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let raw: [String]
    if path.isEmpty {
      raw = [
        "\(originText)/.well-known/oauth-authorization-server",
        "\(originText)/.well-known/openid-configuration",
      ]
    } else {
      raw = [
        "\(originText)/.well-known/oauth-authorization-server/\(path)",
        "\(originText)/\(path)/.well-known/oauth-authorization-server",
        "\(originText)/\(path)/.well-known/openid-configuration",
        "\(originText)/.well-known/openid-configuration/\(path)",
      ]
    }
    return raw.compactMap(normalizedHTTP)
  }

  private static func insertWellKnown(_ url: URL, name: String) -> URL? {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let path = parts.path == "/" ? "" : parts.path
    parts.path = "/.well-known/\(name)" + path
    parts.query = nil
    parts.fragment = nil
    return parts.url
  }

  private static func originURL(_ url: URL) -> URL? {
    guard let scheme = url.scheme, let host = url.host else { return nil }
    var text = "\(scheme)://\(host)"
    if let port = url.port { text += ":\(port)" }
    return URL(string: text)
  }

  private static func normalizedHTTP(_ string: String) -> URL? {
    guard var parts = URLComponents(string: string), isHTTP(parts) else { return nil }
    if parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
    parts.query = nil
    parts.fragment = nil
    return parts.url
  }

  private static func isHTTP(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
  }

  private static func isHTTP(_ parts: URLComponents) -> Bool {
    guard let scheme = parts.scheme?.lowercased(), parts.host != nil else { return false }
    return scheme == "http" || scheme == "https"
  }

  private static func stringList(_ value: Any?) -> [String] {
    if let list = value as? [String] { return list }
    if let list = value as? [Any] { return list.compactMap { $0 as? String } }
    return []
  }

  private static func unique(_ urls: [URL]) -> [URL] {
    var seen: [String] = []
    return urls.filter { url in
      let key = url.absoluteString
      if seen.contains(key) { return false }
      seen.append(key)
      return true
    }
  }

  private static func getJSON(_ url: URL) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return json
  }

  private static func postJSON(_ url: URL, body: [String: Any]) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await session.data(for: request)
    let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      return json
    }
    return json
  }

  private static func form(_ fields: [String: String]) -> Data {
    fields
      .sorted { $0.key < $1.key }
      .map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }
      .joined(separator: "&")
      .data(using: .utf8) ?? Data()
  }

  private static func urlEncode(_ text: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
  }

  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 30
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieAcceptPolicy = .never
    return URLSession(configuration: config)
  }()
}

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

private struct OAuthMetadata {
  var resource: String
  var authorize: URL
  var tokenEndpoint: URL
  var registration: URL?
  var scope: String
}

private struct OAuthClient {
  var id: String
  var secret: String?
}

private enum McpPKCE {
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

private enum McpOAuthStore {
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

private final class LoopbackCallback {
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

private final class ResumeBox: @unchecked Sendable {
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

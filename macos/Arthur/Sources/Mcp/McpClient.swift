import Darwin
import Foundation

enum McpClient {
  /// One `tools/call` against an HTTP MCP server. Used for Arthur's loopback calendar tool.
  static func callTool(
    urlString: String,
    name: String,
    arguments: [String: Any] = [:],
    headers: [String: String] = [:]
  ) async throws -> String {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host != nil
    else { throw McpClientError.invalidURL }
    let http = HttpMcpTransport(endpoint: url, headers: headers)
    _ = try await initialize(http)
    try await http.notify(method: "notifications/initialized", params: [:])
    let result = try await http.request(
      method: "tools/call",
      params: ["name": name, "arguments": arguments]
    )
    await http.close()
    return McpFraming.textContent(from: result)
  }

  static func probeRemote(
    urlString: String,
    headers: [String: String],
    notice: ((McpConnectNotice) -> Void)? = nil
  ) async throws -> McpProbe {
    let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host, !host.isEmpty
    else { throw McpClientError.invalidURL }

    do {
      return try await openSession(url: url, headers: headers)
    } catch let error as McpClientError where error.needsBrowserSignIn {
      guard case .unauthorized(let challenge) = error else { throw error }
      if let token = await McpOAuth.refresh(resource: url) {
        do {
          return try await openSession(url: url, headers: headers.replacingAuthorization(token.authorizationValue))
        } catch let retry as McpClientError where retry.needsBrowserSignIn {
          // The saved grant was rejected. Fall through and open the browser.
        }
      }
      let token = try await McpOAuth.signIn(resource: url, challenge: challenge) { message in
        await MainActor.run { notice?(.status(message)) }
      }
      let value = token.authorizationValue
      await MainActor.run { notice?(.authorization(value)) }
      do {
        return try await openSession(url: url, headers: headers.replacingAuthorization(value))
      } catch let retry as McpClientError where retry.needsBrowserSignIn {
        throw McpClientError.signIn("Signed in, but the server still refused the connection.")
      }
    }
  }

  private static func openSession(url: URL, headers: [String: String]) async throws -> McpProbe {
    let http = HttpMcpTransport(endpoint: url, headers: headers)
    do {
      let probe = try await handshake(http)
      await http.close()
      return probe
    } catch {
      await http.close()
      guard let mcp = error as? McpClientError, mcp.shouldTryLegacy else { throw error }
      let legacy = SseMcpTransport(endpoint: url, headers: headers)
      do {
        let probe = try await handshake(legacy)
        await legacy.close()
        return probe
      } catch let legacyError {
        await legacy.close()
        if case .http(let code, _) = mcp, code == 404 || code == 405 {
          throw legacyError
        }
        throw error
      }
    }
  }

  static func probeLocal(command: String, args: [String], env: [String: String]) async throws -> McpProbe {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw McpClientError.failedToStart("Enter a command to launch.")
    }
    let stdio = StdioMcpTransport(command: trimmed, args: args, env: env)
    do {
      let probe = try await handshake(stdio)
      await stdio.close()
      return probe
    } catch {
      await stdio.close()
      throw error
    }
  }
}

import Foundation

/// JSON-RPC surface for Arthur's on-Mac tools. Read-only in this phase.
struct LocalToolHost {
  var calendarText: (String) -> String

  /// Nil when the body is a notification and the HTTP server should answer 202.
  func respond(to body: [String: Any]) -> [String: Any]? {
    let method = body["method"] as? String ?? ""
    if method.hasPrefix("notifications/") || body["id"] == nil {
      return nil
    }
    let id = body["id"] ?? NSNull()
    let params = body["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
      let requested = params["protocolVersion"] as? String ?? ""
      let version = requested.isEmpty ? "2025-06-18" : requested
      return rpc(id, result: [
        "protocolVersion": version,
        "capabilities": ["tools": ["listChanged": false]],
        "serverInfo": ["name": "arthur", "version": "1.0"],
      ])
    case "tools/list":
      return rpc(id, result: ["tools": [Self.calendarTool]])
    case "tools/call":
      return rpc(id, result: call(params))
    case "ping":
      return rpc(id, result: [:])
    default:
      return rpcError(id, code: -32601, message: "Unknown method.")
    }
  }

  private func call(_ params: [String: Any]) -> [String: Any] {
    let name = params["name"] as? String ?? ""
    guard name == "calendar.read" else {
      return [
        "content": [["type": "text", "text": "Unknown tool."]],
        "isError": true,
      ]
    }
    let arguments = params["arguments"] as? [String: Any] ?? [:]
    let day = (arguments["day"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let text = calendarText(day)
    return [
      "content": [["type": "text", "text": text]],
      "isError": false,
    ]
  }

  private func rpc(_ id: Any, result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "result": result]
  }

  private func rpcError(_ id: Any, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
  }

  private static let calendarTool: [String: Any] = [
    "name": "calendar.read",
    "description": "Read today's or tomorrow's calendar on this Mac. day is today or tomorrow. Returns unavailable when the user has not allowed it.",
    "inputSchema": [
      "type": "object",
      "properties": [
        "day": [
          "type": "string",
          "description": "today or tomorrow. Omit for both.",
        ],
      ],
    ],
  ]
}

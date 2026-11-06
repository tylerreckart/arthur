import Foundation

/// JSON-RPC surface for Arthur's on-Mac tools. Writes return a pending
/// approval instead of changing anything.
struct LocalToolHost {
  var act: (String, [String: Any]) -> String = { _, _ in
    "That action is not available."
  }
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
      return rpc(id, result: ["tools": Self.tools])
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
    let arguments = params["arguments"] as? [String: Any] ?? [:]
    switch name {
    case "calendar.read":
      let day = (arguments["day"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return [
        "content": [["type": "text", "text": calendarText(day)]],
        "isError": false,
      ]
    case "calendar.move", "calendar.create", "reminders.create", "reminders.complete":
      let text = act(name, arguments)
      return [
        "content": [["type": "text", "text": text]],
        "isError": false,
      ]
    default:
      return [
        "content": [["type": "text", "text": "Unknown tool."]],
        "isError": true,
      ]
    }
  }

  private func rpc(_ id: Any, result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "result": result]
  }

  private func rpcError(_ id: Any, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
  }

  private static let tools: [[String: Any]] = [
    [
      "name": "calendar.read",
      "description": "Read today's or tomorrow's calendar on this Mac. day is today or tomorrow. Returns unavailable when the user has not allowed it.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "day": ["type": "string", "description": "today or tomorrow. Omit for both."],
        ],
      ],
    ],
    [
      "name": "calendar.move",
      "description": "Propose moving one event. Does not move it. Pass title and/or from, plus to as 24-hour HH:MM. Set confirmed true only when the user already said just do it. Tell them nothing has changed until they approve.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "title": ["type": "string"],
          "from": ["type": "string", "description": "Current start, 24-hour HH:MM."],
          "to": ["type": "string", "description": "New start, 24-hour HH:MM."],
          "day": ["type": "string", "description": "today or tomorrow."],
          "confirmed": ["type": "boolean"],
        ],
        "required": ["to"],
      ],
    ],
    [
      "name": "calendar.create",
      "description": "Propose a new event. Does not create it until they approve. start is 24-hour HH:MM. Set confirmed true only when they already said just do it.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "title": ["type": "string"],
          "start": ["type": "string"],
          "end": ["type": "string"],
          "day": ["type": "string"],
          "confirmed": ["type": "boolean"],
        ],
        "required": ["title", "start"],
      ],
    ],
    [
      "name": "reminders.create",
      "description": "Propose a reminder. Does not create it until they approve. due is optional 24-hour HH:MM.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "title": ["type": "string"],
          "due": ["type": "string"],
          "day": ["type": "string"],
          "confirmed": ["type": "boolean"],
        ],
        "required": ["title"],
      ],
    ],
    [
      "name": "reminders.complete",
      "description": "Propose completing a reminder. Does not complete it until they approve.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "title": ["type": "string"],
          "confirmed": ["type": "boolean"],
        ],
        "required": ["title"],
      ],
    ],
  ]
}

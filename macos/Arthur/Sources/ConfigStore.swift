import Foundation
import SQLite3

struct DeviceSession: Identifiable, Hashable {
  var id: String { deviceId }
  let deviceId: String
  let conversationId: Int64
  let lastTurnId: String
}

struct ClientConfig: Equatable {
  var configPath: String
  var host: String
  var httpPort: Int
  var wsPort: Int
  var deviceToken: String
  var deviceId: String
  var sessionDb: String
  var sampleRate: Int
}

enum ConfigStore {
  private static let configPathKey = "arthur.configPath"
  private static let deviceIdKey = "arthur.deviceId"
  private static let hostKey = "arthur.host"
  private static let soundOnKey = "arthur.soundOn"
  private static let pttKeyCodeKey = "arthur.pttKeyCode"
  private static let pttModifiersKey = "arthur.pttModifierFlags"

  static func load() -> ClientConfig {
    let path = resolvedConfigPath()
    let json = readJSON(path) ?? [:]
    let token = json["device_token"] as? String ?? ""
    let httpPort = intValue(json["listen_port"], 8090)
    let wsPort = intValue(json["ws_listen_port"], 8093)
    let sampleRate = intValue(json["sample_rate"], 24000)
    let sessionDb = expandHome(json["session_db"] as? String ?? "~/.intercom/sessions.db")
    let sessions = loadSessions(dbPath: sessionDb)
    let storedId = UserDefaults.standard.string(forKey: deviceIdKey) ?? ""
    let deviceId = preferredDeviceId(stored: storedId, sessions: sessions)
    let host = UserDefaults.standard.string(forKey: hostKey) ?? "127.0.0.1"
    return ClientConfig(
      configPath: path,
      host: host,
      httpPort: httpPort,
      wsPort: wsPort,
      deviceToken: token,
      deviceId: deviceId,
      sessionDb: sessionDb,
      sampleRate: sampleRate
    )
  }

  static func saveDeviceId(_ id: String) {
    UserDefaults.standard.set(id, forKey: deviceIdKey)
  }

  static func saveHost(_ host: String) {
    UserDefaults.standard.set(host, forKey: hostKey)
  }

  static func saveConfigPath(_ path: String) {
    UserDefaults.standard.set(path, forKey: configPathKey)
  }

  static func loadSoundOn() -> Bool {
    if UserDefaults.standard.object(forKey: soundOnKey) == nil { return true }
    return UserDefaults.standard.bool(forKey: soundOnKey)
  }

  static func saveSoundOn(_ on: Bool) {
    UserDefaults.standard.set(on, forKey: soundOnKey)
  }

  static func loadDraft() -> String {
    guard let data = try? Data(contentsOf: draftURL()),
          let text = String(data: data, encoding: .utf8)
    else { return "" }
    return text
  }

  static func saveDraft(_ text: String) {
    let url = draftURL()
    let dir = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if text.isEmpty {
      try? FileManager.default.removeItem(at: url)
      return
    }
    try? text.data(using: .utf8)?.write(to: url, options: .atomic)
  }

  static func loadPTTHotkey() -> (keyCode: UInt16, modifiers: UInt)? {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: pttKeyCodeKey) != nil else { return nil }
    let code = UInt16(clamping: defaults.integer(forKey: pttKeyCodeKey))
    let modifiers = UInt(bitPattern: defaults.integer(forKey: pttModifiersKey))
    return (code, modifiers)
  }

  static func savePTTHotkey(keyCode: UInt16, modifiers: UInt) {
    UserDefaults.standard.set(Int(keyCode), forKey: pttKeyCodeKey)
    UserDefaults.standard.set(Int(modifiers), forKey: pttModifiersKey)
  }

  static func loadTranscript(deviceId: String) -> [DiscussionLine] {
    guard !deviceId.isEmpty,
          let data = try? Data(contentsOf: transcriptURL()),
          let all = try? JSONDecoder().decode([String: [DiscussionLine]].self, from: data)
    else { return [] }
    return all[deviceId] ?? []
  }

  static func saveTranscript(_ lines: [DiscussionLine], deviceId: String) {
    guard !deviceId.isEmpty else { return }
    var all: [String: [DiscussionLine]] = [:]
    if let data = try? Data(contentsOf: transcriptURL()),
       let decoded = try? JSONDecoder().decode([String: [DiscussionLine]].self, from: data) {
      all = decoded
    }
    all[deviceId] = lines
    let dir = transcriptURL().deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(all) {
      try? data.write(to: transcriptURL(), options: .atomic)
    }
  }

  static func loadSessions(dbPath: String) -> [DeviceSession] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
      return []
    }
    defer { sqlite3_close(db) }
    let sql = "SELECT device_id, conversation_id, last_turn_id FROM device_sessions ORDER BY updated_at DESC"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    var out: [DeviceSession] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let idPtr = sqlite3_column_text(stmt, 0) else { continue }
      let id = String(cString: idPtr)
      let conv = sqlite3_column_int64(stmt, 1)
      let turn = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
      out.append(DeviceSession(deviceId: id, conversationId: conv, lastTurnId: turn))
    }
    return out
  }

  private static func preferredDeviceId(stored: String, sessions: [DeviceSession]) -> String {
    if !stored.isEmpty { return stored }
    if let nano = sessions.first(where: { $0.deviceId.hasPrefix("nano-") }) {
      return nano.deviceId
    }
    return sessions.first?.deviceId ?? "mac-arthur"
  }

  private static func resolvedConfigPath() -> String {
    if let saved = UserDefaults.standard.string(forKey: configPathKey), FileManager.default.isReadableFile(atPath: saved) {
      return saved
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
      "\(home)/dev/intercom/intercom.json",
      FileManager.default.currentDirectoryPath + "/intercom.json",
      Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("intercom.json").path,
    ]
    return candidates.first { FileManager.default.isReadableFile(atPath: $0) } ?? candidates[0]
  }

  private static func readJSON(_ path: String) -> [String: Any]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let json = obj as? [String: Any]
    else { return nil }
    return json
  }

  private static func intValue(_ raw: Any?, _ fallback: Int) -> Int {
    if let n = raw as? Int { return n }
    if let n = raw as? NSNumber { return n.intValue }
    return fallback
  }

  static func expandHome(_ path: String) -> String {
    if path.hasPrefix("~/") {
      return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
    }
    return path
  }

  private static func supportDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Arthur", isDirectory: true)
  }

  private static func transcriptURL() -> URL {
    supportDirectory().appendingPathComponent("transcripts.json")
  }

  private static func draftURL() -> URL {
    supportDirectory().appendingPathComponent("draft.txt")
  }
}

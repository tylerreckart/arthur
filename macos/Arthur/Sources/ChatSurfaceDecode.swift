import Foundation

/// Wire-decode helpers kept next to the model so the C++ surface fixture
/// and the desk decoder stay aligned. Call `ChatSurface.decodeEvent`.
enum ChatSurfaceDecode {
  /// Parse a `{type:surface}` JSON string. Unknown kinds become generic.
  static func event(from jsonText: String) -> (turnId: String, surface: ChatSurface)? {
    guard let data = jsonText.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let json = obj as? [String: Any]
    else { return nil }
    return ChatSurface.decodeEvent(json)
  }
}

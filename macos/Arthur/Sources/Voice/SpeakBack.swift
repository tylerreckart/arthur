import AppKit
import Foundation
import UserNotifications

struct SpeakBackNotice: Equatable, Identifiable {
  let id: UUID
  var kind: String
  var runId: String
  var spokenText: String
  var muted: Bool
  var live: Bool

  var title: String {
    kind == "schedule" || kind.isEmpty ? "Reminder" : "Arthur"
  }

  var message: String {
    let trimmed = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    if muted { return "Arthur spoke a reminder (muted)" }
    return live ? "Arthur is speaking a reminder." : "Arthur spoke a reminder."
  }
}

enum SpeakBackNotifier {
  static func announce(_ notice: SpeakBackNotice) {
    guard !NSApp.isActive else { return }
    NSApp.dockTile.badgeLabel = "1"
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      switch settings.authorizationStatus {
      case .authorized, .provisional:
        post(notice)
      case .notDetermined:
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
          if granted { post(notice) }
        }
      default:
        break
      }
    }
  }

  static func clearBadge() {
    NSApp.dockTile.badgeLabel = nil
    UNUserNotificationCenter.current().setBadgeCount(0)
  }

  private static func post(_ notice: SpeakBackNotice) {
    let content = UNMutableNotificationContent()
    content.title = notice.title
    content.body = notice.message
    content.threadIdentifier = "arthur.speakback"
    // Arthur is already speaking when sound is on; ding only if the desk is muted.
    content.sound = notice.muted ? .default : nil
    let id = notice.runId.isEmpty
      ? "arthur.speakback.\(notice.id.uuidString)"
      : "arthur.speakback.\(notice.runId)"
    let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
  }
}

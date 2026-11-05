import SwiftUI

struct DeskConversation: Identifiable, Equatable, Codable {
  var id: UUID
  var title: String
  var updatedAt: Date
  var serverConversationId: Int64
  /// True until Intercom acknowledges a brand-new server conversation.
  var needsFreshServer: Bool = false
  var lines: [DiscussionLine]

  static func title(for lines: [DiscussionLine]) -> String {
    let raw = lines.first(where: \.fromYou)?.text ?? ""
    let flat = raw
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if flat.isEmpty { return "New conversation" }
    if flat.count <= 42 { return flat }
    let end = flat.index(flat.startIndex, offsetBy: 42)
    return flat[..<end].trimmingCharacters(in: .whitespaces) + "…"
  }

  static func empty(serverConversationId: Int64 = 0, needsFreshServer: Bool = false) -> DeskConversation {
    DeskConversation(
      id: UUID(),
      title: "New conversation",
      updatedAt: Date(),
      serverConversationId: serverConversationId,
      needsFreshServer: needsFreshServer,
      lines: []
    )
  }
}

struct ConversationLibrary: Equatable, Codable {
  var activeId: UUID
  var conversations: [DeskConversation]

  static func imported(lines: [DiscussionLine]) -> ConversationLibrary {
    var item = DeskConversation.empty()
    item.lines = lines
    item.title = DeskConversation.title(for: lines)
    return ConversationLibrary(activeId: item.id, conversations: [item])
  }
}

struct ConversationSidebar: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    List(selection: selection) {
      ForEach(model.listedConversations) { item in
        VStack(alignment: .leading, spacing: 3) {
          Text(item.title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(item.id == model.activeConversationId ? 1 : 0.88))
            .lineLimit(2)
          Text(stamp(item.updatedAt))
            .font(.system(size: 11))
            .foregroundStyle(ArthurTheme.whisper)
        }
        .padding(.vertical, 4)
        .tag(item.id)
        .accessibilityLabel("\(item.title), \(stamp(item.updatedAt))")
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .navigationTitle("Conversations")
    .toolbarTitleDisplayMode(.inline)
    .toolbarBackground(Color.black, for: .windowToolbar)
    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    .navigationSplitViewColumnWidth(min: 196, ideal: 232, max: 280)
    .background(Color.black)
  }

  private var selection: Binding<UUID?> {
    Binding(
      get: { model.activeConversationId },
      set: { id in
        guard let id else { return }
        model.openConversation(id)
      }
    )
  }

  private func stamp(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(date: .abbreviated, time: .omitted)
  }
}

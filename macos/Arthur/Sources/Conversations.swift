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
    VStack(spacing: 0) {
      TextField("Search", text: $model.historyQuery)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      if !model.sidebarNotice.isEmpty {
        Text(model.sidebarNotice)
          .font(.caption).foregroundStyle(ArthurTheme.mute)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
      }
      searchList
    }
    .background(Color.black)
    .navigationTitle("Conversations")
    .toolbarTitleDisplayMode(.inline)
    .toolbarBackground(Color.black, for: .windowToolbar)
    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    .navigationSplitViewColumnWidth(min: 196, ideal: 232, max: 280)
  }

  @ViewBuilder
  private var searchList: some View {
    if model.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
      if model.historyHits.isEmpty {
        Text("Nothing matches \u{201C}\(model.historyQuery)\u{201D}")
          .font(.callout).foregroundStyle(ArthurTheme.mute)
          .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        Spacer()
      } else {
      List {
        ForEach(model.historyHits) { hit in
          Button {
            model.openHistory(hit)
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text(hit.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
              Text(hit.snippet)
                .font(.system(size: 11))
                .foregroundStyle(ArthurTheme.whisper)
                .lineLimit(2)
            }
            .padding(.vertical, 4)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(hit.title), \(hit.snippet)")
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      }
    } else {
      conversationList
    }
  }

  private var conversationList: some View {
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

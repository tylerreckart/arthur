import SwiftUI

struct McpSettingsSection: View {
  @Environment(AppModel.self) private var model
  @State private var editor: McpDraft?
  @State private var confirmRemove: String?

  var body: some View {
    Section {
      if model.mcpServers.isEmpty {
        Text("No MCP servers in Arbiter’s registry yet.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.mcpServers) { server in
          McpServerRow(server: server) {
            editor = McpDraft(server: server)
          } onRemove: {
            confirmRemove = server.name
          }
        }
      }

      Button("Add MCP…") {
        editor = McpDraft()
      }
      Button("Add Playwright") {
        model.upsertMcp(McpServer.playwright())
      }
      .disabled(model.mcpServers.contains { $0.name == "playwright" })
    } header: {
      Text("MCP servers")
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text(model.mcpRegistryPath)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Text(footerCopy)
      }
    }
    .sheet(item: $editor) { draft in
      McpEditorSheet(draft: draft)
        .environment(model)
    }
    .confirmationDialog(
      "Remove \(confirmRemove ?? "this server")?",
      isPresented: Binding(
        get: { confirmRemove != nil },
        set: { if !$0 { confirmRemove = nil } }
      )
    ) {
      Button("Remove", role: .destructive) {
        if let name = confirmRemove { model.removeMcp(name) }
        confirmRemove = nil
      }
    }
  }

  private var footerCopy: String {
    if model.arbiterReachable {
      return "Enabled servers are written to Arbiter’s registry. The next voice turn loads them through /mcp. Hosted URLs use npx mcp-remote — Arbiter has no native HTTP MCP client."
    }
    return "Saved locally. Intercom cannot reach Arbiter right now, so status is configured/enabled only — restart or reconnect Arbiter for the next turn to pick this up."
  }
}

private struct McpServerRow: View {
  @Environment(AppModel.self) private var model
  let server: McpServer
  var onEdit: () -> Void
  var onRemove: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(server.name)
          .font(.body)
        Text("\(server.transportLabel) · \(statusLabel)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Toggle("Enabled", isOn: Binding(
        get: { server.enabled },
        set: { model.setMcpEnabled(server.name, $0) }
      ))
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
      Menu {
        Button("Edit…", action: onEdit)
        Button("Remove", role: .destructive, action: onRemove)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(server.name), \(server.transportLabel), \(statusLabel)")
  }

  private var statusLabel: String {
    if !server.enabled { return "Disabled" }
    if model.arbiterReachable { return "Enabled" }
    return "Enabled · Arbiter unreachable"
  }
}

private struct McpDraft: Identifiable {
  let id = UUID()
  var originalName = ""
  var name = ""
  var hosted = false
  var command = ""
  var argsLine = ""
  var url = ""
  var env: [McpEnvRow] = []
  var initTimeoutMs = ""
  var callTimeoutMs = ""

  init() {}

  init(server: McpServer) {
    originalName = server.name
    name = server.name
    hosted = server.isHosted
    command = server.isHosted ? "npx" : server.command
    argsLine = server.isHosted ? "" : server.argsLine
    url = server.hostedURL
    env = server.env.keys.sorted().map { McpEnvRow(key: $0, value: server.env[$0] ?? "") }
    if let ms = server.initTimeoutMs { initTimeoutMs = String(ms) }
    if let ms = server.callTimeoutMs { callTimeoutMs = String(ms) }
  }

  func makeServer() -> McpServer? {
    let trimmed = McpServer.canonicalName(name)
    guard !trimmed.isEmpty else { return nil }
    if hosted {
      let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !link.isEmpty else { return nil }
      var server = McpServer.hosted(name: trimmed, url: link)
      server.env = envMap()
      server.initTimeoutMs = intOrNil(initTimeoutMs) ?? 90_000
      server.callTimeoutMs = intOrNil(callTimeoutMs)
      return server
    }
    let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cmd.isEmpty else { return nil }
    var server = McpServer.stdio(name: trimmed, command: cmd, args: McpServer.parseArgs(argsLine), env: envMap())
    server.initTimeoutMs = intOrNil(initTimeoutMs)
    server.callTimeoutMs = intOrNil(callTimeoutMs)
    return server
  }

  private func envMap() -> [String: String] {
    var out: [String: String] = [:]
    for row in env {
      let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else { continue }
      out[key] = row.value
    }
    return out
  }

  private func intOrNil(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return Int(trimmed)
  }
}

private struct McpEnvRow: Identifiable, Equatable {
  let id = UUID()
  var key: String
  var value: String
}

private struct McpEditorSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var draft: McpDraft

  init(draft: McpDraft) {
    _draft = State(initialValue: draft)
  }

  var body: some View {
    NavigationStack {
      Form {
        Picker("Kind", selection: $draft.hosted) {
          Text("Command").tag(false)
          Text("Hosted URL").tag(true)
        }
        .pickerStyle(.segmented)

        LabeledContent("Name") {
          TextField("playwright", text: $draft.name)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
        }

        if draft.hosted {
          LabeledContent("URL") {
            TextField("https://mcp.example.com/mcp", text: $draft.url)
              .textFieldStyle(.plain)
              .multilineTextAlignment(.trailing)
          }
        } else {
          LabeledContent("Command") {
            TextField("npx", text: $draft.command)
              .textFieldStyle(.plain)
              .multilineTextAlignment(.trailing)
          }
          LabeledContent("Arguments") {
            TextField("-y @playwright/mcp@latest --headless", text: $draft.argsLine)
              .textFieldStyle(.plain)
              .multilineTextAlignment(.trailing)
          }
        }

        Section {
          ForEach($draft.env) { $row in
            HStack {
              TextField("NAME", text: $row.key)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
              SecureField("value", text: $row.value)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
              Button {
                draft.env.removeAll { $0.id == row.id }
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
            }
          }
          Button("Add environment variable") {
            draft.env.append(McpEnvRow(key: "", value: ""))
          }
        } header: {
          Text("Environment")
        } footer: {
          Text("Values are written to Arbiter’s registry (mode 0600) and never logged. Hosted servers use npx mcp-remote.")
        }

        Section("Timeouts (optional)") {
          LabeledContent("Init ms") {
            TextField("60000", text: $draft.initTimeoutMs)
              .textFieldStyle(.plain)
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
          }
          LabeledContent("Call ms") {
            TextField("30000", text: $draft.callTimeoutMs)
              .textFieldStyle(.plain)
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(draft.originalName.isEmpty ? "Add MCP" : "Edit MCP")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { save() }
            .buttonStyle(.glassProminent)
            .disabled(draft.makeServer() == nil)
        }
      }
    }
    .frame(minWidth: 440, minHeight: 420)
    .preferredColorScheme(.dark)
    .tint(ArthurTheme.accent)
  }

  private func save() {
    guard var server = draft.makeServer() else { return }
    if let existing = model.mcpServers.first(where: { $0.name == draft.originalName }) {
      server.enabled = existing.enabled
    }
    if !draft.originalName.isEmpty, draft.originalName != server.name {
      model.removeMcp(draft.originalName)
    }
    model.upsertMcp(server)
    dismiss()
  }
}

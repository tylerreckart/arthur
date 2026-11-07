import AppKit
import SwiftUI

enum McpEditorRoute: Hashable {
  case add
  case edit(String)
}

struct McpSettingsSection: View {
  @Environment(AppModel.self) private var model
  @State private var confirmRemove: String?

  var body: some View {
    Section {
      if model.mcpServers.isEmpty {
        Text("No MCP servers yet. Connect one by its URL, or add a local command.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.mcpServers) { server in
          McpServerRow(server: server) {
            confirmRemove = server.name
          }
        }
      }

      NavigationLink(value: McpEditorRoute.add) {
        Label("Connect a server", systemImage: "link")
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
      return "Connect talks to the server from this Mac. Saving registers it with Arbiter for the next voice turn."
    }
    return "Saved on this Mac. Intercom cannot reach Arbiter right now, so a voice turn will not see these servers until Arbiter is back."
  }
}

private struct McpServerRow: View {
  @Environment(AppModel.self) private var model
  let server: McpServer
  var onRemove: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      NavigationLink(value: McpEditorRoute.edit(server.name)) {
        VStack(alignment: .leading, spacing: 2) {
          Text(server.name)
            .font(.body)
          Text(server.endpointLine)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(statusLabel)
            .font(.caption)
            .foregroundStyle(statusColor)
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Toggle("Enabled", isOn: Binding(
        get: { server.enabled },
        set: { model.setMcpEnabled(server.name, $0) }
      ))
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
      Menu {
        Button("Remove", role: .destructive, action: onRemove)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(server.name), \(server.transportLabel), \(server.endpointLine), \(statusLabel)")
  }

  private var statusLabel: String {
    if !server.enabled { return "Disabled" }
    if let probe = model.mcpProbes[server.name] { return probe.summary }
    if model.arbiterReachable { return "Enabled" }
    return "Enabled · Arbiter unreachable"
  }

  private var statusColor: Color {
    if let probe = model.mcpProbes[server.name], !probe.ok, server.enabled { return .red }
    return .secondary
  }
}

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

private struct McpDraft {
  var originalName = ""
  var name = ""
  var enabled = true
  var hosted = true
  var command = ""
  var argsLine = ""
  var url = ""
  var headers: [McpEnvRow] = []
  var remoteExtra: [String] = []
  var env: [McpEnvRow] = []
  var initTimeoutMs = ""
  var callTimeoutMs = ""

  init() {}

  init(server: McpServer) {
    originalName = server.name
    name = server.name
    enabled = server.enabled
    hosted = server.isHosted
    command = server.isHosted ? "" : server.command
    argsLine = server.isHosted ? "" : server.argsLine
    url = server.hostedURL
    headers = server.httpHeaders.keys.sorted().map { McpEnvRow(key: $0, value: server.httpHeaders[$0] ?? "") }
    remoteExtra = server.remoteExtra
    env = server.env.keys.sorted().map { McpEnvRow(key: $0, value: server.env[$0] ?? "") }
    if let ms = server.initTimeoutMs { initTimeoutMs = String(ms) }
    if let ms = server.callTimeoutMs { callTimeoutMs = String(ms) }
  }

  var remoteURL: URL? {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsed = URL(string: trimmed),
          let scheme = parsed.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = parsed.host, !host.isEmpty
    else { return nil }
    return parsed
  }

  func makeServer() -> McpServer? {
    let trimmed = McpServer.canonicalName(name)
    guard !trimmed.isEmpty else { return nil }
    if hosted {
      guard remoteURL != nil else { return nil }
      var server = McpServer.hosted(
        name: trimmed,
        url: url.trimmingCharacters(in: .whitespacesAndNewlines),
        headers: headerMap(),
        extra: remoteExtra,
        env: envMap()
      )
      server.enabled = enabled
      server.initTimeoutMs = intOrNil(initTimeoutMs) ?? 90_000
      server.callTimeoutMs = intOrNil(callTimeoutMs)
      return server
    }
    let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cmd.isEmpty else { return nil }
    var server = McpServer.stdio(
      name: trimmed,
      command: cmd,
      args: McpServer.parseArgs(argsLine),
      env: envMap()
    )
    server.enabled = enabled
    server.initTimeoutMs = intOrNil(initTimeoutMs)
    server.callTimeoutMs = intOrNil(callTimeoutMs)
    return server
  }

  func matchesSavedEndpoint(_ servers: [McpServer]) -> Bool {
    let key = McpServer.canonicalName(originalName.isEmpty ? name : originalName)
    guard let saved = servers.first(where: { $0.name == key }) else { return false }
    if hosted {
      return saved.isHosted
        && saved.hostedURL == url.trimmingCharacters(in: .whitespacesAndNewlines)
        && saved.httpHeaders == headerMap()
    }
    return !saved.isHosted
      && saved.command == command.trimmingCharacters(in: .whitespacesAndNewlines)
      && saved.argsLine == argsLine.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  mutating func setAuthorization(_ value: String) {
    if let index = headers.firstIndex(where: {
      $0.key.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Authorization") == .orderedSame
    }) {
      headers[index].key = "Authorization"
      headers[index].value = value
    } else {
      headers.insert(McpEnvRow(key: "Authorization", value: value), at: 0)
    }
  }

  func headerMap() -> [String: String] { map(headers) }

  func envMap() -> [String: String] { map(env) }

  func invalidHeaderMessage() -> String? {
    for row in headers {
      let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else { continue }
      if key.contains(":") || key.contains(where: \.isWhitespace) {
        return "Header names are a single token, such as Authorization."
      }
    }
    return nil
  }

  private func map(_ rows: [McpEnvRow]) -> [String: String] {
    var out: [String: String] = [:]
    for row in rows {
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

struct McpServerEditor: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let route: McpEditorRoute
  @State private var draft: McpDraft
  @State private var connecting = false
  @State private var connectStatus = ""
  @State private var ignoreHeaderChange = false
  @State private var probe: McpProbe?
  @State private var connectTask: Task<Void, Never>?
  @State private var confirmRemove = false
  @FocusState private var nameFocused: Bool

  init(route: McpEditorRoute, server: McpServer?) {
    self.route = route
    if let server {
      _draft = State(initialValue: McpDraft(server: server))
    } else {
      _draft = State(initialValue: McpDraft())
    }
  }

  var body: some View {
    Form {
      Picker("Connection", selection: $draft.hosted) {
        Text("Remote").tag(true)
        Text("Local").tag(false)
      }
      .pickerStyle(.segmented)

      Toggle("Enabled", isOn: $draft.enabled)

      if draft.hosted {
        remoteFields
      } else {
        localFields
      }

      nameField
      connectSection

      if draft.hosted {
        headerSection
      }

      DisclosureGroup("Advanced") {
        environmentSection
        timeoutSection
      }

      if !draft.originalName.isEmpty {
        Button("Remove server", role: .destructive) {
          confirmRemove = true
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(draft.originalName.isEmpty ? "Connect server" : draft.originalName)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .buttonStyle(.glassProminent)
          .disabled(draft.makeServer() == nil || nameConflict)
      }
    }
    .onChange(of: draft.hosted) { _, _ in
      invalidateProbe()
    }
    .onChange(of: draft.url) { _, _ in
      invalidateProbe()
      fillNameFromURL()
    }
    .onChange(of: draft.headers) { _, _ in
      if ignoreHeaderChange {
        ignoreHeaderChange = false
        return
      }
      invalidateProbe()
    }
    .onChange(of: draft.command) { _, _ in
      invalidateProbe()
    }
    .onChange(of: draft.argsLine) { _, _ in
      invalidateProbe()
    }
    .onDisappear { connectTask?.cancel() }
    .confirmationDialog(
      "Remove \(draft.originalName)?",
      isPresented: $confirmRemove,
      titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) {
        model.removeMcp(draft.originalName)
        dismiss()
      }
    }
    .frame(minWidth: 480, minHeight: 420)
  }

  @ViewBuilder
  private var remoteFields: some View {
    Section {
      McpTextField(
        text: $draft.url,
        placeholder: "https://mcp.example.com/mcp",
        autofocus: route == .add
      ) {
        DispatchQueue.main.async { beginConnect() }
      }
      .frame(maxWidth: .infinity, minHeight: 32)
      if !draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.remoteURL == nil {
        Text("Use a full http or https URL.")
          .font(.caption)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Server URL")
    } footer: {
      Text("Paste the MCP endpoint. Arthur connects to it directly. If the server asks you to sign in, your browser opens.")
    }
  }

  @ViewBuilder
  private var localFields: some View {
    Section {
      TextField("npx", text: $draft.command)
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
        .autocorrectionDisabled()
      TextField("-y @playwright/mcp@latest --headless", text: $draft.argsLine)
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
        .autocorrectionDisabled()
    } header: {
      Text("Command")
    } footer: {
      Text("Arthur starts this process and speaks MCP over its standard input and output.")
    }
  }

  private var nameField: some View {
    Section {
      TextField("sentry", text: $draft.name)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        .focused($nameFocused)
      if nameConflict {
        Text("A server named \(McpServer.canonicalName(draft.name)) is already in the list.")
          .font(.caption)
          .foregroundStyle(.red)
      }
    } header: {
      Text("Name")
    } footer: {
      Text("Arthur calls the server by this name.")
    }
  }

  @ViewBuilder
  private var connectSection: some View {
    Section {
      Button {
        beginConnect()
      } label: {
        HStack {
          Text(connecting ? "Connecting…" : "Connect")
          Spacer()
          if connecting {
            ProgressView()
              .controlSize(.small)
          }
        }
      }
      .disabled(connecting || !canConnect)

      if connecting, !connectStatus.isEmpty {
        Text(connectStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let probe {
        if probe.ok {
          LabeledContent("Server") {
            Text(serverLabel(probe))
              .foregroundStyle(.secondary)
          }
          if !probe.protocolVersion.isEmpty {
            LabeledContent("Protocol", value: probe.protocolVersion)
          }
          if probe.tools.isEmpty {
            Text("Connected. This server published no tools.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(Array(probe.tools.prefix(40))) { tool in
              VStack(alignment: .leading, spacing: 2) {
                Text(tool.name)
                  .font(.system(.body, design: .monospaced))
                  .textSelection(.enabled)
                if !tool.summary.isEmpty {
                  Text(tool.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
              }
            }
            if probe.tools.count > 40 {
              Text("\(probe.tools.count - 40) more")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        } else {
          Text(probe.message)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
    } header: {
      Text(probe?.ok == true ? "Connected" : "Connection")
    }
  }

  private var headerSection: some View {
    Section {
      ForEach($draft.headers) { $row in
        McpPairRow(name: $row.key, value: $row.value, namePrompt: "Name", valuePrompt: "Value") {
          draft.headers.removeAll { $0.id == row.id }
        }
      }
      Button("Add header") {
        draft.headers.append(McpEnvRow(key: "", value: ""))
      }
    } header: {
      Text("Headers")
    } footer: {
      Text("Sent with the connection. A sign-in fills in the Authorization header. Values are stored in Arbiter’s registry and are not logged.")
    }
  }

  @ViewBuilder
  private var environmentSection: some View {
    ForEach($draft.env) { $row in
      McpPairRow(name: $row.key, value: $row.value, namePrompt: "Name", valuePrompt: "Value") {
        draft.env.removeAll { $0.id == row.id }
      }
    }
    Button("Add environment variable") {
      draft.env.append(McpEnvRow(key: "", value: ""))
    }
  }

  private var timeoutSection: some View {
    Section {
      LabeledContent("Init ms") {
        TextField("90000", text: $draft.initTimeoutMs)
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .frame(width: 100)
      }
      LabeledContent("Call ms") {
        TextField("30000", text: $draft.callTimeoutMs)
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .frame(width: 100)
      }
    } footer: {
      Text("Used when Arbiter calls this server during a voice turn.")
    }
  }

  private var nameConflict: Bool {
    let name = McpServer.canonicalName(draft.name)
    guard !name.isEmpty else { return false }
    return model.mcpServers.contains { $0.name == name && $0.name != draft.originalName }
  }

  private var canConnect: Bool {
    if let message = draft.invalidHeaderMessage(), !message.isEmpty { return false }
    if draft.hosted { return draft.remoteURL != nil }
    return !draft.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func serverLabel(_ probe: McpProbe) -> String {
    let name = probe.serverName.isEmpty ? "MCP server" : probe.serverName
    if probe.serverVersion.isEmpty { return name }
    return "\(name) \(probe.serverVersion)"
  }

  private func fillNameFromURL() {
    guard draft.originalName.isEmpty else { return }
    guard draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    guard let host = draft.remoteURL?.host else { return }
    let labels = host.split(separator: ".").map(String.init).filter { $0 != "www" && $0 != "mcp" }
    guard let label = labels.first else { return }
    draft.name = McpServer.canonicalName(label)
  }

  private func invalidateProbe() {
    connectTask?.cancel()
    connecting = false
    connectStatus = ""
    probe = nil
  }

  private func applyAuthorization(_ value: String) {
    ignoreHeaderChange = true
    draft.setAuthorization(value)
  }

  private func beginConnect() {
    guard canConnect, !connecting else { return }
    if let message = draft.invalidHeaderMessage() {
      probe = .failure(message)
      return
    }
    connectTask?.cancel()
    connectTask = Task { await runConnect() }
  }

  private func runConnect() async {
    connecting = true
    connectStatus = ""
    probe = nil
    defer {
      connecting = false
      connectStatus = ""
    }
    do {
      let result: McpProbe
      if draft.hosted {
        result = try await McpClient.probeRemote(urlString: draft.url, headers: draft.headerMap()) { notice in
          switch notice {
          case .status(let text):
            connectStatus = text
          case .authorization(let value):
            applyAuthorization(value)
          }
        }
      } else {
        result = try await McpClient.probeLocal(
          command: draft.command,
          args: McpServer.parseArgs(draft.argsLine),
          env: draft.envMap()
        )
      }
      if Task.isCancelled { return }
      probe = result
      publish(result)
    } catch is CancellationError {
      return
    } catch {
      if Task.isCancelled { return }
      let failed = McpProbe.failure(mcpUserMessage(error))
      probe = failed
      publish(failed)
    }
  }

  private func publish(_ probe: McpProbe) {
    guard draft.matchesSavedEndpoint(model.mcpServers) else { return }
    model.rememberMcpProbe(draft.name, probe)
  }

  private func save() {
    guard var server = draft.makeServer() else { return }
    if nameConflict { return }
    if !draft.originalName.isEmpty, draft.originalName != server.name {
      model.removeMcp(draft.originalName)
    }
    server.enabled = draft.enabled
    model.upsertMcp(server)
    if let probe {
      model.rememberMcpProbe(server.name, probe)
    }
    dismiss()
  }
}

private struct McpPairRow: NSViewRepresentable {
  @Binding var name: String
  @Binding var value: String
  var namePrompt: String
  var valuePrompt: String
  var onRemove: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(name: $name, value: $value, onRemove: onRemove)
  }

  func makeNSView(context: Context) -> NSStackView {
    let nameField = Self.field(prompt: namePrompt, value: name)
    let valueField = Self.field(prompt: valuePrompt, value: value)
    nameField.delegate = context.coordinator
    valueField.delegate = context.coordinator
    nameField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    nameField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    nameField.widthAnchor.constraint(equalToConstant: 168).isActive = true

    let remove = NSButton()
    remove.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove")
    remove.imagePosition = .imageOnly
    remove.bezelStyle = .inline
    remove.isBordered = false
    remove.controlSize = .large
    remove.target = context.coordinator
    remove.action = #selector(Coordinator.remove(_:))
    remove.setContentHuggingPriority(.required, for: .horizontal)
    remove.toolTip = "Remove"

    let stack = NSStackView(views: [nameField, valueField, remove])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 8
    stack.distribution = .fill
    stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
    context.coordinator.nameField = nameField
    context.coordinator.valueField = valueField
    return stack
  }

  func updateNSView(_ stack: NSStackView, context: Context) {
    context.coordinator.onRemove = onRemove
    context.coordinator.nameChanged = { name = $0 }
    context.coordinator.valueChanged = { value = $0 }
    if let nameField = context.coordinator.nameField, nameField.currentEditor() == nil, nameField.stringValue != name {
      nameField.stringValue = name
    }
    if let valueField = context.coordinator.valueField, valueField.currentEditor() == nil, valueField.stringValue != value {
      valueField.stringValue = value
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSStackView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? 480, height: 32)
  }

  private static func field(prompt: String, value: String) -> NSTextField {
    let field = NSTextField(string: value)
    field.placeholderString = prompt
    field.isEditable = true
    field.isSelectable = true
    field.isBezeled = true
    field.bezelStyle = .roundedBezel
    field.controlSize = .large
    field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    field.lineBreakMode = .byTruncatingTail
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.cell?.sendsActionOnEndEditing = false
    field.focusRingType = .default
    return field
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var nameChanged: (String) -> Void
    var valueChanged: (String) -> Void
    var onRemove: () -> Void
    weak var nameField: NSTextField?
    weak var valueField: NSTextField?

    init(name: Binding<String>, value: Binding<String>, onRemove: @escaping () -> Void) {
      nameChanged = { name.wrappedValue = $0 }
      valueChanged = { value.wrappedValue = $0 }
      self.onRemove = onRemove
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      if field === nameField {
        nameChanged(field.stringValue)
      } else if field === valueField {
        valueChanged(field.stringValue)
      }
    }

    @objc func remove(_ sender: NSButton) {
      onRemove()
    }
  }
}

private struct McpTextField: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  var autofocus: Bool
  var onSubmit: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, onSubmit: onSubmit)
  }

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField(string: text)
    field.placeholderString = placeholder
    field.isEditable = true
    field.isSelectable = true
    field.isBezeled = true
    field.bezelStyle = .roundedBezel
    field.controlSize = .large
    field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    field.lineBreakMode = .byTruncatingHead
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.cell?.sendsActionOnEndEditing = false
    field.focusRingType = .default
    field.delegate = context.coordinator
    field.target = context.coordinator
    field.action = #selector(Coordinator.submit(_:))
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.onSubmit = onSubmit
    context.coordinator.textChanged = { text = $0 }
    if field.currentEditor() == nil, field.stringValue != text {
      field.stringValue = text
    }
    guard autofocus, !context.coordinator.didFocus else { return }
    context.coordinator.didFocus = true
    focus(field)
  }

  private func focus(_ field: NSTextField, attempt: Int = 0) {
    DispatchQueue.main.async {
      if field.window != nil {
        field.window?.makeFirstResponder(field)
      } else if attempt < 6 {
        focus(field, attempt: attempt + 1)
      }
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    @Binding var text: String
    var onSubmit: () -> Void
    var textChanged: (String) -> Void
    var didFocus = false

    init(text: Binding<String>, onSubmit: @escaping () -> Void) {
      _text = text
      self.onSubmit = onSubmit
      textChanged = { _ in }
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      textChanged(field.stringValue)
    }

    @objc func submit(_ sender: NSTextField) {
      textChanged(sender.stringValue)
      onSubmit()
    }
  }
}

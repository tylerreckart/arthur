import AppKit
import AVFoundation
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var settingsPath = NavigationPath()

  var body: some View {
    @Bindable var model = model
    NavigationStack(path: $settingsPath) {
      Form {
        Section {
          Text("Connection and device below apply when you tap Done. Switches, pickers, and voice enrollment further down apply right away.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("Connection") {
          LabeledContent("Host") {
            TextField("127.0.0.1", text: $model.config.host)
          }
          LabeledContent("HTTP") {
            TextField("8090", value: $model.config.httpPort, format: .number)
              .frame(width: 80)
          }
          LabeledContent("WebSocket") {
            TextField("8093", value: $model.config.wsPort, format: .number)
              .frame(width: 80)
          }
          LabeledContent("intercom.json") {
            Text(model.config.configPath)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .truncationMode(.middle)
          }
          LabeledContent("Token") {
            Text(model.config.deviceToken.isEmpty ? "missing" : "loaded")
              .foregroundStyle(model.config.deviceToken.isEmpty ? .red : .secondary)
          }
        }
        Section {
          Picker("Device", selection: $model.config.deviceId) {
            ForEach(model.sessions) { session in
              Text(session.deviceId).tag(session.deviceId)
            }
            if !model.sessions.contains(where: { $0.deviceId == model.config.deviceId }) {
              Text(model.config.deviceId).tag(model.config.deviceId)
            }
          }
        } header: {
          Text("Shared memory")
        } footer: {
          Text("The conversation you have open is this device’s memory. Pick the hallway device to share that memory with the wall button.")
        }

        Section {
          LabeledContent("Access") {
            Text(model.micGranted ? "Allowed" : "Off")
              .foregroundStyle(model.micGranted ? Color.secondary : Color.primary)
          }
          if !model.micGranted {
            Button(microphoneAccessTitle) {
              model.requestMicrophoneAccess()
            }
          }
          Picker("Input", selection: $model.microphoneID) {
            Text("System default").tag("")
            ForEach(model.microphones) { mic in
              Text(mic.name).tag(mic.id)
            }
            if !model.microphoneID.isEmpty,
               !model.microphones.contains(where: { $0.id == model.microphoneID }) {
              Text("Unavailable").tag(model.microphoneID)
            }
          }
        } header: {
          Text("Microphone")
        } footer: {
          Text(microphoneFooter)
        }

        Section {
          Toggle("Quiet text mode", isOn: $model.quietTextMode)
        } header: {
          Text("Typing")
        } footer: {
          Text("When on, Space will not start push-to-talk. \(model.pttHotkey.display) and the menu-bar droplet still talk.")
        }

        Section {
          Picker("Shortcut", selection: $model.pttHotkey) {
            ForEach(pttHotkeyChoices) { hotkey in
              Text(hotkey.display).tag(hotkey)
            }
          }
        } header: {
          Text("Push to talk")
        } footer: {
          Text(pttHotkeyFooter)
        }

        Section {
          if model.household.isEmpty {
            Text("No one enrolled")
              .foregroundStyle(.secondary)
          }
          ForEach(model.household) { person in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                if !person.calendar.isEmpty {
                  Text(person.calendar)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              Text(person.phrases >= 3 ? "Voice ready" : "\(person.phrases) of 3")
                .foregroundStyle(.secondary)
              Button("Remove") { model.forgetPerson(person.id) }
            }
          }
          Button("Enroll a household member…") { model.householdEnrollOpen = true }
          if !model.householdStatus.isEmpty {
            Text(model.householdStatus)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("Household")
        } footer: {
          Text("Three phrases teach a voice. He uses a name only when he is sure. He does not mix calendars or memories. Someone he does not recognize can still use the lights and the timers.")
        }

        Section {
          Picker("Calendar", selection: $model.calendarSharing) {
            ForEach(CalendarSharing.allCases, id: \.self) { choice in
              Text(choice.settingsLabel).tag(choice)
            }
          }
          Toggle("App and selection", isOn: $model.seesFront)
          if model.seesFront, !FrontDesk.trusted {
            Button("Allow Accessibility") { FrontDesk.prompt() }
          }
          Toggle("Look at the screen", isOn: $model.screenLook)
          if model.screenLook, !ScreenLook.allowed {
            Button("Allow Screen Recording") { ScreenLook.requestAccess() }
          }
          Toggle("Reminders, Finder, and Mail", isOn: $model.macTools)
          Toggle("Wake word", isOn: $model.wakeWord)
          if model.wakeWord, model.wakeMuted {
            Text("The microphone is muted.")
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("This Mac")
        } footer: {
          Text("Today and tomorrow stay on this Mac. Arthur does not read the app in front of you, your reminders, or the screen unless you turn that on. A file you drop is included with the next question. A change, a Mail draft, and opening something wait until you approve. He does not send mail. Wake word listens for “Arthur” and starts a hands-free turn. It stays off until you turn it on, and it stays quiet while the microphone is muted. Restart arbiter --api once after Arthur first writes these tools.")
        }

        McpSettingsSection()

        if !model.mcpSaveError.isEmpty {
          Section {
            Text(model.mcpSaveError)
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Settings")
      .navigationDestination(for: McpEditorRoute.self) { route in
        McpServerEditor(route: route, server: mcpServer(for: route))
      }
      .toolbar {
        if settingsPath.isEmpty {
          ToolbarItem(placement: .cancellationAction) {
            Button("Reload") { model.reloadFromDisk() }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              model.applySettings()
              dismiss()
            }
            .font(.system(size: 13, weight: .semibold))
          }
        }
      }
      .sheet(isPresented: $model.householdEnrollOpen) {
        HouseholdEnrollSheet().environment(model)
      }
      .onAppear {
        model.loadMcpRegistry()
        model.refreshMicrophones()
        model.loadHousehold()
      }
    }
    .frame(minWidth: 520, minHeight: 560)
  }

  private func mcpServer(for route: McpEditorRoute) -> McpServer? {
    guard case .edit(let name) = route else { return nil }
    return model.mcpServers.first { $0.name == name }
  }

  private var pttHotkeyChoices: [PTTHotkey] {
    var items = PTTHotkey.presets
    if !items.contains(model.pttHotkey) {
      items.insert(model.pttHotkey, at: 0)
    }
    return items
  }

  private var microphoneAccessTitle: String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .denied, .restricted:
      return "Open System Settings"
    default:
      return "Allow microphone"
    }
  }

  private var microphoneFooter: String {
    if !model.microphoneID.isEmpty,
       !model.microphones.contains(where: { $0.id == model.microphoneID }) {
      return "That microphone is unplugged. Arthur will use the system default until it comes back."
    }
    if let chosen = model.microphones.first(where: { $0.id == model.microphoneID }) {
      return "Arthur records from \(chosen.name) while you hold talk."
    }
    let system = AudioIO.captureDevice(preferredID: "")?.localizedName ?? "the Mac’s current microphone"
    return "System default is \(system). Arthur follows it until you pick an input."
  }

  private var pttHotkeyFooter: String {
    var text = "Hold \(model.pttHotkey.display) from anywhere — the Arthur window does not need to be focused."
    if model.quietTextMode {
      text += " Quiet text is on, so Space will not start talk inside the window."
    } else {
      text += " Space still works as push-to-talk inside the window when you are not typing."
    }
    text += " The default shortcut uses the system hotkey API and does not need Accessibility or Input Monitoring."
    if DeskAccessory.shared.usingInputMonitoringFallback {
      text += " Arthur could not register that system hotkey, so it is listening with a global key monitor. Grant Input Monitoring to Arthur in System Settings → Privacy & Security if the shortcut does nothing while another app is focused."
    }
    return text
  }
}


private struct HouseholdEnrollSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    @Bindable var model = model
    VStack(alignment: .leading, spacing: 16) {
      Text("Teach Arthur a voice").font(.title3.weight(.semibold))
      Text("Say each phrase when asked. Wake word pauses while you record.")
        .font(.callout).foregroundStyle(.secondary)
      // 1-2-3 progress
      HStack(spacing: 8) {
        ForEach(0..<HouseholdRoster.phrases.count, id: \.self) { i in
          VStack(spacing: 4) {
            Circle().fill(i < model.teachPhrase || !model.teaching && !model.householdStatus.isEmpty && model.householdStatus.contains("enrolled") ? Color.white : Color.white.opacity(0.18))
              .frame(width: 10, height: 10)
            Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
          }
          if i < HouseholdRoster.phrases.count - 1 { Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1) }
        }
      }
      .accessibilityLabel(model.teaching ? "Phrase \(min(model.teachPhrase + 1, HouseholdRoster.phrases.count)) of \(HouseholdRoster.phrases.count)" : "Not recording")
      if !model.teaching {
        TextField("Name", text: $model.teachName)
        TextField("Calendar title", text: $model.teachCalendar)
      }
      if model.teaching {
        Text(HouseholdRoster.phrases[min(model.teachPhrase, HouseholdRoster.phrases.count - 1)])
          .font(.callout).foregroundStyle(.primary)
      }
      if !model.householdStatus.isEmpty {
        Text(model.householdStatus).font(.callout).foregroundStyle(.secondary)
      }
      HStack {
        if model.teaching {
          Button("Cancel enrollment") { model.cancelTeach() }
        }
        Spacer()
        Button("Close") { if model.teaching { model.cancelTeach() }; dismiss() }
        if !model.teaching {
          Button(model.teaching ? "Listening…" : "Start — 3 phrases") { model.teachVoice() }
            .disabled(model.teachName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .font(.callout.weight(.semibold))
        }
      }
    }
    .padding(20).frame(width: 440)
  }
}

#if DEBUG
#Preview("Household · mid-enrollment") {
  let m = AppModel.previewCanvas(); m.teaching = true; m.teachPhrase = 1; m.teachName = "Sam"
  return HouseholdEnrollSheet().environment(m).frame(width: 480, height: 380)
}

#Preview("Settings") {
  SettingsView()
    .environment(AppModel.previewCanvas())
    .frame(width: 560, height: 680)
    .preferredColorScheme(.dark)
}
#endif

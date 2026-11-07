import SwiftUI

struct MemoryDesk: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        if !model.deskStatus.isEmpty {
          Section {
            HStack {
              Text(model.deskStatus).font(.callout).foregroundStyle(Color.secondary)
              Spacer()
              Button("Dismiss") { model.deskStatus = "" }.font(.caption.weight(.semibold))
            }
          }
        }
        if model.deskLoadState.isLoading {
          Section { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(Color.secondary) } }
        } else if let failure = model.deskLoadState.failureMessage {
          Section {
            VStack(alignment: .leading, spacing: 8) {
              Label(failure, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(ArthurTheme.error)
              Button("Retry") { model.loadDesk() }
                .accessibilityLabel("Retry loading memory")
            }
          }
        }
        Section {
          TextField("Search facts", text: $model.memoryQuery)
          if model.deskLoadState == .loaded, model.memoryFacts.isEmpty {
            Text(model.memoryQuery.isEmpty ? "No facts yet" : "Nothing matches")
              .foregroundStyle(Color.secondary)
          }
          ForEach(model.memoryFacts) { fact in
            VStack(alignment: .leading, spacing: 6) {
              Text(fact.title).font(.body.weight(.semibold))
              if !fact.content.isEmpty {
                Text(fact.content).font(.callout).foregroundStyle(Color.secondary).lineLimit(4)
              }
              HStack {
                Button("Edit") { model.beginMemoryEdit(fact) }
                Button("Remove") { model.removeMemory(fact) }
              }.buttonStyle(.borderless)
              // Edit form lives directly under the row it edits.
              if model.editingMemory, model.editingMemoryId == fact.id {
                TextField("Title", text: $model.memoryEditTitle)
                TextField("Fact", text: $model.memoryEditContent, axis: .vertical)
                HStack {
                  Button("Save") { model.saveMemoryEdit() }
                    .disabled(model.memoryEditTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                  Button("Cancel") { model.editingMemory = false }
                }.buttonStyle(.borderless)
              }
            }.padding(.vertical, 4)
          }
          if let undo = model.memoryUndo {
            Button("Undo remove \(undo.title)") { model.restoreMemory() }
          }
        } header: { Text("Memory") } footer: {
          Text("Removing a fact means Arthur stops using it. Undo puts that fact back.")
        }

        Section {
          if model.deskLoadState == .loaded, model.deskSchedules.isEmpty {
            Text("No upcoming reminders").foregroundStyle(Color.secondary)
          }
          ForEach(model.deskSchedules) { item in
            VStack(alignment: .leading, spacing: 6) {
              Text(item.message.isEmpty ? item.phrase : item.message).font(.body.weight(.semibold))
              if !item.phrase.isEmpty { Text(item.phrase).font(.caption).foregroundStyle(Color.secondary) }
              DatePicker("New time", selection: dateBinding(item.id), displayedComponents: [.date, .hourAndMinute])
                .accessibilityLabel("New time for \(item.message.isEmpty ? item.phrase : item.message)")
              Text("Arthur will hear: \(ReschedulePhrase.phrase(for: model.rescheduleDates[item.id] ?? ReschedulePhrase.defaultDate()))")
                .font(.caption).foregroundStyle(Color.secondary)
              HStack {
                Button("Reschedule") { model.reschedule(item) }
                Button("Complete") { model.finishSchedule(item.id, status: "completed") }
                Button("Cancel") { model.finishSchedule(item.id, status: "canceled") }
              }.buttonStyle(.borderless)
            }.padding(.vertical, 4)
          }
        } header: { Text("Schedules") }

        Section {
          if model.deskLoadState == .loaded, model.deskTodos.isEmpty {
            Text("Nothing open").foregroundStyle(.secondary)
          }
          ForEach(model.deskTodos) { item in
            VStack(alignment: .leading, spacing: 6) {
              Text(item.subject).font(.body.weight(.semibold))
              HStack {
                Button("Complete") { model.finishTodo(item.id, status: "completed") }
                Button("Cancel") { model.finishTodo(item.id, status: "canceled") }
              }.buttonStyle(.borderless)
            }.padding(.vertical, 4)
          }
        } header: { Text("Todos") }
      }
      .formStyle(.grouped)
      .navigationTitle("Memory")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .onAppear { model.loadDesk() }
      .onChange(of: model.memoryQuery) { _, _ in model.loadDesk() }
    }
    .frame(minWidth: 520, minHeight: 560)
  }

  private func dateBinding(_ id: Int) -> Binding<Date> {
    Binding(
      get: { model.rescheduleDates[id] ?? ReschedulePhrase.defaultDate() },
      set: { var next = model.rescheduleDates; next[id] = $0; model.rescheduleDates = next }
    )
  }
}

#if DEBUG
#Preview("Memory · loading") {
  let m = AppModel.previewCanvas(); m.deskLoadState = .loading
  return MemoryDesk().environment(m).frame(width: 560, height: 620)
}
#Preview("Memory · empty") {
  MemoryDesk().environment(AppModel.previewCanvas()).frame(width: 560, height: 620)
}
#Preview("Memory · populated") {
  let m = AppModel.previewCanvas()
  m.memoryFacts = [MemoryFact(id: 1, title: "Kitchen", content: "Stays blue.", type: "user")]
  m.deskSchedules = [DeskSchedule(id: 3, message: "Water the plants", phrase: "tomorrow at 9:00 am", status: "active")]
  m.deskTodos = [DeskTodo(id: 9, subject: "Buy milk", status: "pending")]
  return MemoryDesk().environment(m).frame(width: 560, height: 620)
}
#Preview("Memory · failed") {
  let m = AppModel.previewCanvas(); m.deskLoadState = .failed("Could not reach Arthur. Check the connection, then retry.")
  return MemoryDesk().environment(m).frame(width: 560, height: 620)
}
#endif

import SwiftUI

struct MemoryDesk: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        Section {
          TextField("Search facts", text: $model.memoryQuery)
          if model.memoryFacts.isEmpty {
            Text(model.memoryQuery.isEmpty ? "No facts yet" : "Nothing matches")
              .foregroundStyle(.secondary)
          }
          ForEach(model.memoryFacts) { fact in
            VStack(alignment: .leading, spacing: 6) {
              Text(fact.title)
                .font(.system(size: 14, weight: .semibold))
              if !fact.content.isEmpty {
                Text(fact.content)
                  .font(.system(size: 13))
                  .foregroundStyle(.secondary)
                  .lineLimit(4)
              }
              HStack {
                Button("Edit") { model.beginMemoryEdit(fact) }
                Button("Remove") { model.removeMemory(fact) }
              }
              .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
          }
          if let undo = model.memoryUndo {
            Button("Undo remove \(undo.title)") { model.restoreMemory() }
          }
          if model.editingMemory {
            TextField("Title", text: $model.memoryEditTitle)
            TextField("Fact", text: $model.memoryEditContent, axis: .vertical)
            Button("Save") { model.saveMemoryEdit() }
              .disabled(model.memoryEditTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        } header: {
          Text("Memory")
        } footer: {
          Text("Removing a fact means Arthur stops using it. Undo puts that fact back.")
        }

        Section {
          if model.deskSchedules.isEmpty {
            Text("No upcoming reminders")
              .foregroundStyle(.secondary)
          }
          ForEach(model.deskSchedules) { item in
            VStack(alignment: .leading, spacing: 6) {
              Text(item.message.isEmpty ? item.phrase : item.message)
                .font(.system(size: 14, weight: .semibold))
              if !item.phrase.isEmpty {
                Text(item.phrase)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              TextField("New time", text: phraseBinding(item.id, item.phrase))
              HStack {
                Button("Reschedule") { model.reschedule(item) }
                Button("Complete") { model.finishSchedule(item.id, status: "completed") }
                Button("Cancel") { model.finishSchedule(item.id, status: "canceled") }
              }
              .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
          }
        } header: {
          Text("Schedules")
        }

        Section {
          if model.deskTodos.isEmpty {
            Text("Nothing open")
              .foregroundStyle(.secondary)
          }
          ForEach(model.deskTodos) { item in
            VStack(alignment: .leading, spacing: 6) {
              Text(item.subject)
                .font(.system(size: 14, weight: .semibold))
              HStack {
                Button("Complete") { model.finishTodo(item.id, status: "completed") }
                Button("Cancel") { model.finishTodo(item.id, status: "canceled") }
              }
              .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
          }
        } header: {
          Text("Todos")
        }

        if !model.deskStatus.isEmpty {
          Section {
            Text(model.deskStatus)
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .background(Color.black)
      .navigationTitle("Memory")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .onAppear { model.loadDesk() }
      .onSubmit { model.loadDesk() }
      .onChange(of: model.memoryQuery) { _, _ in model.loadDesk() }
    }
    .frame(minWidth: 520, minHeight: 560)
    .preferredColorScheme(.dark)
  }

  private func phraseBinding(_ id: Int, _ fallback: String) -> Binding<String> {
    Binding(
      get: { model.reschedulePhrases[id] ?? fallback },
      set: {
        var next = model.reschedulePhrases
        next[id] = $0
        model.reschedulePhrases = next
      }
    )
  }
}

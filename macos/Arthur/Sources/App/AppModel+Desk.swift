import AppKit
import AVFoundation
import Foundation
import Intents
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppModel {
  func loadDesk() {
    deskLoadState = .loading
    let query = memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    Task {
      var anyOK = false; var anyFail = false
      let path = query.isEmpty
        ? "/v1/desk/memory/entries?limit=50"
        : "/v1/desk/memory/entries?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)&limit=50"
      if let (data, code) = await householdCall(path, method: "GET", body: nil), code == 200 {
        memoryFacts = DeskLibrary.facts(from: data); anyOK = true
      } else { anyFail = true }
      if let (data, code) = await householdCall("/v1/desk/schedules?status=active", method: "GET", body: nil),
         code == 200 {
        deskSchedules = DeskLibrary.schedules(from: data); anyOK = true
      } else { anyFail = true }
      if let (data, code) = await householdCall("/v1/desk/todos", method: "GET", body: nil), code == 200 {
        deskTodos = DeskLibrary.todos(from: data); anyOK = true
      } else { anyFail = true }
      deskLoadState = anyOK ? .loaded : .failed("Could not reach Arthur. Check the connection, then retry.")
      if anyOK && anyFail { deskStatus = "Some sections could not load." }
    }
  }

  func beginMemoryEdit(_ fact: MemoryFact) {
    editingMemory = true
    editingMemoryId = fact.id
    memoryEditTitle = fact.title
    memoryEditContent = fact.content
  }

  func saveMemoryEdit() {
    let title = memoryEditTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard editingMemoryId > 0, !title.isEmpty else { return }
    let action = SurfaceAction(
      id: "memory-\(editingMemoryId)",
      label: "Save",
      kind: "desk",
      toolCall: .object([
        "resource": .string("memory"),
        "op": .string("edit"),
        "id": .number(Double(editingMemoryId)),
        "title": .string(title),
        "content": .string(memoryEditContent),
      ])
    )
    resolveSurfaceAction(action)
  }

  func removeMemory(_ fact: MemoryFact) {
    resolveSurfaceAction(SurfaceAction(
      id: "memory-\(fact.id)",
      label: "Remove",
      kind: "desk",
      toolCall: .object([
        "resource": .string("memory"),
        "op": .string("delete"),
        "id": .number(Double(fact.id)),
      ])
    ))
  }

  func restoreMemory() {
    guard memoryUndo != nil else { return }
    resolveSurfaceAction(SurfaceAction(
      id: "memory-undo",
      label: "Undo",
      kind: "desk",
      toolCall: .object([
        "resource": .string("memory"),
        "op": .string("restore"),
      ])
    ))
  }

  func reschedule(_ item: DeskSchedule) {
    let phrase: String
    if let date = rescheduleDates[item.id] {
      phrase = ReschedulePhrase.phrase(for: date)
    } else {
      phrase = (reschedulePhrases[item.id] ?? item.phrase)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !phrase.isEmpty else { return }
    resolveSurfaceAction(SurfaceAction(
      id: "schedule-\(item.id)",
      label: "Reschedule",
      kind: "desk",
      toolCall: .object([
        "resource": .string("schedule"),
        "op": .string("reschedule"),
        "id": .number(Double(item.id)),
        "phrase": .string(phrase),
        "message": .string(item.message),
      ])
    ))
  }

  func finishSchedule(_ id: Int, status: String) {
    resolveSurfaceAction(SurfaceAction(
      id: "schedule-\(id)",
      label: status == "completed" ? "Complete" : "Cancel",
      kind: "desk",
      toolCall: .object([
        "resource": .string("schedule"),
        "op": .string(status),
        "id": .number(Double(id)),
      ])
    ))
  }

  func finishTodo(_ id: Int, status: String) {
    resolveSurfaceAction(SurfaceAction(
      id: "todo-\(id)",
      label: status == "completed" ? "Complete" : "Cancel",
      kind: "desk",
      toolCall: .object([
        "resource": .string("todo"),
        "op": .string(status),
        "id": .number(Double(id)),
      ])
    ))
  }

  func performDesk(_ action: SurfaceAction) {
    let call = action.toolCall.object
    let resource = call["resource"]?.displayString ?? ""
    let op = call["op"]?.displayString ?? ""
    let id = call["id"]?.intValue ?? 0
    Task {
      switch (resource, op) {
      case ("memory", "delete"):
        guard let fact = memoryFacts.first(where: { $0.id == id }) else { return }
        guard let (_, code) = await householdCall(
          "/v1/desk/memory/entries/\(id)", method: "DELETE", body: nil), code == 200
        else {
          deskStatus = "Could not remove that fact."
          return
        }
        memoryUndo = fact
        editingMemory = false
        deskStatus = "Removed. Arthur will not use it."
        loadDesk()
      case ("memory", "restore"):
        guard let fact = memoryUndo,
              let body = try? JSONSerialization.data(withJSONObject: DeskLibrary.restoreBody(fact)),
              let (_, code) = await householdCall("/v1/desk/memory/entries", method: "POST", body: body),
              code == 200 || code == 201
        else {
          deskStatus = "Could not put that fact back."
          return
        }
        memoryUndo = nil
        deskStatus = "Restored."
        loadDesk()
      case ("memory", "edit"):
        let body: [String: String] = [
          "title": call["title"]?.displayString ?? "",
          "content": call["content"]?.displayString ?? "",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let (_, code) = await householdCall(
                "/v1/desk/memory/entries/\(id)", method: "PATCH", body: data),
              code == 200
        else {
          deskStatus = "Could not save that fact."
          return
        }
        editingMemory = false
        deskStatus = "Saved."
        loadDesk()
      case ("schedule", "reschedule"):
        let created: [String: String] = [
          "schedule": call["phrase"]?.displayString ?? "",
          "message": call["message"]?.displayString ?? "",
          "agent": "arthur",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: created),
              let (_, code) = await householdCall("/v1/desk/schedules", method: "POST", body: data),
              code == 200 || code == 201
        else {
          deskStatus = "Could not reschedule that."
          return
        }
        let cancel = try? JSONSerialization.data(withJSONObject: ["status": "canceled"])
        _ = await householdCall("/v1/desk/schedules/\(id)", method: "PATCH", body: cancel)
        deskStatus = "Rescheduled."
        loadDesk()
      case ("schedule", "completed"), ("schedule", "canceled"):
        guard let data = try? JSONSerialization.data(withJSONObject: ["status": op]),
              let (_, code) = await householdCall(
                "/v1/desk/schedules/\(id)", method: "PATCH", body: data),
              code == 200
        else {
          deskStatus = "Could not update that reminder."
          return
        }
        deskStatus = op == "completed" ? "Completed." : "Canceled."
        loadDesk()
      case ("todo", "completed"), ("todo", "canceled"):
        guard let data = try? JSONSerialization.data(withJSONObject: ["status": op]),
              let (_, code) = await householdCall(
                "/v1/desk/todos/\(id)", method: "PATCH", body: data),
              code == 200
        else {
          deskStatus = "Could not update that todo."
          return
        }
        deskStatus = op == "completed" ? "Completed." : "Canceled."
        loadDesk()
      default:
        break
      }
    }
  }
}

import AppKit
import AVFoundation
import Foundation
import Intents
import SwiftUI
import UniformTypeIdentifiers

@MainActor
extension AppModel {
  func loadHousehold() {
    Task { await reloadHousehold() }
  }

  func cancelTeach() {
    teachCancelled = true
    teaching = false
    householdStatus = "Enrollment canceled."
    resumeWake()
  }

  func teachVoice() {
    let name = teachName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !teaching else { return }
    guard phase == .idle, !holding else {
      householdStatus = "Finish the current turn first."
      return
    }
    teachCancelled = false
    teaching = true
    teachPhrase = 0
    householdStatus = ""
    let calendar = teachCalendar
    Task { await runTeach(name: name, calendar: calendar) }
  }

  func forgetPerson(_ id: String) {
    Task {
      _ = await householdCall("/v1/household/people/\(id)", method: "DELETE", body: nil)
      await reloadHousehold()
    }
  }

  func runTeach(name: String, calendar: String) async {
    defer {
      teaching = false
      resumeWake()
    }
    let body: [String: String] = ["name": name, "calendar": calendar]
    guard let payload = try? JSONSerialization.data(withJSONObject: body),
          let (data, code) = await householdCall("/v1/household/people", method: "POST", body: payload),
          code == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = json["id"] as? String
    else {
      householdStatus = "Could not add that person."
      return
    }
    for index in 0..<HouseholdRoster.phrases.count {
      if teachCancelled { return }
      teachPhrase = index
      let pcm = await recordEnrollment()
      guard let pcm else {
        householdStatus = "The microphone was busy."
        return
      }
      let voice: [String: Any] = [
        "pcm": pcm.base64EncodedString(),
        "sample_rate": Int(AudioIO.sampleRate),
        "phrase": index,
      ]
      guard let voiceBody = try? JSONSerialization.data(withJSONObject: voice),
            let (_, voiceCode) = await householdCall(
              "/v1/household/people/\(id)/voice", method: "POST", body: voiceBody),
            voiceCode == 200
      else {
        householdStatus = "That phrase did not stick. Try again."
        return
      }
    }
    teachName = ""
    teachCalendar = ""
    householdStatus = "\(name) is enrolled."
    await reloadHousehold()
  }

  func reloadHousehold() async {
    guard let (data, code) = await householdCall("/v1/household/people", method: "GET", body: nil),
          code == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rows = json["people"] as? [[String: Any]]
    else { return }
    household = rows.compactMap { row in
      guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
      let phrases = (row["phrases"] as? NSNumber)?.intValue ?? (row["phrases"] as? Int ?? 0)
      return HouseholdRoster.Person(
        id: id,
        name: name,
        calendar: row["calendar"] as? String ?? "",
        phrases: phrases
      )
    }
  }

  func recordEnrollment() async -> Data? {
    await withCheckedContinuation { continuation in
      audio.recordClip { data in
        continuation.resume(returning: data)
      }
    }
  }

  func householdCall(_ path: String, method: String, body: Data?) async -> (Data, Int)? {
    guard let url = URL(string: "http://\(config.host):\(config.httpPort)\(path)") else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Bearer \(config.deviceToken)", forHTTPHeaderField: "Authorization")
    request.setValue(config.deviceId, forHTTPHeaderField: "X-Device-Id")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = body
    }
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse
    else { return nil }
    return (data, http.statusCode)
  }

  func resumeWake() {
    guard !previewCanvas else { return }
    guard !teaching else {
      audio.setWakeWanted(false)
      return
    }
    guard wakeWord, micGranted, !holding, !preparingTalk, phase == .idle else {
      if !holding, !wakeWord || !micGranted {
        audio.setWakeWanted(false)
      }
      if !wakeWord { wakeMuted = false }
      return
    }
    wakeMuted = AudioIO.inputHardwareMuted()
    if wakeMuted {
      audio.setWakeWanted(false)
      return
    }
    audio.setWakeWanted(true)
  }

  func noteFalseWake() {
    wakeTurn = false
    let count = ConfigStore.bumpWakeFalseAccepts()
    NSLog("arthur wake false-accept count=%d", count)
  }
}

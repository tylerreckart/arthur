import XCTest

final class ArthurPresenceTests: XCTestCase {
  func testFrontmostStaysQuietWithoutAccessibility() {
    let text = DeskPresence.frontmost(app: "Xcode", window: "Build failed", trusted: false)
    XCTAssertTrue(text.contains("Xcode"))
    XCTAssertFalse(text.contains("Build failed"))
    XCTAssertTrue(text.contains("Do not invent"))
  }

  func testFrontmostNamesTheWindowWhenTrusted() {
    let text = DeskPresence.frontmost(app: "Xcode", window: "Build failed", trusted: true)
    XCTAssertTrue(text.contains("Xcode"))
    XCTAssertTrue(text.contains("Build failed"))
  }

  func testSelectionOmitsAnEmptyRange() {
    XCTAssertNil(DeskPresence.selection("  \n"))
    let text = DeskPresence.selection("error: cannot find symbol")
    XCTAssertTrue(text?.contains("cannot find symbol") == true)
  }

  func testRemindersGroupByList() {
    let text = DeskPresence.reminders([
      ReminderLine(list: "Home", title: "Call the bank", due: "Fri 4:00 PM"),
      ReminderLine(list: "Home", title: "Bins", due: ""),
    ])
    XCTAssertTrue(text.contains("Home:"))
    XCTAssertTrue(text.contains("Call the bank"))
    XCTAssertTrue(text.contains("Bins"))
  }

  func testDroppedTextKeepsTheNameAndBody() {
    XCTAssertEqual(DeskFiles.kind(filename: "notes.md"), .text)
    XCTAssertEqual(DeskFiles.kind(filename: "shot.PNG"), .image)
    XCTAssertEqual(DeskFiles.kind(filename: "report.pdf"), .other)
    let note = DeskFiles.textNote(name: "notes.md", body: "Ship the desk.")
    XCTAssertTrue(note.hasPrefix("notes.md"))
    XCTAssertTrue(note.contains("Ship the desk."))
    XCTAssertNil(DeskFiles.utf8Text(Data([0, 1, 2])))
    XCTAssertEqual(DeskFiles.utf8Text(Data("hello".utf8)), "hello")
  }

  func testFinderQueryDropsQuotesAndShortWords() {
    XCTAssertEqual(DeskFiles.finderQuery("  "), "")
    XCTAssertEqual(DeskFiles.finderQuery("a"), "")
    let query = DeskFiles.finderQuery("build log's")
    XCTAssertFalse(query.contains("log's"))
    XCTAssertTrue(query.contains("build logs"))
    XCTAssertTrue(query.hasPrefix("kMDItemDisplayName"))
  }

  func testOpenTargetsStayNarrow() {
    XCTAssertEqual(DeskFiles.webURL("https://example.com/a"), "https://example.com/a")
    XCTAssertNil(DeskFiles.webURL("file:///etc/passwd"))
    XCTAssertNil(DeskFiles.webURL("https://user:pass@example.com"))
    XCTAssertEqual(DeskFiles.appName("Safari"), "Safari")
    XCTAssertNil(DeskFiles.appName("../Safari"))
    XCTAssertNil(DeskFiles.appName("/Applications/Safari.app"))
    XCTAssertEqual(DeskFiles.email("ada@example.com"), "ada@example.com")
    XCTAssertNil(DeskFiles.email("not an address"))
    XCTAssertFalse(DeskFiles.appleString("say \"hi\"\nthere").contains("\n"))
    XCTAssertTrue(DeskFiles.appleString("say \"hi\"").contains("\\\""))
  }

  func testContextWireCarriesAnImageWithoutPuttingItInTheText() {
    var context = DeskContext.calendar("Today: nothing")
    context.images = [DeskContext.Image(mediaType: "image/jpeg", data: "aGVsbG8=")]
    let wire = context.wire
    let sources = wire["sources"] as? [[String: String]]
    XCTAssertEqual(sources?.first?["text"], "Today: nothing")
    let images = wire["images"] as? [[String: String]]
    XCTAssertEqual(images?.first?["media_type"], "image/jpeg")
    XCTAssertEqual(images?.first?["data"], "aGVsbG8=")
    XCTAssertFalse(context.isEmpty)
  }

  func testToolHostListsReadsAndStagesWrites() {
    let host = LocalToolHost(
      act: { name, args in
        XCTAssertEqual(name, "mail.draft")
        XCTAssertEqual(args["subject"] as? String, "Lunch")
        return "Pending approval. Nothing has changed."
      },
      remindersText: { "Home:\n- Call the bank" },
      finderText: { query in
        XCTAssertEqual(query, "arthur")
        return "- /Users/ada/arthur"
      },
      calendarText: { _ in "unused" }
    )
    let listed = host.respond(to: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
    let tools = (listed?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
    let names = tools?.compactMap { $0["name"] as? String } ?? []
    XCTAssertTrue(names.contains("reminders.list"))
    XCTAssertTrue(names.contains("finder.search"))
    XCTAssertTrue(names.contains("finder.reveal"))
    XCTAssertTrue(names.contains("mail.draft"))
    XCTAssertTrue(names.contains("open.url"))
    XCTAssertTrue(names.contains("open.app"))

    let reminders = host.respond(to: [
      "jsonrpc": "2.0", "id": 2, "method": "tools/call",
      "params": ["name": "reminders.list", "arguments": [:]],
    ])
    let reminderText = ((reminders?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
    XCTAssertEqual(reminderText, "Home:\n- Call the bank")

    let found = host.respond(to: [
      "jsonrpc": "2.0", "id": 3, "method": "tools/call",
      "params": ["name": "finder.search", "arguments": ["query": "arthur"]],
    ])
    let foundText = ((found?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
    XCTAssertEqual(foundText, "- /Users/ada/arthur")

    let draft = host.respond(to: [
      "jsonrpc": "2.0", "id": 4, "method": "tools/call",
      "params": ["name": "mail.draft", "arguments": ["subject": "Lunch"]],
    ])
    let draftText = ((draft?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
    XCTAssertEqual(draftText, "Pending approval. Nothing has changed.")
    XCTAssertEqual((draft?["result"] as? [String: Any])?["isError"] as? Bool, false)
  }

  func testReadsStayUnavailableUntilWired() {
    let host = LocalToolHost { _ in "calendar" }
    let listed = host.respond(to: [
      "jsonrpc": "2.0", "id": 1, "method": "tools/call",
      "params": ["name": "reminders.list"],
    ])
    let text = ((listed?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
    XCTAssertTrue(text?.contains("unavailable") == true)
    XCTAssertTrue(text?.contains("Do not invent") == true)
  }
}

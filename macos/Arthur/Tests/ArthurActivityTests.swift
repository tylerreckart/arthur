import XCTest

final class ArthurActivityTests: XCTestCase {
  func testApprovalIsMostUrgentAndCounts() {
    let jobs = ActivityBuilder.jobs(
      pendingTitle: "Add event", pendingSummary: "Dentist", pendingLabel: "Approve",
      isRunning: false, workLine: "", canCancel: false,
      errorText: "Offline", isOffline: true,
      schedules: [DeskSchedule(id: 3, message: "Water", phrase: "tomorrow", status: "active")],
      todos: [])
    XCTAssertEqual(ActivityBuilder.attentionCount(jobs), 2)
    XCTAssertEqual(ActivityBuilder.mostUrgent(jobs)?.title, "Add event")
    XCTAssertEqual(ActivityBuilder.jobs(in: jobs, section: "Needs you").count, 2)
  }

  func testRunningShowsStepAndStop() {
    let jobs = ActivityBuilder.jobs(
      pendingTitle: "", pendingSummary: "", pendingLabel: "",
      isRunning: true, workLine: "Looking something up.", canCancel: true,
      errorText: "", isOffline: false, schedules: [], todos: [])
    XCTAssertEqual(jobs.first?.state, .running(stepLabel: "Looking something up."))
    XCTAssertEqual(jobs.first?.primaryLabel, "Stop")
    XCTAssertEqual(ActivityBuilder.attentionCount(jobs), 0)
  }

  func testReschedulePhraseFromPicker() {
    var comps = DateComponents(); comps.year = 2026; comps.month = 11; comps.day = 6; comps.hour = 15; comps.minute = 30
    let now = Calendar.current.date(from: comps)!
    var later = comps; later.day = 7
    XCTAssertEqual(ReschedulePhrase.phrase(for: Calendar.current.date(from: later)!, now: now), "tomorrow at 3:30 pm")
    var future = comps; future.day = 10
    XCTAssertEqual(ReschedulePhrase.phrase(for: Calendar.current.date(from: future)!, now: now), "on Nov 10 at 3:30 pm")
  }

  func testDeskLoadStatesAreDistinct() {
    XCTAssertTrue(DeskLoadState.loading.isLoading)
    XCTAssertEqual(DeskLoadState.failed("nope").failureMessage, "nope")
    XCTAssertNil(DeskLoadState.loaded.failureMessage)
  }
}

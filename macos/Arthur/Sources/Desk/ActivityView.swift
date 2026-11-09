import SwiftUI

/// Shared job card rendered in Activity, the transcript, and (compact) the droplet.
struct JobCard: View {
  let job: JobItem
  var compact = false
  /// Caps the card so a transcript approval sits with weather and news.
  /// Activity leaves this open so the row fills the panel.
  var maxCardWidth: CGFloat = .infinity
  var onPrimary: () -> Void = {}
  var onSecondary: () -> Void = {}
  var onTap: () -> Void = {}

  private var hasActions: Bool {
    !job.primaryLabel.isEmpty || !job.secondaryLabel.isEmpty
  }

  var body: some View {
    Group {
      if hasActions {
        GlassEffectContainer(spacing: 12) {
          VStack(alignment: .leading, spacing: 8) {
            plate
            actionRow
          }
        }
      } else {
        plate
      }
    }
    .frame(maxWidth: maxCardWidth, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(job.title). \(job.state.chipLabel). \(job.summary)")
  }

  private var plate: some View {
    VStack(alignment: .leading, spacing: compact ? 4 : 6) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: symbolName)
          .font(compact ? .caption : .body)
          .foregroundStyle(.secondary)
          .padding(.top, compact ? 2 : 3)
          .accessibilityHidden(true)
        Text(job.title)
          .font(.system(compact ? .callout : .body, design: .serif).weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(compact ? 1 : 2)
        Spacer(minLength: 4)
        ArthurStatusChip(label: job.state.chipLabel, urgent: job.state.needsAttention)
      }
      if !job.summary.isEmpty {
        Text(job.summary)
          .font(compact ? .caption : .callout)
          .foregroundStyle(.secondary)
          .lineLimit(compact ? 1 : 3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(compact ? 10 : 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .arthurPlate(radius: compact ? 16 : 20)
    .modifier(CompactCardTap(enabled: compact, action: onTap))
  }

  @ViewBuilder
  private var actionRow: some View {
    HStack(spacing: 8) {
      if !job.primaryLabel.isEmpty {
        Button(job.primaryLabel, action: onPrimary)
          .arthurAction(prominent: true)
          .controlSize(compact ? .small : .regular)
          .accessibilityLabel("\(job.primaryLabel), \(job.title)")
      }
      if !job.secondaryLabel.isEmpty {
        Button(job.secondaryLabel, action: onSecondary)
          .arthurAction(prominent: false)
          .controlSize(compact ? .small : .regular)
          .accessibilityLabel("\(job.secondaryLabel), \(job.title)")
      }
    }
  }

  private var symbolName: String {
    switch job.kind {
    case .approval: return "checkmark.circle"
    case .turn: return "hourglass"
    case .error: return "exclamationmark.circle"
    case .schedule: return "calendar"
    case .todo: return "checklist"
    case .speakBack: return "bell"
    }
  }
}

/// Compact status cards open Activity on tap. Full cards leave the click to their buttons.
private struct CompactCardTap: ViewModifier {
  var enabled: Bool
  var action: () -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    if enabled {
      content
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    } else {
      content
    }
  }
}

struct ActivityPanel: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          connectionRow
          if !model.deskStatus.isEmpty {
            Text(model.deskStatus).font(.callout).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading).padding(12).arthurPlate(radius: 16)
          }
          section("Needs you", jobs: ActivityBuilder.jobs(in: model.activityJobs, section: "Needs you"),
                  empty: "Nothing needs you right now.")
          section("Running", jobs: ActivityBuilder.jobs(in: model.activityJobs, section: "Running"),
                  empty: "Nothing is running.")
          section("Done & open", jobs: ActivityBuilder.jobs(in: model.activityJobs, section: "Done"),
                  empty: "No schedules or todos. Open Memory to add context.")
        }.padding(16)
      }
      .navigationTitle("Activity")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .onAppear { model.loadDesk() }
    }
    .frame(minWidth: 480, minHeight: 520)
  }

  private var connectionRow: some View {
    HStack(spacing: 8) {
      Circle().fill(model.phase == .disconnected || model.phase == .connecting ? ArthurTheme.error : Color(red: 0.40, green: 0.72, blue: 0.52))
        .frame(width: 8, height: 8)
      VStack(alignment: .leading, spacing: 1) {
        Text(model.chromeLabel).font(.callout.weight(.semibold))
        Text(model.chromeDetail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      if model.phase == .disconnected || model.phase == .connecting {
        Button("Reconnect") { model.reconnect() }
          .buttonStyle(.plain)
          .font(.callout.weight(.semibold))
          .accessibilityLabel("Reconnect to Arthur")
      }
      if model.wakeWord { Text(model.wakeMuted ? "Wake muted" : "Wake on").font(.caption).foregroundStyle(.secondary) }
      Text(model.micGranted ? "Mic on" : "Mic off").font(.caption).foregroundStyle(.secondary)
    }.padding(12).arthurPlate(radius: 16)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Connection: \(model.chromeDetail)")
  }

  @ViewBuilder
  private func section(_ title: String, jobs: [JobItem], empty: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      if jobs.isEmpty {
        Text(empty).font(.callout).foregroundStyle(.secondary)
      } else {
        ForEach(jobs) { job in
          JobCard(job: job, onPrimary: { model.performJobAction(job, primary: true) },
                  onSecondary: { model.performJobAction(job, primary: false) })
        }
      }
    }
  }
}

#if DEBUG
#Preview("Activity · approval") {
  ActivityPanel().environment(AppModel.previewCanvas()).frame(width: 520, height: 620)
}
#Preview("Job card · needs you") {
  JobCard(job: JobItem(id: "1", kind: .approval, title: "Add calendar event",
                       summary: "Dentist, tomorrow at 9am", state: .needsApproval,
                       primaryLabel: "Approve", secondaryLabel: "Not now"))
    .arthurPreviewDesk(width: 400)
}

#Preview("Status cards") {
  VStack(alignment: .leading, spacing: 18) {
    JobCard(job: JobItem(id: "1", kind: .approval, title: "Add calendar event",
                         summary: "Dentist, tomorrow at 9am", state: .needsApproval,
                         primaryLabel: "Approve", secondaryLabel: "Not now"))
    JobCard(job: JobItem(id: "2", kind: .turn, title: "Arthur is working",
                         summary: "Checking the calendar", state: .running(stepLabel: "Checking the calendar"),
                         primaryLabel: "Stop"))
    JobCard(job: JobItem(id: "3", kind: .error, title: "Arthur is offline",
                         summary: "Disconnected from intercom.", state: .blocked(error: "Disconnected from intercom."),
                         primaryLabel: "Reconnect", secondaryLabel: "Dismiss"))
    JobCard(job: JobItem(id: "4", kind: .approval, title: "Add calendar event",
                         summary: "Dentist, tomorrow at 9am", state: .needsApproval),
            compact: true)
  }
  .arthurPreviewDesk(width: 400)
}
#endif

#if DEBUG
#Preview("Activity · error offline") {
  let m = AppModel.previewCanvas(phase: .disconnected); m.errorText = "Disconnected from intercom."
  return ActivityPanel().environment(m).frame(width: 520, height: 620)
}
#Preview("Activity · approval pending") {
  let m = AppModel.previewCanvas()
  m.pendingWriteTitle = "Add calendar event"; m.pendingWriteSummary = "Dentist tomorrow at 9am"
  // pendingWriteLabel is derived from private phase; surface via schedules as fallback rows
  m.deskSchedules = [DeskSchedule(id: 3, message: "Water the plants", phrase: "tomorrow at 9:00 am", status: "active")]
  return ActivityPanel().environment(m).frame(width: 520, height: 620)
}
#endif

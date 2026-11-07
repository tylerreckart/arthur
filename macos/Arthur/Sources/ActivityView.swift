import SwiftUI

/// Shared job card rendered in Activity, the transcript, and (compact) the droplet.
struct JobCard: View {
  let job: JobItem
  var compact = false
  var onPrimary: () -> Void = {}
  var onSecondary: () -> Void = {}
  var onTap: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: compact ? 4 : 6) {
      HStack(spacing: 8) {
        Text(job.title)
          .font(compact ? .callout.weight(.semibold) : .body.weight(.semibold))
          .foregroundStyle(.primary).lineLimit(compact ? 1 : 2)
        Spacer(minLength: 4)
        Text(job.state.chipLabel)
          .font(.caption2.weight(.bold))
          .padding(.horizontal, 7).padding(.vertical, 3)
          .foregroundStyle(chipForeground)
          .background(chipBackground, in: Capsule())
          .accessibilityLabel("State: \(job.state.chipLabel)")
      }
      if !job.summary.isEmpty {
        Text(job.summary)
          .font(compact ? .caption : .callout)
          .foregroundStyle(.secondary)
          .lineLimit(compact ? 1 : 3)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !job.primaryLabel.isEmpty || !job.secondaryLabel.isEmpty {
        HStack(spacing: 8) {
          if !job.primaryLabel.isEmpty {
            Button(job.primaryLabel, action: onPrimary)
              .buttonStyle(.borderedProminent)
              .controlSize(compact ? .small : .regular)
              .accessibilityLabel("\(job.primaryLabel), \(job.title)")
          }
          if !job.secondaryLabel.isEmpty {
            Button(job.secondaryLabel, action: onSecondary)
              .buttonStyle(.bordered)
              .controlSize(compact ? .small : .regular)
              .accessibilityLabel("\(job.secondaryLabel), \(job.title)")
          }
        }.padding(.top, 2)
      }
    }
    .padding(compact ? 10 : 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .arthurPlate(radius: compact ? 14 : 16)
    .contentShape(Rectangle())
    .onTapGesture { if compact { onTap() } }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(job.title). \(job.state.chipLabel). \(job.summary)")
  }

  private var chipBackground: Color {
    switch job.state {
    case .needsApproval, .blocked: return Color(red: 0.86, green: 0.40, blue: 0.42).opacity(0.9)
    case .running: return Color.primary.opacity(0.22)
    default: return Color.primary.opacity(0.12)
    }
  }
  private var chipForeground: Color {
    switch job.state { case .needsApproval, .blocked: return .white; default: return Color.primary }
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
              .frame(maxWidth: .infinity, alignment: .leading).padding(10).arthurPlate(radius: 12)
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
      Circle().fill(model.phase == .disconnected || model.phase == .connecting ? Color(red: 0.86, green: 0.40, blue: 0.42) : Color(red: 0.40, green: 0.72, blue: 0.52))
        .frame(width: 8, height: 8)
      VStack(alignment: .leading, spacing: 1) {
        Text(model.chromeLabel).font(.callout.weight(.semibold))
        Text(model.chromeDetail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Spacer()
      if model.phase == .disconnected || model.phase == .connecting {
        Button("Reconnect") { model.reconnect() }.accessibilityLabel("Reconnect to Arthur")
      }
      if model.wakeWord { Text(model.wakeMuted ? "Wake muted" : "Wake on").font(.caption).foregroundStyle(.secondary) }
      Text(model.micGranted ? "Mic on" : "Mic off").font(.caption).foregroundStyle(.secondary)
    }.padding(10).arthurPlate(radius: 12)
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
    .padding().background(Color.black).preferredColorScheme(.dark)
}
#endif

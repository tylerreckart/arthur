import AppKit
import SwiftUI

// MARK: - Card

struct DropletCardRoot: View {
  var session: DropletSession
  private var bead: BeadState { DeskAccessory.shared.bead }

  var body: some View {
    let ticking = session.chromeAnimating || session.closing || session.dragging
    let reply = session.content.reply
    let height = session.cardHeight
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !ticking)) { timeline in
      let now = timeline.date
      let sample = session.sample(at: now)
      let drag = session.dragOffset(at: now)
      GeometryReader { geo in
        let layout = layout(in: geo.size, sample: sample, drag: drag)
        card(sample: sample, layout: layout)
        .frame(width: geo.size.width, height: geo.size.height)
        .onAppear { session.actions.cardFrame(layout.card) }
        .onChange(of: layout.card) { _, rect in
          session.actions.cardFrame(rect)
        }
        .onContinuousHover { phase in
          switch phase {
          case .active(let loc):
            if !session.hovering {
              session.hovering = true
              session.actions.hover(true)
            }
            let card = layout.card
            guard card.width > 1, card.height > 1 else { return }
            session.pointer = CGPoint(
              x: min(1, max(0, (loc.x - card.minX) / card.width)),
              y: min(1, max(0, (loc.y - card.minY) / card.height))
            )
          case .ended:
            if session.hovering {
              session.hovering = false
              session.actions.hover(false)
            }
          @unknown default:
            break
          }
        }
      }
      .onChange(of: hitsOpen(sample)) { _, open in
        session.actions.setAcceptsHits(open)
      }
      .onChange(of: now) { _, date in
        let wants = session.wantsChromeAnimation(at: date)
        if wants != session.chromeAnimating {
          session.setChromeAnimating(wants)
        }
      }
    }
    .onChange(of: reply) { _, _ in }
    .onChange(of: height) { _, _ in }
    .onChange(of: session.closeToken) { _, token in
      guard token > 0 else { return }
      let expected = token
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(280))
        guard session.closeToken == expected, session.closing else { return }
        session.actions.didFinishClose()
      }
    }
  }

  private func hitsOpen(_ sample: DripSample) -> Bool {
    sample.presence > 0.2
  }

  private func layout(in size: CGSize, sample: DripSample, drag: CGSize) -> DropletLayout {
    let width = DropletMetrics.cardWidth
    let height = session.cardHeight
    let margin = DropletMetrics.cornerMargin
    let rect = CGRect(
      x: size.width - width - margin + drag.width,
      y: size.height - height - margin + drag.height,
      width: width,
      height: height
    )
    return DropletLayout(
      card: rect,
      anchor: CGPoint(x: rect.midX, y: rect.minY),
      squish: CGSize(width: 1, height: 1)
    )
  }

  @ViewBuilder
  private func card(sample: DripSample, layout: DropletLayout) -> some View {
    let reveal = CGFloat(min(max(sample.content, 0), 1))
    let rise = CGFloat(min(max(sample.fall, 0), 1))
    DropletCardBody(session: session)
      .fixedSize(horizontal: false, vertical: true)
      .background {
        GeometryReader { proxy in
          Color.clear.preference(key: DropletHeightKey.self, value: proxy.size.height)
        }
      }
      .background(Color.black, in: RoundedRectangle(cornerRadius: DropletMetrics.corner, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: DropletMetrics.corner, style: .continuous)
          .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
      .clipShape(RoundedRectangle(cornerRadius: DropletMetrics.corner, style: .continuous))
      .opacity(reveal)
      .offset(y: (1 - rise) * 36)
      .position(x: layout.card.midX, y: layout.card.midY)
      .onPreferenceChange(DropletHeightKey.self) { session.setCardHeight($0) }
      .preferredColorScheme(.dark)
  }
}

private struct DropletLayout {
  var card: CGRect
  var anchor: CGPoint
  var squish: CGSize
}

private struct DropletHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

private struct DropletCardBody: View {
  var session: DropletSession

  var body: some View {
    let content = session.content
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 0) {
        Button(action: { session.actions.open() }) {
          ArthurGlyph()
            .fill(Color.white.opacity(0.92))
            .frame(width: 16, height: 16)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the conversation")
        .accessibilityLabel("Open Arthur")
        Spacer(minLength: 0)
        Button(action: { session.actions.dismiss() }) {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.82))
            .frame(width: 36, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
      }

      if !content.you.isEmpty {
        Text(content.you)
          .font(.callout)
          .foregroundStyle(ArthurTheme.mute)
          .lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("You said: \(content.you)")
      }

      if content.reply.isEmpty {
        Text(content.stage == .ready ? "Hello." : content.title)
          .font(.system(.title3, design: .serif))
          .foregroundStyle(Color.white.opacity(0.92))
          .frame(maxWidth: .infinity, alignment: .leading)
        // Subtitle (work line, error, or hint) shows in every stage — not
        // only .ready — so a long think never reads as a bare "…".
        if !content.subtitle.isEmpty,
           !content.subtitle.hasPrefix("Hold the droplet") {
          Text(content.subtitle)
            .font(.callout)
            .foregroundStyle(content.stage == .ready && content.subtitle == session.content.subtitle && !content.attentionTitle.isEmpty ? ArthurTheme.mute : ArthurTheme.mute)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(content.subtitle)
        }
      } else {
        SpokenReply(text: content.reply, live: content.replyLive)
          .equatable()
        if content.stage == .thinking || content.stage == .replying, !content.subtitle.isEmpty {
          Text(content.subtitle)
            .font(.callout).foregroundStyle(ArthurTheme.mute)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      // Nothing is approvable blind: the pending item's title + summary
      // sit directly above Approve / Not now, and tapping opens Activity.
      if !content.approveLabel.isEmpty, !content.noteTitle.isEmpty || !content.noteBody.isEmpty {
        JobCard(
          job: JobItem(id: "droplet-approval", kind: .approval,
                       title: content.noteTitle.isEmpty ? content.attentionTitle : content.noteTitle,
                       summary: content.noteBody.isEmpty ? content.attentionSummary : content.noteBody,
                       state: .needsApproval, primaryLabel: "", secondaryLabel: ""),
          compact: true,
          onTap: { session.actions.openActivity() }
        )
        .accessibilityHint("Opens Activity")
      } else if content.attentionCount > 0, !content.attentionTitle.isEmpty {
        Button { session.actions.openActivity() } label: {
          HStack(spacing: 6) {
            Text("\(content.attentionCount)").font(.caption2.weight(.bold))
              .padding(5).background(Color(red: 0.86, green: 0.40, blue: 0.42), in: Circle()).foregroundStyle(.white)
            Text(content.attentionTitle).font(.callout.weight(.semibold)).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right").font(.caption2)
          }.foregroundStyle(ArthurTheme.paper)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(content.attentionCount) items need you. Most urgent: \(content.attentionTitle)")
        .accessibilityHint("Opens Activity")
      }

      if content.canCancel {
        Button("Stop") { session.actions.stop() }
          .buttonStyle(.plain).font(.callout.weight(.semibold))
          .padding(.horizontal, 12).padding(.vertical, 7)
          .foregroundStyle(.black).background(Color.white.opacity(0.92), in: Capsule())
          .accessibilityLabel("Stop Arthur")
      }

      if !content.approveLabel.isEmpty || !content.lookLabel.isEmpty {
        HStack(spacing: 8) {
          if !content.lookLabel.isEmpty {
            Button(content.lookLabel) { session.actions.look() }
              .buttonStyle(.plain)
              .font(.system(size: 13, weight: .semibold))
              .padding(.horizontal, 12)
              .padding(.vertical, 7)
              .foregroundStyle(Color.white.opacity(0.92))
              .overlay(Capsule().stroke(Color.white.opacity(0.92), lineWidth: 1))
              .accessibilityLabel("Look at the screen")
          }
          if !content.approveLabel.isEmpty {
            Button(content.approveLabel) { session.actions.approve() }
              .buttonStyle(.plain)
              .font(.system(size: 13, weight: .semibold))
              .padding(.horizontal, 12)
              .padding(.vertical, 7)
              .foregroundStyle(Color.black)
              .background(Color.white.opacity(0.92), in: Capsule())
              .accessibilityLabel(content.approveLabel)
          }
        }
      }

    }
    .padding(24)
    .frame(width: DropletMetrics.cardWidth, alignment: .leading)
    .simultaneousGesture(cardDrag)
  }

  private var cardDrag: some Gesture {
    DragGesture(minimumDistance: 18)
      .onChanged { value in
        guard !session.talkArmed, !session.closing else { return }
        let sample = session.sample(at: Date())
        guard sample.morph > 0.92 else { return }
        session.updateDrag(value.translation)
      }
      .onEnded { _ in
        guard session.dragging else { return }
        let drop = session.endDrag()
        if drop > 108, !session.content.live {
          session.actions.dismiss()
        }
      }
  }

}

/// Arthur's reply. While it is still arriving, keep the newest lines in view.
private struct SpokenReply: View, Equatable {
  var text: String
  var live = false

  static func == (lhs: SpokenReply, rhs: SpokenReply) -> Bool {
    lhs.text == rhs.text && lhs.live == rhs.live
  }

  var body: some View {
    Text(text)
      .font(.system(size: 20, weight: .regular, design: .serif))
      .foregroundStyle(Color.white)
      .lineLimit(8)
      .truncationMode(live ? .head : .tail)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .transaction { $0.animation = nil }
      .contextMenu {
        Button("Copy") { ArthurPasteboard.copy(text) }
      }
  }
}

#if DEBUG
private struct DropletCardPreview: View {
  var content: DropletContent
  @State private var session: DropletSession

  init(content: DropletContent) {
    self.content = content
    let session = DropletSession()
    session.content = content
    session.openBegan = .distantPast
    _session = State(initialValue: session)
  }

  var body: some View {
    DropletCardBody(session: session)
      .background(Color.black, in: RoundedRectangle(cornerRadius: DropletMetrics.corner, style: .continuous))
      .preferredColorScheme(.dark)
  }
}

#Preview("Droplet · ready") {
  DropletCardPreview(content: .empty)
}

#Preview("Droplet · listening") {
  DropletCardPreview(content: ArthurPreviews.listeningDroplet)
}

#Preview("Droplet · reply") {
  DropletCardPreview(content: ArthurPreviews.replyDroplet)
}

#Preview("Droplet · thinking") {
  DropletCardPreview(content: ArthurPreviews.thinkingDroplet)
}

#Preview("Droplet · approval") {
  DropletCardPreview(content: ArthurPreviews.approvalDroplet)
}
#endif


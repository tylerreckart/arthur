import SwiftUI

struct MarketsCard: View {
  let surface: ChatSurface
  let markets: MarketsPayload
  var compact = false

  private static let up = Color(red: 0.40, green: 0.72, blue: 0.52)
  private static let down = Color(red: 0.86, green: 0.40, blue: 0.42)

  var body: some View {
    if compact {
      compactBody
    } else {
      fullBody
    }
  }

  private var fullBody: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(surface.title.isEmpty ? "Markets" : surface.title)
        .font(.system(.caption, design: .serif).weight(.semibold))
        .foregroundStyle(.secondary)
      VStack(spacing: 6) {
        ForEach(markets.instruments.prefix(8)) { inst in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
              Text(inst.symbol)
                .font(.callout.weight(.semibold).monospaced())
                .foregroundStyle(.primary)
              if !inst.name.isEmpty, inst.name != inst.symbol {
                Text(inst.name)
                  .font(.caption2)
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
              }
            }
            Spacer(minLength: 8)
            Text(inst.priceText)
              .font(.callout.monospacedDigit())
              .foregroundStyle(.primary)
            Text(inst.changeText)
              .font(.caption.monospacedDigit().weight(.semibold))
              .foregroundStyle(changeColor(inst))
              .frame(minWidth: 58, alignment: .trailing)
          }
        }
      }
      sourceRow
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: 360, alignment: .leading)
    .arthurPlate(radius: 20, tint: Self.up.opacity(0.45))
  }

  private var compactBody: some View {
    HStack(spacing: 10) {
      Image(systemName: "chart.line.uptrend.xyaxis")
        .font(.body)
        .foregroundStyle(Self.up)
        .symbolRenderingMode(.hierarchical)
      VStack(alignment: .leading, spacing: 1) {
        Text(surface.title.isEmpty ? "Markets" : surface.title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(compactSummary)
          .font(.callout)
          .foregroundStyle(.primary)
          .lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .arthurPlate(radius: 16, tint: Self.up.opacity(0.45))
  }

  private var compactSummary: String {
    if !surface.summary.isEmpty { return surface.summary }
    if !markets.marketSummary.isEmpty { return markets.marketSummary }
    if let first = markets.instruments.first {
      return "\(first.symbol)  \(first.priceText)  \(first.changeText)"
    }
    return "Markets"
  }

  private func changeColor(_ inst: MarketInstrument) -> Color {
    if inst.isUp { return Self.up }
    if inst.isDown { return Self.down }
    return .secondary
  }

  @ViewBuilder
  private var sourceRow: some View {
    if let source = surface.sources.first {
      if let url = source.link {
        Link(destination: url) {
          Text(source.title.isEmpty ? url.host ?? "Source" : source.title)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .arthurQuietLink()
      } else if !source.title.isEmpty {
        Text(source.title)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
    }
  }
}

#if DEBUG
private func marketsPreview(compact: Bool, width: CGFloat) -> some View {
  let surface = ArthurPreviews.marketsSurface
  return MarketsCard(surface: surface, markets: MarketsPayload(surface.payload), compact: compact)
    .arthurPreviewDesk(width: width)
}

#Preview("Markets") {
  marketsPreview(compact: false, width: 400)
}

#Preview("Markets · compact") {
  marketsPreview(compact: true, width: 320)
}
#endif

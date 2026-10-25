import SwiftUI

/// The bottom-half readouts: the optional debug block above the two status lines.
struct StatusColumn: View {
  let model: AppModel

  var body: some View {
    VStack(spacing: 16) {
      if model.settings.showsDebugOverlay {
        DebugOverlay(snapshot: model.snapshot)
      }
      StatusLines(presentation: model.snapshot.presentation)
    }
    .padding(.bottom, 36)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .allowsHitTesting(false)
  }
}

/// A status dot with the connection text, and the tracking text under it.
struct StatusLines: View {
  let presentation: StatusPresentation

  var body: some View {
    VStack(spacing: 4) {
      HStack(spacing: 8) {
        StatusDot(level: presentation.level)
        Text(presentation.connection)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.primary)
      }
      Text(presentation.tracking)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .padding(.horizontal, 56)
    .accessibilityElement(children: .combine)
  }
}

/// The small coloured dot beside the connection text. The text carries the meaning too.
struct StatusDot: View {
  let level: StatusLevel

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 8, height: 8)
  }

  private var color: Color {
    switch level {
    case .good: .green
    case .caution: .orange
    case .problem: .red
    }
  }
}

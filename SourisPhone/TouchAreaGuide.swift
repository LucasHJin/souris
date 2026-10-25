import SwiftUI

import SourisCore

/// Marks the touch area: a hairline at its lower edge, another down the middle between the left
/// and right buttons, and a faint lightening over each half while its button is held.
struct TouchAreaGuide: View {
  let fraction: Double
  let heldButtons: MouseButtons

  @Environment(\.displayScale) private var displayScale

  var body: some View {
    GeometryReader { proxy in
      let height = proxy.size.height * fraction
      let hairline = 1 / displayScale
      ZStack(alignment: .top) {
        HStack(spacing: 0) {
          pressShade(for: .left)
          pressShade(for: .right)
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.08), value: heldButtons)
        Color.white
          .opacity(0.1)
          .frame(width: hairline, height: height)
        Color.white
          .opacity(0.1)
          .frame(height: hairline)
          .offset(y: height)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .allowsHitTesting(false)
  }

  private func pressShade(for button: MouseButtons) -> some View {
    Color.white.opacity(heldButtons.contains(button) ? 0.06 : 0)
  }
}

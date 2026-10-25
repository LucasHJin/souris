import SwiftUI

import SourisCore

/// Marks the touch area: a hairline at its lower edge, and a faint lightening while a button is
/// held (left a little, right a little more).
struct TouchAreaGuide: View {
  let fraction: Double
  let heldButtons: MouseButtons

  @Environment(\.displayScale) private var displayScale

  var body: some View {
    GeometryReader { proxy in
      let height = proxy.size.height * fraction
      ZStack(alignment: .top) {
        Color.white
          .opacity(pressOpacity)
          .frame(height: height)
          .animation(.easeOut(duration: 0.08), value: heldButtons)
        Color.white
          .opacity(0.1)
          .frame(height: 1 / displayScale)
          .offset(y: height)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .allowsHitTesting(false)
  }

  private var pressOpacity: Double {
    if heldButtons.contains(.right) { return 0.09 }
    if heldButtons.contains(.left) { return 0.05 }
    return 0
  }
}

import SwiftUI

import SourisCore

/// Marks the touch area: a hairline at its lower edge, another down the middle between the left
/// and right buttons, a faint lightening over each half while its button is held, and the scroll
/// wheel on the middle line.
struct TouchAreaGuide: View {
  let touch: TouchSettings
  let controller: TouchController

  @Environment(\.displayScale) private var displayScale

  var body: some View {
    GeometryReader { proxy in
      let height = proxy.size.height * touch.acceptedFraction
      let hairline = 1 / displayScale
      ZStack(alignment: .top) {
        HStack(spacing: 0) {
          pressShade(for: .left)
          pressShade(for: .right)
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.08), value: controller.heldButtons)
        Color.white
          .opacity(0.1)
          .frame(width: hairline, height: height)
        Color.white
          .opacity(0.1)
          .frame(height: hairline)
          .offset(y: height)
        if let wheel = TouchClassifier(settings: touch).wheelRect(in: proxy.size) {
          WheelStrip(
            controller: controller, notchSpacing: touch.wheel.notchSpacing, hairline: hairline)
            .frame(width: wheel.width, height: wheel.height)
            .offset(y: wheel.minY)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .allowsHitTesting(false)
  }

  private func pressShade(for button: MouseButtons) -> some View {
    Color.white.opacity(controller.heldButtons.contains(button) ? 0.06 : 0)
  }
}

/// The scroll wheel: a capsule a shade lighter than the surface, with faint ridges a notch apart
/// that move with the finger and keep moving while the wheel spins. It lightens while touched or
/// middle-clicked, and shows a microphone while a hold dictates: faint while the Mac's Dictation
/// starts, bright once it listens. Reads the rotation itself so only it redraws while the wheel
/// turns.
private struct WheelStrip: View {
  let controller: TouchController
  let notchSpacing: Double
  let hairline: CGFloat

  var body: some View {
    let isLit = controller.isWheelTouched || controller.heldButtons.contains(.middle)
    let rotation = controller.wheelRotation
    Canvas { context, size in
      let spacing = CGFloat(max(4, notchSpacing))
      // The ridges move down the screen as the wheel turns toward the palm.
      var phase = CGFloat(-rotation).truncatingRemainder(dividingBy: 1)
      if phase < 0 {
        phase += 1
      }
      var ridges = Path()
      var y = phase * spacing
      while y < size.height {
        ridges.move(to: CGPoint(x: 12, y: y))
        ridges.addLine(to: CGPoint(x: size.width - 12, y: y))
        y += spacing
      }
      context.stroke(ridges, with: .color(.white.opacity(0.14)), lineWidth: hairline)
    }
    .mask {
      // Fading the ridges out toward the ends makes the strip read as a cylinder.
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0),
          .init(color: .black, location: 0.3),
          .init(color: .black, location: 0.7),
          .init(color: .clear, location: 1),
        ],
        startPoint: .top,
        endPoint: .bottom)
    }
    .background {
      Capsule()
        .fill(Color(white: isLit ? 0.25 : 0.215))
        .animation(.easeOut(duration: 0.08), value: isLit)
    }
    .overlay {
      Capsule()
        .strokeBorder(Color.white.opacity(0.1), lineWidth: hairline)
    }
    .overlay {
      if controller.isDictating {
        Image(systemName: "mic.fill")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(.white.opacity(controller.isDictationListening ? 0.75 : 0.3))
          .animation(.easeOut(duration: 0.15), value: controller.isDictationListening)
          .transition(.scale(scale: 0.8).combined(with: .opacity))
      }
    }
    // Fades in with a slight overshoot, settling back to full size.
    .animation(.spring(duration: 0.3, bounce: 0.35), value: controller.isDictating)
  }
}

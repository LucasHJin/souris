import SwiftUI

import SourisCore

/// Marks the touch area: hairlines at its lower edges and down the middle between the left and
/// right buttons, and one between each button and the key below it; a faint lightening over each
/// button while it is held and over each key while touched; a faint return arrow on the Enter key
/// and a delete symbol on the Delete key; and the scroll wheel on the middle line.
struct TouchAreaGuide: View {
  let touch: TouchSettings
  let controller: TouchController

  @Environment(\.displayScale) private var displayScale

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      let half = size.width / 2
      let areaBottom = size.height * CGFloat(touch.acceptedFraction)
      let classifier = TouchClassifier(settings: touch)
      let enterKey = classifier.keyRect(.returnKey, in: size)
      let deleteKey = classifier.keyRect(.deleteKey, in: size)
      let hairline = 1 / displayScale
      ZStack(alignment: .topLeading) {
        pressShade(isLit: controller.heldButtons.contains(.left))
          .frame(width: half, height: enterKey?.minY ?? areaBottom)
        pressShade(isLit: controller.heldButtons.contains(.right))
          .frame(width: half, height: deleteKey?.minY ?? areaBottom)
          .offset(x: half)
        if let enterKey {
          key(.returnKey, symbol: "return", in: enterKey, hairline: hairline)
        }
        if let deleteKey {
          key(.deleteKey, symbol: "delete.left", in: deleteKey, hairline: hairline)
        }
        line(width: hairline, height: max(areaBottom, enterKey?.maxY ?? 0, deleteKey?.maxY ?? 0))
          .offset(x: half - hairline / 2)
        line(width: half, height: hairline)
          .offset(y: enterKey?.maxY ?? areaBottom)
        line(width: half, height: hairline)
          .offset(x: half, y: deleteKey?.maxY ?? areaBottom)
        if let wheel = classifier.wheelRect(in: size) {
          WheelStrip(
            controller: controller, notchSpacing: touch.wheel.notchSpacing, hairline: hairline)
            .frame(width: wheel.width, height: wheel.height)
            .offset(x: wheel.minX, y: wheel.minY)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .allowsHitTesting(false)
  }

  /// A key's lightening and symbol, and the hairline between it and the button above.
  @ViewBuilder
  private func key(
    _ key: TouchKey, symbol: String, in rect: CGRect, hairline: CGFloat
  ) -> some View {
    let isTouched = controller.touchedKeys.contains(key)
    pressShade(isLit: isTouched)
      .frame(width: rect.width, height: rect.height)
      .offset(x: rect.minX, y: rect.minY)
    Image(systemName: symbol)
      .font(.system(size: 20, weight: .regular))
      .foregroundStyle(.white.opacity(isTouched ? 0.4 : 0.16))
      .animation(.easeOut(duration: 0.08), value: isTouched)
      .frame(width: rect.width, height: rect.height)
      .offset(x: rect.minX, y: rect.minY)
    line(width: rect.width, height: hairline)
      .offset(x: rect.minX, y: rect.minY)
  }

  private func pressShade(isLit: Bool) -> some View {
    Color.white
      .opacity(isLit ? 0.06 : 0)
      .animation(.easeOut(duration: 0.08), value: isLit)
  }

  private func line(width: CGFloat, height: CGFloat) -> some View {
    Color.white
      .opacity(0.1)
      .frame(width: width, height: height)
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

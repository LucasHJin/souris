import SwiftUI
import UIKit

/// The full-screen multi-touch view, hosted in SwiftUI.
struct TouchSurface: UIViewRepresentable {
  let controller: TouchController

  func makeUIView(context: Context) -> TouchView {
    TouchView(controller: controller)
  }

  func updateUIView(_ uiView: TouchView, context: Context) {}
}

/// Hands raw touches to the `TouchController` at the moment UIKit delivers them.
final class TouchView: UIView {
  private let controller: TouchController

  init(controller: TouchController) {
    self.controller = controller
    super.init(frame: .zero)
    isMultipleTouchEnabled = true
    backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    controller.touchesBegan(touches, in: self)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    controller.touchesEnded(touches)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    controller.touchesEnded(touches)
  }
}

import AppKit

/// The "Allow this iPhone?" prompt.
///
/// It is shown as a plain window, not a modal session, so the menu bar keeps working while it is
/// up and `bringToFront()` can raise it again. The alert's own buttons only end a modal session,
/// so their actions are replaced.
@MainActor
final class ApprovalAlert: NSObject {
  private let alert = NSAlert()
  private let onChoice: @MainActor (Bool) -> Void
  private var isFinished = false

  /// Creates the alert without showing it.
  ///
  /// - Parameters:
  ///   - deviceName: The phone's name as it introduced itself.
  ///   - onChoice: Called once with `true` for Allow and `false` for Don't Allow.
  init(deviceName: String, onChoice: @escaping @MainActor (Bool) -> Void) {
    self.onChoice = onChoice
    super.init()

    alert.messageText = "Allow “\(deviceName)” to control the pointer?"
    alert.informativeText =
      "Only allow iPhones you own. You can forget approved iPhones from the Souris menu."
    let allow = alert.addButton(withTitle: "Allow")
    let deny = alert.addButton(withTitle: "Don’t Allow")
    allow.target = self
    allow.action = #selector(allowClicked)
    deny.target = self
    deny.action = #selector(denyClicked)
    deny.keyEquivalent = "\u{1b}"
  }

  /// Shows the alert and brings the app forward.
  func show() {
    alert.layout()
    alert.window.center()
    bringToFront()
  }

  /// Raises the alert above other windows, whether or not macOS lets the app take focus.
  func bringToFront() {
    NSApplication.shared.activate()
    alert.window.level = .floating
    alert.window.makeKeyAndOrderFront(nil)
    alert.window.orderFrontRegardless()
  }

  /// Closes the alert without answering, when the request no longer matters.
  func dismiss() {
    isFinished = true
    alert.window.orderOut(nil)
  }

  @objc private func allowClicked() {
    finish(approved: true)
  }

  @objc private func denyClicked() {
    finish(approved: false)
  }

  private func finish(approved: Bool) {
    guard !isFinished else { return }
    isFinished = true
    alert.window.orderOut(nil)
    onChoice(approved)
  }
}

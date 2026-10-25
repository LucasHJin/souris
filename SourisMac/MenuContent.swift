import SwiftUI

/// The menu bar menu. Plain native items only.
struct MenuContent: View {
  let model: MacModel

  var body: some View {
    Text(verbatim: model.statusTitle)
    if let detail = model.statusDetail {
      Text(verbatim: detail)
    }
    if let usb = model.usbDetail {
      Text(verbatim: usb)
    }

    if model.pendingApproval != nil || !model.isAccessibilityGranted {
      Divider()
    }
    if let peer = model.pendingApproval {
      Button("Allow “\(peer.displayName)”…") {
        model.showApproval()
      }
    }
    if !model.isAccessibilityGranted {
      Button("Allow Souris to Control the Pointer…") {
        model.openAccessibilitySettings()
      }
    }

    Divider()

    Toggle(
      "Accept Connections",
      isOn: Binding(
        get: { model.acceptsConnections },
        set: { model.setAcceptsConnections($0) }))
    if model.isConnected {
      Button("Disconnect iPhone") {
        model.disconnectController()
      }
    }
    if let address = model.addressText {
      Text(verbatim: address)
    }

    Menu("Advanced") {
      Toggle(
        "Allow Peer-to-Peer Wi-Fi",
        isOn: Binding(
          get: { model.allowsPeerToPeer },
          set: { model.setAllowsPeerToPeer($0) }))
      Button("Forget Approved iPhones") {
        model.forgetApprovedDevices()
      }
      .disabled(!model.hasApprovedDevices)
      Button("Show Logs in Finder") {
        model.showLogs()
      }
    }

    Divider()

    Button("Quit Souris") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}

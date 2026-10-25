import SwiftUI

/// The menu-bar app. There is no window; everything lives in the menu.
@main
struct SourisMacApp: App {
  @State private var model: MacModel

  init() {
    let model = MacModel()
    _model = State(initialValue: model)
    // Deferred so the server and the permission prompt start after launch has finished.
    Task { @MainActor in
      model.start()
    }
  }

  var body: some Scene {
    MenuBarExtra("Souris", systemImage: model.menuBarSymbol) {
      MenuContent(model: model)
    }
    .menuBarExtraStyle(.menu)
  }
}

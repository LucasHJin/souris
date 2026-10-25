import SwiftUI

@main
struct SourisPhoneApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      MainView(model: model)
    }
  }
}

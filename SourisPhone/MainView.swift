import SwiftUI

/// The only screen: a flat grey touch surface, with the status in the palm zone at the bottom.
struct MainView: View {
  @Bindable var model: AppModel
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    ZStack {
      Color(white: 0.18)
      VolumeViewHost(buttons: model.volumeButtons)
        .frame(width: 1, height: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      TouchSurface(controller: model.touchController)
      TouchAreaGuide(touch: model.settings.touch, controller: model.touchController)
      StatusColumn(model: model)
      settingsButton
    }
    .ignoresSafeArea()
    .statusBarHidden()
    .persistentSystemOverlays(.hidden)
    .defersSystemGestures(on: .all)
    .preferredColorScheme(.dark)
    .sheet(isPresented: $model.isSettingsPresented) {
      SettingsView(model: model)
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      model.scenePhaseDidChange(to: phase)
    }
  }

  private var settingsButton: some View {
    Button {
      model.isSettingsPresented = true
    } label: {
      Image(systemName: "gearshape")
        .font(.system(size: 18))
        .foregroundStyle(.secondary)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Settings")
    // Top-right, clear of the palm. It sits in the click area, but a touch on it goes to the
    // button, never to the touch surface.
    .padding(.top, 10)
    .padding(.trailing, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
  }
}

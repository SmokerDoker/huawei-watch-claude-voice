import SwiftUI

@main
struct HuaSideloadApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PhoneRinger.shared.prepareNotifications()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            // opening the app stops a "find phone" alarm
            if phase == .active {
                PhoneRinger.shared.stop(notifyWatch: true)
                CameraRemote.shared.appBecameActive()
            }
        }
    }
}

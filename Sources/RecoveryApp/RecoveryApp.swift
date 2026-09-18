import SwiftUI

@main
struct RecoveryApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 580)
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            AppSettingsView()
        }
    }
}

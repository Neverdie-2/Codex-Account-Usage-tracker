import SwiftUI

@main
struct CodexAccountTrackerApp: App {
    @StateObject private var viewModel = AccountTrackerViewModel()

    var body: some Scene {
        WindowGroup("Codex Account Tracker") {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 860, minHeight: 620)
                .task {
                    await viewModel.start()
                }
        }
        .windowStyle(.titleBar)

        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .frame(width: 520)
                .padding()
        }
    }
}

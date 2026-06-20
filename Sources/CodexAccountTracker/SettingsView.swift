import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var viewModel: AccountTrackerViewModel

    var body: some View {
        Form {
            TextField("Codex app-server URL", text: $viewModel.endpointText)
                .textFieldStyle(.roundedBorder)
            LabeledContent("Default mode", value: "Connect-only manual refresh")
            LabeledContent("Live refresh interval", value: "\(Int(viewModel.refreshIntervalSeconds)) seconds")
            LabeledContent("Storage", value: viewModel.storagePath)
            LabeledContent("Cursor API base", value: "https://cursor.com")
            LabeledContent("Cursor usage cache", value: "cursor-usage-cache.json")
            LabeledContent("Cursor accounts", value: "cursor-accounts.json")
            Picker("Cursor usage window", selection: $viewModel.cursorUsageScanMode) {
                ForEach(CodexUsageScanMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }
}

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
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }
}

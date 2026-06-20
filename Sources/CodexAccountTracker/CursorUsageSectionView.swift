import AppKit
import SwiftUI

/// TABLE 1 — Cursor usage. One card listing local Cursor conversations
/// (composers) scanned from `state.vscdb`, plus the "models used today" chip
/// row. Mirrors the `CodexLogUsageSectionView` card chrome.
struct CursorUsageSectionView: View {
    @EnvironmentObject private var viewModel: AccountTrackerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cursor Usage")
                        .font(.headline)
                    Text("Local Cursor conversations from state.vscdb — model, messages, AI lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Window", selection: $viewModel.cursorUsageWindow) {
                    ForEach(CursorUsageTimeWindow.allCases) { window in
                        Text(window.label).tag(window)
                    }
                }
                .labelsHidden()
                .controlSize(.large)
                .frame(width: 167)

                Button {
                    viewModel.refreshCursorUsage()
                } label: {
                    Label(
                        viewModel.isCursorUsageRefreshing ? "Refreshing" : "Refresh",
                        systemImage: "arrow.clockwise"
                    )
                }
                .controlSize(.large)
                .disabled(viewModel.isCursorUsageRefreshing)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Models used today")
                    .font(CursorUsageFont.captionSemibold)
                    .foregroundStyle(.secondary)

                if viewModel.cursorUsage.modelsUsedToday.isEmpty {
                    Text("No models used today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(viewModel.cursorUsage.modelsUsedToday, id: \.self) { model in
                            CursorUsageChip(text: model)
                        }
                    }
                }
            }

            CursorUsageTableView(
                records: viewModel.cursorUsage.records,
                summary: viewModel.cursorUsage.summary
            )
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

private struct CursorUsageTableView: View {
    let records: [CursorUsageRecord]
    let summary: CursorUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CursorUsageHeaderRow()

            if !summary.databaseFound {
                CursorUsageMissingDatabaseView(warnings: summary.warnings)
            } else if records.isEmpty {
                Text("No Cursor conversations yet")
                    .font(CursorUsageFont.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                ForEach(records) { record in
                    Divider()
                    CursorUsageRow(record: record)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private enum CursorUsageColumnWidth {
    static let mode: CGFloat = 70
    static let models: CGFloat = 180
    static let msgs: CGFloat = 70
    static let linesAdded: CGFloat = 60
    static let linesRemoved: CGFloat = 60
    static let files: CGFloat = 50
    static let last: CGFloat = 160
}

private enum CursorUsageFont {
    static let caption = Font.system(size: 14)
    static let captionSemibold = Font.system(size: 14, weight: .semibold)
    static let captionMonospaced = Font.system(size: 14)
}

private struct CursorUsageHeaderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Project")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Title")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Mode")
                .frame(width: CursorUsageColumnWidth.mode, alignment: .leading)
            Text("Models")
                .frame(width: CursorUsageColumnWidth.models, alignment: .leading)
            Text("Msgs")
                .frame(width: CursorUsageColumnWidth.msgs, alignment: .trailing)
            Text("+L")
                .frame(width: CursorUsageColumnWidth.linesAdded, alignment: .trailing)
            Text("-L")
                .frame(width: CursorUsageColumnWidth.linesRemoved, alignment: .trailing)
            Text("Files")
                .frame(width: CursorUsageColumnWidth.files, alignment: .trailing)
            Text("Last")
                .frame(width: CursorUsageColumnWidth.last, alignment: .trailing)
        }
        .font(CursorUsageFont.captionSemibold)
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
    }
}

private struct CursorUsageRow: View {
    let record: CursorUsageRecord

    var body: some View {
        HStack(spacing: 8) {
            Text(record.workspace.name)
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(record.title)
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(record.mode)
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: CursorUsageColumnWidth.mode, alignment: .leading)
            Text(record.modelSummary)
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: CursorUsageColumnWidth.models, alignment: .leading)
            Text("\(record.userCount)+\(record.assistantCount)")
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: CursorUsageColumnWidth.msgs, alignment: .trailing)
            Text("\(record.linesAdded)")
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: CursorUsageColumnWidth.linesAdded, alignment: .trailing)
            Text("\(record.linesRemoved)")
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: CursorUsageColumnWidth.linesRemoved, alignment: .trailing)
            Text("\(record.filesChanged)")
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: CursorUsageColumnWidth.files, alignment: .trailing)
            Text(DateFormats.display(date: record.lastActivity))
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(width: CursorUsageColumnWidth.last, alignment: .trailing)
        }
        .font(CursorUsageFont.captionMonospaced)
        .padding(.vertical, 6)
    }
}

private struct CursorUsageMissingDatabaseView: View {
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Cursor database not found. Expected at \(CursorStateDBReader.defaultDatabaseURL().path)",
                systemImage: "exclamationmark.triangle"
            )
            .font(CursorUsageFont.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(CursorUsageFont.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
}

private struct CursorUsageChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.13))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
            .textSelection(.enabled)
    }
}

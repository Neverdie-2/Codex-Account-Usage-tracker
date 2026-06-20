import AppKit
import SwiftUI

/// TABLE 2 — the signed-in Cursor account(s) and their monthly included-usage
/// limits, fetched from cursor.com. Mirrors the account-card chrome and the
/// QuotaPanel/FixedColorProgressBar look from `ContentView`, but bound to the
/// Cursor view-model surface (`viewModel.cursorAccounts`).
struct CursorLimitsSectionView: View {
    @EnvironmentObject private var viewModel: AccountTrackerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cursor Account Limits")
                        .font(.headline)
                    Text("Monthly included-usage cycle from cursor.com")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    viewModel.refreshCursorLimits()
                } label: {
                    Label(
                        viewModel.isCursorLimitsRefreshing ? "Refreshing" : "Refresh",
                        systemImage: "arrow.clockwise"
                    )
                }
                .controlSize(.large)
                .disabled(viewModel.isCursorLimitsRefreshing)
            }

            if viewModel.cursorAccounts.isEmpty {
                Text("No Cursor account signed in yet. Open Cursor and sign in, then Refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                    .padding(16)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
            } else {
                ForEach(viewModel.cursorAccounts) { account in
                    CursorAccountCardView(account: account, displayNow: viewModel.displayNow)
                }
            }
        }
        .textSelection(.enabled)
    }
}

private struct CursorAccountCardView: View {
    let account: CursorAccountRecord
    let displayNow: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.email)
                    .font(.system(size: 14.5, weight: .semibold))
                    .textSelection(.enabled)

                Spacer()

                CursorPlanPill(text: account.membershipType.uppercased())
                if account.stale {
                    CursorStatusPill(text: "Stale")
                }
            }

            if account.isUnlimited {
                Text("Unlimited")
                    .font(.title2.weight(.semibold))
            } else {
                billingCyclePanel
            }

            onDemandRow

            if let status = account.subscriptionStatus, !status.isEmpty {
                Text(status)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let cancels = account.pendingCancellationDate, !cancels.isEmpty {
                Text("Cancels \(cancels)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Last updated \(account.lastSeenAt)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(16)
        .textSelection(.enabled)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private var billingCyclePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(percentText(account.totalPercentUsed)) used")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(quotaColor)
                Text("remaining \(percentText(account.pctRemaining))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            CursorProgressBar(value: account.totalPercentUsed ?? 0, total: 100, color: quotaColor)

            Text("Included \(amt(account.includedAmount)) + Bonus \(amt(account.bonusAmount)) = Total \(amt(account.totalAmount))")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("Resets \(DateFormats.display(date: account.billingCycleEndDate))  (\(CursorAccountRecord.formatCountdown(account.resetCountdown(now: displayNow) ?? 0)))")
                .font(.system(size: 14))
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var onDemandRow: some View {
        if account.onDemandEnabled {
            Text("On-demand: used \(amt(account.onDemandUsed)) of \(amt(account.onDemandLimit))")
                .font(.system(size: 14))
                .textSelection(.enabled)
        } else {
            Text("On-demand: off")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }

    /// Green / amber / red by remaining headroom, matching `QuotaPanel`.
    private var quotaColor: Color {
        guard let remaining = account.pctRemaining else { return .secondary }
        if remaining > 25 { return .green }
        if remaining > 10 { return Color(red: 0.95, green: 0.72, blue: 0.16) }
        return .red
    }

    /// Format a `Double?` percentage to one decimal place, or `--%`.
    private func percentText(_ value: Double?) -> String {
        guard let value else { return "--%" }
        return String(format: "%.1f%%", value)
    }

    /// Format a `Double?` amount with no decimals, or `--`.
    private func amt(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.0f", value)
    }
}

/// Mirrors `FixedColorProgressBar` from `ContentView` (file-private there).
private struct CursorProgressBar: View {
    let value: Double
    let total: Double
    let color: Color

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(value / total, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, proxy.size.width * fraction))
            }
        }
        .frame(height: 5)
        .accessibilityLabel("Used quota")
        .accessibilityValue("\(Int((fraction * 100).rounded()))%")
    }
}

/// Mirrors `StatusPill` from `ContentView` (file-private there).
private struct CursorStatusPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.13))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
    }
}

/// Mirrors `PlanPill` from `ContentView` (file-private there). The caller passes
/// an already-uppercased string.
private struct CursorPlanPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Color(nsColor: .separatorColor))
            }
    }
}

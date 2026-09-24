import SwiftUI

extension ContentView {
    var usageContainer: some View {
        let notchWidth = min(configuredIdleIslandWidth, layout.closedSize.width)
        return IslandContainerView(
            size: layout.closedSize,
            cornerRadius: layout.cornerRadius,
            spacing: layout.spacing
        ) {
            CodexBackgroundActivityStatusView(
                size: layout.closedSize,
                notchWidth: notchWidth,
                fiveHourText: compactUsageText(codexUsageManager.fiveHour),
                weeklyText: compactUsageText(codexUsageManager.weekly),
                showsUsage: settingsManager.enableCodexUsageSync
            )
        }
        .accessibilityLabel("Codex running. Five hour \(usageText(codexUsageManager.fiveHour)), weekly \(usageText(codexUsageManager.weekly))")
    }

    private func compactUsageText(_ window: CodexUsageWindow) -> String {
        window.visiblePercent.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    private func usageText(_ window: CodexUsageWindow) -> String {
        window.visiblePercent.map { "\(Int(($0 * 100).rounded()))% used" } ?? "unavailable"
    }
}

struct CodexBackgroundActivityStatusView: View {
    let size: CGSize
    let notchWidth: CGFloat
    let fiveHourText: String
    let weeklyText: String
    let showsUsage: Bool

    private var sideWidth: CGFloat { max(0, (size.width - notchWidth) / 2) }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                Circle()
                    .fill(.mint)
                    .frame(width: 5, height: 5)
                Text("Codex")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.system(size: 10, weight: .semibold))
            .frame(width: sideWidth, height: size.height)
            .clipped()

            Spacer(minLength: notchWidth)

            if showsUsage {
                VStack(spacing: 0) {
                    Text("5h \(fiveHourText)")
                    Text("7d \(weeklyText)")
                }
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: sideWidth, height: size.height)
                .clipped()
            } else {
                Color.clear.frame(width: sideWidth)
            }
        }
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height)
        .accessibilityLabel("Codex running. Five hour \(fiveHourText), weekly \(weeklyText)")
    }
}

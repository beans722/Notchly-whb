import SwiftUI

extension ContentView {
    var focusStatusContainer: some View {
        let physicalNotchWidth = IslandWidthResolver.notchWidth(for: currentScreen) ?? 0
        let width = min(max(layout.closedSize.width, physicalNotchWidth + 144), 360)
        let size = CGSize(width: width, height: closedHeight)
        let sideWidth = max(0, (width - physicalNotchWidth) / 2)

        return IslandContainerView(
            size: size,
            cornerRadius: layout.cornerRadius,
            spacing: layout.spacing
        ) {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    if let pet = focusSessionManager.selectedPet {
                        FocusPetView(pet: pet, size: 23, isActive: true)
                    } else {
                        Image(systemName: "timer")
                            .foregroundStyle(.mint)
                    }
                    Text(focusSessionManager.phase == .paused ? "已暂停" : "专注中")
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                }
                .frame(width: sideWidth, height: size.height)
                .clipped()

                Spacer(minLength: physicalNotchWidth)

                FocusCountdownView(
                    manager: focusSessionManager,
                    showsExactTime: isHovered || focusSessionManager.alwaysShowsExactTime
                )
                    .frame(width: sideWidth, height: size.height, alignment: .trailing)
                    .clipped()
            }
            .foregroundStyle(.white)
            .frame(width: size.width, height: size.height)
        }
    }

    var usageContainer: some View {
        let physicalNotchWidth = IslandWidthResolver.notchWidth(for: currentScreen) ?? 0
        let width = min(max(layout.closedSize.width, physicalNotchWidth + 144), 360)
        let size = CGSize(width: width, height: closedHeight)
        return IslandContainerView(
            size: size,
            cornerRadius: layout.cornerRadius,
            spacing: layout.spacing
        ) {
            CodexBackgroundActivityStatusView(
                size: size,
                notchWidth: min(physicalNotchWidth, size.width),
                fiveHourText: compactUsageText(codexUsageManager.fiveHour),
                weeklyText: compactUsageText(codexUsageManager.weekly),
                showsUsage: settingsManager.enableCodexUsageSync,
                pet: focusSessionManager.selectedPet,
                focusManager: focusSessionManager,
                showsFocusExactTime: isHovered || focusSessionManager.alwaysShowsExactTime
            )
        }
        .accessibilityLabel(
            focusSessionManager.phase == .idle
                ? "Codex running. Five hour \(usageText(codexUsageManager.fiveHour)), weekly \(usageText(codexUsageManager.weekly))"
                : "Codex running. Focus countdown \(Int(ceil(focusSessionManager.remainingSeconds))) seconds"
        )
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
    let pet: FocusPet?
    @ObservedObject var focusManager: FocusSessionManager
    let showsFocusExactTime: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var sideWidth: CGFloat { max(0, (size.width - notchWidth) / 2) }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                if let pet {
                    FocusPetView(pet: pet, size: 23, isActive: true)
                        .frame(width: 23, height: 25)
                } else {
                    ZStack {
                        Circle()
                            .stroke(.mint.opacity(reduceMotion ? 0 : 0.55), lineWidth: 1)
                            .frame(width: 8, height: 8)
                            .scaleEffect(pulse && !reduceMotion ? 1.55 : 0.8)
                            .opacity(pulse && !reduceMotion ? 0 : 1)
                        Circle()
                            .fill(.mint)
                            .frame(width: 5, height: 5)
                    }
                    .frame(width: 10, height: 10)
                }
                Text("Codex")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.system(size: 10, weight: .semibold))
            .frame(width: sideWidth, height: size.height)
            .clipped()

            Spacer(minLength: notchWidth)

            if focusManager.phase != .idle {
                FocusCountdownView(manager: focusManager, showsExactTime: showsFocusExactTime)
                    .frame(width: sideWidth, height: size.height, alignment: .trailing)
                    .clipped()
            } else if showsUsage {
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
        .accessibilityLabel(
            focusManager.phase == .idle
                ? "Codex running. Five hour \(fiveHourText), weekly \(weeklyText)"
                : "Codex running. Focus countdown \(Int(ceil(focusManager.remainingSeconds))) seconds"
        )
        .onAppear {
            guard pet == nil, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.15).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

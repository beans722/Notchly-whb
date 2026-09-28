import SwiftUI

struct FocusControlsView: View {
    @ObservedObject var manager: FocusSessionManager
    @Binding var isExpanded: Bool
    let showsCompletionNotice: Bool
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: showsCompletionNotice ? "checkmark.circle.fill" : "timer")
                    .foregroundStyle(showsCompletionNotice ? .mint : .white.opacity(0.8))

                Text(headerText)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("专注")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 25)
                    .background(.white.opacity(0.13), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起专注设置" : "展开专注设置")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)

            if isExpanded {
                Rectangle()
                    .fill(.white.opacity(0.12))
                    .frame(height: 1)
                    .padding(.horizontal, 12)

                VStack(spacing: 11) {
                    HStack(spacing: 6) {
                        ForEach(FocusSessionManager.availableMinutes, id: \.self) { minutes in
                            Button("\(minutes) 分钟") {
                                manager.setTargetMinutes(minutes)
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(manager.targetMinutes == minutes ? .black : .white.opacity(0.8))
                            .frame(maxWidth: .infinity)
                            .frame(height: 25)
                            .background(
                                manager.targetMinutes == minutes ? Color.mint : Color.white.opacity(0.11),
                                in: Capsule()
                            )
                            .buttonStyle(.plain)
                            .disabled(manager.phase != .idle)
                        }
                    }

                    HStack(spacing: 8) {
                        Text(manager.phase == .idle ? "满 15 分钟计入累计" : "剩余 \(clockText(manager.remainingSeconds))")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.75))

                        Spacer(minLength: 4)

                        if manager.phase != .idle {
                            Button("结束") { manager.finishEarly() }
                                .foregroundStyle(.white.opacity(0.72))
                                .accessibilityLabel("结束并结算专注")
                        }

                        Button(primaryActionTitle) { performPrimaryAction() }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(.mint, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))

                    HStack {
                        Text("累计专注 \(durationText(manager.totalSeconds))")
                        Spacer()
                        Text(unlockHint)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))

                    HStack(spacing: 8) {
                        preferenceButton(
                            "专注时歌词",
                            isOn: manager.showsLyricsDuringFocus
                        ) {
                            manager.setShowsLyricsDuringFocus(!manager.showsLyricsDuringFocus)
                        }
                        preferenceButton(
                            "时间常显",
                            isOn: manager.alwaysShowsExactTime
                        ) {
                            manager.setAlwaysShowsExactTime(!manager.alwaysShowsExactTime)
                        }
                    }

                    HStack(spacing: 8) {
                        ForEach(FocusPet.allCases) { pet in
                            petCard(for: pet)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
        }
        .frame(width: width)
        .background(.black, in: UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 15,
            bottomTrailingRadius: 15,
            topTrailingRadius: 0,
            style: .continuous
        ))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .foregroundStyle(.white)
    }

    private var headerText: String {
        if showsCompletionNotice { return "专注完成" }
        if manager.phase == .running { return "专注中 · \(clockText(manager.remainingSeconds))" }
        if manager.phase == .paused { return "已暂停 · \(clockText(manager.remainingSeconds))" }
        return "开始一次专注"
    }

    private var primaryActionTitle: String {
        switch manager.phase {
        case .idle: return "开始"
        case .running: return "暂停"
        case .paused: return "继续"
        }
    }

    private var unlockHint: String {
        switch manager.unlockPolicy {
        case .preview: return "测试版：两只均需 15 分钟"
        case .publicRelease: return "豆子 10 小时 · 小牛 100 小时"
        }
    }

    private func performPrimaryAction() {
        switch manager.phase {
        case .idle: manager.start()
        case .running: manager.pause()
        case .paused: manager.resume()
        }
    }

    private func preferenceButton(
        _ title: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? .mint : .white.opacity(0.5))
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 25)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(isOn ? "已开启" : "已关闭")")
    }

    private func petCard(for pet: FocusPet) -> some View {
        let isClaimed = manager.claimedPets.contains(pet)
        let isSelected = manager.selectedPet == pet
        let isAvailable = manager.canClaim(pet)

        return Button {
            if isClaimed {
                manager.select(pet)
            } else if isAvailable {
                manager.claim(pet)
            }
        } label: {
            HStack(spacing: 3) {
                FocusPetView(pet: pet, size: 37, isActive: false)
                    .frame(width: 37, height: 37)

                VStack(alignment: .leading, spacing: 3) {
                    Text(pet == .jumpingBean ? "跳跃豆子" : "小牛")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(isSelected ? "使用中" : isClaimed ? "使用" : isAvailable ? "领取" : "未解锁")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isAvailable || isSelected ? .mint : .white.opacity(0.56))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                isSelected ? Color.mint.opacity(0.16) : Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isClaimed && !isAvailable)
        .accessibilityLabel("\(pet.title), \(isSelected ? "使用中" : isClaimed ? "可切换" : isAvailable ? "可领取" : "未解锁")")
    }

    private func clockText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)小时\(minutes % 60)分" : "\(minutes)分"
    }
}

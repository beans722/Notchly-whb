import SwiftUI

struct FocusCountdownView: View {
    @ObservedObject var manager: FocusSessionManager
    let showsExactTime: Bool

    private var remaining: Int { max(0, Int(ceil(manager.remainingSeconds))) }
    private var fraction: CGFloat {
        let target = max(1, manager.targetMinutes * 60)
        return CGFloat(min(1, max(0, manager.remainingSeconds / Double(target))))
    }
    private var isPaused: Bool { manager.phase == .paused }
    private var tint: Color {
        isPaused ? Color(red: 1, green: 0.67, blue: 0.30) : Color(red: 0.96, green: 0.32, blue: 0.28)
    }

    var body: some View {
        HStack(spacing: 5) {
            SegmentedRemainingRing(fraction: fraction, tint: tint)
            .frame(width: 26, height: 26)
            .animation(.linear(duration: 0.9), value: fraction)

            if showsExactTime {
                Text(String(format: "%02d:%02d", remaining / 60, remaining % 60))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPaused ? "专注已暂停，剩余 \(remaining / 60) 分 \(remaining % 60) 秒" : "专注剩余 \(remaining / 60) 分 \(remaining % 60) 秒")
    }
}

private struct SegmentedRemainingRing: View {
    let fraction: CGFloat
    let tint: Color
    private let segmentCount = 16

    var body: some View {
        ZStack {
            ForEach(0..<segmentCount, id: \.self) { index in
                RingSegment(index: index, count: segmentCount, filledFraction: 1)
                    .fill(.white.opacity(0.14))
                RingSegment(
                    index: index,
                    count: segmentCount,
                    filledFraction: min(1, max(0, fraction * CGFloat(segmentCount) - CGFloat(index)))
                )
                .fill(tint)
                .shadow(color: tint.opacity(0.25), radius: 1.5)
            }
            Circle()
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.6)
                .padding(5.5)
        }
        .accessibilityHidden(true)
    }
}

private struct RingSegment: Shape {
    let index: Int
    let count: Int
    var filledFraction: CGFloat

    var animatableData: CGFloat {
        get { filledFraction }
        set { filledFraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(filledFraction, 0), 1)
        guard clamped > 0 else { return Path() }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * 0.56
        let step = 360.0 / Double(count)
        let gap = 2.2
        let start = -90.0 + Double(index) * step + gap / 2
        let end = start + (step - gap) * Double(clamped)
        var path = Path()
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: .degrees(start),
            endAngle: .degrees(end),
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: .degrees(end),
            endAngle: .degrees(start),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}

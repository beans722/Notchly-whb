//
//  CompactMusicView.swift
//  Notchly
//
//  Created by n0xbyte on 25.03.2026.
//

import SwiftUI
import AppKit

struct CompactMusicView: View {
    let artwork: NSImage?
    let waveformColor: Color
    let isPlaying: Bool
    let size: CGSize
    let hoverOffsetY: CGFloat
    let skipIndicator: String?
    let fiveHourUsage: CodexUsageWindow
    let weeklyUsage: CodexUsageWindow
    let showsUsage: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }

            Spacer()

            if showsUsage {
                Text("5h \(format(fiveHourUsage))  7d \(format(weeklyUsage))")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            MusicWaveformView(
                isPlaying: isPlaying,
                color: waveformColor,
                skipIndicator: skipIndicator
            )
            .frame(width: 36, height: 18)
        }
        .padding(.horizontal, 12)
        .frame(width: size.width, height: size.height)
        .offset(y: hoverOffsetY)
    }

    private func format(_ window: CodexUsageWindow) -> String {
        window.visiblePercent.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }
}

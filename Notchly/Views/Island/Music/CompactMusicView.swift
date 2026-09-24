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
    let showsControls: Bool
    let isLivestream: Bool
    let onPrevious: () -> Void
    let onTogglePlay: () -> Void
    let onNext: () -> Void
    let onOpenPlayer: () -> Void

    private var leadingControls: some View {
        HStack(spacing: 2) {
            Button(action: onPrevious) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 27, height: 28)
            }
            .disabled(isLivestream)
            .accessibilityLabel("Previous track")
            .buttonStyle(IslandControlButtonStyle())

            Button(action: onTogglePlay) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 29, height: 28)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            .buttonStyle(IslandControlButtonStyle(pressedScale: 0.9))
        }
        .foregroundStyle(.white)
        .opacity(isLivestream ? 0.8 : 1)
    }

    private var nextControl: some View {
        Button(action: onNext) {
            Image(systemName: "forward.fill")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 27, height: 28)
        }
        .disabled(isLivestream)
        .accessibilityLabel("Next track")
        .buttonStyle(IslandControlButtonStyle())
        .opacity(isLivestream ? 0.8 : 1)
    }

    var body: some View {
        HStack(spacing: 10) {
            if showsControls {
                leadingControls
                    .transition(.opacity)
            } else {
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
            }

            Spacer()

            if showsUsage {
                Text("5h \(format(fiveHourUsage))  7d \(format(weeklyUsage))")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpenPlayer)
            }

            if showsControls {
                nextControl
                    .transition(.opacity)
            } else {
                MusicWaveformView(
                    isPlaying: isPlaying,
                    color: waveformColor,
                    skipIndicator: skipIndicator
                )
                .frame(width: 36, height: 18)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenPlayer)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: size.width, height: size.height)
        .offset(y: hoverOffsetY)
        .animation(.easeInOut(duration: 0.14), value: showsControls)
    }

    private func format(_ window: CodexUsageWindow) -> String {
        window.visiblePercent.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }
}

struct CompactMusicLyricsRow: View {
    let lyricLine: String
    let isAccessibilityAvailable: Bool

    private var displayedLine: String {
        let trimmedLine = lyricLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLine.isEmpty {
            return trimmedLine
        }
        return isAccessibilityAvailable ? "Waiting for lyrics…" : "Enable Accessibility for lyrics"
    }

    var body: some View {
        Text(displayedLine)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: IslandLayout.compactLyricsRowHeight)
            .accessibilityLabel("Apple Music lyrics: \(displayedLine)")
    }
}

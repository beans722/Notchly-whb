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
    let notchWidth: CGFloat
    let hoverOffsetY: CGFloat
    let skipIndicator: String?
    let fiveHourUsage: CodexUsageWindow
    let weeklyUsage: CodexUsageWindow
    let showsUsage: Bool
    let showsControls: Bool
    let pet: FocusPet?
    @ObservedObject var focusManager: FocusSessionManager
    let showsFocusExactTime: Bool
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

    private var usageReadout: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("5h \(format(fiveHourUsage))")
            Text("7d \(format(weeklyUsage))")
        }
        .font(.system(size: 9, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.8))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("5 hour \(format(fiveHourUsage)), weekly \(format(weeklyUsage))")
    }

    private var leadingContent: some View {
        Group {
            if showsControls {
                HStack(spacing: 1) {
                    leadingControls
                    if focusManager.phase != .idle { nextControl }
                }
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
        }
    }

    private var notchLeadingContent: some View {
        Group {
            if showsControls {
                HStack(spacing: 1) {
                    leadingControls
                    nextControl
                }
                .transition(.opacity)
            } else if focusManager.phase != .idle, let pet {
                HStack(spacing: 5) {
                    artworkContent
                    FocusPetView(pet: pet, size: 23, isActive: isPlaying)
                }
            } else if showsUsage {
                HStack(spacing: 5) {
                    artworkContent
                    waveformContent
                }
            } else {
                artworkContent
            }
        }
    }

    @ViewBuilder
    private var artworkContent: some View {
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

    private var waveformContent: some View {
        Group {
            if let pet {
                FocusPetView(pet: pet, size: 26, isActive: isPlaying)
            } else {
                MusicWaveformView(
                    isPlaying: isPlaying,
                    color: waveformColor,
                    skipIndicator: skipIndicator
                )
            }
        }
        .frame(width: 36, height: 18)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenPlayer)
    }

    private var notchTrailingContent: some View {
        Group {
            if focusManager.phase != .idle {
                FocusCountdownView(manager: focusManager, showsExactTime: showsFocusExactTime)
            } else if showsUsage {
                usageReadout
            } else {
                waveformContent
            }
        }
    }

    private var trailingContent: some View {
        Group {
            if focusManager.phase != .idle {
                FocusCountdownView(manager: focusManager, showsExactTime: showsFocusExactTime)
            } else if showsControls {
                nextControl
                    .transition(.opacity)
            } else {
                waveformContent
            }
        }
    }

    var body: some View {
        let physicalNotchWidth = min(max(notchWidth, 0), size.width)
        let sideWidth = max(0, (size.width - physicalNotchWidth) / 2)

        Group {
            if physicalNotchWidth > 0 {
                HStack(spacing: 0) {
                    notchLeadingContent
                        .frame(width: sideWidth, alignment: .leading)
                        .clipped()

                    Spacer(minLength: physicalNotchWidth)

                    notchTrailingContent
                        .frame(width: sideWidth, alignment: .trailing)
                        .clipped()
                }
            } else {
                HStack(spacing: 10) {
                    leadingContent

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

                    trailingContent
                }
                .padding(.horizontal, 12)
            }
        }
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
    let emptyMessage: String

    private var displayedLine: String {
        let trimmedLine = lyricLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLine.isEmpty {
            return trimmedLine
        }
        return emptyMessage
    }

    var body: some View {
        Text(displayedLine)
            .accessibilityLabel("Apple Music lyrics: \(displayedLine)")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.78))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .frame(height: IslandLayout.compactLyricsRowHeight)
    }
}

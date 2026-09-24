//
//  MusicSettingsView.swift
//  Notchly
//
//  Created by n0xbyte on 01.04.2026.
//

import SwiftUI

struct MusicSettingsView: View {
    @ObservedObject var settingsManager: SettingsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                VStack(spacing: 0) {
                    SettingsToggleRow(
                        title: "Show Music",
                        subtitle: "Show Apple Music around the notch, with basic playback controls and lyrics.",
                        isOn: $settingsManager.showMusic
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: "Apple Music Lyrics",
                        subtitle: "Read only the lyric line currently visible in Music using macOS Accessibility.",
                        isOn: $settingsManager.showAppleMusicLyrics
                    )
                    .disabled(!settingsManager.showMusic)
                    .opacity(settingsManager.showMusic ? 1 : 0.45)
                }
            }

            Text("Lyrics stay on this Mac. Enable Notchly under System Settings > Privacy & Security > Accessibility before turning on Apple Music Lyrics.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

//
//  SettingsView.swift
//  Notchly
//
//  Created by n0xbyte on 16.03.2026.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var codexHookIntegrationManager: CodexHookIntegrationManager
    @ObservedObject var codexUsageManager: CodexUsageManager
    @State private var selectedSection: SettingsSection = .music

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 190)

            detail
        }
        .frame(width: 760, height: 560, alignment: .top)
        .background(SettingsBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    sidebarGroup(
                        title: "Live Activities",
                        sections: [.music, .codex]
                    )

                    sidebarGroup(
                        title: "Notchly",
                        sections: [.about]
                    )
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 34)
        .padding(.bottom, 16)
        .background(.black.opacity(0.12))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 1)
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            topBar

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    selectedContent
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 30)
                .padding(.top, 14)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading) {
                Text(selectedSection.rawValue)
                    .font(.system(size: 15, weight: .medium))

            }

            Spacer()

            if selectedSection == .about {
               EmptyView()
            } else {
                Button("Reset") {
                    resetSelectedSection()
                }
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(.black.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .buttonStyle(SubtleHoverButtonStyle(
                    pressedScale: 0.96,
                    hoverScale: 1.025,
                    hoverBackgroundOpacity: 0.08,
                    cornerRadius: 19
                ))
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 18)
        .padding(.top, 0)
        .padding(.bottom, 14)
        .frame(height: 70, alignment: .center)
        .background {
            ZStack {
                WindowDragHandle()
                Color.black.opacity(0.06)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.07))
                .frame(height: 1)
        }
    }

    private func sidebarGroup(title: String, sections: [SettingsSection]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)

            ForEach(sections) { section in
                sidebarButton(section)
            }
        }
    }

    private func sidebarButton(_ section: SettingsSection) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack(spacing: 6) {
                SettingsSidebarIconView(
                    systemName: section.iconName,
                    backgroundColor: section.iconColor
                )

                Text(section.rawValue)
                    .font(.system(size: 14, weight: .regular))

                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selectedSection == section ? Color.accentColor.opacity(0.65) : Color.clear)
            }
            .foregroundStyle(selectedSection == section ? .white : .primary)
        }
        .buttonStyle(SubtleHoverButtonStyle(
            pressedScale: 0.98,
            hoverScale: 1.01,
            hoverBackgroundOpacity: selectedSection == section ? 0 : 0.06,
            cornerRadius: 10
        ))
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .music:
            MusicSettingsView(settingsManager: settingsManager)

        case .codex:
            CodexSettingsView(
                settingsManager: settingsManager,
                codexHookIntegrationManager: codexHookIntegrationManager,
                codexUsageManager: codexUsageManager
            )
            
        case .about:
              AboutSettingsView()
          }
    }

    private func resetSelectedSection() {
        withAnimation(.easeInOut(duration: 0.18)) {
            switch selectedSection {
            case .about:
                break
            case .music:
                settingsManager.resetMusicSettings()
            case .codex:
                settingsManager.resetCodexSettings()
            }
        }
    }
}

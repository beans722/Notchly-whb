//
//  SettingsSection.swift
//  Notchly
//
//  Created by n0xbyte on 29.04.2026.
//

import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case music = "Now Playing"
    case codex = "Codex"
    case about = "About"

    var id: Self { self }

    var iconName: String {
        switch self {
        case .music:
            return "music.note"
        case .codex:
            return "sparkles"
        case .about:
            return "info.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .music:
            return .red
        case .codex:
            return .mint
        case .about:
            return .gray
        }
    }

    var subtitle: String {
        switch self {
        case .music:
            return "Customize now playing controls and previews."
        case .codex:
            return "Show background task status and usage limits."
        case .about:
            return "Version, links, and app information."
        }
    }
}

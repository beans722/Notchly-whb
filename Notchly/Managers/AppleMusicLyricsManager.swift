import AppKit
import ApplicationServices
import Combine

@MainActor
final class AppleMusicLyricsManager: ObservableObject {
    @Published private(set) var currentLine = ""
    @Published private(set) var isAccessibilityAvailable = AXIsProcessTrusted()

    private weak var musicManager: MusicManager?
    private weak var settingsManager: SettingsManager?
    private var refreshTask: Task<Void, Never>?

    init(musicManager: MusicManager, settingsManager: SettingsManager) {
        self.musicManager = musicManager
        self.settingsManager = settingsManager
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(0.8))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        currentLine = ""
    }

    private func refresh() {
        isAccessibilityAvailable = AXIsProcessTrusted()
        guard settingsManager?.showAppleMusicLyrics == true,
              musicManager?.currentSource == .appleMusic,
              isAccessibilityAvailable,
              let musicApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Music" }) else {
            currentLine = ""
            return
        }

        let ignored = Set([
            musicManager?.trackTitle ?? "", musicManager?.artistName ?? "", musicManager?.albumTitle ?? "",
            "Music", "Lyrics", "Now Playing", "Up Next", "Search", "Browse", "Radio", "Library"
        ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let values = collectText(from: AXUIElementCreateApplication(musicApp.processIdentifier), limit: 250)
        currentLine = values.first(where: { value in
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.count > 2 && text.count < 180 && !ignored.contains(text) && !text.allSatisfy({ $0.isNumber || $0 == ":" })
        }) ?? ""
    }

    private func collectText(from element: AXUIElement, limit: Int) -> [String] {
        var collected: [String] = []
        var visited = Set<CFHashCode>()

        func walk(_ item: AXUIElement) {
            guard collected.count < limit else { return }
            let identity = CFHash(item)
            guard visited.insert(identity).inserted else { return }
            for attribute in [kAXValueAttribute as String, kAXTitleAttribute as String, kAXDescriptionAttribute as String] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(item, attribute as CFString, &value) == .success,
                   let text = value as? String {
                    collected.append(text)
                }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &children) == .success,
               let elements = children as? [AXUIElement] {
                elements.forEach(walk)
            }
        }

        walk(element)
        return Array(NSOrderedSet(array: collected)) as? [String] ?? collected
    }
}

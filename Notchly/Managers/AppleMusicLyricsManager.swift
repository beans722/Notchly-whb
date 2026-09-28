import Foundation
import Combine

@MainActor
final class AppleMusicLyricsManager: ObservableObject {
    @Published private(set) var currentLine = ""
    @Published private(set) var lyricStatus = "Waiting for synced lyrics…"

    private weak var musicManager: MusicManager?
    private weak var settingsManager: SettingsManager?
    private var refreshTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var loadedTrackIdentity: String?
    private var lastCacheLookupAt: Date?
    private var timedLyrics: [TimedLyric] = []

    init(musicManager: MusicManager, settingsManager: SettingsManager) {
        self.musicManager = musicManager
        self.settingsManager = settingsManager
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        cacheTask?.cancel()
        cacheTask = nil
        loadedTrackIdentity = nil
        lastCacheLookupAt = nil
        timedLyrics = []
        currentLine = ""
        lyricStatus = "Waiting for synced lyrics…"
    }

    private func refresh() {
        guard settingsManager?.showAppleMusicLyrics == true,
              let musicManager,
              musicManager.currentSource == .appleMusic,
              musicManager.isPlaying else {
            currentLine = ""
            lyricStatus = "Waiting for synced lyrics…"
            return
        }

        let trackIdentity = musicManager.currentTrackIdentity
        let shouldRetryCacheRead = timedLyrics.isEmpty &&
            Date().timeIntervalSince(lastCacheLookupAt ?? .distantPast) >= 30
        if loadedTrackIdentity != trackIdentity || shouldRetryCacheRead {
            loadLyrics(for: musicManager, identity: trackIdentity)
        }

        let position = musicManager.playbackPosition / 1_000
        currentLine = timedLyrics.first(where: { $0.start <= position && position < $0.end })?.text ?? ""
        if !timedLyrics.isEmpty {
            lyricStatus = "Waiting for synced lyrics…"
        } else if cacheTask != nil {
            lyricStatus = "Checking local Apple Music cache…"
        } else {
            lyricStatus = "No synced lyrics in local cache"
        }
    }

    private func loadLyrics(for musicManager: MusicManager, identity: String) {
        cacheTask?.cancel()
        loadedTrackIdentity = identity
        lastCacheLookupAt = Date()
        timedLyrics = []
        currentLine = ""
        lyricStatus = "Checking local Apple Music cache…"

        let title = musicManager.trackTitle
        let artist = musicManager.artistName
        let duration = musicManager.durationMs
        let loadTask = Task.detached(priority: .utility) {
            LocalAppleMusicLyricsCache.load(title: title, artist: artist, durationMs: duration)
        }
        cacheTask = Task { @MainActor [weak self] in
            let result = await loadTask.value
            guard let self,
                  self.musicManager?.currentTrackIdentity == identity else { return }
            self.timedLyrics = result
            self.cacheTask = nil
            self.lyricStatus = result.isEmpty ? "No synced lyrics in local cache" : "Waiting for synced lyrics…"
            self.refresh()
        }
    }
}

private struct TimedLyric: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Reads only Apple Music's existing on-disk response cache. It performs no requests.
nonisolated private enum LocalAppleMusicLyricsCache {
    static func load(title: String, artist: String, durationMs: Double) -> [TimedLyric] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.apple.Music/fsCachedData", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let normalizedTitle = normalize(title)
        let normalizedArtist = normalize(artist)
        guard !normalizedTitle.isEmpty, !normalizedArtist.isEmpty else { return [] }

        for file in files {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size < 2_000_000,
                  let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let songs = root["data"] as? [[String: Any]] else { continue }

            for song in songs {
                guard let attributes = song["attributes"] as? [String: Any],
                      let cachedTitle = attributes["name"] as? String,
                      let cachedArtist = attributes["artistName"] as? String,
                      normalize(cachedTitle) == normalizedTitle,
                      normalize(cachedArtist) == normalizedArtist,
                      durationMatches(attributes["durationInMillis"], currentDurationMs: durationMs),
                      let relationships = song["relationships"] as? [String: Any],
                      let lyricRelationship = relationships["syllable-lyrics"] as? [String: Any],
                      let lyricData = lyricRelationship["data"] as? [[String: Any]],
                      let lyricAttributes = lyricData.first?["attributes"] as? [String: Any],
                      let ttml = lyricAttributes["ttmlLocalizations"] as? String else { continue }

                return parse(ttml)
            }
        }
        return []
    }

    private static func durationMatches(_ value: Any?, currentDurationMs: Double) -> Bool {
        guard currentDurationMs > 0,
              let cachedDuration = value as? Double,
              cachedDuration > 0 else { return true }
        return abs(cachedDuration - currentDurationMs) <= 2_500
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func parse(_ ttml: String) -> [TimedLyric] {
        guard let data = ttml.data(using: .utf8) else { return [] }
        let delegate = TTMLLineParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.lines.sorted { $0.start < $1.start }
    }
}

nonisolated private final class TTMLLineParser: NSObject, XMLParserDelegate {
    private(set) var lines: [TimedLyric] = []
    private var currentStart: TimeInterval?
    private var currentEnd: TimeInterval?
    private var currentText = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "p" else { return }
        currentStart = attributeDict["begin"].flatMap(Self.time)
        currentEnd = attributeDict["end"].flatMap(Self.time)
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentStart != nil else { return }
        currentText.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "p",
              let start = currentStart,
              let end = currentEnd,
              end > start else { return }
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            lines.append(TimedLyric(start: start, end: end, text: text))
        }
        currentStart = nil
        currentEnd = nil
        currentText = ""
    }

    private static func time(_ rawValue: String) -> TimeInterval? {
        let value = rawValue.hasSuffix("s") ? String(rawValue.dropLast()) : rawValue
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reversed().enumerated().reduce(0) { total, component in
            total + component.element * pow(60, Double(component.offset))
        }
    }
}

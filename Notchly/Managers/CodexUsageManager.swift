import Foundation
import Combine

struct CodexUsageWindow: Equatable {
    let usedPercent: Double?
    let resetAt: Date?
    static let unavailable = CodexUsageWindow(usedPercent: nil, resetAt: nil)

    var visiblePercent: Double? {
        if let resetAt, resetAt <= Date() { return nil }
        return usedPercent
    }
}

@MainActor
final class CodexUsageManager: ObservableObject {
    @Published private(set) var fiveHour = CodexUsageWindow.unavailable
    @Published private(set) var weekly = CodexUsageWindow.unavailable
    @Published private(set) var errorMessage: String?

    private let settingsManager: SettingsManager
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    private var isRefreshing = false

    init(settingsManager: SettingsManager) { self.settingsManager = settingsManager }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.settingsManager.enableCodexUsageSync { await self.refreshIfNeeded() }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func stop() { refreshTask?.cancel(); refreshTask = nil }

    func refreshIfNeeded(force: Bool = false) async {
        guard settingsManager.enableCodexUsageSync, !isRefreshing,
              force || Date().timeIntervalSince(lastRefresh) >= 300 else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastRefresh = Date()
        guard let token = readAccessToken() else {
            fiveHour = .unavailable; weekly = .unavailable
            errorMessage = "Codex sign-in is unavailable"; return
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rateLimit = object["rate_limit"] as? [String: Any] else {
                if status == 401 { fiveHour = .unavailable; weekly = .unavailable }
                errorMessage = status == 401 ? "Codex sign-in expired" : "Usage is temporarily unavailable"; return
            }
            var nextFive = CodexUsageWindow.unavailable
            var nextWeek = CodexUsageWindow.unavailable
            for (index, key) in ["primary_window", "secondary_window"].enumerated() {
                guard let value = rateLimit[key] as? [String: Any] else { continue }
                guard let rawPercent = (value["used_percent"] as? NSNumber)?.doubleValue,
                      rawPercent.isFinite, (0...100).contains(rawPercent) else { continue }
                let window = CodexUsageWindow(
                    usedPercent: rawPercent / 100,
                    resetAt: (value["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                )
                let span = (value["limit_window_seconds"] as? NSNumber)?.doubleValue
                if (span ?? (index == 0 ? 18_000 : 604_800)) >= 86_400 {
                    if nextWeek.usedPercent == nil { nextWeek = window }
                } else if nextFive.usedPercent == nil { nextFive = window }
            }
            fiveHour = nextFive; weekly = nextWeek; errorMessage = nil
        } catch { errorMessage = "Usage refresh failed" }
    }

    private func readAccessToken() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any] else { return nil }
        return tokens["access_token"] as? String
    }
}

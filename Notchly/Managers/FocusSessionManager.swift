import AppKit
import Combine
import Foundation

enum FocusPet: String, CaseIterable, Identifiable {
    case jumpingBean
    case calf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jumpingBean: return "Jumping Bean"
        case .calf: return "Little Calf"
        }
    }

    var imageName: String {
        switch self {
        case .jumpingBean: return "FocusJumpingBean"
        case .calf: return "FocusLittleCalf"
        }
    }
}

enum FocusSessionPhase {
    case idle
    case running
    case paused
}

enum FocusPetUnlockPolicy {
    case preview
    case publicRelease

    // This fork is currently a tester build. A public release must define
    // NOTCHLY_PUBLIC_RELEASE so the agreed 10h/100h thresholds take effect.
    static var current: Self {
        #if NOTCHLY_PUBLIC_RELEASE
        .publicRelease
        #else
        .preview
        #endif
    }

    func requiredSeconds(for pet: FocusPet) -> TimeInterval {
        switch (self, pet) {
        case (.preview, _): return 15 * 60
        case (.publicRelease, .jumpingBean): return 10 * 60 * 60
        case (.publicRelease, .calf): return 100 * 60 * 60
        }
    }
}

@MainActor
final class FocusSessionManager: ObservableObject {
    static let availableMinutes = [15, 25, 60]
    static let minimumCreditableSeconds: TimeInterval = 15 * 60

    private enum Key {
        static let totalSeconds = "notchly.focus.totalSeconds"
        static let targetMinutes = "notchly.focus.targetMinutes"
        static let pausedSeconds = "notchly.focus.pausedSeconds"
        static let claimedPets = "notchly.focus.claimedPets"
        static let selectedPet = "notchly.focus.selectedPet"
        static let showsLyricsDuringFocus = "notchly.focus.showsLyricsDuringFocus"
        static let alwaysShowsExactTime = "notchly.focus.alwaysShowsExactTime"
    }

    @Published private(set) var phase: FocusSessionPhase
    @Published private(set) var targetMinutes: Int
    @Published private(set) var elapsedSeconds: TimeInterval
    @Published private(set) var totalSeconds: TimeInterval
    @Published private(set) var claimedPets: Set<FocusPet>
    @Published private(set) var selectedPet: FocusPet?
    @Published private(set) var showsLyricsDuringFocus: Bool
    @Published private(set) var alwaysShowsExactTime: Bool
    @Published private(set) var completionEventID = 0

    private let defaults: UserDefaults
    private let now: () -> Date
    private var timer: Timer?
    private var segmentStartedAt: Date?
    private var segmentBaseSeconds: TimeInterval = 0
    private var lockObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        let savedTarget = defaults.integer(forKey: Key.targetMinutes)
        let restoredTarget = Self.availableMinutes.contains(savedTarget) ? savedTarget : 25
        let restoredElapsed = min(
            max(0, defaults.double(forKey: Key.pausedSeconds)),
            TimeInterval(restoredTarget * 60)
        )
        let restoredClaims = Set(
            (defaults.stringArray(forKey: Key.claimedPets) ?? []).compactMap(FocusPet.init(rawValue:))
        )
        targetMinutes = restoredTarget
        totalSeconds = max(0, defaults.double(forKey: Key.totalSeconds))
        elapsedSeconds = restoredElapsed
        phase = restoredElapsed > 0 ? .paused : .idle
        claimedPets = restoredClaims
        let savedPet = defaults.string(forKey: Key.selectedPet).flatMap(FocusPet.init(rawValue:))
        selectedPet = savedPet.flatMap { restoredClaims.contains($0) ? $0 : nil }
        showsLyricsDuringFocus = defaults.bool(forKey: Key.showsLyricsDuringFocus)
        alwaysShowsExactTime = defaults.bool(forKey: Key.alwaysShowsExactTime)
    }

    var remainingSeconds: TimeInterval {
        max(0, TimeInterval(targetMinutes * 60) - elapsedSeconds)
    }

    var unlockPolicy: FocusPetUnlockPolicy { .current }

    func requiredSeconds(for pet: FocusPet) -> TimeInterval {
        unlockPolicy.requiredSeconds(for: pet)
    }

    func canClaim(_ pet: FocusPet) -> Bool {
        !claimedPets.contains(pet) && totalSeconds >= requiredSeconds(for: pet)
    }

    func setTargetMinutes(_ minutes: Int) {
        guard phase == .idle, Self.availableMinutes.contains(minutes) else { return }
        targetMinutes = minutes
        defaults.set(minutes, forKey: Key.targetMinutes)
    }

    func setShowsLyricsDuringFocus(_ enabled: Bool) {
        showsLyricsDuringFocus = enabled
        defaults.set(enabled, forKey: Key.showsLyricsDuringFocus)
    }

    func setAlwaysShowsExactTime(_ enabled: Bool) {
        alwaysShowsExactTime = enabled
        defaults.set(enabled, forKey: Key.alwaysShowsExactTime)
    }

    func start() {
        guard phase == .idle else { return }
        elapsedSeconds = 0
        segmentBaseSeconds = 0
        resumeTimer()
    }

    func resume() {
        guard phase == .paused else { return }
        segmentBaseSeconds = elapsedSeconds
        resumeTimer()
    }

    func pause() {
        guard phase == .running else { return }
        refreshElapsed()
        guard phase == .running else { return }
        timer?.invalidate()
        timer = nil
        segmentStartedAt = nil
        segmentBaseSeconds = elapsedSeconds
        phase = .paused
        defaults.set(elapsedSeconds, forKey: Key.pausedSeconds)
    }

    func finishEarly() {
        guard phase != .idle else { return }
        if phase == .running { refreshElapsed() }
        guard phase != .idle else { return }
        settleSession(reachedTarget: false)
    }

    func claim(_ pet: FocusPet) {
        guard canClaim(pet) else { return }
        claimedPets.insert(pet)
        defaults.set(claimedPets.map(\.rawValue).sorted(), forKey: Key.claimedPets)
        select(pet)
    }

    func select(_ pet: FocusPet) {
        guard claimedPets.contains(pet) else { return }
        selectedPet = pet
        defaults.set(pet.rawValue, forKey: Key.selectedPet)
    }

    func startObserving() {
        guard lockObserver == nil, sleepObserver == nil else { return }
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
    }

    func stopObserving() {
        pause()
        if let lockObserver {
            DistributedNotificationCenter.default().removeObserver(lockObserver)
            self.lockObserver = nil
        }
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        timer?.invalidate()
        timer = nil
    }

    private func resumeTimer() {
        segmentStartedAt = now()
        phase = .running
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshElapsed() }
        }
    }

    private func refreshElapsed() {
        guard phase == .running, let segmentStartedAt else { return }
        let targetSeconds = TimeInterval(targetMinutes * 60)
        elapsedSeconds = min(targetSeconds, segmentBaseSeconds + max(0, now().timeIntervalSince(segmentStartedAt)))
        defaults.set(elapsedSeconds, forKey: Key.pausedSeconds)
        if elapsedSeconds >= targetSeconds {
            settleSession(reachedTarget: true)
        }
    }

    private func settleSession(reachedTarget: Bool) {
        let creditedSeconds = elapsedSeconds >= Self.minimumCreditableSeconds ? elapsedSeconds : 0
        if creditedSeconds > 0 {
            totalSeconds += creditedSeconds
            defaults.set(totalSeconds, forKey: Key.totalSeconds)
        }
        timer?.invalidate()
        timer = nil
        segmentStartedAt = nil
        segmentBaseSeconds = 0
        elapsedSeconds = 0
        phase = .idle
        defaults.removeObject(forKey: Key.pausedSeconds)
        if reachedTarget { completionEventID += 1 }
    }
}

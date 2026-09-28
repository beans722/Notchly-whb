import Foundation

private final class TestClock {
    var value = Date(timeIntervalSince1970: 1_700_000_000)

    func advance(minutes: Int) {
        value.addTimeInterval(TimeInterval(minutes * 60))
    }
}

@main
struct FocusSessionManagerSmoke {
    @MainActor
    static func main() {
        let suiteName = "xyz.notchly.focus-smoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Cannot create isolated test defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let clock = TestClock()
        let manager = FocusSessionManager(defaults: defaults, now: { clock.value })
        precondition(manager.targetMinutes == 25)
        precondition(!manager.showsLyricsDuringFocus)
        precondition(!manager.alwaysShowsExactTime)
        manager.setShowsLyricsDuringFocus(true)
        manager.setAlwaysShowsExactTime(true)
        precondition(FocusPetUnlockPolicy.preview.requiredSeconds(for: .jumpingBean) == 900)
        precondition(FocusPetUnlockPolicy.preview.requiredSeconds(for: .calf) == 900)
        precondition(FocusPetUnlockPolicy.publicRelease.requiredSeconds(for: .jumpingBean) == 36_000)
        precondition(FocusPetUnlockPolicy.publicRelease.requiredSeconds(for: .calf) == 360_000)

        manager.start()
        clock.advance(minutes: 14)
        manager.finishEarly()
        precondition(manager.totalSeconds == 0, "Sub-15-minute session must not count")

        manager.start()
        clock.advance(minutes: 10)
        manager.pause()
        clock.advance(minutes: 30)
        manager.resume()
        clock.advance(minutes: 8)
        manager.finishEarly()
        precondition(manager.totalSeconds == 18 * 60, "Pause must not accrue time")
        precondition(manager.canClaim(.jumpingBean) && manager.canClaim(.calf))

        manager.claim(.jumpingBean)
        manager.claim(.calf)
        precondition(manager.claimedPets.count == 2)
        precondition(manager.selectedPet == .calf)
        precondition(manager.totalSeconds == 18 * 60, "Claiming must not spend focus time")
        manager.select(.jumpingBean)

        let restored = FocusSessionManager(defaults: defaults, now: { clock.value })
        precondition(restored.showsLyricsDuringFocus)
        precondition(restored.alwaysShowsExactTime)
        restored.setShowsLyricsDuringFocus(false)
        restored.setAlwaysShowsExactTime(false)
        let preferencesRestored = FocusSessionManager(defaults: defaults, now: { clock.value })
        precondition(!preferencesRestored.showsLyricsDuringFocus)
        precondition(!preferencesRestored.alwaysShowsExactTime)
        preferencesRestored.stopObserving()
        precondition(restored.totalSeconds == 18 * 60)
        precondition(restored.claimedPets.count == 2)
        precondition(restored.selectedPet == .jumpingBean)

        restored.setTargetMinutes(15)
        restored.start()
        clock.advance(minutes: 15)
        restored.pause()
        precondition(restored.completionEventID == 1)
        precondition(restored.totalSeconds == 33 * 60)
        restored.stopObserving()
        manager.stopObserving()
        print("Focus timer and pet unlock smoke checks passed")
    }
}

//
//  LockScreenStateController.swift
//  Notchly
//
//  Created by n0xbyte on 03.05.2026.
//

import AppKit

@MainActor
final class LockScreenStateController {
    private let model: LockScreenOverlayModel
    private let onLocked: () -> Void
    private let onUnlocked: () -> Void
    private var observers: [Any] = []
    private var pollingTask: Task<Void, Never>?

    init(
        model: LockScreenOverlayModel,
        onLocked: @escaping () -> Void = {},
        onUnlocked: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onLocked = onLocked
        self.onUnlocked = onUnlocked
    }

    func start() {
        installObserversIfNeeded()
        startPolling()
    }

    func stop() {
        let center = DistributedNotificationCenter.default()

        for observer in observers {
            center.removeObserver(observer)
        }

        observers.removeAll()
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }

        let center = DistributedNotificationCenter.default()

        let lockObserver = center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleStateNotification(.locked)
            }
        }

        let unlockObserver = center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleStateNotification(.music)
            }
        }

        observers = [lockObserver, unlockObserver]
    }

    private func handleStateNotification(_ state: LockScreenOverlayState) {
        // Distributed lock notifications are authoritative. Querying the
        // session immediately can return the previous state for several polls.
        pollingTask?.cancel()
        pollingTask = nil

        if state == .locked {
            onLocked()
        } else {
            onUnlocked()
        }

        guard model.state != state else { return }
        model.state = state
    }

    private func startPolling() {
        pollingTask?.cancel()

        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var stableCount = 0
            var lastObservedState: LockScreenOverlayState?

            for _ in 0..<10 {
                if Task.isCancelled { return }

                let currentState = readCurrentState()

                if model.state != currentState {
                    if currentState == .locked {
                        onLocked()
                    } else {
                        onUnlocked()
                    }

                    model.state = currentState
                }

                if lastObservedState == currentState {
                    stableCount += 1
                } else {
                    stableCount = 0
                    lastObservedState = currentState
                }

                if stableCount >= 2 {
                    break
                }

                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
            }

            pollingTask = nil
        }
    }

    private func readCurrentState() -> LockScreenOverlayState {
        isScreenLocked() ? .locked : .music
    }
}

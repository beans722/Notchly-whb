//
//  AppDelegate.swift
//  Notchly
//
//  Created by n0xbyte on 16.03.2026.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()
    private var startupTask: Task<Void, Never>?
    private var didValidateSingleInstance = false

    private lazy var menuController = AppMenuController(
        settingsWindow: environment.settingsWindow,
        agentEventManager: environment.agentEventManager
    )

    private lazy var lockScreenController = LockScreenStateController(
        model: environment.lockScreenOverlayModel,
        onLocked: { [environment] in
            environment.lockScreenWallpaperManager.screenDidLock()
        },
        onUnlocked: { [environment] in
            environment.lockScreenWallpaperManager.screenDidUnlock()
            environment.lockScreenWallpaperManager.refreshCachedDesktopWallpapers()
        }
    )

    private lazy var overlayController = SkyLightOverlayController(
        environment: environment
    )

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard validateSingleRunningInstance() else { return }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard validateSingleRunningInstance() else { return }

        NSApp.setActivationPolicy(.accessory)

        menuController.install()
        environment.agentEventManager.start()
        environment.musicManager.start()
        environment.appleMusicLyricsManager.start()
        environment.codexUsageManager.start()
        overlayController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        startupTask?.cancel()
        startupTask = nil
        environment.musicManager.stop()
        environment.appleMusicLyricsManager.stop()
        environment.codexUsageManager.stop()
        environment.agentEventManager.stop()
        overlayController.stop()
    }

    @discardableResult
    private func validateSingleRunningInstance() -> Bool {
        guard !didValidateSingleInstance else { return true }
        didValidateSingleInstance = true

        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return true
        }

        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let otherInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentProcessIdentifier }

        guard let existingInstance = otherInstances.first else {
            return true
        }

        existingInstance.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)
        return false
    }
}

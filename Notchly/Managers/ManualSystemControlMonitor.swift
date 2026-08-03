//
//  ManualSystemControlMonitor.swift
//  Notchly
//
//  Created by n0xbyte on 25.03.2026.
//
import AppKit

extension Notification.Name {
    static let notchlyManualBrightnessInput = Notification.Name("xyz.notchly.manual-brightness-input")
    static let notchlyManualVolumeInput = Notification.Name("xyz.notchly.manual-volume-input")
}

@MainActor
final class ManualSystemControlMonitor {
    static let shared = ManualSystemControlMonitor()

    private(set) var brightnessInputGeneration = 0
    private(set) var volumeInputGeneration = 0

    private var lastBrightnessInputDate = Date.distantPast
    private var lastVolumeInputDate = Date.distantPast
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {}

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func recentBrightnessInput(after generation: Int, maximumAge: TimeInterval = 1.2) -> Int? {
        guard brightnessInputGeneration > generation,
              Date().timeIntervalSince(lastBrightnessInputDate) <= maximumAge else {
            return nil
        }
        return brightnessInputGeneration
    }

    func recentVolumeInput(after generation: Int, maximumAge: TimeInterval = 1.2) -> Int? {
        guard volumeInputGeneration > generation,
              Date().timeIntervalSince(lastVolumeInputDate) <= maximumAge else {
            return nil
        }
        return volumeInputGeneration
    }

    private func handle(_ event: NSEvent) {
        guard event.subtype.rawValue == 8 else { return }

        let data = UInt32(truncatingIfNeeded: event.data1)
        let keyCode = Int((data & 0xFFFF0000) >> 16)
        let keyState = Int((data & 0x0000FF00) >> 8)
        guard keyState == 0x0A else { return }

        switch keyCode {
        case 2, 3: // NX_KEYTYPE_BRIGHTNESS_UP / NX_KEYTYPE_BRIGHTNESS_DOWN
            brightnessInputGeneration += 1
            lastBrightnessInputDate = Date()
            NotificationCenter.default.post(name: .notchlyManualBrightnessInput, object: nil)
        case 0, 1, 7: // NX_KEYTYPE_SOUND_UP / SOUND_DOWN / MUTE
            volumeInputGeneration += 1
            lastVolumeInputDate = Date()
            NotificationCenter.default.post(name: .notchlyManualVolumeInput, object: nil)
        default:
            break
        }
    }
}

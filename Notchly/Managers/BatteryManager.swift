//
//  BatteryManager.swift
//  Notchly
//
//  Created by n0xbyte on 16.03.2026.
//

import Foundation
import IOKit
import IOKit.ps
import Combine

final class BatteryManager: ObservableObject {
    @Published var batteryLevel: Int = 0
    @Published var isCharging: Bool = false
    @Published var isBatteryAvailable: Bool = true
    @Published var powerSource: String = "Unknown"

    // Battery indicators are not part of Notchly's focused Apple Music/Codex
    // experience, so this manager intentionally performs no background polling.

    func updateBatteryInfo() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.isBatteryAvailable {
                    self.isBatteryAvailable = false
                }
                if self.powerSource != "Unknown" {
                    self.powerSource = "Unknown"
                }
            }
            return
        }

        let current = description[kIOPSCurrentCapacityKey as String] as? Int ?? 0
        let max = description[kIOPSMaxCapacityKey as String] as? Int ?? 100
        let charging = description[kIOPSIsChargingKey as String] as? Bool ?? false
        let powerSourceState = description[kIOPSPowerSourceStateKey as String] as? String ?? ""
        let percent = max > 0 ? Int((Double(current) / Double(max)) * 100.0) : 0

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let nextIsCharging = charging || powerSourceState == kIOPSACPowerValue

            if self.batteryLevel != percent {
                self.batteryLevel = percent
            }
            if self.isCharging != nextIsCharging {
                self.isCharging = nextIsCharging
            }
            if !self.isBatteryAvailable {
                self.isBatteryAvailable = true
            }
            if self.powerSource != powerSourceState {
                self.powerSource = powerSourceState
            }
        }
    }
}

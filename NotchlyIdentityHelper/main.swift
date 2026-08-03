//
//  main.swift
//  NotchlyIdentityHelper
//
//  Created by n0xbyte on 03.05.2026.
//

import Foundation
import Security
import Darwin

private enum IdentityHelperConstants {
    static let machServiceName = "xyz.notchly.Notchly.IdentityHelper"
    static let mainApplicationIdentifier = "xyz.notchly.Notchly"
    static let loginWindowPreferences = URL(
        fileURLWithPath: "/Library/Preferences/com.apple.loginwindow.plist"
    )
    static let stateFile = URL(
        fileURLWithPath: "/var/db/NotchlyIdentityHelperState.plist"
    )
    static let hiddenPreferenceKey = "HideUserAvatarAndName"
}

@objc(NotchlyIdentityHelperProtocol)
private protocol IdentityHelperProtocol {
    func setIdentityHidden(
        _ hidden: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    )
}

private enum IdentityHelperError: LocalizedError {
    case couldNotReadPreferences
    case couldNotWritePreferences
    case invalidStateFile

    var errorDescription: String? {
        switch self {
        case .couldNotReadPreferences:
            return "Could not read the loginwindow preferences."
        case .couldNotWritePreferences:
            return "Could not update the loginwindow preferences."
        case .invalidStateFile:
            return "The identity restoration state is invalid."
        }
    }
}

private struct IdentityPreferenceBaseline {
    let hidden: Bool?
}

private final class IdentityPreferenceController: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "xyz.notchly.identity-helper.preferences",
        qos: .userInitiated
    )
    private var activeLeases = Set<UUID>()
    private var baseline: IdentityPreferenceBaseline?

    init() {
        queue.sync {
            recoverInterruptedSessionIfNeeded()
        }
    }

    func setHidden(
        _ hidden: Bool,
        leaseID: UUID,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        queue.async { [self] in
            do {
                if hidden {
                    try acquireLease(leaseID)
                } else {
                    try releaseLease(leaseID)
                }
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func connectionInvalidated(
        leaseID: UUID,
        completion: @escaping @Sendable () -> Void
    ) {
        queue.async { [self] in
            try? releaseLease(leaseID)
            completion()
        }
    }

    private func acquireLease(_ leaseID: UUID) throws {
        guard !activeLeases.contains(leaseID) else { return }

        if activeLeases.isEmpty {
            let originalValue = try readHiddenPreference()
            try persistRestorationState(originalValue)

            do {
                try writeHiddenPreference(true)
                baseline = originalValue
            } catch {
                try? FileManager.default.removeItem(at: IdentityHelperConstants.stateFile)
                throw error
            }
        }

        activeLeases.insert(leaseID)
    }

    private func releaseLease(_ leaseID: UUID) throws {
        activeLeases.remove(leaseID)
        guard activeLeases.isEmpty else { return }

        let restorationValue: IdentityPreferenceBaseline?
        if let baseline {
            restorationValue = baseline
        } else {
            restorationValue = try readRestorationState()
        }
        guard let restorationValue else { return }

        try writeHiddenPreference(restorationValue.hidden)
        baseline = nil
        try? FileManager.default.removeItem(at: IdentityHelperConstants.stateFile)
    }

    private func recoverInterruptedSessionIfNeeded() {
        guard let restorationValue = try? readRestorationState() else {
            return
        }

        guard (try? writeHiddenPreference(restorationValue.hidden)) != nil else { return }
        try? FileManager.default.removeItem(at: IdentityHelperConstants.stateFile)
    }

    private func readHiddenPreference() throws -> IdentityPreferenceBaseline {
        guard let data = try? Data(contentsOf: IdentityHelperConstants.loginWindowPreferences),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let preferences = propertyList as? [String: Any] else {
            throw IdentityHelperError.couldNotReadPreferences
        }

        let hidden = (preferences[IdentityHelperConstants.hiddenPreferenceKey] as? NSNumber)?.boolValue
        return IdentityPreferenceBaseline(hidden: hidden)
    }

    private func writeHiddenPreference(_ hidden: Bool?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        if let hidden {
            process.arguments = [
                "write",
                "/Library/Preferences/com.apple.loginwindow",
                IdentityHelperConstants.hiddenPreferenceKey,
                "-bool",
                hidden ? "true" : "false",
            ]
        } else {
            process.arguments = [
                "delete",
                "/Library/Preferences/com.apple.loginwindow",
                IdentityHelperConstants.hiddenPreferenceKey,
            ]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw IdentityHelperError.couldNotWritePreferences
        }
    }

    private func persistRestorationState(_ baseline: IdentityPreferenceBaseline) throws {
        let state: [String: Any] = [
            "containsValue": baseline.hidden != nil,
            "baselineHidden": baseline.hidden ?? false,
            "createdAt": Date(),
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: state,
            format: .binary,
            options: 0
        )
        try data.write(to: IdentityHelperConstants.stateFile, options: .atomic)
    }

    private func readRestorationState() throws -> IdentityPreferenceBaseline? {
        guard FileManager.default.fileExists(atPath: IdentityHelperConstants.stateFile.path) else {
            return nil
        }

        let data = try Data(contentsOf: IdentityHelperConstants.stateFile)
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let state = propertyList as? [String: Any],
              let baselineHidden = state["baselineHidden"] as? NSNumber else {
            throw IdentityHelperError.invalidStateFile
        }

        let containsValue = (state["containsValue"] as? NSNumber)?.boolValue ?? true
        return IdentityPreferenceBaseline(
            hidden: containsValue ? baselineHidden.boolValue : nil
        )
    }
}

private final class IdentityHelperService: NSObject, IdentityHelperProtocol {
    let leaseID = UUID()

    private let controller: IdentityPreferenceController

    init(controller: IdentityPreferenceController) {
        self.controller = controller
    }

    func setIdentityHidden(
        _ hidden: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    ) {
        NSLog("[NotchlyIdentityHelper] Requested hidden state: %@", hidden.description)
        controller.setHidden(hidden, leaseID: leaseID) { result in
            switch result {
            case .success:
                NSLog("[NotchlyIdentityHelper] Applied hidden state: %@", hidden.description)
                reply(true, nil)
            case let .failure(error):
                NSLog("[NotchlyIdentityHelper] Failed hidden state request: %@", error.localizedDescription)
                reply(false, error.localizedDescription)
            }
        }
    }

    func connectionInvalidated(completion: @escaping @Sendable () -> Void) {
        controller.connectionInvalidated(leaseID: leaseID, completion: completion)
    }
}

private final class IdentityHelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let controller = IdentityPreferenceController()
    private let connectionStateQueue = DispatchQueue(
        label: "xyz.notchly.identity-helper.connections"
    )
    private var activeConnectionCount = 0
    private var exitGeneration = UUID()
    private let clientRequirement = CodeSigningRequirement.requirement(
        for: IdentityHelperConstants.mainApplicationIdentifier
    )

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        connectionStateQueue.sync {
            activeConnectionCount += 1
            exitGeneration = UUID()
        }

        let service = IdentityHelperService(controller: controller)
        newConnection.setCodeSigningRequirement(clientRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: IdentityHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.invalidationHandler = { [weak self] in
            guard let delegate = self else { return }
            service.connectionInvalidated {
                delegate.connectionDidInvalidate()
            }
        }
        newConnection.resume()
        return true
    }

    private func connectionDidInvalidate() {
        connectionStateQueue.async { [self] in
            activeConnectionCount = max(0, activeConnectionCount - 1)
            guard activeConnectionCount == 0 else { return }

            let generation = UUID()
            exitGeneration = generation
            connectionStateQueue.asyncAfter(deadline: .now() + 1) { [self] in
                guard activeConnectionCount == 0,
                      exitGeneration == generation else { return }
                exit(EXIT_SUCCESS)
            }
        }
    }
}

private enum CodeSigningRequirement {
    static func requirement(for identifier: String) -> String {
        guard let teamIdentifier = currentTeamIdentifier(), !teamIdentifier.isEmpty else {
            // Ad-hoc development builds have no team identifier. SMAppService still
            // validates that the daemon belongs to the registered application bundle.
            return "identifier \"\(escaped(identifier))\""
        }

        return "anchor apple generic and identifier \"\(escaped(identifier))\" "
            + "and certificate leaf[subject.OU] = \"\(escaped(teamIdentifier))\""
    }

    private static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let dictionary = information as? [CFString: Any] else {
            return nil
        }

        return dictionary[kSecCodeInfoTeamIdentifier] as? String
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private let delegate = IdentityHelperListenerDelegate()
private let listener = NSXPCListener(
    machServiceName: IdentityHelperConstants.machServiceName
)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()

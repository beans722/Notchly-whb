//
//  LockScreenIdentityManager.swift
//  Notchly
//
//  Created by n0xbyte on 03.05.2026.
//

import AppKit
import ApplicationServices
import Combine
import Foundation
import Security
import ServiceManagement

@objc(NotchlyIdentityHelperProtocol)
public protocol LockScreenIdentityHelperProtocol: NSObjectProtocol {
    func setIdentityHidden(
        _ hidden: Bool,
        withReply reply: @escaping (Bool, String?) -> Void
    )
}

enum LockScreenIdentityAuthorizationState: Equatable {
    case enabled
    case needsApproval
    case disabled
    case unavailable
}

@MainActor
final class LockScreenIdentityManager: ObservableObject {
    private enum Constants {
        static let helperIdentifier = "xyz.notchly.Notchly.IdentityHelper"
        static let daemonPlistName = "xyz.notchly.Notchly.IdentityHelper.plist"
        static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString
    }

    private let daemonService = SMAppService.daemon(plistName: Constants.daemonPlistName)
    @Published private(set) var authorizationState: LockScreenIdentityAuthorizationState = .disabled
    private var connection: NSXPCConnection?
    private var cancellables = Set<AnyCancellable>()
    private var applicationActiveObserver: NSObjectProtocol?
    private var desiredHidden = false
    private var requestInFlight = false
    private var lastAppliedHidden: Bool?
    private var hasStarted = false
    private var hasPresentedApprovalPrompt = false
    private var approvalPollingTask: Task<Void, Never>?
    private var lockUIRefreshTask: Task<Void, Never>?
    private var identityReleaseTask: Task<Void, Never>?

    func start(observing model: LockScreenOverlayModel) {
        guard !hasStarted else { return }
        hasStarted = true

        model.$isArtworkExpanded
            .combineLatest(model.$state)
            .map { isExpanded, state in
                isExpanded && state == .locked
            }
            .removeDuplicates()
            .sink { [weak self] shouldHide in
                self?.setDesiredHidden(shouldHide)
            }
            .store(in: &cancellables)

        applicationActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshServiceState()
            }
        }

        prepareService()
    }

    func refreshAuthorizationState() {
        updateAuthorizationState()
    }

    func requestAuthorizationFromSettings() {
        guard isInstalledApplication else {
            authorizationState = .unavailable
            return
        }

        hasPresentedApprovalPrompt = true

        switch daemonService.status {
        case .enabled:
            updateAuthorizationState()

        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            pollForApproval()

        case .notRegistered, .notFound:
            do {
                try daemonService.register()
                updateAuthorizationState()

                if daemonService.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    pollForApproval()
                } else if daemonService.status == .enabled, desiredHidden {
                    connectIfNeeded()
                }
            } catch {
                let registrationError = error as NSError
                updateAuthorizationState()

                if daemonService.status == .requiresApproval
                    || isApprovalRequired(registrationError) {
                    authorizationState = .needsApproval
                    SMAppService.openSystemSettingsLoginItems()
                    pollForApproval()
                } else {
                    presentRegistrationError(registrationError)
                }
            }

        @unknown default:
            authorizationState = .disabled
        }
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        desiredHidden = false
        cancellables.removeAll()
        approvalPollingTask?.cancel()
        approvalPollingTask = nil
        lockUIRefreshTask?.cancel()
        lockUIRefreshTask = nil
        identityReleaseTask?.cancel()
        identityReleaseTask = nil

        if let applicationActiveObserver {
            NotificationCenter.default.removeObserver(applicationActiveObserver)
            self.applicationActiveObserver = nil
        }

        restoreSynchronouslyIfPossible()
        connection?.invalidate()
        connection = nil
        requestInFlight = false
        lastAppliedHidden = nil
    }

    private func setDesiredHidden(_ hidden: Bool) {
        NSLog("[LockScreenIdentity] Desired hidden state: %@", hidden.description)
        if hidden {
            identityReleaseTask?.cancel()
            identityReleaseTask = nil
            desiredHidden = true
            connectIfNeeded()
        } else {
            guard desiredHidden || lastAppliedHidden == true else { return }

            identityReleaseTask?.cancel()
            identityReleaseTask = Task { @MainActor [weak self] in
                // Keep the native identity hidden until the artwork/player
                // collapse animation has reached its final geometry.
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled, let self else { return }
                self.identityReleaseTask = nil
                self.desiredHidden = false
                self.applyDesiredStateIfPossible()
            }
        }
    }

    private func refreshNativeLockUI(repeating repeatCount: Int) {
        lockUIRefreshTask?.cancel()
        lockUIRefreshTask = Task { @MainActor [weak self] in
            // loginwindow observes this accessibility state and refreshes its
            // current Lock Screen UI when it changes. Repeating briefly covers
            // the transition where loginwindow is still constructing the UI.
            for attempt in 0..<repeatCount {
                guard !Task.isCancelled, let self else { return }
                self.triggerLoginWindowAccessibilityRefresh()
                if attempt < repeatCount - 1 {
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
            self?.lockUIRefreshTask = nil
        }
    }

    private func triggerLoginWindowAccessibilityRefresh() {
        guard AXIsProcessTrusted(),
              let loginWindow = NSRunningApplication
                  .runningApplications(withBundleIdentifier: "com.apple.loginwindow")
                  .first else {
            NSLog("[LockScreenIdentity] Cannot refresh loginwindow: Accessibility is unavailable")
            return
        }

        let applicationElement = AXUIElementCreateApplication(
            loginWindow.processIdentifier
        )
        var currentValue: CFTypeRef?
        let readResult = AXUIElementCopyAttributeValue(
            applicationElement,
            Constants.enhancedUserInterfaceAttribute,
            &currentValue
        )
        let originalValue = (currentValue as? NSNumber)?.boolValue ?? false
        let temporaryValue: CFBoolean = originalValue
            ? kCFBooleanFalse
            : kCFBooleanTrue

        let setResult = AXUIElementSetAttributeValue(
            applicationElement,
            Constants.enhancedUserInterfaceAttribute,
            temporaryValue
        )
        guard setResult == .success else {
            NSLog(
                "[LockScreenIdentity] loginwindow refresh failed (read=%d, set=%d)",
                readResult.rawValue,
                setResult.rawValue
            )
            return
        }

        let restoredValue: CFBoolean = originalValue
            ? kCFBooleanTrue
            : kCFBooleanFalse
        let restoreResult = AXUIElementSetAttributeValue(
            applicationElement,
            Constants.enhancedUserInterfaceAttribute,
            restoredValue
        )
        NSLog(
            "[LockScreenIdentity] Refreshed native Lock Screen UI (restore=%d)",
            restoreResult.rawValue
        )
    }

    private func prepareService() {
        guard isInstalledApplication else {
            authorizationState = .unavailable
            print("[LockScreenIdentity] Helper registration is available from /Applications.")
            return
        }

        updateAuthorizationState()

        switch daemonService.status {
        case .enabled:
            if desiredHidden {
                connectIfNeeded()
            }

        case .notRegistered, .notFound:
            registerService()

        case .requiresApproval:
            presentApprovalPromptIfNeeded()

        @unknown default:
            break
        }
    }

    private func registerService() {
        do {
            try daemonService.register()
            refreshServiceState()
        } catch {
            let registrationError = error as NSError
            print("[LockScreenIdentity] Helper registration failed: \(registrationError)")

            if daemonService.status == .requiresApproval
                || isApprovalRequired(registrationError) {
                presentApprovalPromptIfNeeded()
            } else {
                presentRegistrationError(registrationError)
            }
        }
    }

    private func isApprovalRequired(_ error: NSError) -> Bool {
        let serviceErrorDomain: String
        if #available(macOS 15.0, *) {
            serviceErrorDomain = SMAppServiceErrorDomain
        } else {
            serviceErrorDomain = "SMAppServiceErrorDomain"
        }

        return error.domain == serviceErrorDomain && (error.code == 1 || error.code == 11)
    }

    private func presentRegistrationError(_ error: NSError) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Notchly couldn’t install its Lock Screen helper"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func refreshServiceState() {
        updateAuthorizationState()
        guard hasStarted else { return }

        if daemonService.status == .enabled {
            approvalPollingTask?.cancel()
            approvalPollingTask = nil
            if desiredHidden {
                connectIfNeeded()
            }
        } else if daemonService.status == .notRegistered {
            prepareService()
        } else if daemonService.status == .requiresApproval {
            presentApprovalPromptIfNeeded()
        }
    }

    private func presentApprovalPromptIfNeeded() {
        guard !hasPresentedApprovalPrompt else { return }
        hasPresentedApprovalPrompt = true

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow Notchly to hide the Lock Screen profile"
        alert.informativeText = "macOS needs a one-time administrator approval. "
            + "Notchly will only hide your photo and name while expanded artwork is visible."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")

        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
            pollForApproval()
        }
    }

    private func pollForApproval() {
        approvalPollingTask?.cancel()
        approvalPollingTask = Task { @MainActor [weak self] in
            for _ in 0..<120 {
                guard !Task.isCancelled, let self, self.hasStarted else { return }
                self.updateAuthorizationState()
                if self.daemonService.status == .enabled {
                    self.approvalPollingTask = nil
                    if self.desiredHidden {
                        self.connectIfNeeded()
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            self?.updateAuthorizationState()
            self?.approvalPollingTask = nil
        }
    }

    private func updateAuthorizationState() {
        guard isInstalledApplication else {
            authorizationState = .unavailable
            return
        }

        switch daemonService.status {
        case .enabled:
            authorizationState = .enabled
        case .requiresApproval:
            authorizationState = .needsApproval
        case .notRegistered, .notFound:
            authorizationState = .disabled
        @unknown default:
            authorizationState = .disabled
        }
    }

    private var isInstalledApplication: Bool {
        let applicationURL = Bundle.main.bundleURL.standardizedFileURL
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .standardizedFileURL
        return applicationURL.path.hasPrefix(applicationsURL.path + "/")
    }

    private func connectIfNeeded() {
        guard desiredHidden, daemonService.status == .enabled else { return }

        guard connection == nil else {
            applyDesiredStateIfPossible()
            return
        }

        let newConnection = NSXPCConnection(
            machServiceName: Constants.helperIdentifier,
            options: .privileged
        )
        newConnection.setCodeSigningRequirement(
            CodeSigningRequirement.requirement(for: Constants.helperIdentifier)
        )
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: LockScreenIdentityHelperProtocol.self
        )
        newConnection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.handleConnectionLost()
            }
        }
        newConnection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.handleConnectionLost()
            }
        }
        newConnection.resume()

        connection = newConnection
        lastAppliedHidden = nil
        applyDesiredStateIfPossible()
    }

    private func handleConnectionLost() {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection = nil
        requestInFlight = false
        lastAppliedHidden = nil

        guard hasStarted,
              desiredHidden,
              daemonService.status == .enabled else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.connectIfNeeded()
        }
    }

    private func applyDesiredStateIfPossible() {
        guard !requestInFlight,
              lastAppliedHidden != desiredHidden,
              let helper = helperProxy() else {
            return
        }

        let requestedHidden = desiredHidden
        NSLog("[LockScreenIdentity] Sending hidden state: %@", requestedHidden.description)
        requestInFlight = true
        helper.setIdentityHidden(requestedHidden) { [weak self] success, message in
            Task { @MainActor in
                guard let self else { return }
                self.requestInFlight = false

                if success {
                    NSLog("[LockScreenIdentity] Applied hidden state: %@", requestedHidden.description)
                    self.lastAppliedHidden = requestedHidden
                    self.refreshNativeLockUI(repeating: requestedHidden ? 3 : 1)
                } else if let message {
                    NSLog("[LockScreenIdentity] Helper request failed: %@", message)
                }

                self.applyDesiredStateIfPossible()
            }
        }
    }

    private func helperProxy() -> LockScreenIdentityHelperProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            print("[LockScreenIdentity] XPC error: \(error)")
            Task { @MainActor in
                self?.handleConnectionLost()
            }
        } as? LockScreenIdentityHelperProtocol
    }

    private func restoreSynchronouslyIfPossible() {
        guard lastAppliedHidden == true,
              let helper = helperProxy() else {
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        helper.setIdentityHidden(false) { _, _ in
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 1)
    }
}

private enum CodeSigningRequirement {
    static func requirement(for identifier: String) -> String {
        guard let teamIdentifier = currentTeamIdentifier(), !teamIdentifier.isEmpty else {
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

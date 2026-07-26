//
//  LockScreenWallpaperManager.swift
//  Notchly
//

import AppKit
@preconcurrency import AVFoundation
import CoreImage
import Darwin
import ImageIO

@MainActor
final class LockScreenWallpaperManager {
    private typealias LegacyWindowListCreateImage = @convention(c) (
        CGRect,
        UInt32,
        CGWindowID,
        UInt32
    ) -> Unmanaged<CGImage>?

    private struct OriginalWallpaper {
        let url: URL
        let options: [NSWorkspace.DesktopImageOptionKey: Any]
        let displayID: CGDirectDisplayID?
    }

    private struct RecoveryRecord: Codable {
        let url: String
        let options: Data?
        let displayID: UInt32?
    }

    private struct RecoveryState: Codable {
        let wallpapers: [RecoveryRecord]
        let wallpaperStoreIndex: Data?
        let usesArtworkOverlay: Bool?
    }

    private struct RecoveredWallpaperState {
        let wallpapers: [OriginalWallpaper]
        let wallpaperStoreIndex: Data?
        let usesArtworkOverlay: Bool
    }

    private struct RenderTarget: Sendable {
        let displayID: CGDirectDisplayID?
        let targetSize: CGSize
        let url: URL
    }

    private let workspace = NSWorkspace.shared
    private let renderer = LockScreenBackdropRenderer(maximumSide: 2560)
    private let renderQueue = DispatchQueue(
        label: "xyz.notchly.lock-screen-wallpaper",
        qos: .userInitiated
    )
    private let fileManager = FileManager.default
    private let workingDirectoryURL: URL
    private let recoveryURL: URL
    private let wallpaperStoreIndexURL: URL
    private let aerialThumbnailsDirectoryURL: URL
    private let aerialVideosDirectoryURL: URL
    private lazy var legacyWindowListCreateImage: LegacyWindowListCreateImage? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY
        ),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else {
            return nil
        }

        return unsafeBitCast(symbol, to: LegacyWindowListCreateImage.self)
    }()
    private var originalWallpapers: [OriginalWallpaper] = []
    private var cachedDesktopWallpapers: [OriginalWallpaper] = []
    private var originalWallpaperStoreIndex: Data?
    private var cachedWallpaperStoreIndex: Data?
    private var activeArtworkURLs: Set<URL> = []
    private var wallpaperReloadTransitionControllers: [NSWindowController] = []
    private var wallpaperReloadTransitionCleanupTask: DispatchWorkItem?
    private var pendingDynamicWallpaperStoreIndex: Data?
    private var pendingDynamicWallpaperRestoreTask: DispatchWorkItem?
    private var isDynamicWallpaperRestoreInProgress = false
    private var isUnlockTransitionInProgress = false
    private var cleanupTask: DispatchWorkItem?
    private var previewRestoreTask: DispatchWorkItem?
    private var restoreConfirmationTask: DispatchWorkItem?
    private var desktopWallpaperMonitoringTask: Task<Void, Never>?
    private var aerialPreviewGenerationKeys: Set<String> = []
    private var operationID = UUID()

    init() {
        let applicationSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        workingDirectoryURL = applicationSupport
            .appendingPathComponent("Notchly/LockScreenWallpaper", isDirectory: true)
        recoveryURL = workingDirectoryURL.appendingPathComponent("restore.json")
        wallpaperStoreIndexURL = applicationSupport
            .appendingPathComponent("com.apple.wallpaper/Store/Index.plist")
        aerialThumbnailsDirectoryURL = applicationSupport
            .appendingPathComponent("com.apple.wallpaper/aerials/thumbnails", isDirectory: true)
        aerialVideosDirectoryURL = applicationSupport
            .appendingPathComponent("com.apple.wallpaper/aerials/videos", isDirectory: true)
    }

    func refreshCachedDesktopWallpapers() {
        guard !isScreenLocked(),
              originalWallpapers.isEmpty,
              activeArtworkURLs.isEmpty else {
            return
        }

        let wallpapers = currentDesktopWallpapers().filter {
            !isGeneratedArtworkURL($0.url)
        }

        guard !wallpapers.isEmpty else { return }
        cachedDesktopWallpapers = wallpapers
        cachedWallpaperStoreIndex = try? Data(contentsOf: wallpaperStoreIndexURL)
    }

    func startDesktopWallpaperMonitoring() {
        desktopWallpaperMonitoringTask?.cancel()
        refreshCachedDesktopWallpapers()

        desktopWallpaperMonitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }

                self?.refreshCachedDesktopWallpapers()
            }
        }
    }

    func stopDesktopWallpaperMonitoring() {
        desktopWallpaperMonitoringTask?.cancel()
        desktopWallpaperMonitoringTask = nil
    }

    func screenDidLock() {
        isUnlockTransitionInProgress = false
        pendingDynamicWallpaperRestoreTask?.cancel()
        pendingDynamicWallpaperRestoreTask = nil
    }

    func screenDidUnlock() {
        guard !isDynamicWallpaperRestoreInProgress else { return }

        isUnlockTransitionInProgress = true
        operationID = UUID()
        pendingDynamicWallpaperRestoreTask?.cancel()

        if !originalWallpapers.isEmpty
            || originalWallpaperStoreIndex != nil
            || !activeArtworkURLs.isEmpty {
            restoreOriginalWallpaper()
        }

        guard pendingDynamicWallpaperStoreIndex != nil else {
            refreshCachedDesktopWallpapers()
            return
        }

        schedulePendingDynamicWallpaperRestoreAfterUnlock()
    }

    private func schedulePendingDynamicWallpaperRestoreAfterUnlock() {
        pendingDynamicWallpaperRestoreTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.completePendingDynamicWallpaperRestore()
        }
        pendingDynamicWallpaperRestoreTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(900),
            execute: task
        )
    }

    func recoverSynchronously() {
        let recoveredState = recoveredWallpaperState()
        guard !recoveredState.wallpapers.isEmpty
                || recoveredState.wallpaperStoreIndex != nil else {
            cleanupGeneratedArtwork(keeping: nil)
            return
        }

        if recoveredState.usesArtworkOverlay {
            try? fileManager.removeItem(at: recoveryURL)
            cleanupGeneratedArtwork(keeping: nil)
            return
        }

        restore(
            recoveredState.wallpapers,
            wallpaperStoreIndex: recoveredState.wallpaperStoreIndex,
            logPrefix: "Recovery"
        )

        try? fileManager.removeItem(at: recoveryURL)
        cleanupGeneratedArtwork(keeping: nil)
    }

    func apply(
        artwork: NSImage,
        on screen: NSScreen,
        onReadyToApply: @escaping @MainActor () -> Void = {}
    ) {
        guard !isUnlockTransitionInProgress,
              isScreenLocked() else {
            return
        }

        cleanupTask?.cancel()
        cleanupTask = nil
        closeWallpaperReloadTransition()
        isUnlockTransitionInProgress = false
        pendingDynamicWallpaperRestoreTask?.cancel()
        pendingDynamicWallpaperRestoreTask = nil
        cancelPendingRestores()
        operationID = UUID()
        let currentOperationID = operationID

        guard let sourceImage = artwork.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            onReadyToApply()
            return
        }

        do {
            try fileManager.createDirectory(
                at: workingDirectoryURL,
                withIntermediateDirectories: true
            )

            if originalWallpapers.isEmpty {
                let currentWallpaperStoreIndex = try? Data(
                    contentsOf: wallpaperStoreIndexURL
                )
                if wallpaperStoreHasDynamicProvider(cachedWallpaperStoreIndex),
                   !wallpaperStoreHasDynamicProvider(currentWallpaperStoreIndex) {
                    originalWallpaperStoreIndex = cachedWallpaperStoreIndex
                } else {
                    originalWallpaperStoreIndex =
                        currentWallpaperStoreIndex
                        ?? cachedWallpaperStoreIndex
                }
                let wallpapers = restoredOrCurrentWallpapers(preferredScreen: screen)
                if wallpaperStoreUsesStaticImage(originalWallpaperStoreIndex) {
                    guard let backedUpWallpapers = backedUpOriginalWallpapers(wallpapers) else {
                        originalWallpaperStoreIndex = nil
                        onReadyToApply()
                        return
                    }
                    originalWallpapers = backedUpWallpapers
                } else {
                    originalWallpapers =
                        snapshottedOriginalWallpapers(wallpapers)
                        ?? wallpapers
                }
                guard !originalWallpapers.isEmpty
                        || originalWallpaperStoreIndex != nil else {
                    onReadyToApply()
                    return
                }
                try persistRecovery(
                    for: originalWallpapers,
                    wallpaperStoreIndex: originalWallpaperStoreIndex,
                    usesArtworkOverlay: false
                )
            }

            let renderTargets = orderedScreens(preferredScreen: screen).map { targetScreen in
                let backingScale = max(targetScreen.backingScaleFactor, 1)
                return RenderTarget(
                    displayID: displayID(for: targetScreen),
                    targetSize: CGSize(
                        width: targetScreen.frame.width * backingScale,
                        height: targetScreen.frame.height * backingScale
                    ),
                    url: workingDirectoryURL
                        .appendingPathComponent("artwork-\(UUID().uuidString).jpg")
                )
            }
            let renderer = renderer

            renderQueue.async { [weak self] in
                var renderedArtwork: [(displayID: CGDirectDisplayID?, url: URL)] = []

                for target in renderTargets {
                    guard let jpegData = renderer.renderJPEG(
                        sourceImage: sourceImage,
                        targetSize: target.targetSize
                    ) else {
                        continue
                    }

                    do {
                        try jpegData.write(to: target.url, options: .atomic)
                        renderedArtwork.append((
                            displayID: target.displayID,
                            url: target.url
                        ))
                    } catch {
                        try? FileManager.default.removeItem(at: target.url)
                    }
                }

                guard !renderedArtwork.isEmpty else {
                    DispatchQueue.main.async { [weak self] in
                        self?.cancelFailedApply(operationID: currentOperationID)
                        onReadyToApply()
                    }
                    return
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self, self.operationID == currentOperationID else {
                        renderedArtwork.forEach {
                            try? FileManager.default.removeItem(at: $0.url)
                        }
                        return
                    }

                    let renderedURLs = Set(renderedArtwork.map(\.url))

                    onReadyToApply()

                    var didApplyAnyWallpaper = false
                    for rendered in renderedArtwork {
                        guard let targetScreen = self.screen(with: rendered.displayID) else {
                            try? self.fileManager.removeItem(at: rendered.url)
                            continue
                        }

                        var options = self.workspace.desktopImageOptions(for: targetScreen) ?? [:]
                        options[.imageScaling] =
                            NSImageScaling.scaleProportionallyUpOrDown.rawValue
                        options[.allowClipping] = true

                        do {
                            try self.workspace.setDesktopImageURL(
                                rendered.url,
                                for: targetScreen,
                                options: options
                            )
                            didApplyAnyWallpaper = true
                        } catch {
                            print("[LockScreenWallpaper] Apply failed: \(error)")
                            try? self.fileManager.removeItem(at: rendered.url)
                        }
                    }

                    guard didApplyAnyWallpaper else {
                        self.cancelFailedApply(operationID: currentOperationID)
                        return
                    }

                    self.activeArtworkURLs = renderedURLs
                    self.cleanupGeneratedArtwork(keeping: renderedURLs)
                }
            }
        } catch {
            print("[LockScreenWallpaper] Prepare failed: \(error)")
            cancelFailedApply(operationID: currentOperationID)
            onReadyToApply()
        }
    }

    func restore() {
        restoreOriginalWallpaper()
    }

    func restoreAnimated() {
        restoreOriginalWallpaperPreview()
    }

    func restoreSynchronously() {
        cancelPendingRestores()
        restoreOriginalWallpaper(allowsConfirmation: false)
    }

    private func restoreOriginalWallpaper(allowsConfirmation: Bool = true) {
        guard restoreConfirmationTask == nil else { return }
        previewRestoreTask?.cancel()
        previewRestoreTask = nil
        operationID = UUID()

        let currentOperationID = operationID
        let recoveredState = recoveredWallpaperState()
        let wallpapers = originalWallpapers.isEmpty
            ? recoveredState.wallpapers
            : originalWallpapers
        let wallpaperStoreIndex = originalWallpaperStoreIndex
            ?? recoveredState.wallpaperStoreIndex
        guard !wallpapers.isEmpty || wallpaperStoreIndex != nil else { return }

        let usesStaticImage = wallpaperStoreUsesStaticImage(wallpaperStoreIndex)
        var deferredDynamicRestore = false
        if usesStaticImage {
            restore(wallpapers)
        } else {
            deferredDynamicRestore = restoreDynamicWallpaperStore(
                from: wallpaperStoreIndex,
                previewWallpapers: wallpapers
            )
        }
        activeArtworkURLs.removeAll()

        guard !deferredDynamicRestore else { return }

        guard allowsConfirmation else {
            finishRestore(keeping: wallpapers)
            return
        }

        let task = DispatchWorkItem { [weak self] in
            guard let self, self.operationID == currentOperationID else { return }
            if usesStaticImage {
                self.restore(wallpapers, logPrefix: "Restore confirmation")
            }
            self.restoreConfirmationTask = nil
            self.finishRestore(keeping: wallpapers)
        }
        restoreConfirmationTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(usesStaticImage ? 450 : 650),
            execute: task
        )
    }

    private func finishRestore(keeping wallpapers: [OriginalWallpaper]) {
        originalWallpapers.removeAll()
        originalWallpaperStoreIndex = nil
        try? fileManager.removeItem(at: recoveryURL)
        scheduleGeneratedArtworkCleanup()
        cleanupOriginalWallpaperBackups(
            keeping: Set(wallpapers.map(\.url).filter(isOriginalWallpaperBackupURL))
        )
        refreshCachedDesktopWallpapers()
    }

    private func restoreOriginalWallpaperPreview() {
        previewRestoreTask?.cancel()
        previewRestoreTask = nil
        operationID = UUID()

        let currentOperationID = operationID

        let recoveredState = recoveredWallpaperState()
        let wallpapers = originalWallpapers.isEmpty
            ? recoveredState.wallpapers
            : originalWallpapers
        let wallpaperStoreIndex = originalWallpaperStoreIndex
            ?? recoveredState.wallpaperStoreIndex
        guard !wallpapers.isEmpty || wallpaperStoreIndex != nil else { return }

        let usesStaticImage = wallpaperStoreUsesStaticImage(wallpaperStoreIndex)
        let previewWallpapers = wallpapers.map(upgradedAerialPreviewWallpaper)
        var deferredDynamicRestore = false
        if usesStaticImage {
            restore(previewWallpapers, logPrefix: "Collapse preview")
        } else {
            deferredDynamicRestore = restoreDynamicWallpaperStore(
                from: wallpaperStoreIndex,
                previewWallpapers: previewWallpapers
            )
        }
        activeArtworkURLs.removeAll()
        scheduleGeneratedArtworkCleanup()

        guard !deferredDynamicRestore else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self, self.operationID == currentOperationID else { return }
            if usesStaticImage {
                self.restore(previewWallpapers, logPrefix: "Collapse confirmation")
            }
            self.previewRestoreTask = nil
            self.finishRestore(keeping: wallpapers)
        }
        previewRestoreTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(usesStaticImage ? 250 : 650),
            execute: task
        )
    }

    private func restore(
        _ wallpapers: [OriginalWallpaper],
        wallpaperStoreIndex: Data?,
        logPrefix: String = "Restore"
    ) {
        if wallpaperStoreUsesStaticImage(wallpaperStoreIndex) {
            restore(wallpapers, logPrefix: logPrefix)
        } else if let wallpaperStoreIndex {
            _ = restoreDynamicWallpaperStore(
                from: wallpaperStoreIndex,
                previewWallpapers: wallpapers
            )
        } else {
            restore(wallpapers, logPrefix: logPrefix)
        }
    }

    private func restore(
        _ wallpapers: [OriginalWallpaper],
        logPrefix: String = "Restore"
    ) {
        for wallpaper in wallpapers {
            guard let targetScreen = screen(with: wallpaper.displayID) else { continue }

            do {
                try workspace.setDesktopImageURL(
                    wallpaper.url,
                    for: targetScreen,
                    options: wallpaper.options
                )
            } catch {
                print("[LockScreenWallpaper] \(logPrefix) failed: \(error)")
            }
        }
    }

    private func recoveredOriginalWallpapers() -> [OriginalWallpaper] {
        recoveredWallpaperState().wallpapers
    }

    private func recoveredWallpaperState() -> RecoveredWallpaperState {
        guard let data = try? Data(contentsOf: recoveryURL),
              let recovery = decodeRecoveryState(from: data) else {
            return RecoveredWallpaperState(
                wallpapers: [],
                wallpaperStoreIndex: nil,
                usesArtworkOverlay: false
            )
        }

        let wallpapers: [OriginalWallpaper] = recovery.records.compactMap { record in
            guard let url = URL(string: record.url) else { return nil }
            guard !isGeneratedArtworkURL(url) else { return nil }
            return OriginalWallpaper(
                url: url,
                options: decodeOptions(from: record.options),
                displayID: record.displayID
            )
        }

        return RecoveredWallpaperState(
            wallpapers: wallpapers,
            wallpaperStoreIndex: recovery.wallpaperStoreIndex,
            usesArtworkOverlay: recovery.usesArtworkOverlay
        )
    }

    private func decodeRecoveryState(
        from data: Data
    ) -> (
        records: [RecoveryRecord],
        wallpaperStoreIndex: Data?,
        usesArtworkOverlay: Bool
    )? {
        if let state = try? JSONDecoder().decode(RecoveryState.self, from: data) {
            return (
                state.wallpapers,
                state.wallpaperStoreIndex,
                state.usesArtworkOverlay ?? false
            )
        }

        if let record = try? JSONDecoder().decode(RecoveryRecord.self, from: data) {
            return ([record], nil, false)
        }

        return nil
    }

    private func restoredOrCurrentWallpapers(preferredScreen: NSScreen) -> [OriginalWallpaper] {
        let recoveredWallpapers = recoveredOriginalWallpapers()
        guard recoveredWallpapers.isEmpty else { return recoveredWallpapers }

        let currentWallpapers = currentDesktopWallpapers(
            preferredScreen: preferredScreen
        ).filter {
            !isGeneratedArtworkURL($0.url)
        }
        guard currentWallpapers.isEmpty else { return currentWallpapers }
        return cachedDesktopWallpapers
    }

    private func cancelFailedApply(operationID failedOperationID: UUID) {
        guard operationID == failedOperationID else { return }
        guard activeArtworkURLs.isEmpty else { return }
        originalWallpapers.removeAll()
        originalWallpaperStoreIndex = nil
        try? fileManager.removeItem(at: recoveryURL)
        scheduleGeneratedArtworkCleanup()
    }

    private func persistRecovery(
        for wallpapers: [OriginalWallpaper],
        wallpaperStoreIndex: Data?,
        usesArtworkOverlay: Bool
    ) throws {
        let state = RecoveryState(
            wallpapers: wallpapers.map { wallpaper in
                RecoveryRecord(
                    url: wallpaper.url.absoluteString,
                    options: encodeOptions(wallpaper.options),
                    displayID: wallpaper.displayID
                )
            },
            wallpaperStoreIndex: wallpaperStoreIndex,
            usesArtworkOverlay: usesArtworkOverlay
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: recoveryURL, options: .atomic)
    }

    private func snapshottedOriginalWallpapers(
        _ wallpapers: [OriginalWallpaper]
    ) -> [OriginalWallpaper]? {
        var snapshots: [OriginalWallpaper] = []
        var createdURLs: [URL] = []

        for wallpaper in wallpapers {
            guard let image = wallpaperWindowImage(for: wallpaper.displayID),
                  let data = wallpaperSnapshotPNGData(from: image) else {
                createdURLs.forEach {
                    try? fileManager.removeItem(at: $0)
                }
                return nil
            }

            let snapshotURL = workingDirectoryURL
                .appendingPathComponent("original-\(UUID().uuidString).png")

            do {
                try data.write(to: snapshotURL, options: .atomic)
            } catch {
                createdURLs.forEach {
                    try? fileManager.removeItem(at: $0)
                }
                return nil
            }

            createdURLs.append(snapshotURL)
            snapshots.append(
                OriginalWallpaper(
                    url: snapshotURL,
                    options: wallpaper.options,
                    displayID: wallpaper.displayID
                )
            )
        }

        cleanupOriginalWallpaperBackups(
            keeping: Set(snapshots.map(\.url))
        )
        return snapshots
    }

    private func backedUpOriginalWallpapers(
        _ wallpapers: [OriginalWallpaper]
    ) -> [OriginalWallpaper]? {
        var backups: [OriginalWallpaper] = []
        var createdBackupURLs: [URL] = []

        for wallpaper in wallpapers {
            if isOriginalWallpaperBackupURL(wallpaper.url)
                || isAerialPreviewURL(wallpaper.url) {
                backups.append(wallpaper)
                continue
            }

            do {
                let backupURL: URL
                if wallpaper.url.isFileURL,
                   fileManager.fileExists(atPath: wallpaper.url.path),
                   fileManager.isReadableFile(atPath: wallpaper.url.path) {
                    let pathExtension = wallpaper.url.pathExtension.isEmpty
                        ? "image"
                        : wallpaper.url.pathExtension
                    backupURL = workingDirectoryURL
                        .appendingPathComponent("original-\(UUID().uuidString)")
                        .appendingPathExtension(pathExtension)
                    try fileManager.copyItem(at: wallpaper.url, to: backupURL)
                } else {
                    guard let image = wallpaperWindowImage(
                        for: wallpaper.displayID
                    ),
                          let data = wallpaperSnapshotPNGData(from: image) else {
                        print(
                            "[LockScreenWallpaper] Original image is unavailable: "
                                + wallpaper.url.path
                        )
                        createdBackupURLs.forEach {
                            try? fileManager.removeItem(at: $0)
                        }
                        return nil
                    }

                    backupURL = workingDirectoryURL
                        .appendingPathComponent("original-\(UUID().uuidString).png")
                    try data.write(to: backupURL, options: .atomic)
                }

                createdBackupURLs.append(backupURL)
                backups.append(
                    OriginalWallpaper(
                        url: backupURL,
                        options: wallpaper.options,
                        displayID: wallpaper.displayID
                    )
                )
            } catch {
                print("[LockScreenWallpaper] Original image backup failed: \(error)")
                createdBackupURLs.forEach {
                    try? fileManager.removeItem(at: $0)
                }
                return nil
            }
        }

        cleanupOriginalWallpaperBackups(
            keeping: Set(backups.map(\.url).filter(isOriginalWallpaperBackupURL))
        )
        return backups
    }

    private func wallpaperWindowImage(
        for displayID: CGDirectDisplayID?
    ) -> CGImage? {
        guard let legacyWindowListCreateImage,
              let windowID = wallpaperWindowID(for: displayID) else {
            return nil
        }

        return legacyWindowListCreateImage(
            .null,
            CGWindowListOption.optionIncludingWindow.rawValue,
            windowID,
            CGWindowImageOption.boundsIgnoreFraming.rawValue
                | CGWindowImageOption.bestResolution.rawValue
        )?.takeRetainedValue()
    }

    private func wallpaperWindowID(
        for displayID: CGDirectDisplayID?
    ) -> CGWindowID? {
        guard let targetScreen = screen(with: displayID),
              let targetDisplayID = displayID ?? self.displayID(for: targetScreen),
              let windowInfoList = CGWindowListCopyWindowInfo(
                  .optionAll,
                  kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }

        let targetBounds = CGDisplayBounds(targetDisplayID)
        return windowInfoList.compactMap { info -> CGWindowID? in
            guard (info[kCGWindowOwnerName as String] as? String) == "WindowManager",
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer < 0,
                  let bounds = windowBounds(in: info),
                  wallpaperBoundsMatch(bounds, targetBounds),
                  let number = info[kCGWindowNumber as String] as? NSNumber else {
                return nil
            }

            return CGWindowID(number.uint32Value)
        }.first
    }

    private func windowBounds(in info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? [String: Any],
              let x = (dictionary["X"] as? NSNumber)?.doubleValue,
              let y = (dictionary["Y"] as? NSNumber)?.doubleValue,
              let width = (dictionary["Width"] as? NSNumber)?.doubleValue,
              let height = (dictionary["Height"] as? NSNumber)?.doubleValue else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func wallpaperBoundsMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 2
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func wallpaperStoreUsesStaticImage(_ data: Data?) -> Bool {
        !wallpaperStoreHasDynamicProvider(data)
    }

    private func wallpaperStoreHasDynamicProvider(_ data: Data?) -> Bool {
        guard let data,
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) else {
            return false
        }

        let staticProviders: Set<String> = [
            "default",
            "com.apple.wallpaper.choice.color",
            "com.apple.wallpaper.choice.image",
            "com.apple.wallpaper.choice.image-folder",
            "com.apple.wallpaper.choice.photo-library",
        ]
        return desktopProviders(in: propertyList).contains {
            !staticProviders.contains($0)
        }
    }

    private func desktopProviders(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            var providers: [String] = []
            for (key, nestedValue) in dictionary {
                if key == "Desktop" {
                    providers.append(contentsOf: stringValues(
                        forKey: "Provider",
                        in: nestedValue
                    ))
                } else {
                    providers.append(contentsOf: desktopProviders(in: nestedValue))
                }
            }
            return providers
        }

        if let array = value as? [Any] {
            return array.flatMap(desktopProviders)
        }

        return []
    }

    private func stringValues(forKey searchedKey: String, in value: Any) -> [String] {
        if let data = value as? Data,
           let propertyList = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ) {
            return stringValues(forKey: searchedKey, in: propertyList)
        }

        if let dictionary = value as? [String: Any] {
            var values = (dictionary[searchedKey] as? String).map { [$0] } ?? []
            for nestedValue in dictionary.values {
                values.append(contentsOf: stringValues(
                    forKey: searchedKey,
                    in: nestedValue
                ))
            }
            return values
        }

        if let array = value as? [Any] {
            return array.flatMap {
                stringValues(forKey: searchedKey, in: $0)
            }
        }

        return []
    }

    private func cancelPendingRestores() {
        previewRestoreTask?.cancel()
        previewRestoreTask = nil
        restoreConfirmationTask?.cancel()
        restoreConfirmationTask = nil
    }

    @discardableResult
    private func restoreDynamicWallpaperStore(
        from data: Data?,
        previewWallpapers: [OriginalWallpaper]
    ) -> Bool {
        guard let data else { return false }

        if isDynamicWallpaperRestoreInProgress {
            return true
        }

        if isScreenLocked()
            || isUnlockTransitionInProgress
            || pendingDynamicWallpaperStoreIndex != nil {
            pendingDynamicWallpaperStoreIndex = data
            if !previewWallpapers.isEmpty {
                restore(
                    previewWallpapers,
                    logPrefix: "Dynamic wallpaper preview"
                )
            }
            if isUnlockTransitionInProgress {
                schedulePendingDynamicWallpaperRestoreAfterUnlock()
            }
            return true
        }

        performDynamicWallpaperStoreRestore(
            from: data,
            transitionWallpapers: previewWallpapers
        )
        return false
    }

    private func completePendingDynamicWallpaperRestore() {
        pendingDynamicWallpaperRestoreTask = nil
        guard let data = pendingDynamicWallpaperStoreIndex else { return }

        pendingDynamicWallpaperStoreIndex = nil
        isUnlockTransitionInProgress = false
        isDynamicWallpaperRestoreInProgress = true
        cancelPendingRestores()

        let recoveredState = recoveredWallpaperState()
        let wallpapers = originalWallpapers.isEmpty
            ? recoveredState.wallpapers
            : originalWallpapers

        performDynamicWallpaperStoreRestore(
            from: data,
            transitionWallpapers: wallpapers
        )

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isDynamicWallpaperRestoreInProgress = false
            self.restoreConfirmationTask = nil
            self.finishRestore(keeping: wallpapers)
        }
        restoreConfirmationTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(2300),
            execute: task
        )
    }

    private func performDynamicWallpaperStoreRestore(
        from data: Data,
        transitionWallpapers: [OriginalWallpaper]
    ) {
        showWallpaperReloadTransition(using: transitionWallpapers)
        guard restoreWallpaperStore(from: data) else {
            closeWallpaperReloadTransition()
            isDynamicWallpaperRestoreInProgress = false
            return
        }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(60)
        ) { [weak self] in
            guard let self else { return }
            self.reloadWallpaperAgent()
            self.scheduleWallpaperReloadTransitionCleanup()
        }
    }

    private func reloadWallpaperAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                print(
                    "[LockScreenWallpaper] WallpaperAgent reload exited with "
                        + "\(process.terminationStatus)"
                )
            }
        } catch {
            print("[LockScreenWallpaper] WallpaperAgent reload failed: \(error)")
            closeWallpaperReloadTransition()
        }
    }

    private func showWallpaperReloadTransition(
        using wallpapers: [OriginalWallpaper]
    ) {
        closeWallpaperReloadTransition()

        guard let fallbackURL = wallpapers.first?.url,
              let fallbackImage = NSImage(contentsOf: fallbackURL) else {
            return
        }

        var controllers: [NSWindowController] = []
        for screen in NSScreen.screens {
            let screenDisplayID = displayID(for: screen)
            let image = wallpapers
                .first { $0.displayID == screenDisplayID }
                .flatMap { NSImage(contentsOf: $0.url) }
                ?? fallbackImage
            let imageView = NSImageView(
                frame: NSRect(origin: .zero, size: screen.frame.size)
            )
            imageView.image = image
            imageView.imageAlignment = .alignCenter
            imageView.imageScaling = .scaleAxesIndependently
            imageView.autoresizingMask = [.width, .height]

            let window = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.hidesOnDeactivate = false
            window.isMovable = false
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(
                rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1
            )
            window.collectionBehavior = [
                .fullScreenAuxiliary,
                .stationary,
                .canJoinAllSpaces,
                .ignoresCycle,
            ]
            window.canBecomeVisibleWithoutLogin = true
            window.contentView = imageView

            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            window.contentView?.displayIfNeeded()
            window.displayIfNeeded()
            controllers.append(NSWindowController(window: window))
        }

        wallpaperReloadTransitionControllers = controllers
    }

    private func scheduleWallpaperReloadTransitionCleanup() {
        wallpaperReloadTransitionCleanupTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.closeWallpaperReloadTransition()
        }
        wallpaperReloadTransitionCleanupTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .seconds(2),
            execute: task
        )
    }

    private func closeWallpaperReloadTransition() {
        wallpaperReloadTransitionCleanupTask?.cancel()
        wallpaperReloadTransitionCleanupTask = nil
        wallpaperReloadTransitionControllers.forEach { $0.close() }
        wallpaperReloadTransitionControllers.removeAll()
    }

    @discardableResult
    private func restoreWallpaperStore(from data: Data?) -> Bool {
        guard let data else { return false }

        do {
            try data.write(to: wallpaperStoreIndexURL)
            return true
        } catch {
            print("[LockScreenWallpaper] Wallpaper store restore failed: \(error)")
            return false
        }
    }

    private func currentDesktopWallpapers(preferredScreen: NSScreen? = nil) -> [OriginalWallpaper] {
        let screens = preferredScreen.map { orderedScreens(preferredScreen: $0) } ?? NSScreen.screens

        return screens.compactMap { screen in
            guard let url = wallpaperStoreImageURL(for: screen)
                ?? workspace.desktopImageURL(for: screen) else {
                return nil
            }
            return OriginalWallpaper(
                url: url,
                options: workspace.desktopImageOptions(for: screen) ?? [:],
                displayID: displayID(for: screen)
            )
        }
    }

    private func wallpaperStoreImageURL(for screen: NSScreen) -> URL? {
        guard let displayID = displayID(for: screen),
              let data = try? Data(contentsOf: wallpaperStoreIndexURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let store = propertyList as? [String: Any] else {
            return nil
        }

        let displayDesktop = (store["Displays"] as? [String: Any])
            .flatMap { $0[displayUUID(for: displayID)] as? [String: Any] }?["Desktop"]
        let allDisplaysDesktop = (store["AllSpacesAndDisplays"] as? [String: Any])?["Desktop"]
        let systemDefaultDesktop = (store["SystemDefault"] as? [String: Any])?["Desktop"]

        for desktop in [displayDesktop, allDisplaysDesktop, systemDefaultDesktop].compactMap({ $0 }) {
            if let url = fileURL(in: desktop) {
                return url
            }

            if let assetID = stringValue(forKey: "assetID", in: desktop) {
                if let previewURL = aerialPreviewURL(
                    assetID: assetID,
                    screen: screen,
                    scheduleGeneration: true
                ) {
                    return previewURL
                }

                let thumbnailURL = aerialThumbnailsDirectoryURL
                    .appendingPathComponent(assetID)
                    .appendingPathExtension("png")
                if fileManager.fileExists(atPath: thumbnailURL.path) {
                    return thumbnailURL
                }
            }
        }

        return nil
    }

    private func upgradedAerialPreviewWallpaper(
        _ wallpaper: OriginalWallpaper
    ) -> OriginalWallpaper {
        guard wallpaper.url.deletingLastPathComponent() == aerialThumbnailsDirectoryURL,
              let screen = screen(with: wallpaper.displayID),
              let previewURL = aerialPreviewURL(
                  assetID: wallpaper.url.deletingPathExtension().lastPathComponent,
                  screen: screen,
                  scheduleGeneration: true
              ) else {
            return wallpaper
        }

        return OriginalWallpaper(
            url: previewURL,
            options: wallpaper.options,
            displayID: wallpaper.displayID
        )
    }

    private func aerialPreviewURL(
        assetID: String,
        screen: NSScreen,
        scheduleGeneration: Bool
    ) -> URL? {
        let backingScale = max(screen.backingScaleFactor, 1)
        let targetSize = CGSize(
            width: screen.frame.width * backingScale,
            height: screen.frame.height * backingScale
        )
        let displayIdentifier = displayID(for: screen) ?? 0
        let generationKey = [
            assetID,
            String(displayIdentifier),
            String(Int(targetSize.width)),
            String(Int(targetSize.height)),
        ].joined(separator: "-")
        let previewURL = workingDirectoryURL
            .appendingPathComponent("aerial-preview-\(generationKey).jpg")

        if fileManager.fileExists(atPath: previewURL.path) {
            return previewURL
        }

        guard scheduleGeneration,
              !aerialPreviewGenerationKeys.contains(generationKey) else {
            return nil
        }

        let videoURL = aerialVideosDirectoryURL
            .appendingPathComponent(assetID)
            .appendingPathExtension("mov")
        guard fileManager.fileExists(atPath: videoURL.path) else { return nil }

        aerialPreviewGenerationKeys.insert(generationKey)
        try? fileManager.createDirectory(
            at: workingDirectoryURL,
            withIntermediateDirectories: true
        )

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = targetSize
        let requestedTime = CMTime(seconds: 1, preferredTimescale: 600)

        generator.generateCGImageAsynchronously(for: requestedTime) {
            [weak self, generator] image, _, error in
            if let image,
               let data = aerialPreviewJPEGData(from: image) {
                do {
                    try data.write(to: previewURL, options: .atomic)
                } catch {
                    print("[LockScreenWallpaper] Aerial preview write failed: \(error)")
                }
            } else if let error {
                print("[LockScreenWallpaper] Aerial preview failed: \(error)")
            }

            _ = generator
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.aerialPreviewGenerationKeys.remove(generationKey)
                self.refreshCachedDesktopWallpapers()
            }
        }

        return nil
    }

    private func displayUUID(for displayID: CGDirectDisplayID) -> String {
        let uuid = CGDisplayCreateUUIDFromDisplayID(displayID).takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func fileURL(in value: Any) -> URL? {
        if let data = value as? Data,
           let propertyList = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ) {
            return fileURL(in: propertyList)
        }

        if let string = value as? String {
            if string.hasPrefix("file://") {
                return URL(string: string)
            }

            if string.hasPrefix("/") {
                return URL(fileURLWithPath: string)
            }

            return nil
        }

        if let dictionary = value as? [String: Any] {
            let preferredKeys = ["relative", "url", "path", "file", "Configuration", "Files"]
            for key in preferredKeys {
                if let nestedValue = dictionary[key],
                   let url = fileURL(in: nestedValue) {
                    return url
                }
            }

            for nestedValue in dictionary.values {
                if let url = fileURL(in: nestedValue) {
                    return url
                }
            }
        }

        if let array = value as? [Any] {
            for nestedValue in array {
                if let url = fileURL(in: nestedValue) {
                    return url
                }
            }
        }

        return nil
    }

    private func stringValue(forKey searchedKey: String, in value: Any) -> String? {
        if let data = value as? Data,
           let propertyList = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ) {
            return stringValue(forKey: searchedKey, in: propertyList)
        }

        if let dictionary = value as? [String: Any] {
            if let string = dictionary[searchedKey] as? String {
                return string
            }

            for nestedValue in dictionary.values {
                if let string = stringValue(forKey: searchedKey, in: nestedValue) {
                    return string
                }
            }
        }

        if let array = value as? [Any] {
            for nestedValue in array {
                if let string = stringValue(forKey: searchedKey, in: nestedValue) {
                    return string
                }
            }
        }

        return nil
    }

    private func encodeOptions(_ options: [NSWorkspace.DesktopImageOptionKey: Any]) -> Data? {
        let propertyList = Dictionary(
            uniqueKeysWithValues: options.map { key, value in
                (key.rawValue, value)
            }
        )

        guard PropertyListSerialization.propertyList(
            propertyList,
            isValidFor: .binary
        ) else {
            return nil
        }

        return try? PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .binary,
            options: 0
        )
    }

    private func decodeOptions(from data: Data?) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        guard let data,
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let dictionary = propertyList as? [String: Any] else {
            return [:]
        }

        return Dictionary(
            uniqueKeysWithValues: dictionary.map { key, value in
                (NSWorkspace.DesktopImageOptionKey(rawValue: key), value)
            }
        )
    }

    private func scheduleGeneratedArtworkCleanup() {
        cleanupTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.cleanupGeneratedArtwork(keeping: nil)
            self?.cleanupTask = nil
        }
        cleanupTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: task)
    }

    private func cleanupGeneratedArtwork(keeping activeURL: URL?) {
        cleanupGeneratedArtwork(keeping: activeURL.map { [$0] } ?? [])
    }

    private func cleanupGeneratedArtwork(keeping activeURLs: Set<URL>) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: workingDirectoryURL,
            includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in files where
            fileURL.lastPathComponent.hasPrefix("artwork-")
                || fileURL.lastPathComponent.hasPrefix("transition-") {
            guard !activeURLs.contains(fileURL) else { continue }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func cleanupOriginalWallpaperBackups(keeping activeURLs: Set<URL>) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: workingDirectoryURL,
            includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in files where isOriginalWallpaperBackupURL(fileURL) {
            guard !activeURLs.contains(fileURL) else { continue }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func isGeneratedArtworkURL(_ url: URL) -> Bool {
        guard url.path.hasPrefix(workingDirectoryURL.path) else { return false }
        return url.lastPathComponent.hasPrefix("artwork-")
            || url.lastPathComponent.hasPrefix("transition-")
    }

    private func isOriginalWallpaperBackupURL(_ url: URL) -> Bool {
        url.deletingLastPathComponent() == workingDirectoryURL
            && url.lastPathComponent.hasPrefix("original-")
    }

    private func isAerialPreviewURL(_ url: URL) -> Bool {
        url.deletingLastPathComponent() == aerialThumbnailsDirectoryURL
            || (
                url.deletingLastPathComponent() == workingDirectoryURL
                    && url.lastPathComponent.hasPrefix("aerial-preview-")
            )
    }

    private func orderedScreens(preferredScreen: NSScreen) -> [NSScreen] {
        let preferredDisplayID = displayID(for: preferredScreen)
        let screens = NSScreen.screens
        guard let preferredDisplayID,
              screens.contains(where: { displayID(for: $0) == preferredDisplayID }) else {
            return screens.isEmpty ? [preferredScreen] : screens
        }

        return screens.sorted {
            if displayID(for: $0) == preferredDisplayID { return true }
            if displayID(for: $1) == preferredDisplayID { return false }
            return $0.localizedName < $1.localizedName
        }
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map {
            CGDirectDisplayID($0.uint32Value)
        }
    }

    private func screen(with displayID: UInt32?) -> NSScreen? {
        guard let displayID else { return NSScreen.main ?? NSScreen.screens.first }
        return NSScreen.screens.first { self.displayID(for: $0) == displayID }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

private nonisolated func aerialPreviewJPEGData(from image: CGImage) -> Data? {
    guard let destinationData = CFDataCreateMutable(nil, 0),
          let destination = CGImageDestinationCreateWithData(
              destinationData,
              "public.jpeg" as CFString,
              1,
              nil
          ) else {
        return nil
    }

    let properties = [
        kCGImageDestinationLossyCompressionQuality: 0.94
    ] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return destinationData as Data
}

private nonisolated func wallpaperSnapshotPNGData(from image: CGImage) -> Data? {
    guard let destinationData = CFDataCreateMutable(nil, 0),
          let destination = CGImageDestinationCreateWithData(
              destinationData,
              "public.png" as CFString,
              1,
              nil
          ) else {
        return nil
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return destinationData as Data
}

private nonisolated final class LockScreenBackdropRenderer: @unchecked Sendable {
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private let maximumSide: CGFloat
    private let context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: outputColorSpace,
        .outputColorSpace: outputColorSpace
    ])

    init(maximumSide: CGFloat) {
        self.maximumSide = maximumSide
    }

    func renderJPEG(sourceImage: CGImage, targetSize: CGSize) -> Data? {
        let composition = LockScreenBackdropComposition(
            sourceImage: sourceImage,
            targetSize: targetSize,
            maximumSide: maximumSide
        )
        guard let outputImage = context.createCGImage(
            composition.image,
            from: composition.extent,
            format: .RGBA8,
            colorSpace: Self.outputColorSpace
        ),
              let destinationData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                destinationData,
                "public.jpeg" as CFString,
                1,
                nil
              ) else {
            return nil
        }

        let properties = [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        CGImageDestinationAddImage(destination, outputImage, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return destinationData as Data
    }
}

private nonisolated struct LockScreenBackdropComposition {
    let image: CIImage
    let extent: CGRect

    init(sourceImage: CGImage, targetSize: CGSize, maximumSide: CGFloat) {
        let targetWidth = max(1, targetSize.width)
        let targetHeight = max(1, targetSize.height)
        let renderScale = min(1, maximumSide / max(targetWidth, targetHeight))
        let renderWidth = max(1, floor(targetWidth * renderScale))
        let renderHeight = max(1, floor(targetHeight * renderScale))
        let extent = CGRect(x: 0, y: 0, width: renderWidth, height: renderHeight)
        let inputImage = CIImage(cgImage: sourceImage)
        let fillScale = max(
            renderWidth / inputImage.extent.width,
            renderHeight / inputImage.extent.height
        )
        let scaledImage = inputImage.transformed(
            by: CGAffineTransform(scaleX: fillScale, y: fillScale)
        )
        let centeredImage = scaledImage.transformed(
            by: CGAffineTransform(
                translationX: (renderWidth - scaledImage.extent.width) / 2 - scaledImage.extent.minX,
                y: (renderHeight - scaledImage.extent.height) / 2 - scaledImage.extent.minY
            )
        )
        let blurRadius = max(38, min(renderWidth, renderHeight) * 0.055)
        let backdrop = centeredImage
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
            .cropped(to: extent)
            .applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputSaturationKey: 0.96,
                    kCIInputBrightnessKey: -0.05,
                    kCIInputContrastKey: 0.98
                ]
            )
            .applyingFilter("CIVibrance", parameters: ["inputAmount": -0.10])
        let dimmingLayer = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.18))
            .cropped(to: extent)

        self.image = dimmingLayer.composited(over: backdrop)
        self.extent = extent
    }
}

import AppKit
import CoreGraphics
#if canImport(DisplayAnchorCore)
import DisplayAnchorCore
#endif
import Foundation

@MainActor
final class DisplayAnchorController {
    enum Status {
        case idle
        case paused
        case permissionNeeded
        case snapshotSaved(Int)
        case snapshotSkippedFullscreen
        case restoreScheduled
        case restoreWaitingForUnlock
        case restored(Int)
        case restoreSkippedMissingDisplays
        case restoreSkippedWindowsUnavailable
        case error(String)

        var menuText: String {
            switch self {
            case .idle:
                return "Ready"
            case .paused:
                return "Paused"
            case .permissionNeeded:
                return "Accessibility Permission Needed"
            case .snapshotSaved(let count):
                return "Snapshot Saved: \(count) Windows"
            case .snapshotSkippedFullscreen:
                return "Skipped: Full Screen Active"
            case .restoreScheduled:
                return "Waiting for Displays"
            case .restoreWaitingForUnlock:
                return "Waiting for Unlock"
            case .restored(let count):
                return "Restored: \(count) Windows"
            case .restoreSkippedMissingDisplays:
                return "Skipped: Displays Not Ready"
            case .restoreSkippedWindowsUnavailable:
                return "Skipped: Windows Not Ready"
            case .error(let message):
                return "Error: \(message)"
            }
        }
    }

    var onStatusChange: ((Status) -> Void)?
    var status: Status = .idle {
        didSet {
            onStatusChange?(status)
        }
    }

    private let windowReader = WindowReader()
    private let restorer = WindowRestorer()
    private let store: SnapshotStore
    private let diagnostics = DiagnosticsLog()
    private let restoreRetryInterval: TimeInterval = 0.25
    private let restoreTimeout: TimeInterval = 20
    private let failedRestoreSnapshotHold: TimeInterval = 600
    private var paused = false
    private var stableSnapshotTimer: Timer?
    private var restoreTimer: Timer?
    private var restoreDeadline: Date?
    private var lastStableSnapshot: WindowSnapshot?
    private var frozenSnapshot: WindowSnapshot?
    private var automaticSnapshotSuppressedUntil: Date?
    private var lastRestoreWaitMessage: String?
    private var displayCallbackContext: UnsafeMutableRawPointer?
    private var displaysAreSettling = false
    private var lastKnownPermissionState = AccessibilityPermission.isTrusted

    init() {
        do {
            store = try SnapshotStore()
        } catch {
            fatalError("Unable to create snapshot store: \(error)")
        }
    }

    func start() {
        registerWorkspaceNotifications()
        registerDisplayNotifications()
        refreshPermissionState(force: true)
    }

    func stop() {
        stableSnapshotTimer?.invalidate()
        restoreTimer?.invalidate()
        if let displayCallbackContext {
            CGDisplayRemoveReconfigurationCallback(Self.displayReconfigurationCallback, displayCallbackContext)
        }
    }

    func refreshPermissionState(force: Bool = false) {
        let hasPermission = AccessibilityPermission.isTrusted
        guard force || hasPermission != lastKnownPermissionState else {
            return
        }

        lastKnownPermissionState = hasPermission

        guard hasPermission else {
            diagnostics.write("permission missing; timers stopped")
            stableSnapshotTimer?.invalidate()
            restoreTimer?.invalidate()
            restoreTimer = nil
            restoreDeadline = nil
            displaysAreSettling = false
            frozenSnapshot = nil
            status = .permissionNeeded
            return
        }

        guard !paused else {
            diagnostics.write("permission available but app is paused")
            status = .paused
            return
        }

        diagnostics.write("permission available; starting automatic snapshots")
        saveSnapshot(reason: "permission-refresh")
        startStableSnapshotTimer()
    }

    func snapshotNow() {
        guard AccessibilityPermission.isTrusted else {
            status = .permissionNeeded
            return
        }

        saveSnapshot(reason: "manual", bypassAutomaticGuards: true)
    }

    func restoreLastSnapshot() {
        guard AccessibilityPermission.isTrusted else {
            status = .permissionNeeded
            return
        }

        do {
            guard let snapshot = try store.load() else {
                status = .error("No Snapshot")
                return
            }

            let restoredCount = restorer.restore(snapshot: snapshot)

            if restoredCount == 0,
               RestorePlanner.readiness(
                   savedTopology: snapshot.topology,
                   currentTopology: DisplayReader.currentTopology()
               ) != .ready {
                status = .restoreSkippedMissingDisplays
            } else {
                status = .restored(restoredCount)
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func setPaused(_ isPaused: Bool) {
        paused = isPaused
        status = isPaused ? .paused : .idle

        if isPaused {
            stableSnapshotTimer?.invalidate()
        } else if AccessibilityPermission.isTrusted {
            saveSnapshot(reason: "unpaused", bypassAutomaticGuards: true)
            startStableSnapshotTimer()
        }
    }

    func isPaused() -> Bool {
        paused
    }

    private func saveSnapshot(
        updateStatus: Bool = true,
        reason: String,
        bypassAutomaticGuards: Bool = false
    ) {
        guard AccessibilityPermission.isTrusted, !paused, !displaysAreSettling else {
            return
        }

        guard UserSessionState.isUnlocked else {
            diagnostics.write("snapshot skipped reason=\(reason) session-locked")
            return
        }

        let snapshot = windowReader.snapshot()

        if !bypassAutomaticGuards {
            if let automaticSnapshotSuppressedUntil,
               Date() < automaticSnapshotSuppressedUntil {
                diagnostics.write("snapshot skipped reason=\(reason) holdUntil=\(Self.format(automaticSnapshotSuppressedUntil))")
                return
            }

            if let lastStableSnapshot,
               RestorePlanner.readiness(
                   savedTopology: lastStableSnapshot.topology,
                   currentTopology: snapshot.topology
               ) != .ready {
                diagnostics.write("snapshot skipped reason=\(reason) topology-changed current=\(Self.describe(snapshot.topology)) lastStable=\(Self.describe(lastStableSnapshot.topology))")
                return
            }
        }

        guard let snapshotToSave = fullscreenProtectedSnapshot(for: snapshot, reason: reason) else {
            if updateStatus {
                status = .snapshotSkippedFullscreen
            }
            return
        }

        automaticSnapshotSuppressedUntil = nil

        do {
            try store.save(snapshotToSave)
            lastStableSnapshot = snapshotToSave
            diagnostics.write("snapshot saved reason=\(reason) windows=\(snapshotToSave.windows.count) topology=\(Self.describe(snapshotToSave.topology))")
            if updateStatus {
                status = .snapshotSaved(snapshotToSave.windows.count)
            }
        } catch {
            diagnostics.write("snapshot error reason=\(reason) error=\(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
    }

    private func freezeCurrentSnapshot(reason: String) {
        guard AccessibilityPermission.isTrusted, !paused else {
            return
        }

        displaysAreSettling = true
        diagnostics.write("freeze requested reason=\(reason)")

        // Preserve the earliest stable snapshot for the full disturbance cycle.
        guard frozenSnapshot == nil else {
            diagnostics.write("freeze kept existing snapshot reason=\(reason)")
            return
        }

        if !UserSessionState.isUnlocked, let stableSnapshot = snapshotForFullscreenProtection() {
            frozenSnapshot = stableSnapshot

            do {
                try store.save(stableSnapshot)
                diagnostics.write("freeze reused last stable snapshot reason=\(reason) session-locked stableTopology=\(Self.describe(stableSnapshot.topology))")
            } catch {
                diagnostics.write("freeze error reason=\(reason) error=\(error.localizedDescription)")
                status = .error(error.localizedDescription)
            }
            return
        }

        let liveSnapshot = windowReader.snapshot()
        let snapshot: WindowSnapshot
        if let lastStableSnapshot,
           RestorePlanner.readiness(
               savedTopology: lastStableSnapshot.topology,
               currentTopology: liveSnapshot.topology
           ) != .ready {
            snapshot = lastStableSnapshot
            diagnostics.write("freeze reused last stable snapshot reason=\(reason) liveTopology=\(Self.describe(liveSnapshot.topology)) stableTopology=\(Self.describe(lastStableSnapshot.topology))")
        } else {
            guard let protectedSnapshot = fullscreenProtectedSnapshot(for: liveSnapshot, reason: reason) else {
                frozenSnapshot = snapshotForFullscreenProtection()
                diagnostics.write("freeze kept previous snapshot reason=\(reason) fullscreen-active")
                return
            }

            snapshot = protectedSnapshot
        }

        frozenSnapshot = snapshot

        do {
            try store.save(snapshot)
            lastStableSnapshot = snapshot
            diagnostics.write("freeze saved snapshot reason=\(reason) windows=\(snapshot.windows.count) topology=\(Self.describe(snapshot.topology))")
        } catch {
            diagnostics.write("freeze error reason=\(reason) error=\(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
    }

    private func fullscreenProtectedSnapshot(for candidate: WindowSnapshot, reason: String) -> WindowSnapshot? {
        let fullscreenScan = FullscreenWindowDetector.scan(topology: candidate.topology)

        guard fullscreenScan.hasFullscreenWindows else {
            return candidate
        }

        if !fullscreenScan.screensHaveSeparateSpaces {
            diagnostics.write("snapshot skipped reason=\(reason) fullscreen-active shared-spaces fullscreenWindows=\(fullscreenScan.fullscreenWindowCount)")
            return nil
        }

        guard fullscreenScan.hasIdentifiedAffectedDisplays else {
            diagnostics.write("snapshot skipped reason=\(reason) fullscreen-active unidentified-display fullscreenWindows=\(fullscreenScan.fullscreenWindowCount) identifiedDisplays=\(Self.describe(fullscreenScan.affectedDisplayIDs)) unidentified=\(fullscreenScan.unidentifiedFullscreenWindowCount)")
            return nil
        }

        guard let previousSnapshot = snapshotForFullscreenProtection() else {
            diagnostics.write("snapshot skipped reason=\(reason) fullscreen-active no-previous-snapshot fullscreenDisplays=\(Self.describe(fullscreenScan.affectedDisplayIDs))")
            return nil
        }

        guard RestorePlanner.readiness(
            savedTopology: previousSnapshot.topology,
            currentTopology: candidate.topology
        ) == .ready else {
            diagnostics.write("snapshot skipped reason=\(reason) fullscreen-active topology-changed current=\(Self.describe(candidate.topology)) previous=\(Self.describe(previousSnapshot.topology))")
            return nil
        }

        let mergedSnapshot = SnapshotMerger.merge(
            previous: previousSnapshot,
            candidate: candidate,
            preservingDisplayIDs: fullscreenScan.affectedDisplayIDs
        )

        diagnostics.write("snapshot merged reason=\(reason) fullscreenDisplays=\(Self.describe(fullscreenScan.affectedDisplayIDs)) previousWindows=\(previousSnapshot.windows.count) candidateWindows=\(candidate.windows.count) mergedWindows=\(mergedSnapshot.windows.count)")
        return mergedSnapshot
    }

    private func snapshotForFullscreenProtection() -> WindowSnapshot? {
        if let lastStableSnapshot {
            return lastStableSnapshot
        }

        return try? store.load()
    }

    private func startStableSnapshotTimer() {
        stableSnapshotTimer?.invalidate()
        stableSnapshotTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.saveSnapshot(reason: "timer")
            }
        }
    }

    private func scheduleRestore(reason: String) {
        guard AccessibilityPermission.isTrusted, !paused else {
            return
        }

        displaysAreSettling = true
        if frozenSnapshot == nil {
            frozenSnapshot = lastStableSnapshot
        }
        lastRestoreWaitMessage = nil
        diagnostics.write("restore scheduled reason=\(reason) snapshotWindows=\(frozenSnapshot?.windows.count ?? 0) snapshotTopology=\(frozenSnapshot.map { Self.describe($0.topology) } ?? "none")")
        status = UserSessionState.isUnlocked ? .restoreScheduled : .restoreWaitingForUnlock
        restoreTimer?.invalidate()
        restoreDeadline = UserSessionState.isUnlocked ? Date().addingTimeInterval(restoreTimeout) : nil

        restoreTimer = Timer.scheduledTimer(withTimeInterval: restoreRetryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.attemptScheduledRestore()
            }
        }

        restoreTimer?.fire()
    }

    private func attemptScheduledRestore() {
        guard UserSessionState.isUnlocked else {
            restoreDeadline = nil
            status = .restoreWaitingForUnlock
            writeRestoreWait("restore waiting: session locked")
            return
        }

        if restoreDeadline == nil {
            restoreDeadline = Date().addingTimeInterval(restoreTimeout)
            diagnostics.write("restore deadline started after unlock")
        }

        let snapshot: WindowSnapshot?

        if let frozenSnapshot {
            snapshot = frozenSnapshot
        } else if let lastStableSnapshot {
            snapshot = lastStableSnapshot
        } else {
            snapshot = try? store.load()
        }

        guard let snapshot else {
            diagnostics.write("restore failed: no snapshot")
            suppressAutomaticSnapshotsAfterFailedRestore()
            finishRestoreCycle(with: .error("No Snapshot"))
            return
        }

        let readiness = RestorePlanner.readiness(
            savedTopology: snapshot.topology,
            currentTopology: DisplayReader.currentTopology()
        )

        guard readiness == .ready else {
            writeRestoreWait("restore waiting: displays not ready current=\(Self.describe(DisplayReader.currentTopology())) saved=\(Self.describe(snapshot.topology))")
            if let restoreDeadline, Date() >= restoreDeadline {
                diagnostics.write("restore skipped: displays not ready before deadline")
                suppressAutomaticSnapshotsAfterFailedRestore()
                finishRestoreCycle(with: .restoreSkippedMissingDisplays)
            }
            return
        }

        let startedAt = Date()
        diagnostics.write("restore attempt starting savedWindows=\(snapshot.windows.count)")
        let restoredCount = restorer.restore(snapshot: snapshot)
        diagnostics.write("restore attempt finished restored=\(restoredCount) savedWindows=\(snapshot.windows.count) duration=\(Self.formatDuration(Date().timeIntervalSince(startedAt)))")

        guard restoredCount > 0 || snapshot.windows.isEmpty else {
            if let restoreDeadline, Date() >= restoreDeadline {
                diagnostics.write("restore skipped: windows unavailable before deadline")
                suppressAutomaticSnapshotsAfterFailedRestore()
                finishRestoreCycle(with: .restoreSkippedWindowsUnavailable)
            }
            return
        }

        finishRestoreCycle(with: .restored(restoredCount))
        if restoredCount > 0 {
            saveSnapshot(updateStatus: false, reason: "post-restore", bypassAutomaticGuards: true)
        }
    }

    private func finishRestoreCycle(with status: Status) {
        restoreTimer?.invalidate()
        restoreTimer = nil
        restoreDeadline = nil
        displaysAreSettling = false
        frozenSnapshot = nil
        lastRestoreWaitMessage = nil
        self.status = status
        diagnostics.write("restore cycle finished status=\(status.menuText)")
    }

    private func registerWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.freezeCurrentSnapshot(reason: "will-sleep")
            }
        }

        center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.freezeCurrentSnapshot(reason: "screens-sleep")
            }
        }

        center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.diagnostics.write("notification session-inactive")
                self?.freezeCurrentSnapshot(reason: "session-inactive")
            }
        }

        center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRestore(reason: "did-wake")
            }
        }

        center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRestore(reason: "screens-wake")
            }
        }

        center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.diagnostics.write("notification session-active")
                self?.scheduleRestore(reason: "session-active")
            }
        }
    }

    private func registerDisplayNotifications() {
        let unmanaged = Unmanaged.passUnretained(self).toOpaque()
        displayCallbackContext = unmanaged
        CGDisplayRegisterReconfigurationCallback(Self.displayReconfigurationCallback, unmanaged)
    }

    nonisolated private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo else { return }

        let controller = Unmanaged<DisplayAnchorController>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        Task { @MainActor in
            if flags.contains(.beginConfigurationFlag) {
                controller.freezeCurrentSnapshot(reason: "display-begin")
            } else {
                controller.scheduleRestore(reason: "display-end")
            }
        }
    }

    private func suppressAutomaticSnapshotsAfterFailedRestore() {
        automaticSnapshotSuppressedUntil = Date().addingTimeInterval(failedRestoreSnapshotHold)
    }

    private func writeRestoreWait(_ message: String) {
        guard lastRestoreWaitMessage != message else {
            return
        }

        lastRestoreWaitMessage = message
        diagnostics.write(message)
    }

    private static func describe(_ topology: DisplayTopology) -> String {
        topology.displays
            .map { display in
                let frame = display.frame
                let uuid = display.uuid.map { String($0.prefix(8)) } ?? "no-uuid"
                return "\(uuid):id=\(display.id):main=\(display.isMain):frame=\(Int(frame.x)),\(Int(frame.y)),\(Int(frame.width)),\(Int(frame.height))"
            }
            .joined(separator: "|")
    }

    private static func describe(_ displayIDs: Set<UInt32>) -> String {
        guard !displayIDs.isEmpty else {
            return "none"
        }

        return displayIDs
            .sorted()
            .map(String.init)
            .joined(separator: ",")
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%.2fs", duration)
    }
}

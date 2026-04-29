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
        case restoreScheduled
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
            case .restoreScheduled:
                return "Waiting for Displays"
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
    private let restoreRetryInterval: TimeInterval = 2
    private let restoreTimeout: TimeInterval = 180
    private let failedRestoreSnapshotHold: TimeInterval = 600
    private var paused = false
    private var stableSnapshotTimer: Timer?
    private var restoreTimer: Timer?
    private var restoreDeadline: Date?
    private var lastStableSnapshot: WindowSnapshot?
    private var frozenSnapshot: WindowSnapshot?
    private var automaticSnapshotSuppressedUntil: Date?
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

        automaticSnapshotSuppressedUntil = nil

        do {
            try store.save(snapshot)
            lastStableSnapshot = snapshot
            diagnostics.write("snapshot saved reason=\(reason) windows=\(snapshot.windows.count) topology=\(Self.describe(snapshot.topology))")
            if updateStatus {
                status = .snapshotSaved(snapshot.windows.count)
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
            snapshot = liveSnapshot
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
        diagnostics.write("restore scheduled reason=\(reason) snapshotWindows=\(frozenSnapshot?.windows.count ?? 0) snapshotTopology=\(frozenSnapshot.map { Self.describe($0.topology) } ?? "none")")
        status = .restoreScheduled
        restoreTimer?.invalidate()
        restoreDeadline = Date().addingTimeInterval(restoreTimeout)

        restoreTimer = Timer.scheduledTimer(withTimeInterval: restoreRetryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.attemptScheduledRestore()
            }
        }

        restoreTimer?.fire()
    }

    private func attemptScheduledRestore() {
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
            diagnostics.write("restore waiting: displays not ready current=\(Self.describe(DisplayReader.currentTopology())) saved=\(Self.describe(snapshot.topology))")
            if let restoreDeadline, Date() >= restoreDeadline {
                diagnostics.write("restore skipped: displays not ready before deadline")
                suppressAutomaticSnapshotsAfterFailedRestore()
                finishRestoreCycle(with: .restoreSkippedMissingDisplays)
            }
            return
        }

        let restoredCount = restorer.restore(snapshot: snapshot)
        diagnostics.write("restore attempt restored=\(restoredCount) savedWindows=\(snapshot.windows.count)")

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

    private static func describe(_ topology: DisplayTopology) -> String {
        topology.displays
            .map { display in
                let frame = display.frame
                let uuid = display.uuid.map { String($0.prefix(8)) } ?? "no-uuid"
                return "\(uuid):id=\(display.id):main=\(display.isMain):frame=\(Int(frame.x)),\(Int(frame.y)),\(Int(frame.width)),\(Int(frame.height))"
            }
            .joined(separator: "|")
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

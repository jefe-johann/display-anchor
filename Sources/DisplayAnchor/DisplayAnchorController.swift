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
    private var paused = false
    private var stableSnapshotTimer: Timer?
    private var restoreTimer: Timer?
    private var restoreDeadline: Date?
    private var lastStableSnapshot: WindowSnapshot?
    private var frozenSnapshot: WindowSnapshot?
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
            status = .paused
            return
        }

        saveSnapshot()
        startStableSnapshotTimer()
    }

    func snapshotNow() {
        guard AccessibilityPermission.isTrusted else {
            status = .permissionNeeded
            return
        }

        saveSnapshot()
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
            saveSnapshot()
            startStableSnapshotTimer()
        }
    }

    func isPaused() -> Bool {
        paused
    }

    private func saveSnapshot(updateStatus: Bool = true) {
        guard AccessibilityPermission.isTrusted, !paused, !displaysAreSettling else {
            return
        }

        let snapshot = windowReader.snapshot()

        do {
            try store.save(snapshot)
            lastStableSnapshot = snapshot
            if updateStatus {
                status = .snapshotSaved(snapshot.windows.count)
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func freezeCurrentSnapshot() {
        guard AccessibilityPermission.isTrusted, !paused else {
            return
        }

        displaysAreSettling = true

        // Preserve the earliest stable snapshot for the full disturbance cycle.
        guard frozenSnapshot == nil else {
            return
        }

        let snapshot = windowReader.snapshot()
        frozenSnapshot = snapshot

        do {
            try store.save(snapshot)
            lastStableSnapshot = snapshot
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func startStableSnapshotTimer() {
        stableSnapshotTimer?.invalidate()
        stableSnapshotTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.saveSnapshot()
            }
        }
    }

    private func scheduleRestore() {
        guard AccessibilityPermission.isTrusted, !paused else {
            return
        }

        displaysAreSettling = true
        if frozenSnapshot == nil {
            frozenSnapshot = lastStableSnapshot
        }
        status = .restoreScheduled
        restoreTimer?.invalidate()
        restoreDeadline = Date().addingTimeInterval(30)

        restoreTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
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
            finishRestoreCycle(with: .error("No Snapshot"))
            return
        }

        let readiness = RestorePlanner.readiness(
            savedTopology: snapshot.topology,
            currentTopology: DisplayReader.currentTopology()
        )

        guard readiness == .ready else {
            if let restoreDeadline, Date() >= restoreDeadline {
                finishRestoreCycle(with: .restoreSkippedMissingDisplays)
            }
            return
        }

        let restoredCount = restorer.restore(snapshot: snapshot)
        finishRestoreCycle(with: .restored(restoredCount))
        saveSnapshot(updateStatus: false)
    }

    private func finishRestoreCycle(with status: Status) {
        restoreTimer?.invalidate()
        restoreTimer = nil
        restoreDeadline = nil
        displaysAreSettling = false
        frozenSnapshot = nil
        self.status = status
    }

    private func registerWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.freezeCurrentSnapshot()
            }
        }

        center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRestore()
            }
        }

        center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRestore()
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
                controller.freezeCurrentSnapshot()
            } else {
                controller.scheduleRestore()
            }
        }
    }
}

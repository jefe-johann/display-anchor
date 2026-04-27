import AppKit
import CoreGraphics
import DisplayAnchorCore
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
    private var frozenSnapshot: WindowSnapshot?
    private var displayCallbackContext: UnsafeMutableRawPointer?
    private var displaysAreSettling = false

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

        if !AccessibilityPermission.isTrusted {
            status = .permissionNeeded
            return
        }

        saveSnapshot()
        startStableSnapshotTimer()
    }

    func stop() {
        stableSnapshotTimer?.invalidate()
        restoreTimer?.invalidate()
        if let displayCallbackContext {
            CGDisplayRemoveReconfigurationCallback(Self.displayReconfigurationCallback, displayCallbackContext)
        }
    }

    func requestAccessibilityPermission() {
        AccessibilityPermission.prompt()
        status = AccessibilityPermission.isTrusted ? .idle : .permissionNeeded
    }

    func snapshotNow() {
        guard AccessibilityPermission.isTrusted else {
            status = .permissionNeeded
            AccessibilityPermission.prompt()
            return
        }

        saveSnapshot()
    }

    func restoreLastSnapshot() {
        guard AccessibilityPermission.isTrusted else {
            status = .permissionNeeded
            AccessibilityPermission.prompt()
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

    private func saveSnapshot() {
        guard AccessibilityPermission.isTrusted, !paused, !displaysAreSettling else {
            return
        }

        let snapshot = windowReader.snapshot()

        do {
            try store.save(snapshot)
            frozenSnapshot = snapshot
            status = .snapshotSaved(snapshot.windows.count)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func freezeCurrentSnapshot() {
        guard AccessibilityPermission.isTrusted, !paused else {
            return
        }

        displaysAreSettling = true
        let snapshot = windowReader.snapshot()
        frozenSnapshot = snapshot

        do {
            try store.save(snapshot)
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
        } else {
            snapshot = try? store.load()
        }

        guard let snapshot else {
            restoreTimer?.invalidate()
            restoreTimer = nil
            displaysAreSettling = false
            status = .error("No Snapshot")
            return
        }

        let readiness = RestorePlanner.readiness(
            savedTopology: snapshot.topology,
            currentTopology: DisplayReader.currentTopology()
        )

        guard readiness == .ready else {
            if let restoreDeadline, Date() >= restoreDeadline {
                restoreTimer?.invalidate()
                restoreTimer = nil
                displaysAreSettling = false
                status = .restoreSkippedMissingDisplays
            }
            return
        }

        restoreTimer?.invalidate()
        restoreTimer = nil
        let restoredCount = restorer.restore(snapshot: snapshot)
        status = .restored(restoredCount)
        displaysAreSettling = false
        saveSnapshot()
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

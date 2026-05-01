import Foundation
import Testing
@testable import DisplayAnchorCore

@Suite("Display Anchor Core")
struct DisplayAnchorCoreTests {
    @Test("display topology matching is order independent and tolerant")
    func displayTopologyMatching() {
        let saved = DisplayTopology(displays: [
            display(id: 2, uuid: "external", x: 1440, y: 0, width: 2560, height: 1440, isMain: false),
            display(id: 1, uuid: "built-in", x: 0, y: 0, width: 1440, height: 900, isMain: true)
        ])

        let current = DisplayTopology(displays: [
            display(id: 1, uuid: "built-in", x: 1, y: 0, width: 1440, height: 900, isMain: true),
            display(id: 2, uuid: "external", x: 1440, y: 1, width: 2560, height: 1440, isMain: false)
        ])

        #expect(current.matches(saved))
    }

    @Test("missing display keeps restore from running")
    func missingDisplaySkipsRestore() {
        let saved = DisplayTopology(displays: [
            display(id: 1, uuid: "built-in", x: 0, y: 0, width: 1440, height: 900, isMain: true),
            display(id: 2, uuid: "external", x: 1440, y: 0, width: 2560, height: 1440, isMain: false)
        ])

        let current = DisplayTopology(displays: [
            display(id: 1, uuid: "built-in", x: 0, y: 0, width: 1440, height: 900, isMain: true)
        ])

        #expect(RestorePlanner.readiness(savedTopology: saved, currentTopology: current) == .missingSavedDisplays)
    }

    @Test("restore readiness allows modest display drift after wake")
    func restoreReadinessAllowsModestDisplayDrift() {
        let saved = DisplayTopology(displays: [
            display(id: 1, uuid: "built-in", x: 0, y: 0, width: 1440, height: 900, isMain: true),
            display(id: 2, uuid: "external", x: 1440, y: 0, width: 2560, height: 1440, isMain: false)
        ])

        let current = DisplayTopology(displays: [
            display(id: 11, uuid: "built-in", x: 8, y: 0, width: 1440, height: 900, isMain: true),
            display(id: 12, uuid: "external", x: 1434, y: 6, width: 2560, height: 1440, isMain: false)
        ])

        #expect(RestorePlanner.readiness(savedTopology: saved, currentTopology: current) == .ready)
    }

    @Test("duplicate window matching preserves ordering")
    func duplicateWindowMatchingPreservesOrdering() {
        let saved = [
            window(pid: 100, title: "Notes", order: 0, x: 0),
            window(pid: 100, title: "Notes", order: 1, x: 800)
        ]

        let current = [
            window(pid: 100, title: "Notes", order: 0, x: 1200),
            window(pid: 100, title: "Notes", order: 1, x: 2000)
        ]

        let matches = WindowMatcher.match(saved: saved, current: current)

        #expect(matches.count == 2)
        #expect(matches[0].savedIndex == 0)
        #expect(matches[0].currentIndex == 0)
        #expect(matches[1].savedIndex == 1)
        #expect(matches[1].currentIndex == 1)
    }

    @Test("bundle mismatch prevents restoring a closed app through another app")
    func bundleMismatchPreventsRestoringClosedAppThroughAnotherApp() {
        let saved = [
            window(pid: 100, bundleIdentifier: "com.example.notes", title: "Untitled", order: 0, x: 0)
        ]

        let current = [
            window(pid: 200, bundleIdentifier: "com.example.editor", title: "Untitled", order: 0, x: 800)
        ]

        let matches = WindowMatcher.match(saved: saved, current: current)

        #expect(matches.isEmpty)
    }

    @Test("same bundle can match after process identifier changes")
    func sameBundleCanMatchAfterProcessIdentifierChanges() {
        let saved = [
            window(pid: 100, bundleIdentifier: "com.example.notes", title: "Notes", order: 0, x: 0)
        ]

        let current = [
            window(pid: 200, bundleIdentifier: "com.example.notes", title: "Notes", order: 0, x: 800)
        ]

        let matches = WindowMatcher.match(saved: saved, current: current)

        #expect(matches.count == 1)
        #expect(matches[0].savedIndex == 0)
        #expect(matches[0].currentIndex == 0)
    }

    @Test("frame tolerance treats tiny macOS coordinate drift as equivalent")
    func frameTolerance() {
        let saved = WindowFrame(x: 10, y: 20, width: 500, height: 300)
        let current = WindowFrame(x: 11.5, y: 18.5, width: 501, height: 299)

        #expect(current.isClose(to: saved, tolerance: 2))
        #expect(!current.isClose(to: saved, tolerance: 1))
    }

    @Test("snapshot merge preserves affected display and updates unaffected display")
    func snapshotMergePreservesAffectedDisplayAndUpdatesUnaffectedDisplay() {
        let previous = snapshot(windows: [
            window(pid: 100, title: "Old Primary", order: 0, x: 0, displayID: 1),
            window(pid: 200, title: "Old Fullscreen Display", order: 1, x: 800, displayID: 2)
        ])

        let candidate = snapshot(windows: [
            window(pid: 300, title: "New Primary", order: 0, x: 10, displayID: 1),
            window(pid: 400, title: "Partial Fullscreen Display", order: 1, x: 900, displayID: 2)
        ])

        let merged = SnapshotMerger.merge(
            previous: previous,
            candidate: candidate,
            preservingDisplayIDs: [2]
        )

        #expect(merged.windows.map(\.title) == ["New Primary", "Old Fullscreen Display"])
        #expect(merged.windows.map(\.order) == [0, 1])
    }

    @Test("snapshot merge preserves saved windows without display IDs")
    func snapshotMergePreservesSavedWindowsWithoutDisplayIDs() {
        let previous = snapshot(windows: [
            window(pid: 100, title: "Unknown Display", order: 0, x: 0, displayID: nil),
            window(pid: 200, title: "Old Fullscreen Display", order: 1, x: 800, displayID: 2)
        ])

        let candidate = snapshot(windows: [
            window(pid: 300, title: "New Primary", order: 0, x: 10, displayID: 1),
            window(pid: 400, title: "Candidate Unknown", order: 1, x: 20, displayID: nil)
        ])

        let merged = SnapshotMerger.merge(
            previous: previous,
            candidate: candidate,
            preservingDisplayIDs: [2]
        )

        #expect(merged.windows.map(\.title) == ["Unknown Display", "New Primary", "Old Fullscreen Display"])
        #expect(!merged.windows.map(\.title).contains("Candidate Unknown"))
    }

    @Test("snapshot merge without affected displays returns normalized candidate")
    func snapshotMergeWithoutAffectedDisplaysReturnsCandidate() {
        let previous = snapshot(windows: [
            window(pid: 100, title: "Old Primary", order: 0, x: 0, displayID: 1)
        ])

        let candidate = snapshot(windows: [
            window(pid: 200, title: "Candidate Unknown", order: 9, x: 20, displayID: nil),
            window(pid: 300, title: "New Primary", order: 4, x: 10, displayID: 1)
        ])

        let merged = SnapshotMerger.merge(
            previous: previous,
            candidate: candidate,
            preservingDisplayIDs: []
        )

        #expect(merged.windows.map(\.title) == ["Candidate Unknown", "New Primary"])
        #expect(merged.windows.map(\.order) == [0, 1])
    }

    @Test("snapshot merge normalizes merged window order")
    func snapshotMergeNormalizesMergedWindowOrder() {
        let previous = snapshot(windows: [
            window(pid: 100, title: "Preserved Late", order: 20, x: 800, displayID: 2)
        ])

        let candidate = snapshot(windows: [
            window(pid: 200, title: "Replacement Early", order: 10, x: 0, displayID: 1)
        ])

        let merged = SnapshotMerger.merge(
            previous: previous,
            candidate: candidate,
            preservingDisplayIDs: [2]
        )

        #expect(merged.windows.map(\.title) == ["Replacement Early", "Preserved Late"])
        #expect(merged.windows.map(\.order) == [0, 1])
    }

    private func display(
        id: UInt32,
        uuid: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        isMain: Bool
    ) -> DisplayInfo {
        DisplayInfo(
            id: id,
            uuid: uuid,
            frame: WindowFrame(x: x, y: y, width: width, height: height),
            isMain: isMain
        )
    }

    private func snapshot(windows: [WindowRecord]) -> WindowSnapshot {
        WindowSnapshot(
            createdAt: Date(timeIntervalSince1970: 1_000),
            topology: DisplayTopology(displays: [
                display(id: 1, uuid: "built-in", x: 0, y: 0, width: 1440, height: 900, isMain: true),
                display(id: 2, uuid: "external", x: 1440, y: 0, width: 2560, height: 1440, isMain: false)
            ]),
            windows: windows
        )
    }

    private func window(pid: Int32, title: String, order: Int, x: Double) -> WindowRecord {
        window(pid: pid, bundleIdentifier: "com.example.notes", title: title, order: order, x: x)
    }

    private func window(
        pid: Int32,
        title: String,
        order: Int,
        x: Double,
        displayID: UInt32?
    ) -> WindowRecord {
        window(
            pid: pid,
            bundleIdentifier: "com.example.notes",
            title: title,
            order: order,
            x: x,
            displayID: displayID
        )
    }

    private func window(
        pid: Int32,
        bundleIdentifier: String?,
        title: String,
        order: Int,
        x: Double,
        displayID: UInt32? = 1
    ) -> WindowRecord {
        WindowRecord(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: pid,
            title: title,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            frame: WindowFrame(x: x, y: 0, width: 500, height: 500),
            displayID: displayID,
            order: order
        )
    }
}

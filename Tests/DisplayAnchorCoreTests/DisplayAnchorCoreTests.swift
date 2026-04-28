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

    @Test("frame tolerance treats tiny macOS coordinate drift as equivalent")
    func frameTolerance() {
        let saved = WindowFrame(x: 10, y: 20, width: 500, height: 300)
        let current = WindowFrame(x: 11.5, y: 18.5, width: 501, height: 299)

        #expect(current.isClose(to: saved, tolerance: 2))
        #expect(!current.isClose(to: saved, tolerance: 1))
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

    private func window(pid: Int32, title: String, order: Int, x: Double) -> WindowRecord {
        WindowRecord(
            bundleIdentifier: "com.example.notes",
            processIdentifier: pid,
            title: title,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            frame: WindowFrame(x: x, y: 0, width: 500, height: 500),
            displayID: 1,
            order: order
        )
    }
}

import CoreGraphics
import Foundation

public struct WindowFrame: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    public var center: CGPoint {
        CGPoint(x: x + (width / 2), y: y + (height / 2))
    }

    public func isClose(to other: WindowFrame, tolerance: Double) -> Bool {
        abs(x - other.x) <= tolerance
            && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }

    public func intersectionArea(with other: WindowFrame) -> Double {
        let intersection = cgRect.intersection(other.cgRect)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return Double(intersection.width * intersection.height)
    }

    public func contains(_ point: CGPoint) -> Bool {
        cgRect.contains(point)
    }
}

public struct DisplayInfo: Codable, Equatable, Hashable, Sendable {
    public var id: UInt32
    public var uuid: String?
    public var frame: WindowFrame
    public var isMain: Bool

    public init(id: UInt32, uuid: String?, frame: WindowFrame, isMain: Bool) {
        self.id = id
        self.uuid = uuid
        self.frame = frame
        self.isMain = isMain
    }

    public var stableKey: String {
        uuid ?? "display-\(id)"
    }
}

public struct DisplayTopology: Codable, Equatable, Sendable {
    public var displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) {
        self.displays = displays.sorted { lhs, rhs in
            if lhs.stableKey == rhs.stableKey {
                return lhs.id < rhs.id
            }
            return lhs.stableKey < rhs.stableKey
        }
    }

    public func matches(_ other: DisplayTopology, tolerance: Double = 2) -> Bool {
        guard displays.count == other.displays.count else { return false }

        for display in displays {
            guard let match = other.displays.first(where: { $0.stableKey == display.stableKey }) else {
                return false
            }

            guard display.isMain == match.isMain else { return false }
            guard display.frame.isClose(to: match.frame, tolerance: tolerance) else { return false }
        }

        return true
    }

    public func displayID(containing frame: WindowFrame) -> UInt32? {
        if let containing = displays.first(where: { $0.frame.contains(frame.center) }) {
            return containing.id
        }

        return displays
            .map { display in (display.id, display.frame.intersectionArea(with: frame)) }
            .filter { $0.1 > 0 }
            .max { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }
}

public struct WindowRecord: Codable, Equatable, Sendable {
    public var bundleIdentifier: String?
    public var processIdentifier: Int32
    public var title: String
    public var role: String?
    public var subrole: String?
    public var frame: WindowFrame
    public var displayID: UInt32?
    public var order: Int

    public init(
        bundleIdentifier: String?,
        processIdentifier: Int32,
        title: String,
        role: String?,
        subrole: String?,
        frame: WindowFrame,
        displayID: UInt32?,
        order: Int
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.title = title
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.displayID = displayID
        self.order = order
    }
}

public typealias WindowCandidate = WindowRecord

public struct WindowSnapshot: Codable, Equatable, Sendable {
    public var createdAt: Date
    public var topology: DisplayTopology
    public var windows: [WindowRecord]

    public init(createdAt: Date, topology: DisplayTopology, windows: [WindowRecord]) {
        self.createdAt = createdAt
        self.topology = topology
        self.windows = windows
    }
}

public struct WindowMatch: Equatable, Sendable {
    public var savedIndex: Int
    public var currentIndex: Int
    public var score: Int

    public init(savedIndex: Int, currentIndex: Int, score: Int) {
        self.savedIndex = savedIndex
        self.currentIndex = currentIndex
        self.score = score
    }
}

public enum WindowMatcher {
    public static let minimumScore = 40

    public static func match(saved: [WindowRecord], current: [WindowCandidate]) -> [WindowMatch] {
        var matches: [WindowMatch] = []
        var usedCurrentIndexes = Set<Int>()

        for (savedIndex, savedWindow) in saved.enumerated() {
            let best = current.enumerated()
                .filter { !usedCurrentIndexes.contains($0.offset) }
                .map { currentIndex, candidate in
                    WindowMatch(
                        savedIndex: savedIndex,
                        currentIndex: currentIndex,
                        score: score(saved: savedWindow, candidate: candidate)
                    )
                }
                .filter { $0.score >= minimumScore }
                .max { lhs, rhs in
                    if lhs.score == rhs.score {
                        return current[lhs.currentIndex].order > current[rhs.currentIndex].order
                    }
                    return lhs.score < rhs.score
                }

            if let best {
                matches.append(best)
                usedCurrentIndexes.insert(best.currentIndex)
            }
        }

        return matches
    }

    public static func score(saved: WindowRecord, candidate: WindowCandidate) -> Int {
        var score = 0
        let savedBundle = normalizedBundleIdentifier(saved.bundleIdentifier)
        let candidateBundle = normalizedBundleIdentifier(candidate.bundleIdentifier)

        if let savedBundle {
            guard candidateBundle == savedBundle else {
                return 0
            }
        }

        if saved.processIdentifier == candidate.processIdentifier {
            score += 30
        }

        if let savedBundle,
           savedBundle == candidateBundle {
            score += 25
        }

        if saved.title == candidate.title {
            score += saved.title.isEmpty ? 5 : 20
        }

        if saved.role == candidate.role {
            score += 10
        }

        if saved.subrole == candidate.subrole {
            score += 10
        }

        if saved.displayID != nil, saved.displayID == candidate.displayID {
            score += 5
        }

        score += max(0, 5 - abs(saved.order - candidate.order))

        return score
    }

    private static func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }

        return bundleIdentifier
    }
}

public enum RestoreReadiness: Equatable, Sendable {
    case ready
    case missingSavedDisplays
}

public enum RestorePlanner {
    public static let displayTopologyTolerance: Double = 12

    public static func readiness(
        savedTopology: DisplayTopology,
        currentTopology: DisplayTopology,
        tolerance: Double = displayTopologyTolerance
    ) -> RestoreReadiness {
        currentTopology.matches(savedTopology, tolerance: tolerance) ? .ready : .missingSavedDisplays
    }
}

public final class SnapshotStore {
    public let snapshotURL: URL

    public init(snapshotURL: URL? = nil) throws {
        if let snapshotURL {
            self.snapshotURL = snapshotURL
        } else {
            let baseURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.snapshotURL = baseURL
                .appendingPathComponent("Display Anchor", isDirectory: true)
                .appendingPathComponent("LastSnapshot.json")
        }
    }

    public func load() throws -> WindowSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: snapshotURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WindowSnapshot.self, from: data)
    }

    public func save(_ snapshot: WindowSnapshot) throws {
        let directory = snapshotURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL, options: [.atomic])
    }
}

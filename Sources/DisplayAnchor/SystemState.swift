import AppKit
import ApplicationServices
import CoreGraphics
import DisplayAnchorCore
import Foundation

enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func prompt() {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

enum DisplayReader {
    static func currentTopology() -> DisplayTopology {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)

        let displays = displayIDs.prefix(Int(displayCount)).map { displayID in
            DisplayInfo(
                id: displayID,
                uuid: uuidString(for: displayID),
                frame: WindowFrame(CGDisplayBounds(displayID)),
                isMain: displayID == CGMainDisplayID()
            )
        }

        return DisplayTopology(displays: displays)
    }

    private static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }

        guard let uuidString = CFUUIDCreateString(nil, uuid) else {
            return nil
        }

        return uuidString as String
    }
}

final class WindowReader {
    private let appProcessID = ProcessInfo.processInfo.processIdentifier

    func snapshot() -> WindowSnapshot {
        let topology = DisplayReader.currentTopology()
        let records = currentWindows(topology: topology)

        return WindowSnapshot(
            createdAt: Date(),
            topology: topology,
            windows: records
        )
    }

    func currentWindows(topology: DisplayTopology) -> [WindowRecord] {
        let appsByPID = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications
                .map { ($0.processIdentifier, $0.bundleIdentifier) }
        )

        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return rawWindows.enumerated().compactMap { order, windowInfo in
            guard let processID = windowInfo[kCGWindowOwnerPID as String] as? Int32 else {
                return nil
            }

            guard processID != appProcessID else {
                return nil
            }

            guard let layer = windowInfo[kCGWindowLayer as String] as? Int, layer == 0 else {
                return nil
            }

            guard let boundsDictionary = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
                return nil
            }

            guard bounds.width > 24, bounds.height > 24 else {
                return nil
            }

            let axWindow = accessibilityWindow(processID: processID, bounds: bounds)
            let role = axWindow.flatMap { Self.stringAttribute(kAXRoleAttribute, from: $0) }
            let subrole = axWindow.flatMap { Self.stringAttribute(kAXSubroleAttribute, from: $0) }

            guard role == nil || role == kAXWindowRole as String else {
                return nil
            }

            if subrole == kAXSystemDialogSubrole as String {
                return nil
            }

            if axWindow.flatMap(Self.isMinimized) == true {
                return nil
            }

            if axWindow.flatMap(Self.isFullscreen) == true {
                return nil
            }

            let title = axWindow.flatMap { Self.stringAttribute(kAXTitleAttribute, from: $0) }
                ?? (windowInfo[kCGWindowName as String] as? String)
                ?? ""

            let frame = WindowFrame(bounds)

            return WindowRecord(
                bundleIdentifier: appsByPID[processID] ?? nil,
                processIdentifier: processID,
                title: title,
                role: role,
                subrole: subrole,
                frame: frame,
                displayID: topology.displayID(containing: frame),
                order: order
            )
        }
    }

    private func accessibilityWindow(processID: Int32, bounds: CGRect) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid_t(processID))

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
            let windows = value as? [AXUIElement] else {
            return nil
        }

        return windows.first { window in
            guard let position = Self.pointAttribute(kAXPositionAttribute, from: window),
                  let size = Self.sizeAttribute(kAXSizeAttribute, from: window) else {
                return false
            }

            let windowFrame = CGRect(origin: position, size: size)
            return abs(windowFrame.origin.x - bounds.origin.x) <= 4
                && abs(windowFrame.origin.y - bounds.origin.y) <= 4
                && abs(windowFrame.width - bounds.width) <= 4
                && abs(windowFrame.height - bounds.height) <= 4
        }
    }

    static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }

        return value as? String
    }

    static func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    static func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }

        return size
    }

    static func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }

        return value as? Bool
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        boolAttribute(kAXMinimizedAttribute, from: element) ?? false
    }

    static func isFullscreen(_ element: AXUIElement) -> Bool {
        boolAttribute("AXFullScreen", from: element) ?? false
    }
}

final class WindowRestorer {
    func restore(snapshot: WindowSnapshot) -> Int {
        let topology = DisplayReader.currentTopology()

        guard RestorePlanner.readiness(
            savedTopology: snapshot.topology,
            currentTopology: topology
        ) == .ready else {
            return 0
        }

        let reader = WindowReader()
        let currentWindows = reader.currentWindows(topology: topology)
        let matches = WindowMatcher.match(saved: snapshot.windows, current: currentWindows)

        var restoredCount = 0

        for match in matches {
            let savedWindow = snapshot.windows[match.savedIndex]
            let currentWindow = currentWindows[match.currentIndex]

            guard let axWindow = findAXWindow(for: currentWindow) else {
                continue
            }

            if apply(frame: savedWindow.frame, to: axWindow) {
                restoredCount += 1
            }
        }

        return restoredCount
    }

    private func findAXWindow(for window: WindowRecord) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid_t(window.processIdentifier))

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
            let windows = value as? [AXUIElement] else {
            return nil
        }

        return windows
            .compactMap { element -> (element: AXUIElement, frameDistance: Double)? in
                if !window.title.isEmpty,
                   let title = WindowReader.stringAttribute(kAXTitleAttribute, from: element),
                   title != window.title {
                    return nil
                }

                if let expectedRole = window.role,
                   let role = WindowReader.stringAttribute(kAXRoleAttribute, from: element),
                   role != expectedRole {
                    return nil
                }

                if let expectedSubrole = window.subrole,
                   let subrole = WindowReader.stringAttribute(kAXSubroleAttribute, from: element),
                   subrole != expectedSubrole {
                    return nil
                }

                guard let position = WindowReader.pointAttribute(kAXPositionAttribute, from: element),
                      let size = WindowReader.sizeAttribute(kAXSizeAttribute, from: element) else {
                    return nil
                }

                let currentFrame = WindowFrame(CGRect(origin: position, size: size))
                return (
                    element: element,
                    frameDistance: Self.frameDistance(between: currentFrame, and: window.frame)
                )
            }
            .min { lhs, rhs in
                lhs.frameDistance < rhs.frameDistance
            }?
            .element
    }

    private func apply(frame: WindowFrame, to element: AXUIElement) -> Bool {
        var size = CGSize(width: frame.width, height: frame.height)
        guard let sizeValue = AXValueCreate(.cgSize, &size) else {
            return false
        }

        let sizeResult = AXUIElementSetAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            sizeValue
        )

        var position = CGPoint(x: frame.x, y: frame.y)
        guard let positionValue = AXValueCreate(.cgPoint, &position) else {
            return false
        }

        let positionResult = AXUIElementSetAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            positionValue
        )

        return sizeResult == .success && positionResult == .success
    }

    private static func frameDistance(between lhs: WindowFrame, and rhs: WindowFrame) -> Double {
        abs(lhs.x - rhs.x)
            + abs(lhs.y - rhs.y)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }
}

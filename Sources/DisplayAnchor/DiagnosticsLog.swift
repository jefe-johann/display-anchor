import Foundation

final class DiagnosticsLog {
    private let logURL: URL?
    private let maxLogBytes = 256_000

    init() {
        do {
            let baseURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = baseURL.appendingPathComponent("Display Anchor", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            logURL = directory.appendingPathComponent("Events.log")
        } catch {
            logURL = nil
        }
    }

    func write(_ message: String) {
        guard let logURL else { return }

        do {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let size = try FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber,
                   size.intValue > maxLogBytes {
                    try Data().write(to: logURL, options: [.atomic])
                }
            }

            let line = "\(Self.format(Date())) \(message)\n"
            let data = Data(line.utf8)

            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: logURL, options: [.atomic])
            }
        } catch {
            return
        }
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

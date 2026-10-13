import Foundation

/// Appends timestamped lines to ~/Library/Logs/DDCWidget.log, for tracing HDR / mode changes.
enum EventLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DDCWidget.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [pid \(getpid())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

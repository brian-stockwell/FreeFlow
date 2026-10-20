import Foundation

/// Tiny append-only log at ~/Library/Application Support/FreeFlow/freeflow.log (for diagnosing hotkey issues).
enum Log {
    private static let queue = DispatchQueue(label: "freeflow.log")
    private static let url = Database.shared.supportDirectory.appendingPathComponent("freeflow.log")
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    static func write(_ message: String) {
        NSLog("%@", message)
        let line = "\(fmt.string(from: Date())) \(message)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
            // keep it small
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > 2_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

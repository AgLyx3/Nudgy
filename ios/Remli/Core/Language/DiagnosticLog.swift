import Foundation

/// A plain-text trace of the language layer, written to Documents so it can be pulled off a device
/// without root or a log stream.
///
/// ## What it may contain
///
/// Model state, backend names, SafetyGuard rule identifiers, and error descriptions. **Never** a
/// prompt, a reply, a medication name, or anything from the record — the whole point of this app
/// is that those stay in the encrypted vault, and a debug file is exactly the sort of side channel
/// that quietly undoes that.
///
/// Exists because three separate fallbacks in this layer failed *silently and open*: the app kept
/// working, reported itself healthy, and produced scripted text with nothing to explain it.
enum DiagnosticLog {
    private static let queue = DispatchQueue(label: "app.remli.diagnostics")
    private static let maximumBytes = 256 * 1024

    static var fileURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("remli-diagnostics.txt")
    }

    static func note(_ message: String) {
        queue.async {
            guard let url = fileURL else { return }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                // Truncate rather than grow without bound; this is a trace, not an archive.
                if (try? handle.offset()).map({ $0 > maximumBytes }) == true {
                    try? handle.truncate(atOffset: 0)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}

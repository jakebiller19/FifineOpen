import Foundation

/// A log the app can be diagnosed from after the fact.
///
/// `NSLog` alone was not enough: it writes to stderr, which is discarded when
/// the app is launched from Finder, and Apple's unified log does not pick it
/// up from an ad-hoc-signed bundle like this one — so a Finder-launched app
/// was effectively silent, and "the log shows nothing" could not be told apart
/// from "the code never ran".
enum DeckLog {
    /// Kept beside the settings, so it is findable without knowing where an
    /// app bundle happens to live.
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("FifineDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("debug.log")
    }

    /// Past this the file is rotated to `.log.1`, so a long-running app cannot
    /// quietly fill the disk.
    private static let sizeLimit = 512 * 1024
    private static let queue = DispatchQueue(label: "fifine.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        NSLog("%@", message)
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            let path = url
            if let handle = try? FileHandle(forWritingTo: path) {
                defer { try? handle.close() }
                let end = (try? handle.seekToEnd()) ?? 0
                if end > UInt64(sizeLimit) {
                    try? handle.close()
                    rotate(path)
                    try? line.data(using: .utf8)?.write(to: path)
                    return
                }
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? line.data(using: .utf8)?.write(to: path)
            }
        }
    }

    private static func rotate(_ path: URL) {
        let previous = path.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: path, to: previous)
    }
}

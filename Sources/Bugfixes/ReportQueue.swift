import Foundation

/// Reports waiting to be sent, one file each, so a crash written just before the process dies
/// is still sent on the next launch. Oldest first; past `cap` the oldest are dropped.
final class ReportQueue {
    private let dir: URL
    private let cap: Int
    private let lock = NSLock()
    private var sequence = 0

    init(dir: URL, cap: Int = 50) {
        self.dir = dir
        self.cap = cap
    }

    /// `endpoint` is "bug" or "log"; it's the file's extension.
    func add(_ endpoint: String, _ body: Data) {
        lock.lock()
        defer { lock.unlock() }
        let files = FileManager.default
        try? files.createDirectory(at: dir, withIntermediateDirectories: true)
        for old in unlockedItems().dropLast(cap - 1) { try? files.removeItem(at: old) }
        sequence = (sequence + 1) % 1_000_000
        let name = String(format: "%013lld-%06d.%@", Int64(Date().timeIntervalSince1970 * 1000), sequence, endpoint as NSString)
        do {
            try body.write(to: dir.appendingPathComponent(name), options: .atomic)
        } catch {
            debugLog("couldn't queue a report: \(error)")
        }
    }

    func items() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return unlockedItems()
    }

    private func unlockedItems() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "bug" || $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

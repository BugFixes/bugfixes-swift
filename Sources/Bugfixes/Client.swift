import Foundation

final class Client {
    private static let keyPrefix = "bfm_"

    private let minLevel: Level
    private let payloads: Payloads
    private let queue: ReportQueue
    private let sender: Sender
    private let marker: URL
    let work = DispatchQueue(label: "es.bugfix.client", qos: .utility)

    init(minLevel: Level, payloads: Payloads, queue: ReportQueue, sender: Sender, marker: URL) {
        self.minLevel = minLevel
        self.payloads = payloads
        self.queue = queue
        self.sender = sender
        self.marker = marker
    }

    /// nil means reporting is off: no key, an agent secret, or a server that isn't https.
    static func make(
        key: String, environment: String, release: String?, level: Level, server: String, device: Device, dir: URL
    ) -> Client? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return nil }
        guard key.hasPrefix(keyPrefix) else {
            debugLog("not reporting: the key must be a mobile key (\(keyPrefix)…), never an agent secret")
            return nil
        }
        guard Sender.allowed(server) else {
            debugLog("not reporting: \(server) must be https")
            return nil
        }
        return Client(
            minLevel: level,
            payloads: Payloads(
                device: device,
                release: release ?? "\(device.appVersion) (\(device.build))",
                environment: environment
            ),
            queue: ReportQueue(dir: dir.appendingPathComponent("queue")),
            sender: Sender(server: server, key: key, app: device.app),
            marker: dir.appendingPathComponent("pending_exceptions")
        )
    }

    func report(_ error: Error, symbols: [String]) {
        guard let body = payloads.error(error, symbols: symbols) else { return }
        enqueue("bug", body)
    }

    func log(_ level: Level, _ message: String, error: Error?, symbols: [String]) {
        guard level >= minLevel, let body = payloads.log(level, message, error: error, symbols: symbols) else { return }
        enqueue("log", body)
    }

    private func enqueue(_ endpoint: String, _ body: Data) {
        work.async {
            self.queue.add(endpoint, body)
            self.flush()
        }
    }

    func flushInBackground() {
        work.async { self.flush() }
    }

    /// Runs on `work`. Blocks it, never the main thread.
    private func flush() {
        for item in queue.items() {
            guard let body = try? Data(contentsOf: item) else {
                try? FileManager.default.removeItem(at: item)
                continue
            }
            switch sender.send(item.pathExtension, body) {
            case .sent, .drop: try? FileManager.default.removeItem(at: item)
            // ponytail: no network callback; what's left goes on the next report or when the app becomes active
            case .retry: return
            }
        }
    }

    /// The process is dying: write it now, send it on the next launch.
    func recordException(name: String, reason: String, symbols: [String]) {
        guard let body = payloads.exception(name: name, reason: reason, symbols: symbols) else { return }
        queue.add("bug", body)
        writePendingExceptions(pendingExceptions() + 1)
    }

    /// A crash or hang MetricKit delivered after the process died.
    func recordDiagnostic(reason: String, description: String, symbols: [String]) {
        guard let body = payloads.exit(reason: reason, description: description, symbols: symbols) else { return }
        enqueue("bug", body)
    }

    /// MetricKit also delivers an uncaught exception as a SIGABRT, without its name or reason.
    /// True when this SIGABRT is one we already reported from the exception handler.
    func consumePendingException() -> Bool {
        let pending = pendingExceptions()
        guard pending > 0 else { return false }
        writePendingExceptions(pending - 1)
        return true
    }

    private func pendingExceptions() -> Int {
        (try? String(contentsOf: marker, encoding: .utf8)).flatMap { Int($0) } ?? 0
    }

    private func writePendingExceptions(_ count: Int) {
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(count).write(to: marker, atomically: true, encoding: .utf8)
    }

    func install() {
        #if canImport(ObjectiveC)
        installExceptionHandler(self)
        #endif
        #if canImport(MetricKit)
        installDiagnostics(self)
        #endif
    }
}

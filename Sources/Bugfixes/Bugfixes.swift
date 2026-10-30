import Foundation
#if canImport(UIKit)
import UIKit
#endif

public enum Level: Int, Comparable {
    case debug, info, warn, error

    var wire: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .warn: return "warn"
        case .error: return "error"
        }
    }

    public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Sends the app's crashes, hangs, errors and logs to Bugfixes, which groups them into reports and
/// raises tickets. Start it once at app launch; with no key it does nothing. It never crashes the app.
///
/// ```
/// Bugfixes.start(key: "bfm_…", environment: "production")
/// ```
public enum Bugfixes {
    public static let defaultServer = "https://api.bugfix.es/v1"

    private static let lock = NSLock()
    private static var client: Client?

    /// - Parameters:
    ///   - key: The project's public mobile key (`bfm_…`). Empty: reporting is off.
    ///   - release: Defaults to `CFBundleShortVersionString (CFBundleVersion)`.
    ///   - level: The lowest `log` level sent; `report` and crashes are always sent.
    ///   - server: Only change this for local development.
    public static func start(
        key: String,
        environment: String = "",
        release: String? = nil,
        level: Level = .error,
        server: String = defaultServer
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard client == nil else { return } // a second client would report each crash twice
        guard let device = Device.current(),
              let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let started = Client.make(
                  key: key, environment: environment, release: release, level: level, server: server,
                  device: device, dir: dir.appendingPathComponent("bugfixes")
              )
        else { return }
        client = started
        started.install()
        started.flushInBackground()
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            started.flushInBackground()
        }
        #endif
    }

    /// Reports a caught error.
    public static func report(_ error: Error) {
        current()?.report(error, symbols: Array(Thread.callStackSymbols.dropFirst()))
    }

    /// Sends a log line at or above the client's level (error by default).
    public static func log(_ level: Level, _ message: String, error: Error? = nil) {
        current()?.log(level, message, error: error, symbols: error == nil ? [] : Array(Thread.callStackSymbols.dropFirst()))
    }

    private static func current() -> Client? {
        lock.lock()
        defer { lock.unlock() }
        return client
    }
}

/// Only prints in debug builds; SDK errors are otherwise swallowed.
func debugLog(_ message: String) {
    #if DEBUG
    print("bugfixes: \(message)")
    #endif
}

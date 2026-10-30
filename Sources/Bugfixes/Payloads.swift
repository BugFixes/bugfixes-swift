import Foundation

/// The device and build every report carries.
struct Device {
    let app: String
    let executable: String
    let os: String
    let osVersion: String
    let model: String
    let appVersion: String
    let build: String

    /// nil without a bundle ID: the server only accepts a mobile key along with one.
    static func current() -> Device? {
        let bundle = Bundle.main
        guard let app = bundle.bundleIdentifier else {
            debugLog("not reporting: no bundle identifier")
            return nil
        }
        let info = bundle.infoDictionary ?? [:]
        return Device(
            app: app,
            executable: bundle.executableURL?.lastPathComponent ?? "",
            os: operatingSystem,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            model: model,
            appVersion: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? ""
        )
    }

    private static var operatingSystem: String {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return "macOS"
        #else
        return "iOS"
        #endif
    }

    /// e.g. `iPhone15,2`. Simulators report the host's CPU from `hw.machine`.
    private static var model: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #if canImport(Darwin)
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
        #else
        return ""
        #endif
    }
}

/// Builds `/v1/bug` and `/v1/log` bodies (orchestrator's `readCrashPayload` / `readLogPayload`).
struct Payloads {
    // the server takes up to 1 MiB; JSON escaping can roughly double a trace
    static let maxTrace = 256 * 1024
    static let maxMessage = 4 * 1024

    let device: Device
    let release: String
    let environment: String

    func error(_ error: Error, symbols: [String]) -> Data? {
        // a private type's name holds a memory address, which would split one error into many reports
        let name = String(reflecting: type(of: error))
            .replacingOccurrences(of: #"\(unknown context at \$[0-9a-f]+\)\."#, with: "", options: .regularExpression)
        let described = String(describing: error)
        return crash(
            level: "error", name: name, bug: "\(name): \(described)",
            message: (error as? LocalizedError)?.errorDescription ?? described, symbols: symbols
        )
    }

    func exception(name: String, reason: String, symbols: [String]) -> Data? {
        crash(level: "crash", name: name, bug: "\(name): \(reason)", message: reason, symbols: symbols)
    }

    /// A crash or hang the system recorded after the process died.
    func exit(reason: String, description: String, symbols: [String]) -> Data? {
        crash(
            level: "crash", name: reason, bug: "\(reason): \(description)", message: description, symbols: symbols,
            extra: ["exit_reason": reason]
        )
    }

    func log(_ level: Level, _ message: String, error: Error?, symbols: [String]) -> Data? {
        var fields = base(level.wire)
        fields["file"] = containsApp(symbols) ? device.executable : device.app
        fields["log"] = String(message.prefix(Self.maxMessage))
        if error != nil { fields["stack"] = trace(symbols) }
        return encode(fields)
    }

    private func crash(
        level: String, name: String, bug: String, message: String, symbols: [String], extra: [String: Any] = [:]
    ) -> Data? {
        var fields = base(level).merging(extra) { _, new in new }
        // ponytail: frames have no source file or line until dSYMs are uploaded (BF-54), so the binary stands in
        fields["file"] = containsApp(symbols) ? device.executable : name
        fields["line"] = "0"
        fields["line_number"] = 0
        fields["raw"] = trace(symbols)
        fields["bug"] = String(bug.prefix(Self.maxMessage))
        fields["message"] = String(message.prefix(Self.maxMessage))
        fields["errorName"] = name
        return encode(fields)
    }

    private func base(_ level: String) -> [String: Any] {
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "runtime": "ios",
            "level": level,
            "timestamp": timestamp.string(from: Date()),
            "release": release,
            "environment": environment,
            "os": device.os,
            "os_version": device.osVersion,
            "device_model": device.model,
            "app_version": device.appVersion,
            "build": device.build,
        ]
    }

    private func trace(_ symbols: [String]) -> String {
        String(symbols.joined(separator: "\n").prefix(Self.maxTrace))
    }

    /// `3   MyApp   0x0000000102b7c3a4 $s5MyApp4loadyyF + 128`: the second column is the binary.
    private func containsApp(_ symbols: [String]) -> Bool {
        !device.executable.isEmpty && symbols.contains { line in
            let columns = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            return columns.count > 1 && columns[1] == device.executable
        }
    }

    private func encode(_ fields: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: fields)
    }
}

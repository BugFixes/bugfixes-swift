import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

#if canImport(ObjectiveC)
private var previousHandler: (@convention(c) (NSException) -> Void)?
private var exceptionClient: Client?

/// Keeps any handler already set, such as another crash reporter's.
func installExceptionHandler(_ client: Client) {
    exceptionClient = client
    previousHandler = NSGetUncaughtExceptionHandler()
    NSSetUncaughtExceptionHandler { exception in
        exceptionClient?.recordException(
            name: exception.name.rawValue, reason: exception.reason ?? "", symbols: exception.callStackSymbols
        )
        previousHandler?(exception)
    }
}
#endif

#if canImport(MetricKit)
private var subscriber: DiagnosticsSubscriber?

// ponytail: no signal handler, so fatal signals and Swift traps arrive through MetricKit, usually on the
// next launch, and with the current release rather than the crashed one. Add one if that's too slow.
func installDiagnostics(_ client: Client) {
    let added = DiagnosticsSubscriber(client)
    subscriber = added // MXMetricManager only holds it weakly
    MXMetricManager.shared.add(added)
}

private final class DiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber {
    private let client: Client

    init(_ client: Client) {
        self.client = client
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let signal = crash.signal?.int32Value
                if signal == SIGABRT, client.consumePendingException() { continue }
                let reason = signal.map(signalName) ?? "crash"
                client.recordDiagnostic(
                    reason: reason,
                    description: crash.terminationReason ?? reason,
                    symbols: callStackSymbols(fromTree: crash.callStackTree.jsonRepresentation())
                )
            }
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                client.recordDiagnostic(
                    reason: "hang",
                    description: "the main thread hung for \(String(format: "%.1f", seconds))s",
                    symbols: callStackSymbols(fromTree: hang.callStackTree.jsonRepresentation())
                )
            }
        }
    }
}
#endif

/// Darwin's numbers, which is what MetricKit reports.
func signalName(_ signal: Int32) -> String {
    let names: [Int32: String] = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 10: "SIGBUS", 11: "SIGSEGV"]
    return names[signal] ?? "signal \(signal)"
}

/// Flattens MetricKit's call stack tree into `Thread.callStackSymbols` lines, the format the server parses:
/// the crashed thread, innermost frame first. MetricKit doesn't symbolicate, so the binary stands in
/// for the symbol and its offset is kept for BF-54.
func callStackSymbols(fromTree json: Data) -> [String] {
    guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return [] }
    let tree = root["callStackTree"] as? [String: Any] ?? root
    let stacks = tree["callStacks"] as? [[String: Any]] ?? []
    let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
    var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
    var symbols: [String] = []
    while let current = frame {
        let binary = current["binaryName"] as? String ?? "???"
        let address = (current["address"] as? NSNumber)?.uint64Value ?? 0
        let offset = (current["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
        let hex = String(address, radix: 16)
        let padded = String(repeating: "0", count: max(0, 16 - hex.count)) + hex
        symbols.append("\(symbols.count)   \(binary)   0x\(padded) \(binary) + \(offset)")
        frame = (current["subFrames"] as? [[String: Any]])?.first
    }
    return symbols
}

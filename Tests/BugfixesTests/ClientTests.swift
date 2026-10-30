import XCTest
@testable import Bugfixes

private enum Failure: Error { case timeout }

private let device = Device(
    app: "com.example.app", executable: "MyApp", os: "iOS", osVersion: "Version 18.0", model: "iPhone15,2",
    appVersion: "1.2", build: "34"
)

private let frames = [
    "0   UIKitCore   0x0000000180000000 -[UIApplication run] + 8",
    "1   MyApp   0x0000000102b7c3a4 $s5MyApp4loadyyF + 128",
]

final class ClientTests: XCTestCase {
    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data)) as? [String: Any])
    }

    private func make(_ server: String, level: Level = .error, dir: URL = temporaryDirectory()) throws -> Client {
        try XCTUnwrap(Client.make(key: "bfm_k", environment: "test", release: nil, level: level, server: server, device: device, dir: dir))
    }

    func testAKeyIsNeededAndItMustBeAMobileKey() {
        func make(_ key: String, server: String = Bugfixes.defaultServer) -> Client? {
            Client.make(key: key, environment: "", release: nil, level: .error, server: server, device: device, dir: temporaryDirectory())
        }
        XCTAssertNil(make(""))
        XCTAssertNil(make("   "))
        XCTAssertNil(make("agent_secret"))
        XCTAssertNil(make("bfm_k", server: "http://api.bugfix.es/v1"))
        XCTAssertNotNil(make(" bfm_k "))
    }

    func testAnErrorPayloadCarriesTheDeviceAndStack() throws {
        let body = try json(Payloads(device: device, release: "1.2 (34)", environment: "prod").error(Failure.timeout, symbols: frames))
        XCTAssertEqual(body["runtime"] as? String, "ios")
        XCTAssertEqual(body["level"] as? String, "error")
        XCTAssertEqual(body["release"] as? String, "1.2 (34)")
        XCTAssertEqual(body["environment"] as? String, "prod")
        XCTAssertEqual(body["os"] as? String, "iOS")
        XCTAssertEqual(body["os_version"] as? String, "Version 18.0")
        XCTAssertEqual(body["device_model"] as? String, "iPhone15,2")
        XCTAssertEqual(body["app_version"] as? String, "1.2")
        XCTAssertEqual(body["build"] as? String, "34")
        XCTAssertEqual(body["file"] as? String, "MyApp")
        XCTAssertEqual(body["line"] as? String, "0")
        XCTAssertEqual(body["line_number"] as? Int, 0)
        XCTAssertEqual(body["raw"] as? String, frames.joined(separator: "\n"))
        XCTAssertEqual(body["errorName"] as? String, "BugfixesTests.Failure")
        XCTAssertEqual(body["message"] as? String, "timeout")
        XCTAssertEqual(body["bug"] as? String, "BugfixesTests.Failure: timeout")
    }

    func testAFrameOutsideTheAppFallsBackToTheErrorName() throws {
        let body = try json(Payloads(device: device, release: "", environment: "").exception(name: "NSRangeException", reason: "out of bounds", symbols: [frames[0]]))
        XCTAssertEqual(body["level"] as? String, "crash")
        XCTAssertEqual(body["file"] as? String, "NSRangeException")
        XCTAssertEqual(body["bug"] as? String, "NSRangeException: out of bounds")
    }

    func testLongTracesAndMessagesAreBounded() throws {
        let long = String(repeating: "x", count: Payloads.maxTrace * 2)
        let body = try json(Payloads(device: device, release: "", environment: "").exit(reason: "hang", description: long, symbols: [long]))
        XCTAssertEqual((body["raw"] as? String)?.count, Payloads.maxTrace)
        XCTAssertEqual((body["message"] as? String)?.count, Payloads.maxMessage)
        XCTAssertEqual(body["exit_reason"] as? String, "hang")
    }

    func testALogPayloadOnlyHasAStackWithAnError() throws {
        let payloads = Payloads(device: device, release: "", environment: "")
        let plain = try json(payloads.log(.warn, "slow", error: nil, symbols: []))
        XCTAssertEqual(plain["level"] as? String, "warn")
        XCTAssertEqual(plain["log"] as? String, "slow")
        XCTAssertEqual(plain["file"] as? String, "com.example.app")
        XCTAssertNil(plain["stack"])
        let failed = try json(payloads.log(.error, "failed", error: Failure.timeout, symbols: frames))
        XCTAssertEqual(failed["file"] as? String, "MyApp")
        XCTAssertEqual(failed["stack"] as? String, frames.joined(separator: "\n"))
    }

    func testLogsBelowTheLevelAreNotSent() throws {
        let server = TestServer()
        defer { server.close() }
        let client = try make(server.url)
        client.log(.info, "quiet", error: nil, symbols: [])
        client.log(.warn, "quiet", error: nil, symbols: [])
        client.log(.error, "loud", error: nil, symbols: [])
        client.work.sync {}
        XCTAssertEqual(server.requests.map(\.path), ["/log"])
        XCTAssertTrue(server.requests[0].body.contains("loud"))

        let verbose = try make(server.url, level: .debug)
        verbose.log(.debug, "now sent", error: nil, symbols: [])
        verbose.work.sync {}
        XCTAssertEqual(server.requests.count, 2)
    }

    func testReportsStayQueuedUntilTheServerTakesThem() throws {
        let server = TestServer(status: 503)
        defer { server.close() }
        let client = try make(server.url)
        client.report(Failure.timeout, symbols: frames)
        client.work.sync {}
        XCTAssertEqual(server.requests.map(\.path), ["/bug"])

        server.status = 201
        client.flushInBackground()
        client.work.sync {}
        XCTAssertEqual(server.requests.count, 2)

        client.flushInBackground()
        client.work.sync {}
        XCTAssertEqual(server.requests.count, 2, "sent reports leave the queue")
    }

    func testARecordedExceptionIsSentOnTheNextLaunchAndHidesItsSigabrt() throws {
        let server = TestServer()
        defer { server.close() }
        let dir = temporaryDirectory()
        let dying = try make(server.url, dir: dir)
        dying.recordException(name: "NSRangeException", reason: "out of bounds", symbols: frames)
        XCTAssertTrue(server.requests.isEmpty, "the process is dying: written, not sent")

        let relaunched = try make(server.url, dir: dir)
        relaunched.flushInBackground()
        relaunched.work.sync {}
        XCTAssertEqual(server.requests.map(\.path), ["/bug"])
        XCTAssertTrue(relaunched.consumePendingException())
        XCTAssertFalse(relaunched.consumePendingException(), "a later SIGABRT is a real one")
    }

    func testSignalNames() {
        XCTAssertEqual(signalName(5), "SIGTRAP")
        XCTAssertEqual(signalName(11), "SIGSEGV")
        XCTAssertEqual(signalName(99), "signal 99")
    }

    func testACallStackTreeBecomesLinesTheServerParses() {
        let tree = """
        {"callStackPerThread": true, "callStacks": [
          {"threadAttributed": false, "callStackRootFrames": [{"binaryName": "Other", "address": 1, "offsetIntoBinaryTextSegment": 1}]},
          {"threadAttributed": true, "callStackRootFrames": [{
            "binaryName": "MyApp", "address": 4340564900, "offsetIntoBinaryTextSegment": 128, "sampleCount": 1,
            "subFrames": [{"binaryName": "UIKitCore", "address": 6442450944, "offsetIntoBinaryTextSegment": 8}]
          }]}
        ]}
        """
        XCTAssertEqual(callStackSymbols(fromTree: Data(tree.utf8)), [
            "0   MyApp   0x0000000102b7c3a4 MyApp + 128",
            "1   UIKitCore   0x0000000180000000 UIKitCore + 8",
        ])
        XCTAssertEqual(callStackSymbols(fromTree: Data(#"{"callStackTree": \#(tree)}"#.utf8)).count, 2)
        XCTAssertEqual(callStackSymbols(fromTree: Data("nope".utf8)), [])
    }

    #if canImport(ObjectiveC)
    func testTheExceptionHandlerWritesTheReportAndChainsToThePreviousOne() throws {
        previousCalled = false
        NSSetUncaughtExceptionHandler { _ in previousCalled = true }
        defer { NSSetUncaughtExceptionHandler(nil) }
        let server = TestServer()
        defer { server.close() }
        let dir = temporaryDirectory()
        installExceptionHandler(try make(server.url, dir: dir))

        let handler = try XCTUnwrap(NSGetUncaughtExceptionHandler())
        handler(NSException(name: .rangeException, reason: "out of bounds"))

        XCTAssertTrue(previousCalled)
        XCTAssertEqual(ReportQueue(dir: dir.appendingPathComponent("queue")).items().count, 1)
    }
    #endif
}

#if canImport(ObjectiveC)
private var previousCalled = false
#endif

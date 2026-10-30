import XCTest
@testable import Bugfixes

final class SenderQueueTests: XCTestCase {
    func testOnlyHttpsOrLocalServersAreAllowed() {
        XCTAssertTrue(Sender.allowed("https://api.bugfix.es/v1"))
        XCTAssertTrue(Sender.allowed("http://localhost:8080/v1"))
        XCTAssertTrue(Sender.allowed("http://127.0.0.1:8080/v1"))
        XCTAssertFalse(Sender.allowed("http://api.bugfix.es/v1"))
        XCTAssertFalse(Sender.allowed("ftp://api.bugfix.es"))
        XCTAssertFalse(Sender.allowed("https://"))
        XCTAssertFalse(Sender.allowed("not a url"))
    }

    func testSendsTheMobileKeyAndAppId() throws {
        let server = TestServer()
        defer { server.close() }
        XCTAssertEqual(Sender(server: "\(server.url)/v1", key: "bfm_k", app: "com.example.app").send("bug", Data(#"{"a":1}"#.utf8)), .sent)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.path, "/v1/bug")
        XCTAssertEqual(request.headers["authorization"], "Bearer bfm_k")
        XCTAssertEqual(request.headers["x-bugfixes-app"], "com.example.app")
        XCTAssertEqual(request.body, #"{"a":1}"#)
    }

    func testNeverFollowsARedirectWithTheKey() {
        let other = TestServer()
        let server = TestServer(status: 302, location: "\(other.url)/steal")
        defer {
            other.close()
            server.close()
        }
        XCTAssertEqual(Sender(server: server.url, key: "bfm_k", app: "a.b").send("bug", Data("{}".utf8)), .drop)
        XCTAssertTrue(other.requests.isEmpty)
    }

    func testRetriesServerFailuresAndDropsRejectedReports() {
        let server = TestServer(status: 503)
        defer { server.close() }
        let sender = Sender(server: server.url, key: "bfm_k", app: "a.b")
        let body = Data("{}".utf8)
        XCTAssertEqual(sender.send("bug", body), .retry)
        server.status = 429
        XCTAssertEqual(sender.send("bug", body), .retry)
        server.status = 400
        XCTAssertEqual(sender.send("bug", body), .drop)
        server.status = 401
        XCTAssertEqual(sender.send("bug", body), .drop)
        // nothing listening: try again later
        XCTAssertEqual(Sender(server: "http://127.0.0.1:1", key: "bfm_k", app: "a.b", timeout: 1).send("bug", body), .retry)
    }

    func testQueueKeepsOrderAndDropsTheOldestPastItsCap() throws {
        let queue = ReportQueue(dir: temporaryDirectory(), cap: 3)
        for i in 1...5 { queue.add(i % 2 == 0 ? "log" : "bug", Data("r\(i)".utf8)) }
        let items = queue.items()
        XCTAssertEqual(try items.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }, ["r3", "r4", "r5"])
        XCTAssertEqual(items.map(\.pathExtension), ["bug", "log", "bug"])
    }
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("bugfixes-tests-\(UUID().uuidString)")
}

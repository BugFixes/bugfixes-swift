import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// POSTs one report with the mobile key. Never follows redirects, so the key only goes to `server`.
///
/// ponytail: a plain session, not a background one, which needs file uploads and an app delegate hook;
/// anything unsent stays queued for the next report or activation. Add it if reports go missing.
final class Sender {
    enum Outcome { case sent, drop, retry }

    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    private let server: String
    private let key: String
    private let app: String
    private let timeout: TimeInterval
    private let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    init(server: String, key: String, app: String, timeout: TimeInterval = 15) {
        self.server = server.hasSuffix("/") ? String(server.dropLast()) : server
        self.key = key
        self.app = app
        self.timeout = timeout
    }

    /// https, or plain http only to this machine for local development.
    static func allowed(_ server: String) -> Bool {
        guard let parts = URLComponents(string: server), let host = parts.host, !host.isEmpty else { return false }
        return parts.scheme == "https" || (parts.scheme == "http" && localHosts.contains(host))
    }

    /// Blocks until answered: call it off the main thread.
    func send(_ endpoint: String, _ body: Data) -> Outcome {
        guard let url = URL(string: "\(server)/\(endpoint)") else { return .drop }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(app, forHTTPHeaderField: "X-Bugfixes-App")

        let answer = Answer()
        let answered = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, response, error in
            defer { answered.signal() }
            guard error == nil, let status = (response as? HTTPURLResponse)?.statusCode else { return }
            switch status {
            case 200...299: answer.outcome = .sent
            case 408, 429, 500...599: answer.outcome = .retry
            // a redirect or a rejected report (bad key, bad payload) won't succeed later either
            default: answer.outcome = .drop
            }
        }.resume()
        answered.wait()
        return answer.outcome
    }

    /// Written by the task's callback, read after `answered` has signalled.
    private final class Answer: @unchecked Sendable {
        var outcome = Outcome.retry
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

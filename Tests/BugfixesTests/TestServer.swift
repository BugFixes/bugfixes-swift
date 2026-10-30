import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// A local server that records requests and answers with `status`.
final class TestServer {
    struct Request {
        let path: String
        let headers: [String: String]
        let body: String
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private var answer: Int
    private let location: String?
    private let fd: Int32
    let url: String

    var status: Int {
        get { lock.lock(); defer { lock.unlock() }; return answer }
        set { lock.lock(); answer = newValue; lock.unlock() }
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    init(status: Int = 201, location: String? = nil) {
        answer = status
        self.location = location
        #if canImport(Glibc)
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        #if canImport(Darwin)
        address.sin_len = UInt8(length)
        #endif
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(listener, $0, length)
                _ = getsockname(listener, $0, &length)
            }
        }
        listen(listener, 16)
        fd = listener
        url = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        let thread = Thread { [self] in serve() }
        thread.start()
    }

    func close() {
        shutdown(fd, Int32(SHUT_RDWR))
        #if canImport(Glibc)
        _ = Glibc.close(fd)
        #else
        _ = Darwin.close(fd)
        #endif
    }

    private func serve() {
        while true {
            let connection = accept(fd, nil, nil)
            if connection < 0 { return }
            handle(connection)
            #if canImport(Glibc)
            _ = Glibc.close(connection)
            #else
            _ = Darwin.close(connection)
            #endif
        }
    }

    private func handle(_ connection: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        var expected = Int.max
        while data.count < expected {
            let count = read(connection, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if headEnd == nil, let found = data.range(of: separator) {
                headEnd = found
                let head = String(decoding: data[..<found.lowerBound], as: UTF8.self)
                let length = head.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                expected = found.upperBound + length
            }
        }
        guard let end = headEnd else { return }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { headers[parts[0].lowercased()] = parts[1] }
        }
        let path = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? ""
        lock.lock()
        recorded.append(Request(path: path, headers: headers, body: String(decoding: data[end.upperBound...], as: UTF8.self)))
        let code = answer
        lock.unlock()
        var response = "HTTP/1.1 \(code) Test\r\nContent-Length: 0\r\nConnection: close\r\n"
        if let location { response += "Location: \(location)\r\n" }
        response += "\r\n"
        _ = response.withCString { write(connection, $0, strlen($0)) }
    }
}

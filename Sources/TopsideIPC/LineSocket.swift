import Darwin
import Foundation

/// One request line in, one response line out, over a Unix domain socket.
/// Used for the CLI ↔ engine channel and (from M3) for permission requests.

public enum SocketError: Error, CustomStringConvertible, Equatable {
    case pathTooLong(String)
    case alreadyRunning(String)
    case system(String, Int32)
    case noResponse

    public var description: String {
        switch self {
        case .pathTooLong(let p): return "Socket path is too long (max 103 bytes): \(p)"
        case .alreadyRunning(let p): return "Another process is already listening on \(p)"
        case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
        case .noResponse: return "The other side closed the connection without answering"
        }
    }
}

/// Requests and responses are capped so a broken peer cannot exhaust memory.
let maxMessageBytes = 16 * 1024 * 1024

/// Blocking socket I/O runs on its own thread, never on GCD's shared pool or
/// Swift's cooperative pool: each call can block for up to its timeout, and
/// many of them at once exhausted GCD's thread limit during M1 testing.
func onOwnThread(_ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.stackSize = 256 * 1024
    thread.start()
}

func makeAddress(_ path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return addr
}

func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
    var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

/// Read until the first newline (excluded) or EOF. nil on timeout/error with nothing read.
func readLine(_ fd: Int32) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while data.count < maxMessageBytes {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            if let nl = buffer[0..<n].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: buffer[0..<nl])
                return data
            }
            data.append(contentsOf: buffer[0..<n])
        } else if n == 0 {
            return data.isEmpty ? nil : data
        } else if errno == EINTR {
            continue
        } else {
            return data.isEmpty ? nil : data
        }
    }
    return data
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    return data.withUnsafeBytes { raw -> Bool in
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }
}

public final class LineSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) async -> Data

    public let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "topside.socket.accept")
    private var source: DispatchSourceRead?
    private let lock = NSLock()

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        if LineSocketClient.isListening(path) { throw SocketError.alreadyRunning(path) }
        var addr = try makeAddress(path)
        unlink(path)   // stale socket from a previous run; nobody is listening on it

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        // Not umask(): it is process-wide, and changing it here briefly broke
        // directories other threads were creating (found by the full test run).
        // Connecting needs write permission, which the default umask already
        // withholds from others; chmod then narrows it to this user only.
        let bound = withSockaddr(&addr) { bind(fd, $0, $1) }
        guard bound == 0 else { let e = errno; close(fd); throw SocketError.system("bind", e) }
        guard chmod(path, 0o600) == 0 else { let e = errno; close(fd); unlink(path); throw SocketError.system("chmod", e) }
        guard listen(fd, 128) == 0 else { let e = errno; close(fd); throw SocketError.system("listen", e) }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending(fd) }
        src.setCancelHandler { close(fd) }
        lock.withLock { source = src }
        src.resume()
    }

    private func acceptPending(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }   // EAGAIN: nothing more to accept
            let flags = fcntl(client, F_GETFL)
            _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK)
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            setTimeouts(client, seconds: 10)
            let handler = self.handler
            onOwnThread {
                guard let request = readLine(client) else { close(client); return }
                Task {
                    var response = await handler(request)
                    response.append(UInt8(ascii: "\n"))
                    _ = writeAll(client, response)
                    close(client)
                }
            }
        }
    }

    /// Stop listening and remove the socket file, but only if this server bound
    /// it: a server that failed to start (e.g. because another one is already
    /// listening on the path) must not delete the other server's socket.
    public func stop() {
        let wasListening = lock.withLock { () -> Bool in
            defer { source = nil }
            guard let s = source else { return false }
            s.cancel()
            return true
        }
        if wasListening { unlink(path) }
    }

    deinit { stop() }
}

public enum LineSocketClient {
    /// Async form of `request`. The blocking I/O runs on its own thread, so it
    /// cannot starve Swift's cooperative pool (which a server in the same
    /// process needs to answer) or GCD's.
    public static func send(path: String, _ payload: Data, timeout: TimeInterval = 30) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            onOwnThread {
                continuation.resume(with: Result { try request(path: path, payload, timeout: timeout) })
            }
        }
    }

    /// Send one line, wait for one line back. Blocks the calling thread.
    public static func request(path: String, _ payload: Data, timeout: TimeInterval = 30) throws -> Data {
        var addr = try makeAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        defer { close(fd) }
        setTimeouts(fd, seconds: timeout)
        guard withSockaddr(&addr, { connect(fd, $0, $1) }) == 0 else { throw SocketError.system("connect", errno) }
        var line = payload
        line.append(UInt8(ascii: "\n"))
        guard writeAll(fd, line) else { throw SocketError.system("write", errno) }
        guard let response = readLine(fd) else { throw SocketError.noResponse }
        return response
    }

    public static func isListening(_ path: String) -> Bool {
        guard var addr = try? makeAddress(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withSockaddr(&addr) { connect(fd, $0, $1) } == 0
    }
}

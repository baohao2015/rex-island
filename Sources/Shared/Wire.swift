import Foundation
import Darwin

/// The line protocol between `rexisland-bridge` and the app: one JSON object per line over a Unix socket.
///
/// bridge → app: `{"v":1,"type":"hook","agent":"claude","event":"PermissionRequest","blocking":true,
///                 "rex":{"server","session","block"},"pid":123,"cwd":"…","payload":{…}}`
///               `{"v":1,"type":"ctl","args":["list"]}`
/// app → bridge (blocking hooks only): `{"decision":{…}}`, the object the agent expects under
///               `hookSpecificOutput.decision`, or `{}` for "no answer: let the agent ask in the terminal".
enum Wire {
    static let version = 1
    /// Seconds an agent waits for a PermissionRequest hook. Written into the hook config.
    static let permissionHookTimeout = 3600
    /// The bridge gives up a little before the agent kills it.
    static let replyTimeout: TimeInterval = TimeInterval(permissionHookTimeout - 30)
    static let blockingEvents: Set<String> = ["PermissionRequest"]
}

enum SocketIO {
    /// Connects to a Unix socket; returns the descriptor or -1.
    static func connect(to path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_un()
        guard fillAddress(&addr, path: path) else { close(fd); return -1 }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return -1 }
        noSigPipe(fd)
        return fd
    }

    static func fillAddress(_ addr: inout sockaddr_un, path: String) -> Bool {
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return true
    }

    static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
    }

    /// Reads up to the first newline. Nil on EOF, error, timeout, or a line over `limit` bytes.
    static func readLine(_ fd: Int32, timeout: TimeInterval, limit: Int = 8 << 20) -> Data? {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining, 60) * 1000))
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { continue }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return nil
            }
            if count == 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
            if let newline = buffer.firstIndex(of: 0x0A) {
                return buffer.subdata(in: buffer.startIndex..<newline)
            }
            if buffer.count > limit { return nil }
        }
    }

    static func line(_ object: Any) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        data.append(0x0A)
        return data
    }
}

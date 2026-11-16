import Foundation
import Darwin

/// Listens on the Unix socket that `rexisland-bridge` connects to. Only this user's processes may connect.
final class BridgeServer {
    private let path: String
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "rexisland.bridge")

    /// A hook message, on the main queue. `connection` is set for blocking hooks that wait for an answer.
    var onHook: (_ envelope: [String: Any], _ connection: BridgeConnection?) -> Void = { _, _ in }
    /// A `rexisland-bridge ctl` command, on the main queue. Call `reply` once.
    var onControl: (_ args: [String], _ reply: @escaping ([String: Any]) -> Void) -> Void = { _, reply in reply([:]) }

    init(path: String) {
        self.path = path
    }

    func start() throws {
        RIPaths.ensureSupportDirectory()
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = sockaddr_un()
        guard SocketIO.fillAddress(&addr, path: path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 32) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    private func acceptOne() {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        SocketIO.noSigPipe(fd)
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let line = SocketIO.readLine(fd, timeout: 10),
                  let envelope = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  envelope["v"] as? Int == Wire.version else {
                close(fd)
                return
            }
            self?.dispatch(envelope, fd: fd)
        }
    }

    private func dispatch(_ envelope: [String: Any], fd: Int32) {
        switch envelope["type"] as? String {
        case "hook":
            let blocking = envelope["blocking"] as? Bool ?? false
            let connection = blocking ? BridgeConnection(fd: fd) : nil
            if !blocking { close(fd) }
            DispatchQueue.main.async { self.onHook(envelope, connection) }
        case "ctl":
            let args = envelope["args"] as? [String] ?? []
            let connection = BridgeConnection(fd: fd)
            DispatchQueue.main.async { self.onControl(args) { connection.send($0) } }
        default:
            close(fd)
        }
    }
}

/// A hook waiting for its answer. Closed exactly once: by an answer, by `cancel()`, or by the hook going away.
final class BridgeConnection {
    private let fd: Int32
    private var source: DispatchSourceRead?
    private var finished = false
    private let queue = DispatchQueue(label: "rexisland.connection")

    /// The hook went away before an answer (the agent timed out or exited). Called on the main queue.
    var onHangUp: () -> Void = {}

    init(fd: Int32) {
        self.fd = fd
    }

    /// Starts noticing when the hook process goes away.
    func watchForHangUp() {
        queue.async {
            guard !self.finished else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: self.fd, queue: self.queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                var byte: UInt8 = 0
                if read(self.fd, &byte, 1) <= 0 { self.finish(notify: true) }
            }
            // The descriptor is closed only once the source lets go of it.
            let fd = self.fd
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
    }

    func send(_ object: [String: Any]) {
        queue.async {
            guard !self.finished else { return }
            if let line = SocketIO.line(object) { SocketIO.writeAll(self.fd, line) }
            self.finish(notify: false)
        }
    }

    /// Closes without an answer: the agent goes on as if no hook had run.
    func cancel() {
        queue.async { self.finish(notify: false) }
    }

    private func finish(notify: Bool) {
        guard !finished else { return }
        finished = true
        if let source {
            source.cancel()
            self.source = nil
        } else {
            close(fd)
        }
        if notify { DispatchQueue.main.async { self.onHangUp() } }
    }
}

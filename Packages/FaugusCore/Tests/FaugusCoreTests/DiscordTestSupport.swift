import Darwin
@testable import FaugusCore
import Foundation
import Testing

// MARK: - Test doubles

/// A fake Discord: listens on `<directory>/discord-ipc-<socketIndex>`, answers handshakes and
/// records every frame it receives.
final class FakeDiscordServer: @unchecked Sendable {
    struct Activity: Equatable {
        var clientID: String
        var payload: JSONValue
    }

    let directory: String
    let socketIndex: Int
    private let replyOpcode: DiscordOpcode
    private let lock = NSLock()
    private var listenerDescriptor: Int32 = -1
    private var shouldStop = false
    private var shouldDropConnections = false
    private var handshakes: [String] = []
    private var activities: [Activity] = []
    private var closedCount = 0
    private var openCount = 0

    /// Unix socket paths are limited to about 100 bytes, so the directory lives directly in `/tmp`.
    init(socketIndex: Int = 0, replyOpcode: DiscordOpcode = .frame) {
        directory = "/tmp/fdt-" + String(UUID().uuidString.prefix(8))
        self.socketIndex = socketIndex
        self.replyOpcode = replyOpcode
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    var socketPath: String {
        directory + "/discord-ipc-\(socketIndex)"
    }

    var handshakeClientIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return handshakes
    }

    var receivedActivities: [Activity] {
        lock.lock()
        defer { lock.unlock() }
        return activities
    }

    var closedConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closedCount
    }

    var openConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return openCount
    }

    func dropConnections() {
        lock.lock()
        shouldDropConnections = true
        lock.unlock()
    }

    func restoreConnections() {
        lock.lock()
        shouldDropConnections = false
        lock.unlock()
    }

    func start() throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0, var address = DiscordConnection.makeAddress(path: socketPath) else {
            throw DiscordIPCError.socketUnavailable("fake server")
        }
        unlink(socketPath)
        let bound = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            throw DiscordIPCError.socketUnavailable("fake server bind")
        }
        lock.lock()
        listenerDescriptor = descriptor
        lock.unlock()
        DispatchQueue.global().async { self.acceptLoop(descriptor) }
    }

    func stop() {
        lock.lock()
        shouldStop = true
        lock.unlock()
        // The accept loop closes the listener itself; give it a moment, then remove the files.
        Thread.sleep(forTimeInterval: 0.15)
        try? FileManager.default.removeItem(atPath: directory)
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shouldStop
    }

    private func acceptLoop(_ listener: Int32) {
        while !isStopping {
            var pollDescriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, 50) > 0 else { continue }
            let connectionDescriptor = accept(listener, nil, nil)
            guard connectionDescriptor >= 0 else { continue }
            lock.lock()
            openCount += 1
            lock.unlock()
            DispatchQueue.global().async { self.serve(connectionDescriptor) }
        }
        Darwin.close(listener)
    }

    private func serve(_ descriptor: Int32) {
        var interval = timeval(tv_sec: 0, tv_usec: 50000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        var clientID = ""
        var chunk = [UInt8](repeating: 0, count: 4096)
        loop: while !isStopping {
            lock.lock()
            let mustDrop = shouldDropConnections
            lock.unlock()
            if mustDrop {
                break loop
            }
            let received = recv(descriptor, &chunk, chunk.count, 0)
            if received == 0 {
                break loop
            }
            if received < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    continue
                }
                break loop
            }
            buffer.append(contentsOf: chunk.prefix(received))
            while let frame = try? DiscordFrame.extractFrame(from: &buffer) {
                if frame.opcode == DiscordOpcode.handshake.rawValue {
                    clientID = frame.json?.objectValue?["client_id"]?.stringValue ?? ""
                    record(handshake: clientID)
                } else if let payload = frame.json {
                    record(activity: Activity(clientID: clientID, payload: payload))
                }
                let reply = DiscordFrame(opcode: replyOpcode, json: ["cmd": "DISPATCH", "evt": "READY"])
                _ = reply.encoded().withUnsafeBytes { send(descriptor, $0.baseAddress, $0.count, 0) }
            }
        }
        Darwin.close(descriptor)
        lock.lock()
        closedCount += 1
        openCount -= 1
        lock.unlock()
    }

    private func record(handshake clientID: String) {
        lock.lock()
        handshakes.append(clientID)
        lock.unlock()
    }

    private func record(activity: Activity) {
        lock.lock()
        activities.append(activity)
        lock.unlock()
    }
}

final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value
    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get { lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set { lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&storedValue)
        lock.unlock()
    }
}

final class FakeDiscordPresence: DiscordPresenceControlling, @unchecked Sendable {
    let startCount = LockedValue(0)
    let stopCount = LockedValue(0)
    let iconProvider = LockedValue<DiscordIconProvider?>(nil)
    func start() async {
        startCount.update { $0 += 1 }
    }

    func stop() async {
        stopCount.update { $0 += 1 }
    }
}

func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

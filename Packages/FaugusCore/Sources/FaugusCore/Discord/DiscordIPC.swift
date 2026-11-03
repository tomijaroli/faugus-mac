import Darwin
import Foundation

/// Opcodes of Discord's local IPC protocol.
public enum DiscordOpcode: UInt32, Sendable {
    case handshake = 0
    case frame = 1
    case close = 2
    case ping = 3
    case pong = 4
}

public enum DiscordIPCError: Error, Equatable, Sendable, CustomStringConvertible {
    case socketUnavailable(String)
    case connectionClosed
    case timedOut
    case payloadTooLarge(Int)
    case handshakeRejected
    case inputOutput(String)

    public var description: String {
        switch self {
        case let .socketUnavailable(reason): "Discord socket unavailable: \(reason)"
        case .connectionClosed: "Discord closed the connection"
        case .timedOut: "Discord did not answer in time"
        case let .payloadTooLarge(length): "Discord frame of \(length) bytes is too large"
        case .handshakeRejected: "Discord rejected the handshake"
        case let .inputOutput(reason): "Discord socket error: \(reason)"
        }
    }
}

/// One IPC frame: `UInt32` little-endian opcode, `UInt32` little-endian payload length, JSON
/// payload (upstream `discord_frame`).
public struct DiscordFrame: Equatable, Sendable {
    public static let headerLength = 8
    /// Discord never sends more than a few KiB; anything bigger is a protocol error.
    public static let maximumPayloadLength = 1 << 20

    public var opcode: UInt32
    public var payload: Data

    public init(opcode: UInt32, payload: Data) {
        self.opcode = opcode
        self.payload = payload
    }

    public init(opcode: DiscordOpcode, json: JSONValue) {
        self.init(opcode: opcode.rawValue, payload: JSONWriter.serialize(json, indent: 0))
    }

    /// The payload parsed as JSON, if it is.
    public var json: JSONValue? {
        try? JSONParser.parse(payload)
    }

    public func encoded() -> Data {
        var data = Data(capacity: Self.headerLength + payload.count)
        withUnsafeBytes(of: opcode.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// Reads the 8-byte header; `nil` when fewer than 8 bytes are given.
    public static func decodeHeader(_ header: Data) -> (opcode: UInt32, payloadLength: Int)? {
        let bytes = [UInt8](header.prefix(headerLength))
        guard bytes.count == headerLength else { return nil }
        return (littleEndianInteger(bytes[0 ..< 4]), Int(littleEndianInteger(bytes[4 ..< 8])))
    }

    /// Removes and returns the first complete frame of `buffer`; `nil` while it is still partial.
    public static func extractFrame(from buffer: inout Data) throws -> DiscordFrame? {
        guard let header = decodeHeader(buffer) else { return nil }
        guard header.payloadLength <= maximumPayloadLength else {
            throw DiscordIPCError.payloadTooLarge(header.payloadLength)
        }
        let frameLength = headerLength + header.payloadLength
        guard buffer.count >= frameLength else { return nil }
        let bytes = [UInt8](buffer.prefix(frameLength))
        buffer = Data(buffer.dropFirst(frameLength))
        return DiscordFrame(opcode: header.opcode, payload: Data(bytes[headerLength...]))
    }

    private static func littleEndianInteger(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

/// Where Discord's `discord-ipc-0` ... `discord-ipc-9` sockets live. On macOS that is the per-user
/// temporary directory (`$TMPDIR`); `$XDG_RUNTIME_DIR` and `/tmp` are tried too.
public enum DiscordSocketLocator {
    public static let socketCount = 10

    public static func defaultRuntimeDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let candidates = [
            NSTemporaryDirectory(), environment["TMPDIR"] ?? "", environment["XDG_RUNTIME_DIR"] ?? "", "/tmp",
        ]
        var directories: [String] = []
        for candidate in candidates {
            var trimmed = candidate
            while trimmed.count > 1, trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
            if !trimmed.isEmpty, !directories.contains(trimmed) {
                directories.append(trimmed)
            }
        }
        return directories
    }

    /// Existing socket paths, directory by directory, index 0 through 9.
    public static func socketPaths(
        in directories: [String],
        pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        var paths: [String] = []
        for directory in directories {
            for socketIndex in 0 ..< socketCount {
                let path = directory + "/discord-ipc-\(socketIndex)"
                if pathExists(path) {
                    paths.append(path)
                }
            }
        }
        return paths
    }
}

/// A connected, handshaken Discord IPC socket. Closing is idempotent and safe from any thread,
/// including while another thread is blocked in `send`/`receiveFrame` (the descriptor is only
/// released once no operation is using it).
public final class DiscordConnection: @unchecked Sendable {
    public let socketPath: String
    private let lock = NSLock()
    private var descriptor: Int32
    private var isClosing = false
    private var activeOperations = 0

    private init(descriptor: Int32, socketPath: String) {
        self.descriptor = descriptor
        self.socketPath = socketPath
    }

    deinit {
        close()
    }

    /// Connects to the first Discord socket that accepts the handshake for `clientID`
    /// (upstream `discord_connect`).
    public static func connect(
        clientID: String, socketDirectories: [String], timeout: TimeInterval = 3
    ) -> DiscordConnection? {
        for path in DiscordSocketLocator.socketPaths(in: socketDirectories) {
            if let connection = try? open(path: path, clientID: clientID, timeout: timeout) {
                return connection
            }
        }
        return nil
    }

    static func open(path: String, clientID: String, timeout: TimeInterval) throws -> DiscordConnection {
        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw DiscordIPCError.socketUnavailable(describeLastError()) }
        do {
            try configure(socketDescriptor, timeout: timeout)
            try connectSocket(socketDescriptor, path: path)
            let handshake = DiscordFrame(opcode: .handshake, json: ["v": 1, "client_id": .string(clientID)])
            try writeAll(socketDescriptor, handshake.encoded())
            let reply = try readFrame(socketDescriptor)
            guard reply.opcode != DiscordOpcode.close.rawValue else { throw DiscordIPCError.handshakeRejected }
        } catch {
            Darwin.close(socketDescriptor)
            throw error
        }
        return DiscordConnection(descriptor: socketDescriptor, socketPath: path)
    }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0 && !isClosing
    }

    public func send(_ frame: DiscordFrame) throws {
        let socketDescriptor = try beginOperation()
        defer { endOperation() }
        try Self.writeAll(socketDescriptor, frame.encoded())
    }

    public func receiveFrame() throws -> DiscordFrame {
        let socketDescriptor = try beginOperation()
        defer { endOperation() }
        return try Self.readFrame(socketDescriptor)
    }

    /// Reads and throws away whatever Discord has sent (its replies to our frames) without
    /// blocking. `false` once Discord closed its end or the socket failed.
    public func discardPendingReplies() -> Bool {
        guard let socketDescriptor = try? beginOperation() else { return false }
        defer { endOperation() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = recv(socketDescriptor, &buffer, buffer.count, MSG_DONTWAIT)
            if received > 0 {
                continue
            }
            if received == 0 {
                return false
            }
            if errno == EINTR {
                continue
            }
            return errno == EAGAIN || errno == EWOULDBLOCK
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, !isClosing else { return }
        isClosing = true
        // Wakes up an operation blocked on this socket; it releases the descriptor when it ends.
        shutdown(descriptor, SHUT_RDWR)
        if activeOperations == 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    private func beginOperation() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, !isClosing else { throw DiscordIPCError.connectionClosed }
        activeOperations += 1
        return descriptor
    }

    private func endOperation() {
        lock.lock()
        defer { lock.unlock() }
        activeOperations -= 1
        if isClosing, activeOperations == 0, descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    // MARK: Socket plumbing

    static func makeAddress(path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            for (offset, byte) in pathBytes.enumerated() {
                destination[offset] = UInt8(bitPattern: byte)
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    private static func configure(_ socketDescriptor: Int32, timeout: TimeInterval) throws {
        var enabled: Int32 = 1
        var interval = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000)
        )
        let results = [
            setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)),
            setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size)),
            setsockopt(socketDescriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size)),
        ]
        guard results.allSatisfy({ $0 == 0 }) else { throw DiscordIPCError.inputOutput(describeLastError()) }
    }

    private static func connectSocket(_ socketDescriptor: Int32, path: String) throws {
        guard var address = makeAddress(path: path) else {
            throw DiscordIPCError.socketUnavailable("path too long: \(path)")
        }
        let result = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw DiscordIPCError.socketUnavailable(describeLastError()) }
    }

    private static func writeAll(_ socketDescriptor: Int32, _ data: Data) throws {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { rawBytes in
                Darwin.send(socketDescriptor, rawBytes.baseAddress.map { $0 + offset }, bytes.count - offset, 0)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                throw DiscordIPCError.timedOut
            } else {
                throw DiscordIPCError.inputOutput(describeLastError())
            }
        }
    }

    private static func readExactly(_ socketDescriptor: Int32, count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { rawBytes in
                recv(socketDescriptor, rawBytes.baseAddress.map { $0 + offset }, count - offset, 0)
            }
            if received > 0 {
                offset += received
            } else if received == 0 {
                throw DiscordIPCError.connectionClosed
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw DiscordIPCError.timedOut
            } else {
                throw DiscordIPCError.inputOutput(describeLastError())
            }
        }
        return bytes
    }

    private static func readFrame(_ socketDescriptor: Int32) throws -> DiscordFrame {
        let headerBytes = try readExactly(socketDescriptor, count: DiscordFrame.headerLength)
        guard let header = DiscordFrame.decodeHeader(Data(headerBytes)) else { throw DiscordIPCError.connectionClosed }
        guard header.payloadLength <= DiscordFrame.maximumPayloadLength else {
            throw DiscordIPCError.payloadTooLarge(header.payloadLength)
        }
        let payload = try readExactly(socketDescriptor, count: header.payloadLength)
        return DiscordFrame(opcode: header.opcode, payload: Data(payload))
    }

    private static func describeLastError() -> String {
        String(cString: strerror(errno))
    }
}

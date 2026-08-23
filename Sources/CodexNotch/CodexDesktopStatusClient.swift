import CodexNotchCore
import Darwin
import Foundation

@MainActor
final class CodexDesktopStatusClient {
    typealias SnapshotHandler = @MainActor ([String: CodexTaskState]) -> Void

    private let onSnapshot: SnapshotHandler
    private let workerQueue = DispatchQueue(label: "com.example.codexnotch.desktop-status")
    private let refreshInterval: TimeInterval = 5
    private var requestedThreadIDs: [String] = []
    private var inFlightThreadIDs: [String]?
    private var lastStartedAt = Date.distantPast

    init(onSnapshot: @escaping SnapshotHandler) {
        self.onSnapshot = onSnapshot
    }

    func refresh(threadIDs: [String]) {
        let normalized = Array(Set(threadIDs)).sorted()
        let changed = normalized != requestedThreadIDs
        requestedThreadIDs = normalized

        guard !normalized.isEmpty else {
            onSnapshot([:])
            return
        }
        guard inFlightThreadIDs == nil else { return }
        guard changed || Date().timeIntervalSince(lastStartedAt) >= refreshInterval else { return }

        startRefresh(for: normalized)
    }

    func stop() {
        requestedThreadIDs = []
        inFlightThreadIDs = nil
    }

    private func startRefresh(for threadIDs: [String]) {
        inFlightThreadIDs = threadIDs
        lastStartedAt = Date()

        workerQueue.async { [weak self] in
            let snapshot = (try? CodexDesktopIPCSession().fetchStates(for: threadIDs)) ?? [:]
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlightThreadIDs = nil
                if self.requestedThreadIDs == threadIDs {
                    self.onSnapshot(snapshot)
                } else if !self.requestedThreadIDs.isEmpty {
                    self.startRefresh(for: self.requestedThreadIDs)
                }
            }
        }
    }
}

private final class CodexDesktopIPCSession {
    private enum SessionError: Error {
        case socketUnavailable
        case socketPathTooLong
        case connectionFailed
        case invalidFrame
        case invalidResponse
        case requestFailed
    }

    private let socketPath: String
    private var descriptor: Int32 = -1
    private var clientID = "initializing-client"
    private var receivedStates: [String: CodexTaskState] = [:]

    init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    ) {
        socketPath = codexHome.appendingPathComponent("ipc/ipc.sock").path
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    func fetchStates(for threadIDs: [String]) throws -> [String: CodexTaskState] {
        try connect()
        try initialize()

        for threadID in threadIDs {
            try? fetchState(for: threadID)
        }
        return receivedStates
    }

    private func connect() throws {
        let socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw SessionError.socketUnavailable }
        descriptor = socketDescriptor

        var noSigPipe: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw SessionError.socketUnavailable
        }

        var timeout = timeval(tv_sec: 8, tv_usec: 0)
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var address = sockaddr_un()
        let pathBytes = Array(socketPath.utf8CString)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else { throw SessionError.socketPathTooLong }

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { destination in
                pathBytes.withUnsafeBufferPointer { source in
                    if let baseAddress = source.baseAddress {
                        memcpy(destination, baseAddress, pathBytes.count)
                    }
                }
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else { throw SessionError.connectionFailed }
    }

    private func initialize() throws {
        let response = try request(
            method: "initialize",
            params: ["clientType": "codex-notch"],
            version: 0,
            timeoutMilliseconds: 3_000
        )
        guard response["resultType"] as? String == "success",
              let result = response["result"] as? [String: Any],
              let assignedID = result["clientId"] as? String else {
            throw SessionError.invalidResponse
        }
        clientID = assignedID
    }

    private func fetchState(for threadID: String) throws {
        let ownerResponse = try request(
            method: "thread-owner-discovery",
            params: ["hostId": "local", "conversationId": threadID],
            version: 1,
            timeoutMilliseconds: 3_000
        )
        guard ownerResponse["resultType"] as? String == "success",
              let ownerID = ownerResponse["handledByClientId"] as? String else {
            throw SessionError.requestFailed
        }

        try send([
            "type": "broadcast",
            "method": "thread-stream-following-changed",
            "sourceClientId": clientID,
            "targetClientIds": [ownerID],
            "params": [
                "conversationId": threadID,
                "hostId": "local",
                "following": true
            ],
            "version": 1
        ])
        usleep(100_000)

        _ = try request(
            method: "thread-follower-load-complete-history",
            params: ["conversationId": threadID],
            version: 1,
            targetClientID: ownerID,
            timeoutMilliseconds: 7_000
        )

        try? send([
            "type": "broadcast",
            "method": "thread-stream-following-changed",
            "sourceClientId": clientID,
            "targetClientIds": [ownerID],
            "params": [
                "conversationId": threadID,
                "hostId": "local",
                "following": false
            ],
            "version": 1
        ])
    }

    private func request(
        method: String,
        params: [String: Any],
        version: Int,
        targetClientID: String? = nil,
        timeoutMilliseconds: Int
    ) throws -> [String: Any] {
        let requestID = UUID().uuidString.lowercased()
        var message: [String: Any] = [
            "type": "request",
            "requestId": requestID,
            "sourceClientId": clientID,
            "version": version,
            "method": method,
            "params": params,
            "timeoutMs": timeoutMilliseconds
        ]
        if let targetClientID {
            message["targetClientId"] = targetClientID
        }
        try send(message)

        while true {
            let response = try readMessage()
            switch response["type"] as? String {
            case "client-discovery-request":
                try rejectDiscoveryRequest(response)
            case "request":
                try rejectIncomingRequest(response)
            case "broadcast":
                recordThreadState(from: response)
            case "response":
                guard response["requestId"] as? String == requestID else { continue }
                return response
            default:
                continue
            }
        }
    }

    private func rejectDiscoveryRequest(_ message: [String: Any]) throws {
        guard let requestID = message["requestId"] as? String else { return }
        try send([
            "type": "client-discovery-response",
            "requestId": requestID,
            "response": ["canHandle": false]
        ])
    }

    private func rejectIncomingRequest(_ message: [String: Any]) throws {
        guard let requestID = message["requestId"] as? String else { return }
        try send([
            "type": "response",
            "requestId": requestID,
            "resultType": "error",
            "error": "no-handler-for-request"
        ])
    }

    private func recordThreadState(from message: [String: Any]) {
        guard message["method"] as? String == "thread-stream-state-changed",
              let params = message["params"] as? [String: Any],
              let threadID = params["conversationId"] as? String,
              let change = params["change"] as? [String: Any],
              change["type"] as? String == "snapshot",
              let conversation = change["conversationState"] as? [String: Any],
              let status = conversation["threadRuntimeStatus"] as? [String: Any] else {
            return
        }

        let type = status["type"] as? String ?? "notLoaded"
        guard type != "notLoaded" else { return }
        let flags = status["activeFlags"] as? [String] ?? []
        receivedStates[threadID] = CodexTaskState.appServerStatus(
            type: type,
            activeFlags: flags
        )
    }

    private func send(_ message: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(message) else {
            throw SessionError.invalidFrame
        }
        let payload = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(payload.count).littleEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        try writeAll(frame)
    }

    private func readMessage() throws -> [String: Any] {
        let header = try readExactly(MemoryLayout<UInt32>.size)
        let length = header.withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.load(as: UInt32.self))
        }
        guard length > 0, length <= 256 * 1024 * 1024 else {
            throw SessionError.invalidFrame
        }

        let payload = try readExactly(Int(length))
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw SessionError.invalidFrame
        }
        return object
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: written),
                    data.count - written,
                    0
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw SessionError.connectionFailed }
                written += count
            }
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var received = 0
            while received < count {
                let amount = Darwin.recv(
                    descriptor,
                    baseAddress.advanced(by: received),
                    count - received,
                    0
                )
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw SessionError.connectionFailed }
                received += amount
            }
        }
        return data
    }
}

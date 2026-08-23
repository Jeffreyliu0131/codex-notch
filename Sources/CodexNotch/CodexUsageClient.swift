import CodexNotchCore
import Darwin
import Foundation

@MainActor
final class CodexUsageClient {
    typealias SnapshotHandler = @MainActor (CodexUsageSnapshot) -> Void
    typealias StatusHandler = @MainActor (String) -> Void
    typealias ThreadSnapshotHandler = @MainActor ([String: CodexTaskState]) -> Void
    typealias ThreadStateHandler = @MainActor (String, CodexTaskState) -> Void
    typealias ThreadResetHandler = @MainActor () -> Void

    private let onSnapshot: SnapshotHandler
    private let onStatus: StatusHandler
    private let onThreadSnapshot: ThreadSnapshotHandler
    private let onThreadState: ThreadStateHandler
    private let onThreadReset: ThreadResetHandler
    private var server: Process?
    private var stdin: Pipe?
    private var stdout: Pipe?
    private var stderr: Pipe?
    private var buffer = Data()
    private var nextRequestID = 10
    private var usageRequestIDs: Set<Int> = []
    private var threadListRequestIDs: Set<Int> = []

    init(
        onSnapshot: @escaping SnapshotHandler,
        onStatus: @escaping StatusHandler,
        onThreadSnapshot: @escaping ThreadSnapshotHandler,
        onThreadState: @escaping ThreadStateHandler,
        onThreadReset: @escaping ThreadResetHandler
    ) {
        self.onSnapshot = onSnapshot
        self.onStatus = onStatus
        self.onThreadSnapshot = onThreadSnapshot
        self.onThreadState = onThreadState
        self.onThreadReset = onThreadReset
    }

    func start() {
        guard server == nil else { return }
        guard let executable = Self.codexExecutable() else {
            onStatus("未找到本机 Codex")
            return
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()

        guard Darwin.fcntl(
            input.fileHandleForWriting.fileDescriptor,
            F_SETNOSIGPIPE,
            1
        ) != -1 else {
            onStatus("本机服务管道初始化失败")
            return
        }

        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.receive(data)
            }
        }

        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !message.isEmpty else { return }
                self?.onStatus("本机服务提示：\(message)")
            }
        }

        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self, self.server === terminated else { return }
                self.cleanUp()
                self.onThreadReset()
                self.onStatus("本机服务已断开，稍后重连")
            }
        }

        do {
            try process.run()
            server = process
            stdin = input
            stdout = output
            stderr = errors
            onStatus("正在同步额度")

            write([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex_notch",
                        "title": "Codex Notch",
                        "version": "0.2.0"
                    ]
                ]
            ])
            write(["method": "initialized", "params": [:]])

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.refresh()
            }
        } catch {
            cleanUp()
            onThreadReset()
            onStatus("本机服务启动失败")
        }
    }

    func refresh() {
        guard server?.isRunning == true else {
            start()
            return
        }

        let usageID = makeRequestID()
        usageRequestIDs.insert(usageID)
        write(["id": usageID, "method": "account/rateLimits/read"])

        let threadListID = makeRequestID()
        threadListRequestIDs.insert(threadListID)
        write([
            "id": threadListID,
            "method": "thread/list",
            "params": [
                "archived": false,
                "limit": 50,
                "sortKey": "recency_at",
                "sortDirection": "desc",
                "sourceKinds": ["vscode"],
                "useStateDbOnly": true
            ]
        ])
    }

    func stop() {
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        if server?.isRunning == true {
            server?.terminate()
        }
        cleanUp()
    }

    private func receive(_ data: Data) {
        buffer.append(data)

        while let breakIndex = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<breakIndex])
            buffer.removeSubrange(...breakIndex)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let message = object as? [String: Any] else {
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            handleNotification(method: method, message: message)
            return
        }

        guard let requestID = (message["id"] as? NSNumber)?.intValue else { return }

        if let error = message["error"] as? [String: Any] {
            let detail = error["message"] as? String
            if usageRequestIDs.remove(requestID) != nil {
                onStatus(detail ?? "额度读取失败")
            } else if threadListRequestIDs.remove(requestID) != nil {
                onStatus(detail ?? "任务状态同步失败")
            }
            return
        }

        if usageRequestIDs.remove(requestID) != nil,
           let snapshot = CodexUsageParser.parse(message: message) {
            onSnapshot(snapshot)
        }

        if threadListRequestIDs.remove(requestID) != nil,
           let result = message["result"] as? [String: Any],
           let rows = result["data"] as? [[String: Any]] {
            var states: [String: CodexTaskState] = [:]
            for row in rows {
                guard let threadID = row["id"] as? String,
                      let status = row["status"] as? [String: Any],
                      let state = Self.parseThreadState(status) else { continue }
                states[threadID] = state
            }
            onThreadSnapshot(states)
        }
    }

    private func handleNotification(method: String, message: [String: Any]) {
        if method == "account/rateLimits/updated",
           let snapshot = CodexUsageParser.parse(message: message) {
            onSnapshot(snapshot)
            return
        }

        guard let params = message["params"] as? [String: Any] else { return }

        switch method {
        case "thread/status/changed":
            guard let threadID = params["threadId"] as? String,
                  let status = params["status"] as? [String: Any],
                  let state = Self.parseThreadState(status) else { return }
            onThreadState(threadID, state)

        case "thread/started":
            guard let thread = params["thread"] as? [String: Any],
                  let threadID = thread["id"] as? String,
                  let status = thread["status"] as? [String: Any],
                  let state = Self.parseThreadState(status) else { return }
            onThreadState(threadID, state)

        case "thread/closed", "thread/archived", "thread/deleted":
            guard let threadID = params["threadId"] as? String else { return }
            onThreadState(threadID, .inactive)

        case "error":
            guard let threadID = params["threadId"] as? String,
                  (params["willRetry"] as? Bool) == false else { return }
            onThreadState(threadID, .failed)

        default:
            break
        }
    }

    private static func parseThreadState(_ status: [String: Any]) -> CodexTaskState? {
        let type = status["type"] as? String ?? "notLoaded"
        guard type != "notLoaded" else { return nil }
        let flags = status["activeFlags"] as? [String] ?? []
        return CodexTaskState.appServerStatus(type: type, activeFlags: flags)
    }

    private func makeRequestID() -> Int {
        nextRequestID += 1
        return nextRequestID
    }

    private func write(_ message: [String: Any]) {
        guard let handle = stdin?.fileHandleForWriting,
              JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message) else {
            return
        }

        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
        } catch {
            onStatus("本机请求发送失败")
        }
    }

    private func cleanUp() {
        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        server = nil
        stdin = nil
        stdout = nil
        stderr = nil
        buffer.removeAll(keepingCapacity: false)
        usageRequestIDs.removeAll()
        threadListRequestIDs.removeAll()
    }

    private static func codexExecutable() -> URL? {
        let locations = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]

        return locations
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

import Foundation

public enum RemoteTaskRepositoryError: LocalizedError {
    case readFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .readFailed(let detail):
            return detail.isEmpty ? "读取远端 Codex 任务失败" : detail
        case .invalidResponse:
            return "远端 Codex 任务数据格式无法识别"
        }
    }
}

public final class RemoteTaskRepository {
    private struct FileSignature: Equatable {
        let modifiedAt: Date?
        let size: UInt64?
    }

    private static let summariesPrefix = "remote-thread-summaries-v2:"

    private let globalStateURL: URL
    private let fileManager: FileManager
    private var cachedSignature: FileSignature?
    private var cachedTasks: [CodexTask] = []

    public init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex"),
        fileManager: FileManager = .default
    ) {
        self.globalStateURL = codexHome.appendingPathComponent(".codex-global-state.json")
        self.fileManager = fileManager
    }

    public init(globalStateURL: URL, fileManager: FileManager = .default) {
        self.globalStateURL = globalStateURL
        self.fileManager = fileManager
    }

    public func loadTasks(limitPerHost: Int = 50) throws -> [CodexTask] {
        guard fileManager.fileExists(atPath: globalStateURL.path) else {
            cachedSignature = nil
            cachedTasks = []
            return []
        }

        let signature = fileSignature()
        if let signature, signature == cachedSignature {
            return cachedTasks
        }

        let data: Data
        do {
            data = try Data(contentsOf: globalStateURL)
        } catch {
            throw RemoteTaskRepositoryError.readFailed(error.localizedDescription)
        }

        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RemoteTaskRepositoryError.invalidResponse
            }
            root = object
        } catch let error as RemoteTaskRepositoryError {
            throw error
        } catch {
            throw RemoteTaskRepositoryError.invalidResponse
        }

        guard let persistedState = root["electron-persisted-atom-state"] as? [String: Any] else {
            cachedSignature = signature
            cachedTasks = []
            return []
        }

        let safeLimit = min(max(limitPerHost, 1), 100)
        var tasks: [CodexTask] = []

        for (key, value) in persistedState where key.hasPrefix(Self.summariesPrefix) {
            guard let summaries = value as? [[String: Any]] else { continue }
            let fallbackHostID = String(key.dropFirst(Self.summariesPrefix.count))

            for summary in summaries.prefix(safeLimit) {
                guard let task = Self.makeTask(from: summary, fallbackHostID: fallbackHostID) else {
                    continue
                }
                tasks.append(task)
            }
        }

        cachedSignature = signature
        cachedTasks = tasks.sorted(by: Self.taskOrder)
        return cachedTasks
    }

    private func fileSignature() -> FileSignature? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: globalStateURL.path) else {
            return nil
        }
        return FileSignature(
            modifiedAt: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.uint64Value
        )
    }

    private static func makeTask(
        from summary: [String: Any],
        fallbackHostID: String
    ) -> CodexTask? {
        guard let conversationID = summary["conversationId"] as? String,
              !conversationID.isEmpty else { return nil }

        if let source = summary["source"] as? String,
           source != "vscode" {
            return nil
        }

        let hostID = (summary["hostId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackHostID
        let title = TaskTextSanitizer.compact(summary["title"] as? String ?? "未命名任务")
        let workspacePath = summary["cwd"] as? String ?? ""
        let gitInfo = summary["gitInfo"] as? [String: Any]
        let runtimeStatus = summary["threadRuntimeStatus"] as? [String: Any]
        let statusType = runtimeStatus?["type"] as? String ?? "notLoaded"
        let activeFlags = runtimeStatus?["activeFlags"] as? [String] ?? []
        let updatedNumber = summary["updatedAt"] as? NSNumber
        let updatedValue = updatedNumber?.doubleValue ?? 0
        let updatedSeconds = updatedValue > 100_000_000_000
            ? updatedValue / 1_000
            : updatedValue
        let activity = CodexTaskActivity.appServerStatus(
            type: statusType,
            activeFlags: activeFlags,
            signalID: "remote-runtime:\(updatedValue)"
        )

        return CodexTask(
            id: conversationID,
            hostID: hostID,
            deviceName: deviceName(hostID: hostID, workspacePath: workspacePath),
            title: title,
            preview: title,
            workspacePath: workspacePath,
            repositoryURL: gitInfo?["originUrl"] as? String ?? "",
            model: summary["modelProvider"] as? String ?? "",
            reasoningEffort: "",
            updatedAt: Date(timeIntervalSince1970: updatedSeconds),
            tokensUsed: 0,
            isPinned: false,
            state: activity.state,
            attentionReason: activity.attentionReason,
            attentionSignalID: activity.signalID
        )
    }

    private static func deviceName(hostID: String, workspacePath: String) -> String {
        guard hostID != "local" else { return "MacBook" }

        let pathComponents = URL(fileURLWithPath: workspacePath).pathComponents
        if let usersIndex = pathComponents.firstIndex(of: "Users"),
           pathComponents.indices.contains(usersIndex + 1) {
            let accountName = pathComponents[usersIndex + 1].lowercased()
            if accountName.contains("macmini") || accountName.contains("mac-mini") {
                return "Mac mini"
            }
        }
        return "远端 Mac"
    }

    private static func taskOrder(_ lhs: CodexTask, _ rhs: CodexTask) -> Bool {
        if lhs.isLive != rhs.isLive { return lhs.isLive }
        if lhs.state.displayPriority != rhs.state.displayPriority {
            return lhs.state.displayPriority < rhs.state.displayPriority
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}

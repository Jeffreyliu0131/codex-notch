import Foundation

public enum LocalTaskRepositoryError: LocalizedError {
    case databaseMissing(String)
    case sqliteUnavailable
    case queryFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .databaseMissing:
            return "还没有找到 Codex 本地任务库"
        case .sqliteUnavailable:
            return "系统缺少 sqlite3"
        case .queryFailed(let detail):
            return detail.isEmpty ? "读取 Codex 任务失败" : detail
        case .invalidResponse:
            return "Codex 任务数据格式无法识别"
        }
    }
}

public final class LocalTaskRepository {
    private let databaseURL: URL
    private let locksURL: URL
    private let fileManager: FileManager
    private let lifecycleReader: RolloutTaskStateReader

    public init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        fileManager: FileManager = .default,
        lifecycleReader: RolloutTaskStateReader? = nil
    ) {
        self.databaseURL = codexHome.appendingPathComponent("state_5.sqlite")
        self.locksURL = codexHome.appendingPathComponent("thread-writer-locks", isDirectory: true)
        self.fileManager = fileManager
        self.lifecycleReader = lifecycleReader ?? RolloutTaskStateReader(fileManager: fileManager)
    }

    public func loadTasks(limit: Int = 14) throws -> [CodexTask] {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw LocalTaskRepositoryError.databaseMissing(databaseURL.path)
        }
        guard fileManager.isExecutableFile(atPath: "/usr/bin/sqlite3") else {
            throw LocalTaskRepositoryError.sqliteUnavailable
        }

        let safeLimit = min(max(limit, 1), 50)
        let query = """
        SELECT
            id,
            COALESCE(NULLIF(name, ''), NULLIF(title, ''), '未命名任务') AS display_title,
            COALESCE(cwd, '') AS cwd,
            COALESCE(git_origin_url, '') AS repository_url,
            COALESCE(model, '') AS model,
            COALESCE(reasoning_effort, '') AS reasoning_effort,
            COALESCE(NULLIF(recency_at_ms, 0), NULLIF(updated_at_ms, 0), updated_at * 1000) AS updated_ms,
            tokens_used,
            is_pinned,
            COALESCE(rollout_path, '') AS rollout_path
        FROM threads
        WHERE archived = 0
          AND (COALESCE(name, '') <> '' OR COALESCE(title, '') <> '')
          AND source = 'vscode'
          AND (model IS NULL OR model <> 'codex-auto-review')
        ORDER BY recency_at_ms DESC, id DESC
        LIMIT \(safeLimit);
        """

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", databaseURL.path, query]
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw LocalTaskRepositoryError.queryFailed(error.localizedDescription)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LocalTaskRepositoryError.queryFailed(detail)
        }

        guard let rows = try? JSONDecoder().decode([TaskRow].self, from: data) else {
            throw LocalTaskRepositoryError.invalidResponse
        }

        let activeIDs = activeThreadIDs()
        return rows
            .map { row in
                CodexTask(
                    id: row.id,
                    title: TaskTextSanitizer.compact(row.displayTitle),
                    preview: "",
                    workspacePath: row.cwd,
                    repositoryURL: row.repositoryURL,
                    model: row.model,
                    reasoningEffort: row.reasoningEffort,
                    updatedAt: Date(timeIntervalSince1970: Double(row.updatedMilliseconds) / 1000),
                    tokensUsed: row.tokensUsed,
                    isPinned: row.isPinned != 0,
                    state: taskState(for: row, activeIDs: activeIDs)
                )
            }
            .sorted(by: taskOrder)
    }

    private func taskState(for row: TaskRow, activeIDs: Set<String>) -> CodexTaskState {
        if let lifecycleState = lifecycleReader.state(atPath: row.rolloutPath) {
            return lifecycleState
        }
        return activeIDs.contains(row.id) ? .running : .inactive
    }

    private func activeThreadIDs() -> Set<String> {
        guard let files = try? fileManager.contentsOfDirectory(
            at: locksURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return Set(
            files
                .filter { $0.pathExtension == "lock" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
    }

    private func taskOrder(_ lhs: CodexTask, _ rhs: CodexTask) -> Bool {
        if lhs.isLive != rhs.isLive { return lhs.isLive }
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        return lhs.updatedAt > rhs.updatedAt
    }
}

private struct TaskRow: Decodable {
    let id: String
    let displayTitle: String
    let cwd: String
    let repositoryURL: String
    let model: String
    let reasoningEffort: String
    let updatedMilliseconds: Int64
    let tokensUsed: Int64
    let isPinned: Int
    let rolloutPath: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayTitle = "display_title"
        case cwd
        case repositoryURL = "repository_url"
        case model
        case reasoningEffort = "reasoning_effort"
        case updatedMilliseconds = "updated_ms"
        case tokensUsed = "tokens_used"
        case isPinned = "is_pinned"
        case rolloutPath = "rollout_path"
    }
}

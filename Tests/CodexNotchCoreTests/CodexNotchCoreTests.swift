import Foundation
import Testing
@testable import CodexNotchCore

@Suite
struct CodexNotchCoreTests {
    @Test
    func taskStateMapsAttentionAndFailure() {
        #expect(
            CodexTaskState.appServerStatus(
                type: "active",
                activeFlags: ["waitingOnApproval"]
            ) == .needsAttention
        )
        #expect(CodexTaskState.appServerStatus(type: "systemError") == .failed)
        #expect(CodexTaskState.appServerStatus(type: "idle") == .inactive)
    }

    @Test
    func taskTextIsSingleLineAndBounded() {
        #expect(
            TaskTextSanitizer.compact("\n  Sample   task  \nprivate second line")
                == "Sample task"
        )
        #expect(TaskTextSanitizer.compact("123456", limit: 5) == "1234…")
    }

    @Test
    func repositoryIdentityGroupsWorktreesByOrigin() {
        let first = CodexProjectIdentity.resolve(
            workspacePath: "/Users/demo/Projects/app-main",
            repositoryURL: "git@github.com:example/sample-app.git"
        )
        let second = CodexProjectIdentity.resolve(
            workspacePath: "/Users/demo/Projects/app-worktree",
            repositoryURL: "https://github.com/example/sample-app.git"
        )

        #expect(first.id == second.id)
        #expect(first.name == "sample-app")
    }

    @Test
    func localRepositoryDoesNotStorePromptPreview() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexNotchCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = directory.appendingPathComponent("state_5.sqlite")
        try runSQLite(
            database: database,
            sql: """
            CREATE TABLE threads (
                id TEXT,
                name TEXT,
                title TEXT,
                preview TEXT,
                first_user_message TEXT,
                cwd TEXT,
                git_origin_url TEXT,
                model TEXT,
                reasoning_effort TEXT,
                recency_at_ms INTEGER,
                updated_at_ms INTEGER,
                updated_at INTEGER,
                tokens_used INTEGER,
                is_pinned INTEGER,
                rollout_path TEXT,
                archived INTEGER,
                source TEXT
            );
            INSERT INTO threads VALUES (
                'thread-1',
                'Synthetic task',
                '',
                'sensitive preview must not be stored',
                'sensitive first message must not be stored',
                '/Users/demo/Projects/sample-app',
                'https://github.com/example/sample-app.git',
                'test-model',
                'medium',
                1800000000000,
                1800000000000,
                1800000000,
                0,
                0,
                '',
                0,
                'vscode'
            );
            """
        )

        let tasks = try LocalTaskRepository(codexHome: directory).loadTasks(limit: 5)
        #expect(tasks.count == 1)
        #expect(tasks.first?.title == "Synthetic task")
        #expect(tasks.first?.preview == "")
    }

    private func runSQLite(database: URL, sql: String) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8) ?? "unknown sqlite error"
            throw NSError(
                domain: "CodexNotchCoreTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }
}

@Test func slowRepositoryReadIsBoundedAndDoesNotOccupyMainActor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    FileManager.default.createFile(atPath: root.appendingPathComponent("state_5.sqlite").path, contents: Data())
    let executable = root.appendingPathComponent("slow-query")
    try Data("#!/bin/sh\nexec /bin/sleep 5\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let loader = TaskSnapshotLoader(
        local: LocalTaskRepository(codexHome: root, queryTimeout: 0.15, sqliteExecutable: executable),
        remote: RemoteTaskRepository(codexHome: root)
    )
    let start = Date()
    let pending = Task { try await loader.load() }
    // This hop remains available while the repository actor waits for its child.
    let responsive = await MainActor.run { true }
    #expect(responsive)
    let snapshot = try await pending.value
    if case .failure(let error) = snapshot.local {
        #expect(error is LocalTaskRepositoryError)
        #expect(error.localizedDescription.contains("超时"))
    } else { Issue.record("Expected bounded timeout") }
    #expect(Date().timeIntervalSince(start) < 3)
}

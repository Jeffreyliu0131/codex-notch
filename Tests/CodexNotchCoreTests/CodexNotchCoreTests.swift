import Foundation
import XCTest
@testable import CodexNotchCore

final class CodexNotchCoreTests: XCTestCase {
    func testTaskStateMapsAttentionAndFailure() {
        XCTAssertEqual(
            CodexTaskState.appServerStatus(
                type: "active",
                activeFlags: ["waitingOnApproval"]
            ),
            .needsAttention
        )
        XCTAssertEqual(CodexTaskState.appServerStatus(type: "systemError"), .failed)
        XCTAssertEqual(CodexTaskState.appServerStatus(type: "idle"), .inactive)
    }

    func testTaskTextIsSingleLineAndBounded() {
        XCTAssertEqual(
            TaskTextSanitizer.compact("\n  Sample   task  \nprivate second line"),
            "Sample task"
        )
        XCTAssertEqual(TaskTextSanitizer.compact("123456", limit: 5), "1234…")
    }

    func testRepositoryIdentityGroupsWorktreesByOrigin() {
        let first = CodexProjectIdentity.resolve(
            workspacePath: "/Users/demo/Projects/app-main",
            repositoryURL: "git@github.com:example/sample-app.git"
        )
        let second = CodexProjectIdentity.resolve(
            workspacePath: "/Users/demo/Projects/app-worktree",
            repositoryURL: "https://github.com/example/sample-app.git"
        )

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.name, "sample-app")
    }

    func testLocalRepositoryDoesNotStorePromptPreview() throws {
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
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.title, "Synthetic task")
        XCTAssertEqual(tasks.first?.preview, "")
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

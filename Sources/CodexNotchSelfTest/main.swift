import CodexNotchCore
import Darwin
import Foundation

private var failures: [String] = []
private var checksRun = 0

private func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checksRun += 1
    if !condition() {
        failures.append(name)
    }
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
            domain: "CodexNotchSelfTest",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: detail]
        )
    }
}

let reset = 1_800_000_000.0
let usageMessage: [String: Any] = [
    "id": 12,
    "result": [
        "rateLimits": [
            "primary": ["usedPercent": 27, "resetsAt": reset],
            "credits": ["hasCredits": true, "balance": "12.5"],
            "planType": "pro"
        ]
    ]
]
let usage = CodexUsageParser.parse(message: usageMessage)

check(usage?.usedPercent == 27, "额度使用比例解析")
check(usage?.remainingPercent == 73, "额度剩余比例计算")
check(usage?.creditsBalance == 12.5, "Credits 余额解析")
check(usage?.resetsAt == Date(timeIntervalSince1970: reset), "额度重置时间解析")

let singaporeTimeZone = TimeZone(identifier: "Asia/Singapore")!
var quotaCalendar = Calendar(identifier: .gregorian)
quotaCalendar.timeZone = singaporeTimeZone
let quotaResetDate = quotaCalendar.date(
    from: DateComponents(
        timeZone: singaporeTimeZone,
        year: 2026,
        month: 8,
        day: 20,
        hour: 17,
        minute: 50
    )
)!
let quotaReferenceDate = quotaCalendar.date(byAdding: .day, value: -6, to: quotaResetDate)!
let quotaResetDescription = CodexQuotaResetFormatter.description(
    for: quotaResetDate,
    relativeTo: quotaReferenceDate,
    timeZone: singaporeTimeZone
)
check(quotaResetDescription.exact == "8月20日 周四 17:50", "额度显示精确日期、星期和时间")
check(quotaResetDescription.relative == "6天后", "额度保留相对重置时间")

check(CodexThreadLink.make(threadID: " 019abc ")?.absoluteString == "codex://threads/019abc", "任务深链")
check(TaskTextSanitizer.compact("\n  第一行任务标题  \n这里不应显示") == "第一行任务标题", "标题清洗")
check(TaskTextSanitizer.compact("123456", limit: 5) == "1234…", "标题截断")
check(CodexTaskState.appServerStatus(type: "active") == .running, "运行状态解析")
check(
    CodexTaskState.appServerStatus(
        type: "active",
        activeFlags: ["waitingOnApproval"]
    ) == .needsAttention,
    "等待批准状态解析"
)
check(
    CodexTaskState.appServerStatus(
        type: "active",
        activeFlags: ["waitingOnUserInput"]
    ) == .needsAttention,
    "等待输入状态解析"
)
check(CodexTaskState.appServerStatus(type: "systemError") == .failed, "错误状态解析")
check(CodexTaskState.appServerStatus(type: "idle") == .inactive, "空闲状态解析")
check(CodexTaskState.needsAttention.displayPriority < CodexTaskState.running.displayPriority, "状态优先级")

let retentionReference = Date(timeIntervalSince1970: 1_800_000_000)
check(
    CodexCompletionRetentionPolicy.shouldBeginRetention(from: .running, to: .inactive),
    "运行完成后开始保留"
)
check(
    !CodexCompletionRetentionPolicy.shouldBeginRetention(from: .failed, to: .inactive),
    "错误关闭不误判为完成"
)
check(
    CodexCompletionRetentionPolicy.expirationDate(for: .unseen, from: retentionReference)
        .timeIntervalSince(retentionReference) == 30 * 60,
    "未查看完成任务保留 30 分钟"
)
check(
    CodexCompletionRetentionPolicy.expirationDate(for: .viewed, from: retentionReference)
        .timeIntervalSince(retentionReference) == 5 * 60,
    "已查看完成任务保留 5 分钟"
)

let lifecycleDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodexNotchSelfTest-\(UUID().uuidString)", isDirectory: true)
let lifecycleFile = lifecycleDirectory.appendingPathComponent("rollout.jsonl")
do {
    try FileManager.default.createDirectory(
        at: lifecycleDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: lifecycleDirectory) }

    let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n"
    let unrelated = #"{"type":"response_item","payload":{"type":"custom_tool_call_output","output":"task_complete"}}"# + "\n"
    try Data((started + unrelated).utf8).write(to: lifecycleFile)

    let lifecycleReader = RolloutTaskStateReader()
    check(lifecycleReader.state(atPath: lifecycleFile.path) == .running, "rollout 运行状态识别")

    let completed = #"{"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n"
    let handle = try FileHandle(forWritingTo: lifecycleFile)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(completed.utf8))
    try handle.close()
    check(lifecycleReader.state(atPath: lifecycleFile.path) == .inactive, "rollout 完成状态识别")
} catch {
    failures.append("rollout 生命周期测试：\(error.localizedDescription)")
}

private func projectTask(
    id: String,
    title: String,
    workspacePath: String,
    repositoryURL: String = "",
    state: CodexTaskState = .running,
    updatedAt: Date = Date()
) -> CodexTask {
    CodexTask(
        id: id,
        title: title,
        preview: title,
        workspacePath: workspacePath,
        repositoryURL: repositoryURL,
        model: "gpt-5.6-sol",
        reasoningEffort: "high",
        updatedAt: updatedAt,
        tokensUsed: 0,
        isPinned: false,
        state: state
    )
}

let projectGroups = CodexProjectGroup.group([
    projectTask(
        id: "repo-1",
        title: "主仓任务",
        workspacePath: "/tmp/project-main",
        repositoryURL: "git@github.com:OpenAI/Project.git"
    ),
    projectTask(
        id: "repo-2",
        title: "工作树任务",
        workspacePath: "/tmp/project-worktree",
        repositoryURL: "https://github.com/openai/project.git",
        state: .needsAttention
    ),
    projectTask(
        id: "folder-1",
        title: "独立目录任务",
        workspacePath: "/tmp/local-project"
    )
])
check(projectGroups.count == 2, "同一 Git 项目的工作树归并")
check(projectGroups.first?.name == "Project", "Git 项目名称识别")
check(projectGroups.first?.state == .needsAttention, "项目状态按最高优先级汇总")
check(projectGroups.first?.tasks.first?.id == "repo-2", "项目内任务按状态排序")

let completionOrderGroups = CodexProjectGroup.group(
    [
        projectTask(
            id: "running",
            title: "运行中",
            workspacePath: "/tmp/completion-order",
            state: .running,
            updatedAt: Date()
        ),
        projectTask(
            id: "unseen-completion",
            title: "刚完成",
            workspacePath: "/tmp/completion-order",
            state: .completed,
            updatedAt: Date().addingTimeInterval(-60)
        ),
        projectTask(
            id: "viewed-completion",
            title: "已查看完成",
            workspacePath: "/tmp/completion-order",
            state: .completed,
            updatedAt: Date().addingTimeInterval(-120)
        )
    ],
    viewedCompletionIDs: ["local:viewed-completion"]
)
check(
    completionOrderGroups.first?.tasks.map(\.id)
        == ["unseen-completion", "running", "viewed-completion"],
    "新完成、运行中、已查看完成按展示阶段排序"
)

let temporaryGroups = CodexProjectGroup.group([
    projectTask(
        id: "temp-1",
        title: "临时任务一",
        workspacePath: "/Users/test/Documents/Codex/2026-08-09/new-chat"
    ),
    projectTask(
        id: "temp-2",
        title: "临时任务二",
        workspacePath: "/Users/test/Documents/Codex/2026-08-08/new-chat-2"
    )
])
check(
    temporaryGroups.count == 1 && temporaryGroups.first?.name == "临时任务",
    "无项目会话归入临时任务"
)

let sameNameFolders = CodexProjectGroup.group([
    projectTask(id: "folder-a", title: "A", workspacePath: "/tmp/team-a/app"),
    projectTask(id: "folder-b", title: "B", workspacePath: "/tmp/team-b/app")
])
check(sameNameFolders.count == 2, "同名普通目录按完整路径区分")

let remoteDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodexNotchRemoteSelfTest-\(UUID().uuidString)", isDirectory: true)
let remoteStateFile = remoteDirectory.appendingPathComponent(".codex-global-state.json")
do {
    try FileManager.default.createDirectory(
        at: remoteDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: remoteDirectory) }

    let remoteHostID = "remote-control:env_test"
    let remoteFixture: [String: Any] = [
        "electron-persisted-atom-state": [
            "unrelated-setting": true,
            "remote-thread-summaries-v2:\(remoteHostID)": [
                [
                    "conversationId": "remote-running",
                    "hostId": remoteHostID,
                    "title": "远端运行任务",
                    "cwd": "/Users/demo/Projects/stock-app",
                    "gitInfo": ["originUrl": "https://github.com/example/stock-app.git"],
                    "modelProvider": "openai",
                    "updatedAt": 1_800_000_000_000 as Int64,
                    "source": "vscode",
                    "threadRuntimeStatus": [
                        "type": "active",
                        "activeFlags": [] as [String]
                    ]
                ],
                [
                    "conversationId": "remote-attention",
                    "hostId": remoteHostID,
                    "title": "等待批准",
                    "cwd": "/Users/demo/Projects/stock-app",
                    "updatedAt": 1_799_999_999_000 as Int64,
                    "source": "vscode",
                    "threadRuntimeStatus": [
                        "type": "active",
                        "activeFlags": ["waitingOnApproval"]
                    ]
                ],
                [
                    "conversationId": "remote-idle",
                    "hostId": remoteHostID,
                    "title": "远端空闲任务",
                    "cwd": "/Users/demo/Projects/stock-app",
                    "updatedAt": 1_799_999_998_000 as Int64,
                    "source": "vscode",
                    "threadRuntimeStatus": ["type": "idle"]
                ],
                [
                    "conversationId": "non-codex-thread",
                    "hostId": remoteHostID,
                    "title": "忽略普通对话",
                    "updatedAt": 1_799_999_997_000 as Int64,
                    "source": "chatgpt",
                    "threadRuntimeStatus": ["type": "active"]
                ]
            ]
        ]
    ]
    let remoteData = try JSONSerialization.data(withJSONObject: remoteFixture)
    try remoteData.write(to: remoteStateFile)

    let remoteTasks = try RemoteTaskRepository(globalStateURL: remoteStateFile)
        .loadTasks(limitPerHost: 50)
    check(remoteTasks.count == 3, "远端 Codex 任务过滤")
    check(remoteTasks.first { $0.id == "remote-running" }?.state == .running, "远端运行状态")
    check(
        remoteTasks.first { $0.id == "remote-attention" }?.state == .needsAttention,
        "远端等待批准状态"
    )
    check(remoteTasks.first { $0.id == "remote-idle" }?.state == .inactive, "远端空闲状态")
    check(remoteTasks.first?.deviceName == "远端 Mac", "远端设备标签")
    check(
        remoteTasks.first { $0.id == "remote-running" }?.repositoryURL
            == "https://github.com/example/stock-app.git",
        "远端 Git 项目识别"
    )
    check(
        CodexTask.identityKey(hostID: "local", threadID: "same-thread")
            != CodexTask.identityKey(hostID: remoteHostID, threadID: "same-thread"),
        "本机与远端任务标识隔离"
    )
    if let remoteTask = remoteTasks.first(where: { $0.id == "remote-running" }) {
        check(remoteTask.threadURL == nil, "远端任务不生成无 host 深链")
        check(
            remoteTask.navigationTarget == .remoteThread(
                CodexRemoteThreadNavigationTarget(
                    threadID: "remote-running",
                    hostID: remoteHostID,
                    title: "远端运行任务",
                    workspaceName: "stock-app"
                )
            ),
            "远端导航目标保留 host 与会话信息"
        )
    } else {
        check(false, "远端导航目标测试数据")
    }
} catch {
    failures.append("远端任务摘要测试：\(error.localizedDescription)")
}

let localFixtureDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodexNotchLocalFixture-\(UUID().uuidString)", isDirectory: true)
do {
    try FileManager.default.createDirectory(
        at: localFixtureDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: localFixtureDirectory) }

    let localFixtureDatabase = localFixtureDirectory.appendingPathComponent("state_5.sqlite")
    try runSQLite(
        database: localFixtureDatabase,
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
            'synthetic-local',
            '合成本机任务',
            '',
            '不应读取的预览',
            '不应读取的首条消息',
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

    let localFixtureTasks = try LocalTaskRepository(codexHome: localFixtureDirectory)
        .loadTasks(limit: 5)
    check(localFixtureTasks.count == 1, "合成本机任务库读取")
    check(localFixtureTasks.first?.title == "合成本机任务", "合成本机任务标题")
    check(localFixtureTasks.first?.preview == "", "本机任务不保留预览或首条消息")
    check(localFixtureTasks.first?.threadURL != nil, "合成本机任务深链")
} catch {
    failures.append("合成本机任务摘要测试：\(error.localizedDescription)")
}

if ProcessInfo.processInfo.environment["CODEXNOTCH_RUN_LOCAL_INTEGRATION"] == "1" {
    do {
        let localTasks = try LocalTaskRepository().loadTasks(limit: 5)
        check(!localTasks.isEmpty, "本机任务库读取")
        check(localTasks.first?.threadURL != nil, "本机任务深链生成")
        if let localURL = localTasks.first?.threadURL {
            check(
                localTasks.first?.navigationTarget == .deepLink(localURL),
                "本机导航继续使用官方深链"
            )
        } else {
            check(false, "本机导航目标测试数据")
        }
    } catch {
        failures.append("本机任务库读取：\(error.localizedDescription)")
    }
} else {
    print("CodexNotchSelfTest: skipped local Codex database integration")
}

if failures.isEmpty {
    print("CodexNotchSelfTest: \(checksRun) checks passed")
} else {
    failures.forEach { fputs("FAIL: \($0)\n", stderr) }
    exit(1)
}

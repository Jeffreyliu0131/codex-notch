import AppKit
import CodexNotchCore
import Combine
import Foundation

enum PreviewMode {
    case running
    case attention
    case completion
    case viewedCompletion
    case idle
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var completionPulseSequence: UInt = 0
    @Published private(set) var viewedCompletionIDs: Set<String> = []
    @Published private(set) var usage: CodexUsageSnapshot?
    @Published private(set) var taskError: String?
    @Published private(set) var remoteTaskError: String?
    @Published private(set) var usageStatus = "正在连接额度"
    @Published private(set) var lastRefresh: Date?

    private struct TransientTaskState {
        let state: CodexTaskState
        let phase: CodexCompletionRetentionPhase
        let expiresAt: Date
    }

    private let taskRepository: LocalTaskRepository
    private let remoteTaskRepository: RemoteTaskRepository
    private var taskTimer: Timer?
    private var usageTimer: Timer?
    private var repositoryTasks: [String: CodexTask] = [:]
    private var localRepositoryTasks: [String: CodexTask] = [:]
    private var remoteRepositoryTasks: [String: CodexTask] = [:]
    private var taskCache: [String: CodexTask] = [:]
    private var serverStates: [String: CodexTaskState] = [:]
    private var desktopStates: [String: CodexTaskState] = [:]
    private var effectiveStates: [String: CodexTaskState] = [:]
    private var transientStates: [String: TransientTaskState] = [:]
    private var transientWorkItems: [String: DispatchWorkItem] = [:]
    private var hasRepositoryBaseline = false
    private var hasServerBaseline = false
    private let remoteThreadNavigator = CodexRemoteThreadNavigator()

    private lazy var usageClient = CodexUsageClient(
        onSnapshot: { [weak self] snapshot in
            self?.usage = snapshot
            self?.usageStatus = "额度已同步"
        },
        onStatus: { [weak self] status in
            self?.usageStatus = status
        },
        onThreadSnapshot: { [weak self] states in
            self?.replaceThreadStates(states)
        },
        onThreadState: { [weak self] threadID, state in
            self?.applyThreadState(state, to: threadID)
        },
        onThreadReset: { [weak self] in
            self?.resetThreadStates()
        }
    )

    private lazy var desktopStatusClient = CodexDesktopStatusClient { [weak self] states in
        self?.replaceDesktopStates(states)
    }

    init(
        taskRepository: LocalTaskRepository = LocalTaskRepository(),
        remoteTaskRepository: RemoteTaskRepository = RemoteTaskRepository()
    ) {
        self.taskRepository = taskRepository
        self.remoteTaskRepository = remoteTaskRepository
    }

    var runningCount: Int {
        tasks.lazy.filter { $0.state.isLive }.count
    }

    var attentionCount: Int {
        tasks.lazy.filter { $0.state == .needsAttention }.count
    }

    var failureCount: Int {
        tasks.lazy.filter { $0.state == .failed }.count
    }

    var projectCount: Int {
        CodexProjectGroup.group(tasks).count
    }

    var unseenCompletionCount: Int {
        tasks.lazy.filter {
            $0.state == .completed && !self.viewedCompletionIDs.contains($0.identityKey)
        }.count
    }

    var hasAttention: Bool { attentionCount > 0 }
    var hasFailures: Bool { failureCount > 0 }

    func start() {
        refreshAll()
        usageClient.start()

        taskTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTasks() }
        }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.usageClient.refresh() }
        }
    }

    func stop() {
        taskTimer?.invalidate()
        usageTimer?.invalidate()
        taskTimer = nil
        usageTimer = nil
        transientWorkItems.values.forEach { $0.cancel() }
        transientWorkItems.removeAll()
        transientStates.removeAll()
        viewedCompletionIDs.removeAll()
        desktopStatusClient.stop()
        usageClient.stop()
    }

    func refreshAll() {
        refreshTasks()
        usageClient.refresh()
    }

    func refreshTasks() {
        var refreshedAtLeastOneSource = false

        do {
            let loaded = try taskRepository.loadTasks(limit: 50)
            localRepositoryTasks = Dictionary(
                uniqueKeysWithValues: loaded.map { ($0.identityKey, $0) }
            )
            desktopStatusClient.refresh(
                threadIDs: loaded.filter(\.state.isLive).map(\.id)
            )
            taskError = nil
            refreshedAtLeastOneSource = true
        } catch {
            taskError = error.localizedDescription
        }

        do {
            let loaded = try remoteTaskRepository.loadTasks(limitPerHost: 50)
            remoteRepositoryTasks = Dictionary(
                uniqueKeysWithValues: loaded.map { ($0.identityKey, $0) }
            )
            remoteTaskError = nil
            refreshedAtLeastOneSource = true
        } catch {
            remoteTaskError = error.localizedDescription
        }

        repositoryTasks = localRepositoryTasks
        repositoryTasks.merge(remoteRepositoryTasks) { _, latest in latest }
        taskCache.merge(repositoryTasks) { _, latest in latest }
        rebuildVisibleTasks(emitCompletions: hasRepositoryBaseline)

        if refreshedAtLeastOneSource {
            hasRepositoryBaseline = true
            lastRefresh = Date()
        }
    }

    func open(_ task: CodexTask) {
        guard let target = task.navigationTarget else { return }

        switch target {
        case .deepLink(let url):
            let opened = NSWorkspace.shared.open(url)
            if opened && task.state == .completed {
                markCompletionViewed(for: task.identityKey)
            }

        case .remoteThread(let remoteTarget):
            Task { [weak self] in
                guard let self else { return }
                let opened = await remoteThreadNavigator.open(remoteTarget)
                if opened && task.state == .completed {
                    markCompletionViewed(for: task.identityKey)
                }
            }
        }
    }

    func dismissCompletion(_ task: CodexTask) {
        guard task.state == .completed,
              transientStates[task.identityKey] != nil else { return }
        removeTransientState(for: task.identityKey)
        rebuildVisibleTasks(emitCompletions: false)
    }

    func isCompletionViewed(_ task: CodexTask) -> Bool {
        task.state == .completed && viewedCompletionIDs.contains(task.identityKey)
    }

    func openCodex() {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    func loadPreviewData(_ mode: PreviewMode = .running) {
        let now = Date()
        usage = CodexUsageSnapshot(
            usedPercent: 15,
            resetsAt: now.addingTimeInterval(6 * 24 * 60 * 60),
            planType: "pro",
            creditsBalance: nil,
            hasCredits: false
        )
        usageStatus = "额度已同步"
        lastRefresh = now
        taskError = nil
        viewedCompletionIDs.removeAll()

        switch mode {
        case .running:
            tasks = [
                Self.previewTask(
                    id: "019-preview-01",
                    title: "完成 Mac 刘海任务组件",
                    workspacePath: "/Users/demo/Projects/notch-dashboard",
                    updatedAt: now,
                    state: .running
                ),
                Self.previewTask(
                    id: "019-preview-06",
                    title: "识别项目级任务并可视化",
                    workspacePath: "/Users/demo/Projects/notch-dashboard",
                    updatedAt: now.addingTimeInterval(-120),
                    state: .running
                ),
                Self.previewTask(
                    id: "019-preview-02",
                    title: "整理产品研究材料",
                    workspacePath: "/Users/demo/Projects/research-dashboard",
                    updatedAt: now.addingTimeInterval(-780),
                    state: .running,
                    hostID: "remote-control:preview",
                    deviceName: "Mac mini"
                )
            ]

        case .attention:
            tasks = [
                Self.previewTask(
                    id: "019-preview-03",
                    title: "确认发布前的权限请求",
                    workspacePath: "/Users/demo/Projects/notch-dashboard",
                    updatedAt: now,
                    state: .needsAttention
                ),
                Self.previewTask(
                    id: "019-preview-04",
                    title: "修复额度同步异常",
                    workspacePath: "/Users/demo/Projects/codex-tools",
                    updatedAt: now.addingTimeInterval(-320),
                    state: .failed
                ),
                Self.previewTask(
                    id: "019-preview-05",
                    title: "整理产品研究材料",
                    workspacePath: "/Users/demo/Projects/research-dashboard",
                    updatedAt: now.addingTimeInterval(-780),
                    state: .running
                )
            ]

        case .completion, .viewedCompletion:
            tasks = [
                Self.previewTask(
                    id: "019-preview-01",
                    title: "完成 Mac 刘海任务组件",
                    workspacePath: "/Users/demo/Projects/notch-dashboard",
                    updatedAt: now,
                    state: .running
                ),
                Self.previewTask(
                    id: "019-preview-completed",
                    title: "调研并升级 Agent Memory 方案",
                    workspacePath: "/Users/demo/Projects/notch-dashboard",
                    updatedAt: now.addingTimeInterval(-90),
                    state: .completed
                ),
                Self.previewTask(
                    id: "019-preview-02",
                    title: "整理产品研究材料",
                    workspacePath: "/Users/demo/Projects/research-dashboard",
                    updatedAt: now.addingTimeInterval(-780),
                    state: .running,
                    hostID: "remote-control:preview",
                    deviceName: "Mac mini"
                )
            ]
            if case .viewedCompletion = mode,
               let completion = tasks.first(where: { $0.state == .completed }) {
                viewedCompletionIDs.insert(completion.identityKey)
            }

        case .idle:
            tasks = []
        }

        tasks.sort(by: Self.displayOrder)
    }

    private func replaceThreadStates(_ states: [String: CodexTaskState]) {
        serverStates = Dictionary(uniqueKeysWithValues: states.map {
            (Self.localIdentityKey(for: $0.key), $0.value)
        })
        rebuildVisibleTasks(emitCompletions: hasServerBaseline)
        hasServerBaseline = true
    }

    private func applyThreadState(_ state: CodexTaskState, to threadID: String) {
        let taskKey = Self.localIdentityKey(for: threadID)
        serverStates[taskKey] = state
        if taskCache[taskKey] == nil {
            refreshTasks()
        } else {
            rebuildVisibleTasks(emitCompletions: hasServerBaseline || hasRepositoryBaseline)
        }
    }

    private func resetThreadStates() {
        serverStates.removeAll()
        hasServerBaseline = false
        rebuildVisibleTasks(emitCompletions: false)
    }

    private func replaceDesktopStates(_ states: [String: CodexTaskState]) {
        desktopStates = Dictionary(uniqueKeysWithValues: states.map {
            (Self.localIdentityKey(for: $0.key), $0.value)
        })
        rebuildVisibleTasks(emitCompletions: hasRepositoryBaseline)
    }

    private func rebuildVisibleTasks(emitCompletions: Bool) {
        let now = Date()
        removeExpiredTransientStates(at: now)

        var nextStates: [String: CodexTaskState] = [:]
        for (taskKey, _) in taskCache {
            let repositoryState = repositoryTasks[taskKey]?.state ?? .inactive
            nextStates[taskKey] = desktopStates[taskKey]
                ?? serverStates[taskKey]
                ?? repositoryState
        }

        var detectedCompletion = false
        if emitCompletions {
            for (taskKey, previousState) in effectiveStates {
                let nextState = nextStates[taskKey] ?? .inactive
                guard CodexCompletionRetentionPolicy.shouldBeginRetention(
                    from: previousState,
                    to: nextState
                ) else { continue }
                showCompletion(for: taskKey, now: now)
                detectedCompletion = true
            }
        }

        for (taskKey, state) in nextStates where state.isLive {
            removeTransientState(for: taskKey)
        }

        let liveTasks = nextStates.compactMap { taskKey, state -> CodexTask? in
            guard state.isLive, let task = taskCache[taskKey] else { return nil }
            return task.withState(state)
        }

        let transientTasks = transientStates.compactMap { taskKey, transient -> CodexTask? in
            guard nextStates[taskKey]?.isLive != true,
                  let task = taskCache[taskKey] else { return nil }
            return task.withState(transient.state)
        }

        tasks = (liveTasks + transientTasks).sorted(by: Self.displayOrder)
        effectiveStates = nextStates
        if detectedCompletion {
            completionPulseSequence &+= 1
        }
    }

    private func showCompletion(for threadID: String, now: Date) {
        let phase = CodexCompletionRetentionPhase.unseen
        transientStates[threadID] = TransientTaskState(
            state: .completed,
            phase: phase,
            expiresAt: CodexCompletionRetentionPolicy.expirationDate(for: phase, from: now)
        )
        viewedCompletionIDs.remove(threadID)
        scheduleTransientExpiration(for: threadID)
    }

    private func markCompletionViewed(for threadID: String) {
        guard let transient = transientStates[threadID],
              transient.state == .completed else { return }

        let phase = CodexCompletionRetentionPhase.viewed
        transientStates[threadID] = TransientTaskState(
            state: transient.state,
            phase: phase,
            expiresAt: CodexCompletionRetentionPolicy.expirationDate(for: phase, from: Date())
        )
        viewedCompletionIDs.insert(threadID)
        scheduleTransientExpiration(for: threadID)
    }

    private func scheduleTransientExpiration(for threadID: String) {
        transientWorkItems.removeValue(forKey: threadID)?.cancel()
        guard let scheduledExpiration = transientStates[threadID]?.expiresAt else { return }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      let transient = self.transientStates[threadID],
                      transient.expiresAt == scheduledExpiration,
                      transient.expiresAt <= Date() else { return }
                self.removeTransientState(for: threadID)
                self.rebuildVisibleTasks(emitCompletions: false)
            }
        }
        transientWorkItems[threadID] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, scheduledExpiration.timeIntervalSinceNow) + 0.05,
            execute: workItem
        )
    }

    private func removeTransientState(for threadID: String) {
        transientStates.removeValue(forKey: threadID)
        transientWorkItems.removeValue(forKey: threadID)?.cancel()
        viewedCompletionIDs.remove(threadID)
    }

    private func removeExpiredTransientStates(at date: Date) {
        let expiredIDs = transientStates.compactMap { threadID, transient in
            transient.expiresAt <= date ? threadID : nil
        }
        for threadID in expiredIDs {
            removeTransientState(for: threadID)
        }
    }

    private static func displayOrder(_ lhs: CodexTask, _ rhs: CodexTask) -> Bool {
        if lhs.state.displayPriority != rhs.state.displayPriority {
            return lhs.state.displayPriority < rhs.state.displayPriority
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    private static func localIdentityKey(for threadID: String) -> String {
        CodexTask.identityKey(hostID: "local", threadID: threadID)
    }

    private static func previewTask(
        id: String,
        title: String,
        workspacePath: String,
        updatedAt: Date,
        state: CodexTaskState,
        hostID: String = "local",
        deviceName: String = "MacBook"
    ) -> CodexTask {
        CodexTask(
            id: id,
            hostID: hostID,
            deviceName: deviceName,
            title: title,
            preview: title,
            workspacePath: workspacePath,
            model: "gpt-5.6-sol",
            reasoningEffort: "high",
            updatedAt: updatedAt,
            tokensUsed: 0,
            isPinned: false,
            state: state
        )
    }
}

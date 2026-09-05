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

struct CodexApprovalAlert: Identifiable, Equatable {
    let id: String
    let task: CodexTask
    let reason: CodexAttentionReason
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var completionPulseSequence: UInt = 0
    @Published private(set) var latestApprovalAlert: CodexApprovalAlert?
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
    private lazy var snapshotLoader = TaskSnapshotLoader(local: taskRepository, remote: remoteTaskRepository)
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    @Published private(set) var taskDataIsStale = true
    private var taskTimer: Timer?
    private var usageTimer: Timer?
    private var repositoryTasks: [String: CodexTask] = [:]
    private var localRepositoryTasks: [String: CodexTask] = [:]
    private var remoteRepositoryTasks: [String: CodexTask] = [:]
    private var taskCache: [String: CodexTask] = [:]
    private var serverActivities: [String: CodexTaskActivity] = [:]
    private var desktopActivities: [String: CodexTaskActivity] = [:]
    private var effectiveStates: [String: CodexTaskState] = [:]
    private var transientStates: [String: TransientTaskState] = [:]
    private var transientWorkItems: [String: DispatchWorkItem] = [:]
    private var hasRepositoryBaseline = false
    private var hasServerBaseline = false
    private var threadReadsInFlight: Set<String> = []
    private let alertLedger: CodexApprovalAlertLedger
    private let remoteThreadNavigator = CodexRemoteThreadNavigator()

    private lazy var usageClient = CodexUsageClient(
        onSnapshot: { [weak self] snapshot in
            self?.usage = snapshot
            self?.usageStatus = "额度已同步"
        },
        onStatus: { [weak self] status in
            self?.usageStatus = status
        },
        onThreadSnapshot: { [weak self] activities in
            self?.replaceThreadActivities(activities)
        },
        onThreadActivity: { [weak self] threadID, activity in
            self?.applyThreadActivity(activity, to: threadID)
        },
        onThreadObservation: { [weak self] threadID, observation in
            self?.applyThreadObservation(observation, to: threadID)
        },
        onThreadReset: { [weak self] in
            self?.resetThreadStates()
        }
    )

    private lazy var desktopStatusClient = CodexDesktopStatusClient { [weak self] activities in
        self?.replaceDesktopActivities(activities)
    }

    init(
        taskRepository: LocalTaskRepository = LocalTaskRepository(),
        remoteTaskRepository: RemoteTaskRepository = RemoteTaskRepository(),
        alertLedger: CodexApprovalAlertLedger = CodexApprovalAlertLedger()
    ) {
        self.taskRepository = taskRepository
        self.remoteTaskRepository = remoteTaskRepository
        self.alertLedger = alertLedger
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
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
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
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) > 10 { taskDataIsStale = true }
        guard refreshTask == nil else { return }
        let generation = refreshGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == refreshGeneration { refreshTask = nil } }
            do {
                let snapshot = try await snapshotLoader.load()
                guard !Task.isCancelled, generation == refreshGeneration else { return }
                applySnapshot(snapshot)
            } catch {
                if !Task.isCancelled, generation == refreshGeneration { taskDataIsStale = true }
            }
        }
    }

    private func applySnapshot(_ snapshot: TaskRepositorySnapshot) {
        var refreshedAtLeastOneSource = false
        switch snapshot.local {
        case .success(let loaded):
            localRepositoryTasks = Dictionary(loaded.map { ($0.identityKey, $0) }, uniquingKeysWith: { _, latest in latest })
            taskError = nil
            refreshedAtLeastOneSource = true
        case .failure(let error): taskError = error.localizedDescription
        }
        switch snapshot.remote {
        case .success(let loaded):
            remoteRepositoryTasks = Dictionary(loaded.map { ($0.identityKey, $0) }, uniquingKeysWith: { _, latest in latest })
            remoteTaskError = nil
            refreshedAtLeastOneSource = true
        case .failure(let error): remoteTaskError = error.localizedDescription
        }
        taskDataIsStale = taskError != nil || remoteTaskError != nil

        repositoryTasks = localRepositoryTasks
        repositoryTasks.merge(remoteRepositoryTasks) { _, latest in latest }
        taskCache.merge(repositoryTasks) { _, latest in latest }

        let probeTargets = repositoryTasks.values.compactMap { task -> CodexThreadProbeTarget? in
            let wasLive = effectiveStates[task.identityKey]?.isLive == true
            guard task.state.isLive || wasLive else { return nil }
            return CodexThreadProbeTarget(threadID: task.id, hostID: task.hostID)
        }
        desktopStatusClient.refresh(targets: probeTargets)
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
                    state: .needsAttention,
                    attentionReason: .structuredApproval,
                    attentionSignalID: "preview-approval"
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

    private func replaceThreadActivities(_ activities: [String: CodexTaskActivity]) {
        serverActivities = Dictionary(uniqueKeysWithValues: activities.map {
            (Self.localIdentityKey(for: $0.key), $0.value)
        })
        rebuildVisibleTasks(emitCompletions: hasServerBaseline)
        hasServerBaseline = true
    }

    private func applyThreadActivity(_ activity: CodexTaskActivity, to threadID: String) {
        let taskKey = Self.localIdentityKey(for: threadID)
        serverActivities[taskKey] = activity
        if taskCache[taskKey] == nil {
            refreshTasks()
        } else {
            rebuildVisibleTasks(emitCompletions: hasServerBaseline || hasRepositoryBaseline)
        }
    }

    private func resetThreadStates() {
        serverActivities.removeAll()
        threadReadsInFlight.removeAll()
        hasServerBaseline = false
        rebuildVisibleTasks(emitCompletions: false)
    }

    private func replaceDesktopActivities(_ activities: [String: CodexTaskActivity]) {
        desktopActivities = activities
        rebuildVisibleTasks(emitCompletions: hasRepositoryBaseline)
    }

    private func applyThreadObservation(
        _ observation: CodexThreadObservation?,
        to threadID: String
    ) {
        threadReadsInFlight.remove(threadID)
        guard let observation else { return }

        let taskKey = Self.localIdentityKey(for: threadID)
        serverActivities[taskKey] = observation.activity
        rebuildVisibleTasks(emitCompletions: hasRepositoryBaseline)
    }

    private func rebuildVisibleTasks(emitCompletions: Bool) {
        let now = Date()
        removeExpiredTransientStates(at: now)

        var nextActivities: [String: CodexTaskActivity] = [:]
        var nextStates: [String: CodexTaskState] = [:]
        for (taskKey, cachedTask) in taskCache {
            let repositoryTask = repositoryTasks[taskKey] ?? cachedTask
            let repositoryActivity = CodexTaskActivity(
                state: repositoryTask.state,
                attentionReason: repositoryTask.attentionReason,
                signalID: repositoryTask.attentionSignalID
            )
            let activity = Self.preferredActivity(
                desktop: desktopActivities[taskKey],
                server: serverActivities[taskKey],
                repository: repositoryActivity
            )
            nextActivities[taskKey] = activity
            nextStates[taskKey] = activity.state
        }

        var detectedCompletion = false
        if emitCompletions {
            for (taskKey, previousState) in effectiveStates {
                let nextState = nextStates[taskKey] ?? .inactive
                guard CodexCompletionRetentionPolicy.shouldBeginRetention(
                    from: previousState,
                    to: nextState
                ) else { continue }

                if let task = taskCache[taskKey],
                   !task.isRemote,
                   threadReadsInFlight.insert(task.id).inserted,
                   !usageClient.readThread(task.id) {
                    threadReadsInFlight.remove(task.id)
                }
                showCompletion(for: taskKey, now: now)
                detectedCompletion = true
            }
        }

        for (taskKey, state) in nextStates where state.isLive {
            removeTransientState(for: taskKey)
        }

        let liveTasks = nextActivities.compactMap { taskKey, activity -> CodexTask? in
            guard activity.state.isLive, let task = taskCache[taskKey] else { return nil }
            return task.withActivity(activity)
        }

        let transientTasks = transientStates.compactMap { taskKey, transient -> CodexTask? in
            guard nextStates[taskKey]?.isLive != true,
                  let task = taskCache[taskKey] else { return nil }
            return task.withState(transient.state)
        }

        tasks = (liveTasks + transientTasks).sorted(by: Self.displayOrder)
        emitApprovalAlerts(from: tasks, notify: hasRepositoryBaseline)
        effectiveStates = nextStates
        if detectedCompletion {
            completionPulseSequence &+= 1
        }
    }

    private func emitApprovalAlerts(from tasks: [CodexTask], notify: Bool) {
        for task in tasks {
            guard let reason = task.attentionReason, reason.shouldAlert else { continue }
            let rawSignalID = task.attentionSignalID
                ?? "fallback:\(Int(task.updatedAt.timeIntervalSince1970 * 1_000))"
            let signalID = "\(task.identityKey):\(reason.rawValue):\(rawSignalID)"
            guard alertLedger.markIfNew(signalID) else { continue }
            guard notify else { continue }
            latestApprovalAlert = CodexApprovalAlert(
                id: signalID,
                task: task,
                reason: reason
            )
        }
    }

    private static func preferredActivity(
        desktop: CodexTaskActivity?,
        server: CodexTaskActivity?,
        repository: CodexTaskActivity
    ) -> CodexTaskActivity {
        let candidates = [desktop, server, repository].compactMap { $0 }
        if let structured = candidates.first(where: {
            $0.attentionReason == .structuredApproval
        }) {
            return structured
        }
        if let textual = candidates.first(where: {
            $0.attentionReason == .textualApproval
        }) {
            return textual
        }
        return desktop ?? server ?? repository
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
        attentionReason: CodexAttentionReason? = nil,
        attentionSignalID: String? = nil,
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
            state: state,
            attentionReason: attentionReason,
            attentionSignalID: attentionSignalID
        )
    }
}

import Foundation

public enum CodexTaskState: String, Equatable, Sendable {
    case inactive
    case running
    case needsAttention
    case failed
    case completed

    public var isLive: Bool {
        switch self {
        case .running, .needsAttention, .failed:
            return true
        case .inactive, .completed:
            return false
        }
    }

    public var displayPriority: Int {
        switch self {
        case .needsAttention: return 0
        case .failed: return 1
        case .running: return 2
        case .completed: return 3
        case .inactive: return 4
        }
    }

    public static func appServerStatus(type: String, activeFlags: [String] = []) -> CodexTaskState {
        switch type {
        case "active":
            return activeFlags.contains("waitingOnApproval")
                || activeFlags.contains("waitingOnUserInput")
                ? .needsAttention
                : .running
        case "systemError":
            return .failed
        case "idle", "notLoaded":
            return .inactive
        default:
            return .inactive
        }
    }
}

public enum CodexCompletionRetentionPhase: Equatable, Sendable {
    case unseen
    case viewed
}

public enum CodexCompletionRetentionPolicy {
    public static let unseenDuration: TimeInterval = 30 * 60
    public static let viewedDuration: TimeInterval = 5 * 60

    public static func shouldBeginRetention(
        from previousState: CodexTaskState,
        to nextState: CodexTaskState
    ) -> Bool {
        (previousState == .running || previousState == .needsAttention)
            && !nextState.isLive
    }

    public static func expirationDate(
        for phase: CodexCompletionRetentionPhase,
        from date: Date
    ) -> Date {
        switch phase {
        case .unseen:
            return date.addingTimeInterval(unseenDuration)
        case .viewed:
            return date.addingTimeInterval(viewedDuration)
        }
    }
}

public struct CodexRemoteThreadNavigationTarget: Equatable, Sendable {
    public let threadID: String
    public let hostID: String
    public let title: String
    public let workspaceName: String

    public init(
        threadID: String,
        hostID: String,
        title: String,
        workspaceName: String
    ) {
        self.threadID = threadID
        self.hostID = hostID
        self.title = title
        self.workspaceName = workspaceName
    }
}

public enum CodexTaskNavigationTarget: Equatable, Sendable {
    case deepLink(URL)
    case remoteThread(CodexRemoteThreadNavigationTarget)
}

public struct CodexTask: Identifiable, Equatable, Sendable {
    public let id: String
    public let hostID: String
    public let deviceName: String
    public let title: String
    public let preview: String
    public let workspacePath: String
    public let repositoryURL: String
    public let model: String
    public let reasoningEffort: String
    public let updatedAt: Date
    public let tokensUsed: Int64
    public let isPinned: Bool
    public let state: CodexTaskState

    public init(
        id: String,
        hostID: String = "local",
        deviceName: String = "MacBook",
        title: String,
        preview: String,
        workspacePath: String,
        repositoryURL: String = "",
        model: String,
        reasoningEffort: String,
        updatedAt: Date,
        tokensUsed: Int64,
        isPinned: Bool,
        state: CodexTaskState
    ) {
        self.id = id
        self.hostID = hostID
        self.deviceName = deviceName
        self.title = title
        self.preview = preview
        self.workspacePath = workspacePath
        self.repositoryURL = repositoryURL
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.updatedAt = updatedAt
        self.tokensUsed = tokensUsed
        self.isPinned = isPinned
        self.state = state
    }

    public var isRunning: Bool { state == .running }

    public var isLive: Bool { state.isLive }

    public var isRemote: Bool { hostID != "local" }

    public var identityKey: String {
        Self.identityKey(hostID: hostID, threadID: id)
    }

    public static func identityKey(hostID: String, threadID: String) -> String {
        "\(hostID):\(threadID)"
    }

    public var workspaceName: String {
        guard !workspacePath.isEmpty else { return "未指定项目" }
        return URL(fileURLWithPath: workspacePath).lastPathComponent
    }

    public var threadURL: URL? {
        guard !isRemote else { return nil }
        return CodexThreadLink.make(threadID: id)
    }

    public var navigationTarget: CodexTaskNavigationTarget? {
        if isRemote {
            return .remoteThread(
                CodexRemoteThreadNavigationTarget(
                    threadID: id,
                    hostID: hostID,
                    title: title,
                    workspaceName: workspaceName
                )
            )
        }

        return threadURL.map(CodexTaskNavigationTarget.deepLink)
    }

    public func withState(_ state: CodexTaskState) -> CodexTask {
        CodexTask(
            id: id,
            hostID: hostID,
            deviceName: deviceName,
            title: title,
            preview: preview,
            workspacePath: workspacePath,
            repositoryURL: repositoryURL,
            model: model,
            reasoningEffort: reasoningEffort,
            updatedAt: updatedAt,
            tokensUsed: tokensUsed,
            isPinned: isPinned,
            state: state
        )
    }
}

public struct CodexProjectIdentity: Equatable, Sendable {
    public let id: String
    public let name: String

    public static func resolve(
        workspacePath: String,
        repositoryURL: String
    ) -> CodexProjectIdentity {
        if let repository = normalizedRepository(repositoryURL) {
            return CodexProjectIdentity(
                id: "repository:\(repository)",
                name: repositoryDisplayName(repositoryURL)
                    ?? repository.split(separator: "/").last.map(String.init)
                    ?? "Git 项目"
            )
        }

        let path = standardizedPath(workspacePath)
        guard !path.isEmpty else {
            return CodexProjectIdentity(id: "unassigned", name: "未指定项目")
        }

        let folderName = URL(fileURLWithPath: path).lastPathComponent
        if isTemporaryWorkspace(path: path, folderName: folderName) {
            return CodexProjectIdentity(id: "temporary", name: "临时任务")
        }

        return CodexProjectIdentity(
            id: "workspace:\(path)",
            name: folderName.isEmpty ? "未指定项目" : folderName
        )
    }

    private static func normalizedRepository(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let components = URLComponents(string: value),
           let host = components.host,
           !host.isEmpty {
            value = host + components.path
        } else if let at = value.lastIndex(of: "@"),
                  let separator = value[at...].firstIndex(of: ":") {
            let hostStart = value.index(after: at)
            let pathStart = value.index(after: separator)
            value = String(value[hostStart..<separator]) + "/" + String(value[pathStart...])
        }

        value = value.replacingOccurrences(of: "\\", with: "/")
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasSuffix(".git") {
            value.removeLast(4)
        }

        let normalized = value.lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func standardizedPath(_ rawValue: String) -> String {
        let expanded = NSString(string: rawValue).expandingTildeInPath
        guard !expanded.isEmpty else { return "" }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func repositoryDisplayName(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "\\", with: "/")
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasSuffix(".git") {
            value.removeLast(4)
        }

        let separators = [value.lastIndex(of: "/"), value.lastIndex(of: ":")]
            .compactMap { $0 }
        guard let separator = separators.max(), separator < value.index(before: value.endIndex) else {
            return value.isEmpty ? nil : value
        }
        let name = String(value[value.index(after: separator)...])
        return name.removingPercentEncoding ?? name
    }

    private static func isTemporaryWorkspace(path: String, folderName: String) -> Bool {
        let loweredPath = path.lowercased()
        let loweredName = folderName.lowercased()
        return loweredPath.contains("/documents/codex/")
            && (loweredName == "new-chat" || loweredName.hasPrefix("new-chat-"))
    }
}

public struct CodexProjectGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let workspacePath: String
    public let tasks: [CodexTask]
    public let state: CodexTaskState
    public let updatedAt: Date

    public var liveTaskCount: Int {
        tasks.lazy.filter { $0.state.isLive }.count
    }

    public static func group(
        _ tasks: [CodexTask],
        viewedCompletionIDs: Set<String> = []
    ) -> [CodexProjectGroup] {
        var buckets: [String: [CodexTask]] = [:]
        for task in tasks {
            let identity = CodexProjectIdentity.resolve(
                workspacePath: task.workspacePath,
                repositoryURL: task.repositoryURL
            )
            buckets[identity.id, default: []].append(task)
        }

        return buckets.compactMap { projectID, projectTasks in
            let orderedTasks = projectTasks.sorted {
                taskOrder(
                    $0,
                    $1,
                    viewedCompletionIDs: viewedCompletionIDs
                )
            }
            guard let representative = orderedTasks.first else { return nil }
            let identity = CodexProjectIdentity.resolve(
                workspacePath: representative.workspacePath,
                repositoryURL: representative.repositoryURL
            )
            let projectName = orderedTasks
                .map {
                    CodexProjectIdentity.resolve(
                        workspacePath: $0.workspacePath,
                        repositoryURL: $0.repositoryURL
                    ).name
                }
                .sorted()
                .first ?? identity.name
            let state = orderedTasks.min {
                $0.state.displayPriority < $1.state.displayPriority
            }?.state ?? .inactive

            return CodexProjectGroup(
                id: projectID,
                name: projectName,
                workspacePath: representative.workspacePath,
                tasks: orderedTasks,
                state: state,
                updatedAt: orderedTasks.map(\.updatedAt).max() ?? .distantPast
            )
        }
        .sorted {
            projectOrder(
                $0,
                $1,
                viewedCompletionIDs: viewedCompletionIDs
            )
        }
    }

    private static func taskOrder(
        _ lhs: CodexTask,
        _ rhs: CodexTask,
        viewedCompletionIDs: Set<String>
    ) -> Bool {
        let lhsPriority = activityDisplayPriority(
            for: lhs,
            viewedCompletionIDs: viewedCompletionIDs
        )
        let rhsPriority = activityDisplayPriority(
            for: rhs,
            viewedCompletionIDs: viewedCompletionIDs
        )
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    private static func projectOrder(
        _ lhs: CodexProjectGroup,
        _ rhs: CodexProjectGroup,
        viewedCompletionIDs: Set<String>
    ) -> Bool {
        let lhsPriority = lhs.tasks.first.map {
            activityDisplayPriority(for: $0, viewedCompletionIDs: viewedCompletionIDs)
        } ?? Int.max
        let rhsPriority = rhs.tasks.first.map {
            activityDisplayPriority(for: $0, viewedCompletionIDs: viewedCompletionIDs)
        } ?? Int.max
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func activityDisplayPriority(
        for task: CodexTask,
        viewedCompletionIDs: Set<String>
    ) -> Int {
        if task.state == .completed {
            return viewedCompletionIDs.contains(task.identityKey) ? 4 : 0
        }

        switch task.state {
        case .needsAttention: return 1
        case .failed: return 2
        case .running: return 3
        case .inactive: return 5
        case .completed: return 0
        }
    }
}

public struct CodexUsageSnapshot: Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Date?
    public let planType: String?
    public let creditsBalance: Double?
    public let hasCredits: Bool
    public let capturedAt: Date

    public init(
        usedPercent: Double,
        resetsAt: Date?,
        planType: String?,
        creditsBalance: Double?,
        hasCredits: Bool,
        capturedAt: Date = Date()
    ) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
        self.planType = planType
        self.creditsBalance = creditsBalance
        self.hasCredits = hasCredits
        self.capturedAt = capturedAt
    }

    public var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}

public struct CodexQuotaResetDescription: Equatable, Sendable {
    public let exact: String
    public let relative: String

    public init(exact: String, relative: String) {
        self.exact = exact
        self.relative = relative
    }
}

public enum CodexQuotaResetFormatter {
    public static func description(
        for resetDate: Date,
        relativeTo referenceDate: Date = Date(),
        locale: Locale = Locale(identifier: "zh_CN"),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> CodexQuotaResetDescription {
        let exactFormatter = DateFormatter()
        exactFormatter.locale = locale
        exactFormatter.calendar = Calendar(identifier: .gregorian)
        exactFormatter.timeZone = timeZone
        exactFormatter.dateFormat = "M月d日 EEE HH:mm"

        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.locale = locale
        relativeFormatter.unitsStyle = .full
        relativeFormatter.dateTimeStyle = .numeric

        let exact = exactFormatter.string(from: resetDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let calendarDayDifference = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: referenceDate),
            to: calendar.startOfDay(for: resetDate)
        ).day ?? 0
        let relative: String
        if abs(resetDate.timeIntervalSince(referenceDate)) >= 24 * 60 * 60,
           calendarDayDifference != 0 {
            relative = calendarDayDifference > 0
                ? "\(calendarDayDifference)天后"
                : "\(-calendarDayDifference)天前"
        } else {
            relative = relativeFormatter
                .localizedString(for: resetDate, relativeTo: referenceDate)
                .replacingOccurrences(of: " ", with: "")
        }

        return CodexQuotaResetDescription(exact: exact, relative: relative)
    }
}

public enum CodexThreadLink {
    public static func make(threadID: String) -> URL? {
        let cleaned = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(cleaned)"
        return components.url
    }
}

public enum TaskTextSanitizer {
    public static func compact(_ value: String, limit: Int = 88) -> String {
        let firstUsefulLine = value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "未命名任务"

        let normalized = firstUsefulLine
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(1, limit - 1))) + "…"
    }
}

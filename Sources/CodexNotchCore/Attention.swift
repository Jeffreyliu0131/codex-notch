import CryptoKit
import Foundation

public enum CodexAttentionReason: String, Codable, Equatable, Sendable {
    case structuredApproval
    case textualApproval
    case otherUserInput

    public var shouldAlert: Bool {
        self == .structuredApproval || self == .textualApproval
    }
}

public struct CodexTaskActivity: Equatable, Sendable {
    public let state: CodexTaskState
    public let attentionReason: CodexAttentionReason?
    public let signalID: String?

    public init(
        state: CodexTaskState,
        attentionReason: CodexAttentionReason? = nil,
        signalID: String? = nil
    ) {
        self.state = state
        self.attentionReason = state == .needsAttention ? attentionReason : nil
        self.signalID = state == .needsAttention ? signalID : nil
    }

    public static func appServerStatus(
        type: String,
        activeFlags: [String] = [],
        signalID: String? = nil,
        approvalPromptText: String? = nil
    ) -> CodexTaskActivity {
        switch type {
        case "active":
            if activeFlags.contains("waitingOnApproval") {
                return CodexTaskActivity(
                    state: .needsAttention,
                    attentionReason: .structuredApproval,
                    signalID: signalID
                )
            }
            if activeFlags.contains("waitingOnUserInput") {
                let isApproval = approvalPromptText.map {
                    CodexApprovalTextClassifier.isStructuredApprovalPrompt($0)
                } ?? false
                return CodexTaskActivity(
                    state: .needsAttention,
                    attentionReason: isApproval ? .structuredApproval : .otherUserInput,
                    signalID: signalID
                )
            }
            return CodexTaskActivity(state: .running)

        case "systemError":
            return CodexTaskActivity(state: .failed)

        case "idle", "notLoaded":
            return CodexTaskActivity(state: .inactive)

        default:
            return CodexTaskActivity(state: .inactive)
        }
    }
}

public struct CodexThreadProbeTarget: Hashable, Sendable {
    public let threadID: String
    public let hostID: String

    public init(threadID: String, hostID: String) {
        self.threadID = threadID
        self.hostID = hostID
    }

    public var identityKey: String {
        CodexTask.identityKey(hostID: hostID, threadID: threadID)
    }
}

public struct CodexThreadObservation: Equatable, Sendable {
    public let threadID: String
    public let hostID: String
    public let activity: CodexTaskActivity
    public let latestTurnID: String?
    public let latestFinalMessageID: String?

    public init(
        threadID: String,
        hostID: String,
        activity: CodexTaskActivity,
        latestTurnID: String? = nil,
        latestFinalMessageID: String? = nil
    ) {
        self.threadID = threadID
        self.hostID = hostID
        self.activity = activity
        self.latestTurnID = latestTurnID
        self.latestFinalMessageID = latestFinalMessageID
    }

    public var identityKey: String {
        CodexTask.identityKey(hostID: hostID, threadID: threadID)
    }
}

public enum CodexApprovalTextClassifier {
    private static let negativePhrases = [
        "已允许", "已经允许", "已批准", "已经批准", "已授权", "已经授权",
        "无需允许", "无需批准", "无需授权", "不需要允许", "不需要批准",
        "不需要授权", "允许列表", "权限列表", "permission denied",
        "already approved", "already authorized", "already allowed", "no approval required",
        "does not require approval", "without approval"
    ]

    private static let approvalPatterns = [
        #"请回复[^。！？\n]{0,80}(?:允许|同意|批准|授权|可以|继续|拒绝)"#,
        #"请(?:你|您)?(?:允许|同意|批准|授权)(?:我|我们|本次|此次|这个|该)"#,
        #"请确认[^。！？\n]{0,50}(?:允许|同意|批准|授权)(?:我|我们|本次|此次|这个|该)"#,
        #"(?:是否|能否|可否)(?:允许|同意|批准|授权)(?:我|我们)"#,
        #"(?:你|您)(?:是否|能否|可否)?(?:允许|同意|批准|授权)(?:我|我们|的话)"#,
        #"(?:允许|同意|批准|授权)(?:我|我们)[^。！？\n]{0,100}(?:继续|执行|修改|发送|发布|删除|提交|推送|部署|处理)"#,
        #"如果(?:你|您)(?:允许|同意|批准|授权)"#,
        #"(?:please\s+)?(?:approve|authorize|allow)\s+(?:me|this|the\s+(?:change|action|request|operation))"#,
        #"(?:do|would|can)\s+you\s+(?:approve|authorize|allow)"#,
        #"(?:may|can)\s+i[^.!?\n]{0,100}(?:proceed|modify|send|publish|delete|commit|push|deploy)"#,
        #"reply[^.!?\n]{0,60}(?:allow|approve|approved|yes|proceed|decline|deny)"#
    ]

    private static let explanatoryPhrases = [
        "例如", "比如", "示例", "举例", "原文", "写着", "提到", "引用", "转述",
        "关键词", "识别规则", "这句话", "这些话", "意思是", "会说", "可能说",
        "for example", "e.g.", "example", "quoted", "it says", "the message says",
        "the text says", "keyword"
    ]

    public static func isApprovalRequest(_ text: String) -> Bool {
        let normalized = actionableText(from: text)
        guard !normalized.isEmpty else { return false }
        let tail = String(normalized.suffix(1_200))

        if negativePhrases.contains(where: tail.contains) {
            return false
        }

        return approvalPatterns.contains { pattern in
            tail.range(of: pattern, options: .regularExpression) != nil
        }
    }

    public static func isStructuredApprovalPrompt(_ text: String) -> Bool {
        let normalized = normalize(text)
        if isApprovalRequest(normalized) { return true }

        let decisionPairs = [
            ("accept", "decline"),
            ("allow", "deny"),
            ("approve", "cancel"),
            ("允许", "拒绝"),
            ("同意", "取消"),
            ("批准", "拒绝")
        ]
        return decisionPairs.contains { normalized.contains($0.0) && normalized.contains($0.1) }
    }

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func actionableText(from text: String) -> String {
        let separators = CharacterSet(charactersIn: "\n\r。！？!?")
        return text
            .components(separatedBy: separators)
            .map(normalize)
            .filter { segment in
                guard !segment.isEmpty else { return false }
                guard !explanatoryPhrases.contains(where: segment.contains) else { return false }
                return !isFullyQuotedExample(segment)
            }
            .joined(separator: " ")
    }

    private static func isFullyQuotedExample(_ segment: String) -> Bool {
        var value = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["- ", "* ", "• "] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        let quotePairs = [("“", "”"), ("‘", "’"), ("\"", "\""), ("`", "`")]
        return quotePairs.contains { opening, closing in
            value.count >= opening.count + closing.count
                && value.hasPrefix(opening)
                && value.hasSuffix(closing)
        }
    }
}

public enum CodexThreadObservationParser {
    public static func appServerThread(
        _ thread: [String: Any],
        fallbackThreadID: String,
        fallbackHostID: String = "local"
    ) -> CodexThreadObservation {
        let threadID = nonempty(thread["id"] as? String) ?? fallbackThreadID
        let hostID = nonempty(thread["hostId"] as? String) ?? fallbackHostID
        let turns = thread["turns"] as? [[String: Any]] ?? []
        let latestTurn = turns.last
        return makeObservation(
            threadID: threadID,
            hostID: hostID,
            status: thread["status"] as? [String: Any],
            requests: thread["requests"],
            latestTurn: latestTurn
        )
    }

    public static func desktopConversation(
        _ conversation: [String: Any],
        fallbackThreadID: String,
        fallbackHostID: String
    ) -> CodexThreadObservation {
        let threadID = nonempty(conversation["id"] as? String) ?? fallbackThreadID
        let hostID = nonempty(conversation["hostId"] as? String) ?? fallbackHostID
        let latestTurn = latestDesktopTurn(in: conversation)
        return makeObservation(
            threadID: threadID,
            hostID: hostID,
            status: conversation["threadRuntimeStatus"] as? [String: Any],
            requests: conversation["requests"],
            latestTurn: latestTurn
        )
    }

    private static func makeObservation(
        threadID: String,
        hostID: String,
        status: [String: Any]?,
        requests: Any?,
        latestTurn: [String: Any]?
    ) -> CodexThreadObservation {
        let turnID = nonempty(latestTurn?["id"] as? String)
            ?? nonempty(latestTurn?["turnId"] as? String)
        let requestText = flattenedStrings(from: requests).joined(separator: " ")
        let statusType = status?["type"] as? String ?? "notLoaded"
        let flags = status?["activeFlags"] as? [String] ?? []
        var activity = CodexTaskActivity.appServerStatus(
            type: statusType,
            activeFlags: flags,
            signalID: turnID.map { "structured:\($0)" },
            approvalPromptText: requestText
        )

        let finalMessage = latestFinalMessage(in: latestTurn?["items"] as? [[String: Any]] ?? [])
        if activity.attentionReason != .structuredApproval,
           let finalMessage,
           CodexApprovalTextClassifier.isApprovalRequest(finalMessage.text) {
            activity = CodexTaskActivity(
                state: .needsAttention,
                attentionReason: .textualApproval,
                signalID: "textual:\(finalMessage.id)"
            )
        }

        return CodexThreadObservation(
            threadID: threadID,
            hostID: hostID,
            activity: activity,
            latestTurnID: turnID,
            latestFinalMessageID: finalMessage?.id
        )
    }

    private static func latestDesktopTurn(in conversation: [String: Any]) -> [String: Any]? {
        guard let turnHistory = conversation["turnHistory"] as? [String: Any],
              let history = turnHistory["history"] as? [String: Any],
              let entities = history["entitiesByKey"] as? [String: Any] else {
            return nil
        }

        return entities.values
            .compactMap { $0 as? [String: Any] }
            .max { lhs, rhs in
                number(lhs["turnStartedAtMs"]) < number(rhs["turnStartedAtMs"])
            }
    }

    private static func latestFinalMessage(
        in items: [[String: Any]]
    ) -> (id: String, text: String)? {
        var latest: (id: String, text: String)?
        for (index, item) in items.enumerated() {
            guard item["type"] as? String == "agentMessage",
                  item["phase"] as? String == "final_answer",
                  let text = item["text"] as? String,
                  !text.isEmpty else { continue }

            let hasLaterUserMessage = items.dropFirst(index + 1).contains {
                $0["type"] as? String == "userMessage"
            }
            guard !hasLaterUserMessage else { continue }
            latest = (nonempty(item["id"] as? String) ?? "final-\(index)", text)
        }
        return latest
    }

    private static func flattenedStrings(from value: Any?) -> [String] {
        guard let value else { return [] }
        if let string = value as? String { return [string] }
        if let array = value as? [Any] {
            return array.flatMap(flattenedStrings)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.flatMap(flattenedStrings)
        }
        return []
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func number(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return 0
    }
}

public final class CodexApprovalAlertLedger {
    private struct Entry: Codable {
        let digest: String
        let recordedAt: TimeInterval
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let maximumEntries: Int
    private var entries: [String: Entry]

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "codexNotch.approvalAlertLedger.v1",
        maximumEntries: Int = 200
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.maximumEntries = max(20, maximumEntries)
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    public func markIfNew(_ signalID: String, now: Date = Date()) -> Bool {
        let digest = Self.digest(signalID)
        guard entries[digest] == nil else { return false }
        entries[digest] = Entry(
            digest: digest,
            recordedAt: now.timeIntervalSince1970
        )
        pruneIfNeeded()
        persist()
        return true
    }

    public func contains(_ signalID: String) -> Bool {
        entries[Self.digest(signalID)] != nil
    }

    private func pruneIfNeeded() {
        guard entries.count > maximumEntries else { return }
        let keptKeys = entries
            .sorted { $0.value.recordedAt > $1.value.recordedAt }
            .prefix(maximumEntries)
            .map(\.key)
        entries = entries.filter { keptKeys.contains($0.key) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func digest(_ signalID: String) -> String {
        SHA256.hash(data: Data(signalID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

import Foundation
import Testing
@testable import CodexNotchCore

@Suite
struct ApprovalAttentionTests {
    @Test
    func structuredApprovalFlags() {
        let approval = CodexTaskActivity.appServerStatus(
            type: "active",
            activeFlags: ["waitingOnApproval"],
            signalID: "turn-1"
        )
        #expect(approval.state == .needsAttention)
        #expect(approval.attentionReason == .structuredApproval)
        #expect(approval.attentionReason?.shouldAlert == true)

        let ordinaryInput = CodexTaskActivity.appServerStatus(
            type: "active",
            activeFlags: ["waitingOnUserInput"]
        )
        #expect(ordinaryInput.state == .needsAttention)
        #expect(ordinaryInput.attentionReason == .otherUserInput)
        #expect(ordinaryInput.attentionReason?.shouldAlert != true)

        let approvalInput = CodexTaskActivity.appServerStatus(
            type: "active",
            activeFlags: ["waitingOnUserInput"],
            approvalPromptText: "Accept Decline Cancel"
        )
        #expect(approvalInput.attentionReason == .structuredApproval)
    }

    @Test
    func textualApprovalClassifierPositiveCases() {
        let cases = [
            "请确认：允许我把公开个人主页链接修改为新地址。",
            "你允许的话，我就继续尝试这个地址。",
            "请回复“允许”或“拒绝”，我再继续部署。",
            "请回复“可以”，授权我把这些资料提交给 Singpass。",
            "Do you approve this change so I can proceed?",
            "Please authorize me to publish the update."
        ]
        for text in cases {
            #expect(
                CodexApprovalTextClassifier.isApprovalRequest(text),
                "Expected approval request: \(text)"
            )
        }
    }

    @Test
    func textualApprovalClassifierNegativeCases() {
        let cases = [
            "修改已批准并完成，无需允许。",
            "这里是权限列表和允许列表的说明。",
            "permission denied while opening the file",
            "你希望主页使用蓝色还是绿色？",
            "The request was already approved.",
            "另外，无论你自己的仓库是否授权，第三方素材仍要遵守许可证。",
            "你现在的身体状态，是否还允许真正学习。",
            "在公开讲座中很常见，但是否允许逐场决定，必须先问。",
            """
            现在只识别明确的授权请求，例如：
            - “请回复允许/可以”
            - “允许我……”
            - “授权我……”
            只剩某个任务，因为它最后确实写着“请回复可以，授权我提交”。
            """
        ]
        for text in cases {
            #expect(
                !CodexApprovalTextClassifier.isApprovalRequest(text),
                "Expected non-approval text: \(text)"
            )
        }
    }

    @Test
    func appServerFinalAnswerBecomesTextualApproval() {
        let thread: [String: Any] = [
            "id": "thread-1",
            "status": ["type": "idle"],
            "turns": [[
                "id": "turn-1",
                "items": [
                    ["type": "userMessage", "id": "user-1", "content": []],
                    [
                        "type": "agentMessage",
                        "id": "agent-1",
                        "phase": "final_answer",
                        "text": "请确认：允许我发布这个更新。"
                    ]
                ]
            ]]
        ]

        let observation = CodexThreadObservationParser.appServerThread(
            thread,
            fallbackThreadID: "fallback"
        )
        #expect(observation.threadID == "thread-1")
        #expect(observation.latestTurnID == "turn-1")
        #expect(observation.activity.state == .needsAttention)
        #expect(observation.activity.attentionReason == .textualApproval)
        #expect(observation.activity.signalID == "textual:agent-1")
    }

    @Test
    func laterUserMessageResolvesTextualApproval() {
        let thread: [String: Any] = [
            "id": "thread-1",
            "status": ["type": "idle"],
            "turns": [[
                "id": "turn-1",
                "items": [
                    [
                        "type": "agentMessage",
                        "id": "agent-1",
                        "phase": "final_answer",
                        "text": "请回复允许或拒绝，我再继续。"
                    ],
                    ["type": "userMessage", "id": "user-2", "content": []]
                ]
            ]]
        ]

        let observation = CodexThreadObservationParser.appServerThread(
            thread,
            fallbackThreadID: "thread-1"
        )
        #expect(observation.activity.state == .inactive)
        #expect(observation.activity.attentionReason == nil)
    }

    @Test
    func remoteDesktopConversationUsesHostIdentity() {
        let conversation: [String: Any] = [
            "id": "same-thread",
            "hostId": "remote-control:test",
            "threadRuntimeStatus": ["type": "idle", "activeFlags": []],
            "turnHistory": [
                "history": [
                    "entitiesByKey": [
                        "remote-turn": [
                            "turnId": "turn-remote",
                            "turnStartedAtMs": 200,
                            "items": [[
                                "type": "agentMessage",
                                "id": "agent-remote",
                                "phase": "final_answer",
                                "text": "是否允许我继续推送这次修改？"
                            ]]
                        ]
                    ]
                ]
            ]
        ]

        let observation = CodexThreadObservationParser.desktopConversation(
            conversation,
            fallbackThreadID: "same-thread",
            fallbackHostID: "local"
        )
        #expect(observation.hostID == "remote-control:test")
        #expect(observation.identityKey == "remote-control:test:same-thread")
        #expect(
            observation.identityKey
                != CodexTask.identityKey(hostID: "local", threadID: "same-thread")
        )
        #expect(observation.activity.attentionReason == .textualApproval)
    }

    @Test
    func rolloutTaskCompleteApprovalFallback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        let records = [
            #"{"timestamp":"2026-09-01T00:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-09-01T00:00:01Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"请确认：允许我继续发布。"}}"#
        ].joined(separator: "\n") + "\n"
        try Data(records.utf8).write(to: file)

        let activity = RolloutTaskStateReader().activity(atPath: file.path)
        #expect(activity?.state == .needsAttention)
        #expect(activity?.attentionReason == .textualApproval)
        #expect(activity?.signalID == "rollout:2026-09-01T00:00:01Z")
    }

    @Test
    func alertLedgerDeduplicatesAcrossInstances() throws {
        let suiteName = "CodexNotchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = CodexApprovalAlertLedger(defaults: defaults, storageKey: "ledger")
        #expect(first.markIfNew("signal-1"))
        #expect(!first.markIfNew("signal-1"))

        let restored = CodexApprovalAlertLedger(defaults: defaults, storageKey: "ledger")
        #expect(restored.contains("signal-1"))
        #expect(!restored.markIfNew("signal-1"))
        #expect(restored.markIfNew("signal-2"))
    }
}

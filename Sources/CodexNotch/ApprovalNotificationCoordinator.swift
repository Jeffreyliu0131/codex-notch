import AppKit
import CodexNotchCore
import Combine
import Foundation
import UserNotifications

@MainActor
final class ApprovalNotificationCoordinator: NSObject {
    private static let codexBundleIdentifier = "com.openai.codex"

    private let model: AppModel
    private let center: UNUserNotificationCenter
    private var cancellable: AnyCancellable?
    private var authorizationResolved = false
    private var canDeliverNotifications = false
    private var pending = CodexPendingApprovalQueue()

    init(
        model: AppModel,
        center: UNUserNotificationCenter = .current()
    ) {
        self.model = model
        self.center = center
        super.init()
    }

    func start() {
        center.delegate = self
        cancellable = model.$latestApprovalAlert
            .compactMap { $0 }
            .sink { [weak self] alert in
                self?.handle(alert)
            }
        center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.authorizationResolved = true
                self.canDeliverNotifications = granted
                if granted {
                    let tasks = self.pending.drain(activeTasks: self.model.tasks)
                    for task in tasks {
                        guard let id = CodexApprovalSignal.id(for: task), let reason = task.attentionReason else { continue }
                        self.deliver(CodexApprovalAlert(id: id, task: task, reason: reason))
                    }
                } else {
                    self.pending = CodexPendingApprovalQueue()
                    self.model.notificationStatus = "系统通知未授权 · 刘海提示仍可用"
                }
            }
        }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        pending = CodexPendingApprovalQueue()
    }

    private func handle(_ alert: CodexApprovalAlert) {
        guard authorizationResolved else {
            pending.enqueue(id: alert.id, task: alert.task)
            model.notificationStatus = "审批已检测 · 等待通知权限结果"
            return
        }
        guard canDeliverNotifications else {
            model.notificationStatus = "系统通知未授权 · 刘海提示仍可用"
            return
        }
        deliver(alert)
    }

    private func deliver(_ alert: CodexApprovalAlert) {
        guard !model.taskDataIsStale,
              model.tasks.contains(where: { CodexApprovalSignal.id(for: $0) == alert.id }) else {
            model.notificationStatus = "未发送系统通知 · 审批已变化或来源待更新"
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                != Self.codexBundleIdentifier else {
            model.notificationStatus = "Codex 在前台 · 仅显示刘海提示"
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Codex 需要批准"
        content.subtitle = alert.task.deviceName
        content.body = alert.task.title
        content.userInfo = [
            "threadID": alert.task.id,
            "hostID": alert.task.hostID
        ]

        center.add(
            UNNotificationRequest(
                identifier: alert.id,
                content: content,
                trigger: nil
            )
        ) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if error != nil {
                    self.model.notificationStatus = "系统通知请求失败 · 请从任务列表查看审批"
                } else if self.model.taskDataIsStale || !self.model.tasks.contains(where: { CodexApprovalSignal.id(for: $0) == alert.id }) {
                    self.center.removePendingNotificationRequests(withIdentifiers: [alert.id])
                    self.center.removeDeliveredNotifications(withIdentifiers: [alert.id])
                    self.model.notificationStatus = "审批状态已变化 · 已请求移除过期通知"
                } else {
                    self.model.notificationStatus = "通知请求已提交 · 送达和已读未确认"
                }
            }
        }
    }

    private static func openNotificationTarget(
        threadID: String,
        hostID: String,
        title: String?,
        workspaceName: String?
    ) {
        if hostID == "local" {
            guard let url = CodexThreadLink.make(threadID: threadID) else { return }
            NSWorkspace.shared.open(url)
            return
        }

        let target = CodexRemoteThreadNavigationTarget(
            threadID: threadID,
            hostID: hostID,
            title: title ?? "Codex 任务",
            workspaceName: workspaceName ?? "未指定项目"
        )
        Task { @MainActor in
            _ = await CodexRemoteThreadNavigator().open(target)
        }
    }
}

extension ApprovalNotificationCoordinator: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let threadID = userInfo["threadID"] as? String
        let hostID = userInfo["hostID"] as? String
        let notificationTitle = response.notification.request.content.body
        completionHandler()
        Task { @MainActor [weak self] in
            guard let self, let threadID, let hostID else { return }
            let currentTask = self.model.tasks.first {
                $0.id == threadID && $0.hostID == hostID
            }
            Self.openNotificationTarget(
                threadID: threadID,
                hostID: hostID,
                title: currentTask?.title ?? notificationTitle,
                workspaceName: currentTask?.workspaceName
            )
        }
    }
}

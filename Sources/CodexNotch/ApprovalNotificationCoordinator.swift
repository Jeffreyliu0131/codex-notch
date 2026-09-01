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
    private var pendingAlert: CodexApprovalAlert?

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
                if granted, let pendingAlert = self.pendingAlert {
                    self.pendingAlert = nil
                    self.deliver(pendingAlert)
                } else {
                    self.pendingAlert = nil
                }
            }
        }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        pendingAlert = nil
    }

    private func handle(_ alert: CodexApprovalAlert) {
        guard authorizationResolved else {
            pendingAlert = alert
            return
        }
        guard canDeliverNotifications else { return }
        deliver(alert)
    }

    private func deliver(_ alert: CodexApprovalAlert) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                != Self.codexBundleIdentifier else {
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
        )
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

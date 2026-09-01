import AppKit
import SwiftUI

@main
struct CodexNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let codexBundleIdentifier = "com.openai.codex"

    private var model: AppModel?
    private var notchController: NotchPanelController?
    private var menuBarController: MenuBarController?
    private var notificationCoordinator: ApprovalNotificationCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let target = CodexRemoteThreadNavigator.probeTargetFromArguments() {
            Task { @MainActor in
                let opened = await CodexRemoteThreadNavigator().open(target)
                print(opened ? "remote-navigation-probe: opened" : "remote-navigation-probe: failed")
                NSApp.terminate(nil)
            }
            return
        }

        if let previewURL = PreviewRenderer.destinationFromArguments() {
            do {
                try PreviewRenderer.render(to: previewURL)
                print(previewURL.path)
            } catch {
                fputs("Preview render failed: \(error.localizedDescription)\n", stderr)
            }
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        startObservingCodexLifecycle()
        reconcileWithCodexLifecycle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopObservingCodexLifecycle()
        deactivateInterface()
    }

    private func startObservingCodexLifecycle() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    private func stopObservingCodexLifecycle() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func workspaceApplicationDidLaunch(_ notification: Notification) {
        guard isCodexLifecycleNotification(notification) else { return }
        reconcileWithCodexLifecycle()
    }

    @objc private func workspaceApplicationDidTerminate(_ notification: Notification) {
        guard isCodexLifecycleNotification(notification) else { return }
        reconcileWithCodexLifecycle()
    }

    private func isCodexLifecycleNotification(_ notification: Notification) -> Bool {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        return application?.bundleIdentifier == Self.codexBundleIdentifier
    }

    private func reconcileWithCodexLifecycle() {
        if isCodexRunning {
            activateInterface()
        } else {
            deactivateInterface()
        }
    }

    private var isCodexRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.codexBundleIdentifier && !$0.isTerminated
        }
    }

    private func activateInterface() {
        guard model == nil else { return }

        let model = AppModel()
        let notchController = NotchPanelController(model: model)
        let menuBarController = MenuBarController(model: model, notchController: notchController)
        let notificationCoordinator = ApprovalNotificationCoordinator(model: model)

        self.model = model
        self.notchController = notchController
        self.menuBarController = menuBarController
        self.notificationCoordinator = notificationCoordinator

        model.start()
        notchController.start()
        notificationCoordinator.start()
    }

    private func deactivateInterface() {
        guard let model else { return }

        menuBarController?.stop()
        notchController?.stop()
        notificationCoordinator?.stop()
        model.stop()

        menuBarController = nil
        notchController = nil
        self.model = nil
    }
}

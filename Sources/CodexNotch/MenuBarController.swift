import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private let notchController: NotchPanelController
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()

    init(model: AppModel, notchController: NotchPanelController) {
        self.model = model
        self.notchController = notchController
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "sparkles.rectangle.stack.fill",
                accessibilityDescription: "Codex Notch"
            )
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Codex Notch"
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 420, height: 530)
        popover.contentViewController = NSHostingController(
            rootView: StandaloneDashboardView(model: model)
        )

        model.$tasks
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &subscriptions)
    }

    func stop() {
        popover.performClose(nil)
        subscriptions.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        notchController.toggle()
    }

    @objc private func refresh() {
        model.refreshAll()
    }

    @objc private func openCodex() {
        model.openCodex()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = model.runningCount > 0 ? " \(model.runningCount)" : ""
        button.contentTintColor = model.runningCount > 0 ? .systemGreen : .labelColor
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "刷新", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(withTitle: "打开 Codex", action: #selector(openCodex), keyEquivalent: "o")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Codex Notch", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}

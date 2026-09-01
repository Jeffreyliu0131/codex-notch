import AppKit
import Combine
import SwiftUI

struct ScreenProfile {
    let screen: NSScreen
    let hasNotch: Bool
    let notchWidth: CGFloat
    let topInset: CGFloat

    static func preferred(fallback: ScreenProfile? = nil) -> ScreenProfile {
        let selected = NSScreen.screens.first(where: Self.detectsNotch)
            ?? NSScreen.main
            ?? NSScreen.screens.first
            ?? fallback?.screen
        guard let selected else {
            preconditionFailure("Codex Notch requires an available screen")
        }
        let hasNotch = Self.detectsNotch(selected)
        let left = selected.auxiliaryTopLeftArea
        let right = selected.auxiliaryTopRightArea
        let measuredWidth: CGFloat
        if hasNotch, let left, let right {
            measuredWidth = max(100, right.minX - left.maxX)
        } else {
            measuredWidth = 0
        }

        return ScreenProfile(
            screen: selected,
            hasNotch: hasNotch,
            notchWidth: measuredWidth,
            topInset: max(30, selected.safeAreaInsets.top)
        )
    }

    private static func detectsNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
            && screen.auxiliaryTopLeftArea != nil
            && screen.auxiliaryTopRightArea != nil
    }
}

@MainActor
final class PanelPresentation: ObservableObject {
    @Published var isExpanded = false
}

@MainActor
final class NotchPanelController: NSObject {
    static let collapsedSideExtension: CGFloat = 104
    static let expandedWidth: CGFloat = 456

    private(set) var profile: ScreenProfile
    private let model: AppModel
    private let presentation = PanelPresentation()
    private let panel: FloatingNotchPanel
    private var collapseWorkItem: DispatchWorkItem?
    private var approvalCollapseWorkItem: DispatchWorkItem?
    private var reanchorWorkItems: [DispatchWorkItem] = []
    private var isObservingDisplayLifecycle = false
    private var isHoverExpanded = false
    private var isManualExpanded = false
    private var isApprovalExpanded = false
    private var cancellables: Set<AnyCancellable> = []

    var hasNotch: Bool { profile.hasNotch }

    init(model: AppModel) {
        self.model = model
        self.profile = ScreenProfile.preferred()
        self.panel = FloatingNotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        configurePanel()
        installRootView()
        model.$tasks
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, self.presentation.isExpanded else { return }
                self.updateFrame(animated: true)
            }
            .store(in: &cancellables)
        model.$latestApprovalAlert
            .compactMap { $0 }
            .sink { [weak self] _ in
                self?.presentApprovalAlert()
            }
            .store(in: &cancellables)
        updateFrame(animated: false)
    }

    func start() {
        startObservingDisplayLifecycle()
        reanchorPanel()
    }

    func stop() {
        stopObservingDisplayLifecycle()
        reanchorWorkItems.forEach { $0.cancel() }
        reanchorWorkItems.removeAll()
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        approvalCollapseWorkItem?.cancel()
        approvalCollapseWorkItem = nil
        isHoverExpanded = false
        isManualExpanded = false
        isApprovalExpanded = false
        presentation.isExpanded = false
        panel.orderOut(nil)
    }

    func toggle() {
        if presentation.isExpanded {
            isHoverExpanded = false
            isManualExpanded = false
            isApprovalExpanded = false
            collapseWorkItem?.cancel()
            approvalCollapseWorkItem?.cancel()
        } else {
            isManualExpanded = true
        }
        reconcileExpansion()
    }

    func expand() {
        isManualExpanded = true
        reconcileExpansion()
    }

    private func configurePanel() {
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
    }

    private func installRootView() {
        panel.contentView = NSHostingView(
            rootView: NotchRootView(
                model: model,
                presentation: presentation,
                profile: profile,
                onHoverChange: { [weak self] hovering in
                    self?.requestHoverExpansion(hovering)
                },
                onToggleRequest: { [weak self] in self?.toggle() }
            )
        )
    }

    private func startObservingDisplayLifecycle() {
        guard !isObservingDisplayLifecycle else { return }
        isObservingDisplayLifecycle = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ].forEach { name in
            workspaceCenter.addObserver(
                self,
                selector: #selector(displayEnvironmentDidChange(_:)),
                name: name,
                object: nil
            )
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayEnvironmentDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func stopObservingDisplayLifecycle() {
        guard isObservingDisplayLifecycle else { return }
        isObservingDisplayLifecycle = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func displayEnvironmentDidChange(_ notification: Notification) {
        reanchorWorkItems.forEach { $0.cancel() }
        reanchorWorkItems.removeAll()

        reanchorPanel()

        // AppKit can finish restoring display geometry after the wake notification.
        // Reapply the canonical frame after those asynchronous adjustments settle.
        for delay in [0.2, 0.8] {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.isObservingDisplayLifecycle else { return }
                self.reanchorPanel()
            }
            reanchorWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func reanchorPanel() {
        let refreshedProfile = ScreenProfile.preferred(fallback: profile)
        let viewGeometryChanged = refreshedProfile.hasNotch != profile.hasNotch
            || abs(refreshedProfile.notchWidth - profile.notchWidth) > 0.5
            || abs(refreshedProfile.topInset - profile.topInset) > 0.5
        profile = refreshedProfile

        if viewGeometryChanged {
            installRootView()
        }
        updateFrame(animated: false)
        panel.orderFrontRegardless()
    }

    private func requestHoverExpansion(_ expanded: Bool) {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil

        if expanded {
            isHoverExpanded = true
            reconcileExpansion()
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.isHoverExpanded = false
            self?.reconcileExpansion()
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func presentApprovalAlert() {
        approvalCollapseWorkItem?.cancel()
        isApprovalExpanded = true
        reconcileExpansion()

        let work = DispatchWorkItem { [weak self] in
            self?.isApprovalExpanded = false
            self?.reconcileExpansion()
        }
        approvalCollapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func reconcileExpansion() {
        setExpanded(isHoverExpanded || isManualExpanded || isApprovalExpanded)
    }

    private func setExpanded(_ expanded: Bool) {
        guard presentation.isExpanded != expanded else { return }
        presentation.isExpanded = expanded
        updateFrame(animated: true)
        if expanded {
            model.refreshAll()
            panel.orderFrontRegardless()
        }
    }

    private func updateFrame(animated: Bool) {
        let expanded = presentation.isExpanded
        let size = panelSize(expanded: expanded)
        let screenFrame = profile.screen.frame
        let originX: CGFloat
        if expanded {
            originX = screenFrame.midX - size.width / 2
        } else {
            // The ambient-glass lens wraps the physical notch symmetrically.
            // On external displays it occupies the same centered glance zone.
            originX = screenFrame.midX - size.width / 2
        }
        let frame = NSRect(
            x: originX,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = presentation.isExpanded ? 0.28 : 0.22
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.22,
                    0.78,
                    0.24,
                    1.0
                )
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func panelSize(expanded: Bool) -> NSSize {
        if expanded {
            return NSSize(
                width: Self.expandedWidth,
                height: Self.expandedHeight(
                    taskCount: model.tasks.count,
                    projectCount: model.projectCount,
                    lensHeight: Self.lensHeight(for: profile)
                )
            )
        }
        return NSSize(
            width: Self.collapsedWidth(for: profile),
            height: Self.lensHeight(for: profile)
        )
    }

    static func collapsedWidth(for profile: ScreenProfile) -> CGFloat {
        if profile.hasNotch {
            return profile.notchWidth + collapsedSideExtension * 2
        }
        return 220
    }

    static func expandedLensWidth(for profile: ScreenProfile) -> CGFloat {
        if profile.hasNotch {
            return min(expandedWidth - 32, profile.notchWidth + 164)
        }
        return 220
    }

    static func lensHeight(for profile: ScreenProfile) -> CGFloat {
        profile.topInset
    }

    static func projectListHeight(taskCount: Int, projectCount: Int) -> CGFloat {
        guard taskCount > 0 else { return 82 }
        let visibleTasks = min(max(taskCount, 1), 4)
        let visibleProjects = min(max(projectCount, 1), visibleTasks)
        let naturalHeight = CGFloat(
            visibleProjects * 30
                + visibleTasks * 32
                + max(0, visibleProjects - 1) * 9
        )
        return min(naturalHeight, 248)
    }

    static func expandedHeight(
        taskCount: Int,
        projectCount: Int,
        lensHeight: CGFloat = 38
    ) -> CGFloat {
        let dashboardHeight: CGFloat
        if taskCount > 0 {
            dashboardHeight = 88 + projectListHeight(
                taskCount: taskCount,
                projectCount: projectCount
            )
        } else {
            dashboardHeight = 170
        }
        return min(
            420,
            max(232, lensHeight + 12 + dashboardHeight)
        )
    }
}

final class FloatingNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

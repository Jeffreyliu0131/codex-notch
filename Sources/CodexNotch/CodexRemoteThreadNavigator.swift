import AppKit
import ApplicationServices
import CodexNotchCore
import Foundation
import OSLog

struct CodexRemoteThreadNavigator {
    private static let codexBundleIdentifier = "com.openai.codex"
    private static let logger = Logger(
        subsystem: "com.example.codexnotch",
        category: "remote-thread-navigation"
    )

    static func probeTargetFromArguments(
        _ arguments: [String] = CommandLine.arguments
    ) -> CodexRemoteThreadNavigationTarget? {
        guard let flagIndex = arguments.firstIndex(of: "--probe-remote-navigation"),
              arguments.indices.contains(flagIndex + 4) else {
            return nil
        }
        return CodexRemoteThreadNavigationTarget(
            threadID: arguments[flagIndex + 1],
            hostID: arguments[flagIndex + 2],
            title: arguments[flagIndex + 3],
            workspaceName: arguments[flagIndex + 4]
        )
    }

    func open(_ target: CodexRemoteThreadNavigationTarget) async -> Bool {
        guard let application = await Self.runningOrLaunchCodex() else {
            Self.logger.error("Codex application unavailable")
            return false
        }

        guard Self.ensureAccessibilityPermission() else {
            Self.logger.notice("Accessibility permission requested")
            return false
        }

        application.activate(options: [.activateAllWindows])
        let processIdentifier = application.processIdentifier

        return await Task.detached(priority: .userInitiated) {
            Self.openSynchronously(target, processIdentifier: processIdentifier)
        }.value
    }

    private static func runningOrLaunchCodex() async -> NSRunningApplication? {
        if let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: codexBundleIdentifier
        ).first(where: { !$0.isTerminated }) {
            return application
        }

        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: codexBundleIdentifier
        ) else {
            return nil
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { application, _ in
                continuation.resume(returning: application)
            }
        }
    }

    private static func ensureAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func openSynchronously(
        _ target: CodexRemoteThreadNavigationTarget,
        processIdentifier: pid_t
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )

        if pressTask(target, in: applicationElement) {
            logSuccess(target)
            return true
        }

        if pressShowSidebar(in: applicationElement) {
            Thread.sleep(forTimeInterval: 0.2)
            if pressTask(target, in: applicationElement) {
                logSuccess(target)
                return true
            }
        }

        if revealWorkspaceTasks(target, in: applicationElement) {
            Thread.sleep(forTimeInterval: 0.25)
            if pressTask(target, in: applicationElement) {
                logSuccess(target)
                return true
            }
        }

        logger.error(
            "Remote thread button not found host=\(target.hostID, privacy: .private) thread=\(target.threadID, privacy: .private)"
        )
        return false
    }

    private static func pressTask(
        _ target: CodexRemoteThreadNavigationTarget,
        in applicationElement: AXUIElement
    ) -> Bool {
        let elements = windowDescendants(of: applicationElement)
        let buttons = elements.filter {
            stringAttribute($0, kAXRoleAttribute as CFString) == (kAXButtonRole as String)
        }
        let describedButtons = buttons.filter {
            titleMatches(
                accessibleTitle: stringAttribute($0, kAXDescriptionAttribute as CFString),
                targetTitle: target.title
            )
        }
        let titledButtons = buttons.filter {
            titleMatches(
                accessibleTitle: stringAttribute($0, kAXTitleAttribute as CFString),
                targetTitle: target.title
            )
        }

        guard let button = selectTaskButton(
            from: describedButtons.isEmpty ? titledButtons : describedButtons,
            workspaceName: target.workspaceName
        ) else {
            return false
        }

        _ = AXUIElementPerformAction(button, "AXScrollToVisible" as CFString)
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private static func selectTaskButton(
        from buttons: [AXUIElement],
        workspaceName: String
    ) -> AXUIElement? {
        guard !buttons.isEmpty else { return nil }

        let workspaceButtons = buttons.filter {
            nearestWorkspaceGroup(of: $0, named: workspaceName) != nil
        }
        let remoteWorkspaceButtons = workspaceButtons.filter {
            guard let group = nearestWorkspaceGroup(of: $0, named: workspaceName) else {
                return false
            }
            return containsRemoteStatus(in: group)
        }

        if remoteWorkspaceButtons.count == 1 {
            return remoteWorkspaceButtons[0]
        }
        if workspaceButtons.count == 1 {
            return workspaceButtons[0]
        }
        if buttons.count == 1 {
            return buttons[0]
        }
        return nil
    }

    private static func pressShowSidebar(in applicationElement: AXUIElement) -> Bool {
        let showSidebarLabels = ["显示边栏", "显示侧边栏", "Show sidebar"]
        guard let button = windowDescendants(of: applicationElement).first(where: {
            stringAttribute($0, kAXRoleAttribute as CFString) == (kAXButtonRole as String)
                && showSidebarLabels.contains(
                    stringAttribute($0, kAXDescriptionAttribute as CFString)
                )
        }) else {
            return false
        }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private static func revealWorkspaceTasks(
        _ target: CodexRemoteThreadNavigationTarget,
        in applicationElement: AXUIElement
    ) -> Bool {
        let workspaceGroups = windowDescendants(of: applicationElement).filter {
            stringAttribute($0, kAXRoleAttribute as CFString) == (kAXGroupRole as String)
                && stringAttribute($0, kAXDescriptionAttribute as CFString)
                    == target.workspaceName
        }
        let orderedGroups = workspaceGroups.sorted {
            containsRemoteStatus(in: $0) && !containsRemoteStatus(in: $1)
        }

        for group in orderedGroups {
            let descendants = descendants(of: group)
            if let showMore = descendants.first(where: { element in
                guard stringAttribute(element, kAXRoleAttribute as CFString)
                    == (kAXButtonRole as String) else {
                    return false
                }
                let title = stringAttribute(element, kAXTitleAttribute as CFString)
                let description = stringAttribute(
                    element,
                    kAXDescriptionAttribute as CFString
                )
                return [title, description].contains(where: {
                    ["展开显示", "显示更多", "Show more"].contains($0)
                })
            }), AXUIElementPerformAction(showMore, kAXPressAction as CFString) == .success {
                return true
            }

            if let header = descendants.first(where: { element in
                guard stringAttribute(element, kAXRoleAttribute as CFString)
                    == (kAXButtonRole as String) else {
                    return false
                }
                let description = stringAttribute(
                    element,
                    kAXDescriptionAttribute as CFString
                )
                return description.hasPrefix(target.workspaceName + " ")
                    && !description.contains("开始新聊天")
                    && !description.localizedCaseInsensitiveContains("start new chat")
            }), AXUIElementPerformAction(header, kAXPressAction as CFString) == .success {
                return true
            }
        }

        return false
    }

    private static func nearestWorkspaceGroup(
        of element: AXUIElement,
        named workspaceName: String
    ) -> AXUIElement? {
        var current = element
        for _ in 0..<16 {
            guard let parent = elementAttribute(
                current,
                kAXParentAttribute as CFString
            ) else {
                return nil
            }
            if stringAttribute(parent, kAXRoleAttribute as CFString) == (kAXGroupRole as String),
               stringAttribute(parent, kAXDescriptionAttribute as CFString) == workspaceName {
                return parent
            }
            current = parent
        }
        return nil
    }

    private static func containsRemoteStatus(in group: AXUIElement) -> Bool {
        descendants(of: group, limit: 500).contains { element in
            guard stringAttribute(element, kAXRoleAttribute as CFString) == (kAXImageRole as String)
            else {
                return false
            }
            return !stringAttribute(element, kAXDescriptionAttribute as CFString).isEmpty
        }
    }

    private static func titleMatches(
        accessibleTitle: String,
        targetTitle: String
    ) -> Bool {
        let accessible = accessibleTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessible.isEmpty, !target.isEmpty else { return false }
        if accessible == target {
            return true
        }
        guard accessible.hasSuffix("…") else { return false }
        return target.hasPrefix(String(accessible.dropLast()))
    }

    private static func windowDescendants(of applicationElement: AXUIElement) -> [AXUIElement] {
        guard let windows = attribute(
            applicationElement,
            kAXWindowsAttribute as CFString
        ) as? [AXUIElement] else {
            return []
        }
        return windows.flatMap { descendants(of: $0) }
    }

    private static func descendants(
        of root: AXUIElement,
        limit: Int = 4_000
    ) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var stack = [root]
        var seen = Set<CFHashCode>()

        while let element = stack.popLast(), result.count < limit {
            let hash = CFHash(element)
            guard seen.insert(hash).inserted else { continue }
            result.append(element)
            if let children = attribute(
                element,
                kAXChildrenAttribute as CFString
            ) as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }
        return result
    }

    private static func attribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> String {
        attribute(element, name) as? String ?? ""
    }

    private static func elementAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> AXUIElement? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func logSuccess(_ target: CodexRemoteThreadNavigationTarget) {
        logger.info(
            "Remote thread opened host=\(target.hostID, privacy: .private) thread=\(target.threadID, privacy: .private)"
        )
    }
}

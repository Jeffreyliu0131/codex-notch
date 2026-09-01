import AppKit
import CodexNotchCore
import SwiftUI

private struct GlassBlendingModeKey: EnvironmentKey {
    static let defaultValue: NSVisualEffectView.BlendingMode = .behindWindow
}

extension EnvironmentValues {
    var glassBlendingMode: NSVisualEffectView.BlendingMode {
        get { self[GlassBlendingModeKey.self] }
        set { self[GlassBlendingModeKey.self] = newValue }
    }
}

struct NotchRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: PanelPresentation
    let profile: ScreenProfile
    let onHoverChange: (Bool) -> Void
    let onToggleRequest: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lensWidth: CGFloat {
        if presentation.isExpanded {
            return NotchPanelController.expandedLensWidth(for: profile)
        }
        return NotchPanelController.collapsedWidth(for: profile)
    }

    private var lensHeight: CGFloat {
        NotchPanelController.lensHeight(for: profile)
    }

    var body: some View {
        VStack(spacing: presentation.isExpanded ? 12 : 0) {
            NotchStatusBar(
                activeCount: model.runningCount,
                attentionCount: model.attentionCount,
                failureCount: model.failureCount,
                completionPulseSequence: model.completionPulseSequence,
                usage: model.usage,
                notchGap: profile.notchWidth,
                expanded: presentation.isExpanded,
                sideExtension: NotchPanelController.collapsedSideExtension
            )
            .frame(width: lensWidth, height: lensHeight)
            .background {
                AmbientLensBackground(expanded: presentation.isExpanded)
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 15,
                    bottomTrailingRadius: 15,
                    topTrailingRadius: 0,
                    style: .continuous
                )
            )
            .shadow(
                color: .black.opacity(presentation.isExpanded ? 0.20 : 0.14),
                radius: presentation.isExpanded ? 12 : 7,
                y: presentation.isExpanded ? 5 : 3
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleRequest)

            if presentation.isExpanded {
                DashboardContentView(model: model)
                    .background {
                        AmbientPanelBackground()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.28), radius: 30, y: 15)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover(perform: onHoverChange)
        .animation(
            reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86),
            value: presentation.isExpanded
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.tasks)
    }
}

private struct NotchStatusBar: View {
    let activeCount: Int
    let attentionCount: Int
    let failureCount: Int
    let completionPulseSequence: UInt
    let usage: CodexUsageSnapshot?
    let notchGap: CGFloat
    let expanded: Bool
    let sideExtension: CGFloat

    private var stateTint: Color {
        if failureCount > 0 { return .codexRed }
        if attentionCount > 0 { return .codexOrange }
        if activeCount > 0 { return .codexGreen }
        return .white.opacity(0.28)
    }

    private var stateTitle: String {
        if failureCount > 0 { return "\(failureCount) 项出错" }
        if attentionCount > 0 { return "\(attentionCount) 项待处理" }
        if activeCount > 0 { return "\(activeCount) 个任务" }
        return "Codex"
    }

    @ViewBuilder
    var body: some View {
        if expanded {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    StatusDot(
                        active: activeCount + attentionCount + failureCount > 0,
                        tint: stateTint,
                        completionPulseSequence: completionPulseSequence
                    )
                    Text(stateTitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.94))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear
                    .frame(width: min(notchGap, 116))

                HStack(spacing: 7) {
                    if let usage {
                        QuotaRing(
                            progress: usage.remainingPercent / 100,
                            size: 19,
                            lineWidth: 2.7,
                            tint: quotaTint(for: usage)
                        )
                        Text("\(Int(usage.remainingPercent.rounded()))%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(quotaTint(for: usage))
                    } else {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 11, weight: .semibold))
                        Text("同步中")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                }
                .foregroundStyle(.white.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 18)
        } else {
            HStack(spacing: 0) {
                CompactTaskStatus(
                    activeCount: activeCount,
                    attentionCount: attentionCount,
                    failureCount: failureCount,
                    completionPulseSequence: completionPulseSequence
                )
                .frame(width: sideExtension)

                Color.clear
                    .frame(width: notchGap)

                CompactQuotaStatus(usage: usage)
                    .frame(width: sideExtension)
            }
            .frame(width: sideExtension * 2 + notchGap)
        }
    }
}

private struct CompactTaskStatus: View {
    let activeCount: Int
    let attentionCount: Int
    let failureCount: Int
    let completionPulseSequence: UInt

    private var stateTint: Color {
        if failureCount > 0 { return .codexRed }
        if attentionCount > 0 { return .codexOrange }
        if activeCount > 0 { return .codexGreen }
        return .white.opacity(0.28)
    }

    private var stateTitle: String {
        if failureCount > 0 { return "\(failureCount) 项出错" }
        if attentionCount > 0 { return "\(attentionCount) 项待处理" }
        if activeCount > 0 { return "\(activeCount) 个任务" }
        return "Codex"
    }

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(
                active: activeCount + attentionCount + failureCount > 0,
                tint: stateTint,
                completionPulseSequence: completionPulseSequence
            )
            Text(stateTitle)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stateTitle)
    }
}

private struct CompactQuotaStatus: View {
    let usage: CodexUsageSnapshot?

    var body: some View {
        HStack(spacing: 7) {
            QuotaRing(
                progress: (usage?.remainingPercent ?? 0) / 100,
                size: 19,
                lineWidth: 2.7,
                tint: quotaTint(for: usage)
            )
            Text(usage.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—%")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(usage == nil ? .white.opacity(0.42) : quotaTint(for: usage))
                .lineLimit(1)
                .minimumScaleFactor(0.86)
        }
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            usage.map { "周额度剩余 \(Int($0.remainingPercent.rounded()))%" }
                ?? "周额度同步中"
        )
    }
}

struct StandaloneDashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        DashboardContentView(model: model)
            .background(Color.codexSurface)
            .preferredColorScheme(.dark)
    }
}

struct DashboardContentView: View {
    @ObservedObject var model: AppModel

    private var projectGroups: [CodexProjectGroup] {
        CodexProjectGroup.group(
            model.tasks,
            viewedCompletionIDs: model.viewedCompletionIDs
        )
    }

    private var listHeight: CGFloat {
        guard !model.tasks.isEmpty else { return 82 }
        return NotchPanelController.projectListHeight(
            taskCount: model.tasks.count,
            projectCount: projectGroups.count
        )
    }

    private var listContentHeight: CGFloat {
        let groupHeaders = projectGroups.count * 30
        let taskRows = model.tasks.count * 32
        let groupSpacing = max(0, projectGroups.count - 1) * 9
        return CGFloat(groupHeaders + taskRows + groupSpacing)
    }

    var body: some View {
        VStack(spacing: 12) {
            header

            if model.tasks.isEmpty {
                EmptyActiveTasksView(message: model.taskError ?? model.remoteTaskError)
                    .frame(height: listHeight)
            } else {
                ScrollView(.vertical, showsIndicators: listContentHeight > listHeight) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(projectGroups.enumerated()), id: \.element.id) { index, group in
                            ProjectTaskGroupView(
                                group: group,
                                showsTopDivider: index > 0,
                                completionViewed: model.isCompletionViewed,
                                openTask: model.open,
                                dismissTask: model.dismissCompletion
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        }
                    }
                }
                .frame(height: listHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 21)
        .padding(.bottom, 11)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("活动项目")
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96))
                if !model.tasks.isEmpty || model.taskError != nil || model.remoteTaskError != nil {
                    Text(summaryText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(summaryTint)
                }
            }

            Spacer(minLength: 12)

            if let reset = model.usage?.resetsAt {
                let resetDescription = CodexQuotaResetFormatter.description(
                    for: reset,
                    relativeTo: Date()
                )
                VStack(alignment: .trailing, spacing: 3) {
                    Text("周额度")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.66))
                    Text("\(resetDescription.exact) 重置")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.88))
                    Text(resetDescription.relative)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.46))
                }
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "周额度，\(resetDescription.exact)重置，\(resetDescription.relative)"
                )
            }
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.09),
                            .white.opacity(0.055),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.6)
                .offset(y: 8)
        }
    }

    private var summaryText: String {
        let activeProjects = projectGroups.lazy.filter { $0.liveTaskCount > 0 }.count
        let liveTasks = model.tasks.lazy.filter { $0.state.isLive }.count
        if model.failureCount > 0 {
            return "\(activeProjects) 个项目 · \(model.failureCount) 项出错"
        }
        if model.attentionCount > 0 {
            return "\(activeProjects) 个项目 · \(model.attentionCount) 项需要你"
        }
        if model.taskError != nil {
            return "\(activeProjects) 个项目 · 本机同步失败"
        }
        if model.remoteTaskError != nil {
            return "\(activeProjects) 个项目 · 远端同步失败"
        }
        if model.unseenCompletionCount > 0 && liveTasks > 0 {
            return "\(activeProjects) 个项目 · \(model.unseenCompletionCount) 项新完成"
        }
        if liveTasks > 0 {
            return "\(activeProjects) 个项目"
        }
        if model.unseenCompletionCount > 0 {
            return "\(model.unseenCompletionCount) 个任务已完成，待查看"
        }
        if model.tasks.contains(where: { $0.state == .completed }) {
            return "完成结果已查看"
        }
        return "完成记录保留在 Codex"
    }

    private var summaryTint: Color {
        if model.failureCount > 0 { return .codexRed }
        if model.attentionCount > 0 { return .codexOrange }
        if model.taskError != nil || model.remoteTaskError != nil { return .codexOrange }
        if model.unseenCompletionCount > 0 { return .codexBlue }
        if model.runningCount > 0 { return .white.opacity(0.66) }
        return .white.opacity(0.56)
    }
}

private struct ProjectTaskGroupView: View {
    let group: CodexProjectGroup
    let showsTopDivider: Bool
    let completionViewed: (CodexTask) -> Bool
    let openTask: (CodexTask) -> Void
    let dismissTask: (CodexTask) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showsTopDivider {
                Rectangle()
                    .fill(Color.white.opacity(0.085))
                    .frame(height: 1)
                    .padding(.vertical, 4)
            }

            HStack(spacing: 7) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.60))
                Text(group.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 30)

            ForEach(group.tasks, id: \.identityKey) { task in
                ProjectTaskRow(
                    task: task,
                    completionViewed: completionViewed(task),
                    showsDivider: false,
                    action: { openTask(task) },
                    dismissAction: task.state == .completed
                        ? { dismissTask(task) }
                        : nil
                )
            }
        }
        .help(group.workspacePath)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("项目 \(group.name)，\(group.tasks.count) 个任务")
    }
}

private struct ProjectTaskRow: View {
    let task: CodexTask
    let completionViewed: Bool
    let showsDivider: Bool
    let action: () -> Void
    let dismissAction: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var openHovering = false
    @State private var dismissHovering = false
    @FocusState private var openFocused: Bool

    private var tint: Color { task.state.tint }

    private var isUnseenCompletion: Bool {
        task.state == .completed && !completionViewed
    }

    private var isViewedCompletion: Bool {
        task.state == .completed && completionViewed
    }

    private var deviceSymbolName: String {
        task.isRemote ? "macmini" : "laptopcomputer"
    }

    private var titleTint: Color {
        if isViewedCompletion {
            return .white.opacity(openHovering ? 0.72 : 0.62)
        }
        return .white.opacity(isUnseenCompletion ? 0.96 : 0.91)
    }

    private var metadataTint: Color {
        if isViewedCompletion {
            return .white.opacity(openHovering ? 0.56 : 0.46)
        }
        return .white.opacity(isUnseenCompletion ? 0.56 : 0.64)
    }

    private var statusTint: Color {
        switch task.state {
        case .completed:
            return .white.opacity(isViewedCompletion ? 0.46 : 0.56)
        case .inactive:
            return .white.opacity(0.5)
        default:
            return tint.opacity(0.9)
        }
    }

    private var statusName: String {
        if task.attentionReason?.shouldAlert == true { return "待批准" }
        return task.state.displayName
    }

    private var rowBackground: Color {
        if isUnseenCompletion {
            return .codexBlue.opacity(openHovering ? 0.115 : 0.065)
        }
        return openHovering ? .white.opacity(0.045) : .clear
    }

    private var rowStroke: Color {
        if openFocused {
            return .codexBlue.opacity(0.92)
        }
        if isUnseenCompletion {
            return .codexBlue.opacity(openHovering ? 0.34 : 0.18)
        }
        return .clear
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 9) {
                    if isUnseenCompletion {
                        ZStack {
                            Circle()
                                .fill(Color.codexBlue.opacity(0.18))
                                .frame(width: 13, height: 13)
                            Circle()
                                .fill(Color.codexBlue)
                                .frame(width: 7, height: 7)
                        }
                        .frame(width: 13, height: 13)
                        .accessibilityHidden(true)
                    }

                    Text(task.title)
                        .font(.system(
                            size: 11.5,
                            weight: isUnseenCompletion ? .semibold : .medium
                        ))
                        .foregroundStyle(titleTint)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: isUnseenCompletion ? 6 : 10)

                    HStack(spacing: 5) {
                        Image(systemName: deviceSymbolName)
                            .font(.system(size: task.isRemote ? 9.5 : 9, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 12)
                        Text(task.deviceName)
                            .lineLimit(1)
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(metadataTint)
                    .frame(width: isUnseenCompletion ? 62 : 70, alignment: .leading)

                    if isUnseenCompletion {
                        HStack(spacing: 4) {
                            Text("查看结果")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .bold))
                                .offset(
                                    x: openHovering && !reduceMotion ? 0.7 : 0,
                                    y: openHovering && !reduceMotion ? -0.7 : 0
                                )
                        }
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.codexBlue)
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(
                            Color.codexBlue.opacity(openHovering ? 0.22 : 0.14),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .stroke(
                                    Color.codexBlue.opacity(openHovering ? 0.48 : 0.28),
                                    lineWidth: 1
                                )
                        }
                        .fixedSize()
                        .accessibilityHidden(true)
                    } else {
                        HStack(spacing: 5) {
                            if isViewedCompletion {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                            } else {
                                Circle()
                                    .fill(statusTint)
                                    .frame(width: 5, height: 5)
                            }
                            Text(statusName)
                                .font(.system(size: 9.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(statusTint)
                        .frame(width: 52, alignment: .leading)
                    }

                    if !isUnseenCompletion {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(openHovering ? 0.46 : 0))
                            .frame(width: 10)
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, dismissAction == nil ? 10 : 2)
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .focused($openFocused)
            .help("在 \(task.deviceName) 上打开：\(task.title)")
            .accessibilityLabel(task.title)
            .accessibilityValue(
                isUnseenCompletion
                    ? "\(task.deviceName)，已完成，未查看"
                    : "\(task.deviceName)，\(statusName)"
                        + (isViewedCompletion ? "，已查看" : "")
            )
            .accessibilityHint(
                isUnseenCompletion
                    ? "打开完成结果；成功打开后标记为已查看"
                    : "在 \(task.deviceName) 上打开"
            )
            .onHover { openHovering = $0 }

            if let dismissAction {
                Button(action: dismissAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white.opacity(dismissHovering ? 0.64 : 0))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .help("移除完成记录")
                .accessibilityLabel("移除 \(task.title)")
                .accessibilityHint("从列表中移除此完成记录")
                .onHover { dismissHovering = $0 }
            }
        }
        .frame(height: 32)
        .background(rowBackground)
        .overlay(alignment: .top) {
            if showsDivider {
                Rectangle()
                    .fill(Color.white.opacity(0.055))
                    .frame(height: 1)
                .padding(.horizontal, 10)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(rowStroke, lineWidth: openFocused ? 2 : 1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: openHovering)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isViewedCompletion)
    }
}

private struct EmptyActiveTasksView: View {
    let message: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: message == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(message == nil ? Color.codexGreen.opacity(0.72) : Color.codexRed)

            VStack(alignment: .leading, spacing: 4) {
                Text(message == nil ? "暂无活动任务" : "任务读取失败")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.84))
                Text(message ?? "完成记录会保留在 Codex")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AmbientLensBackground: View {
    let expanded: Bool
    @Environment(\.glassBlendingMode) private var glassBlendingMode

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 15,
            bottomTrailingRadius: 15,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VisualEffectBlur(material: .underWindowBackground, blendingMode: glassBlendingMode)
                .opacity(0.66)

            shape
                .fill(Color.black.opacity(expanded ? 0.085 : 0.10))

            shape
                .fill(Color.codexGlassTint.opacity(expanded ? 0.20 : 0.23))

            shape
                .fill(Color.white.opacity(0.02))

            shape
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.12),
                            Color.codexBlue.opacity(0.045),
                            .clear,
                            Color.black.opacity(0.045)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            shape
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.10),
                            Color.codexBlue.opacity(0.035),
                            .clear
                        ],
                        center: UnitPoint(x: 0.22, y: 0.02),
                        startRadius: 0,
                        endRadius: 150
                    )
                )
                .blendMode(.screen)

            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.22),
                            .white.opacity(0.075),
                            Color.codexBlue.opacity(0.18),
                            Color.codexAccent.opacity(0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )

            shape
                .inset(by: 1)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.07),
                            .clear,
                            Color.codexBlue.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.55
                )

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            Color.codexBlue.opacity(0.66),
                            Color.codexViolet.opacity(0.28),
                            Color.codexAccent.opacity(0.60),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 0.9)
                .padding(.horizontal, expanded ? 31 : 21)
                .shadow(color: Color.codexBlue.opacity(0.20), radius: 2, y: -0.5)
        }
    }
}

private struct AmbientPanelBackground: View {
    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    @Environment(\.glassBlendingMode) private var glassBlendingMode

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .underWindowBackground, blendingMode: glassBlendingMode)
                .opacity(0.50)

            shape
                .fill(Color.black.opacity(0.04))

            shape
                .fill(Color.codexGlassTint.opacity(0.23))

            shape
                .fill(Color.white.opacity(0.025))

            shape
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.14),
                            Color.codexBlue.opacity(0.085),
                            .clear,
                            Color.codexViolet.opacity(0.025),
                            Color.black.opacity(0.055)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            shape
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.14),
                            Color.codexBlue.opacity(0.055),
                            .clear
                        ],
                        center: UnitPoint(x: 0.14, y: 0.04),
                        startRadius: 0,
                        endRadius: 310
                    )
                )
                .blendMode(.screen)

            shape
                .fill(
                    RadialGradient(
                        colors: [
                            Color.codexBlue.opacity(0.10),
                            .clear
                        ],
                        center: .bottomTrailing,
                        startRadius: 0,
                        endRadius: 190
                    )
                )
                .blendMode(.screen)

            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.28),
                            .white.opacity(0.085),
                            Color.codexBlue.opacity(0.28),
                            Color.codexBlue.opacity(0.62)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.85
                )
                .shadow(color: Color.codexBlue.opacity(0.12), radius: 1.5, y: 0.8)

            shape
                .inset(by: 1.15)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.09),
                            .clear,
                            Color.codexBlue.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
        }
    }
}

private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
    }
}

private enum CompletionPulsePhase: CaseIterable {
    case idle
    case bloom
    case release

    var coreScale: CGFloat {
        switch self {
        case .bloom: return 1.28
        case .idle, .release: return 1
        }
    }

    var completionEmphasis: Double {
        switch self {
        case .bloom: return 1
        case .idle, .release: return 0
        }
    }

    var haloScale: CGFloat {
        switch self {
        case .idle: return 0.78
        case .bloom: return 1
        case .release: return 2.35
        }
    }

    var haloOpacity: Double {
        switch self {
        case .bloom: return 0.62
        case .idle, .release: return 0
        }
    }
}

private struct StatusDot: View {
    let active: Bool
    let tint: Color
    let completionPulseSequence: UInt
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var baseColor: Color {
        active ? tint : Color.white.opacity(0.28)
    }

    var body: some View {
        PhaseAnimator(
            CompletionPulsePhase.allCases,
            trigger: completionPulseSequence
        ) { phase in
            ZStack {
                Circle()
                    .stroke(Color.codexGreen, lineWidth: 1.05)
                    .scaleEffect(reduceMotion ? 1 : phase.haloScale)
                    .opacity(reduceMotion ? 0 : phase.haloOpacity)

                Circle()
                    .fill(Color.codexGreen)
                    .opacity(phase.completionEmphasis)
                    .blendMode(.plusLighter)

                Circle()
                    .fill(baseColor)
                    .opacity(1 - phase.completionEmphasis * 0.22)
            }
            .frame(width: 7, height: 7)
            .scaleEffect(reduceMotion ? 1 : phase.coreScale)
            .shadow(
                color: Color.codexGreen.opacity(phase.completionEmphasis * 0.82),
                radius: phase == .bloom ? 6 : 2
            )
            .shadow(color: active ? tint.opacity(0.62) : .clear, radius: 4)
        } animation: { phase in
            if reduceMotion {
                return phase == .bloom
                    ? .easeOut(duration: 0.14)
                    : .easeInOut(duration: 0.42)
            }

            switch phase {
            case .idle:
                return .linear(duration: 0)
            case .bloom:
                return .spring(response: 0.22, dampingFraction: 0.72)
            case .release:
                return .easeOut(duration: 0.68)
            }
        }
    }
}

private struct QuotaRing: View {
    let progress: Double
    let size: CGFloat
    let lineWidth: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.11), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(
                    AngularGradient(
                        colors: [
                            tint.opacity(0.44),
                            tint,
                            .white.opacity(0.78),
                            tint,
                            tint.opacity(0.44)
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(0.22), radius: 4)
    }
}

private func quotaTint(for usage: CodexUsageSnapshot?) -> Color {
    guard let remaining = usage?.remainingPercent else { return .white.opacity(0.38) }
    if remaining < 10 { return .codexRed }
    if remaining < 20 { return .codexOrange }
    return .codexAccent
}

private extension CodexTaskState {
    var displayName: String {
        switch self {
        case .running: return "运行中"
        case .needsAttention: return "需要你"
        case .failed: return "出错"
        case .completed: return "已完成"
        case .inactive: return "待机"
        }
    }

    var tint: Color {
        switch self {
        case .running: return .codexGreen
        case .needsAttention: return .codexOrange
        case .failed: return .codexRed
        case .completed: return .codexAccent
        case .inactive: return .white.opacity(0.38)
        }
    }
}

private extension Color {
    static let codexSurface = Color(red: 0.028, green: 0.032, blue: 0.042)
    static let codexGlassTint = Color(red: 0.025, green: 0.23, blue: 0.68)
    static let codexAccent = Color(red: 0.50, green: 0.96, blue: 0.73)
    static let codexGreen = Color(red: 0.35, green: 0.93, blue: 0.60)
    static let codexOrange = Color(red: 1.00, green: 0.67, blue: 0.28)
    static let codexRed = Color(red: 1.00, green: 0.36, blue: 0.38)
    static let codexBlue = Color(red: 0.30, green: 0.62, blue: 1.00)
    static let codexViolet = Color(red: 0.42, green: 0.47, blue: 1.00)
}

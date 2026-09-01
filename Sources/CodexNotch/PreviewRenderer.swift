import AppKit
import SwiftUI

@MainActor
enum PreviewRenderer {
    private static let previewFlags = [
        "--render-preview",
        "--render-attention-preview",
        "--render-completion-preview",
        "--render-viewed-completion-preview",
        "--render-idle-preview",
        "--render-collapsed-preview"
    ]

    static func destinationFromArguments() -> URL? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(where: previewFlags.contains),
              arguments.indices.contains(flag + 1) else {
            return nil
        }
        return URL(fileURLWithPath: arguments[flag + 1])
    }

    static func render(to destination: URL) throws {
        let model = AppModel()
        let previewMode: PreviewMode
        if CommandLine.arguments.contains("--render-viewed-completion-preview") {
            previewMode = .viewedCompletion
        } else if CommandLine.arguments.contains("--render-attention-preview") {
            previewMode = .attention
        } else if CommandLine.arguments.contains("--render-completion-preview") {
            previewMode = .completion
        } else if CommandLine.arguments.contains("--render-idle-preview") {
            previewMode = .idle
        } else {
            previewMode = .running
        }
        model.loadPreviewData(previewMode)
        let presentation = PanelPresentation()
        let collapsed = CommandLine.arguments.contains("--render-collapsed-preview")
        presentation.isExpanded = !collapsed
        let profile = ScreenProfile.preferred()

        let content: AnyView
        let canvasSize: NSSize
        if collapsed {
            let collapsedWidth = NotchPanelController.collapsedWidth(for: profile)
            content = AnyView(
                CollapsedPreviewCanvas(
                    model: model,
                    presentation: presentation,
                    profile: profile,
                    collapsedWidth: collapsedWidth
                )
            )
            canvasSize = NSSize(width: 430, height: 84)
        } else {
            content = AnyView(
                ExpandedPreviewCanvas(
                    model: model,
                    presentation: presentation,
                    profile: profile
                )
            )
            canvasSize = NSSize(width: 793, height: 496)
        }

        let hostingView = NSHostingView(rootView: content)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: canvasSize)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw PreviewError.bitmapUnavailable
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewError.encodingFailed
        }
        try png.write(to: destination, options: .atomic)
    }
}

private struct ExpandedPreviewCanvas: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: PanelPresentation
    let profile: ScreenProfile

    private var componentHeight: CGFloat {
        NotchPanelController.expandedHeight(
            taskCount: model.tasks.count,
            projectCount: model.projectCount,
            lensHeight: NotchPanelController.lensHeight(for: profile)
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            PreviewDesktopBackdrop()

            NotchRootView(
                model: model,
                presentation: presentation,
                profile: profile,
                onHoverChange: { _ in },
                onToggleRequest: {}
            )
            .environment(\.glassBlendingMode, .withinWindow)
            .frame(
                width: NotchPanelController.expandedWidth,
                height: componentHeight,
                alignment: .top
            )
            .offset(x: -6.5)
        }
        .frame(width: 793, height: 496)
        .preferredColorScheme(.dark)
    }
}

private struct CollapsedPreviewCanvas: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: PanelPresentation
    let profile: ScreenProfile
    let collapsedWidth: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            PreviewDesktopBackdrop()

            NotchRootView(
                model: model,
                presentation: presentation,
                profile: profile,
                onHoverChange: { _ in },
                onToggleRequest: {}
            )
            .environment(\.glassBlendingMode, .withinWindow)
            .frame(
                width: collapsedWidth,
                height: NotchPanelController.lensHeight(for: profile)
            )
        }
        .frame(width: 430, height: 84)
        .preferredColorScheme(.dark)
    }
}

private struct PreviewDesktopBackdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.39, green: 0.59, blue: 0.90),
                    Color(red: 0.055, green: 0.19, blue: 0.37),
                    Color(red: 0.012, green: 0.055, blue: 0.13)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Color.black.opacity(0.20)
                .frame(height: 40)

            Rectangle()
                .fill(Color.white.opacity(0.075))
                .frame(height: 1)
                .offset(y: 40)
        }
    }
}

private enum PreviewError: LocalizedError {
    case bitmapUnavailable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .bitmapUnavailable:
            return "无法创建预览画布"
        case .encodingFailed:
            return "无法编码预览 PNG"
        }
    }
}

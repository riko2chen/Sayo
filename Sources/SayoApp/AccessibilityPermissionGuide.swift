import AppKit
import CoreGraphics
import SwiftUI
import SayoCore
import SayoPlatform

@MainActor
final class AccessibilityPermissionGuideController {
    private let panelSize = NSSize(width: 330, height: 196)
    private var panel: NSPanel?
    private var trackingTask: Task<Void, Never>?
    private var postDropTask: Task<Void, Never>?
    private var onPermissionChanged: (() -> Void)?

    func begin(language: InterfaceLanguage, onPermissionChanged: @escaping () -> Void) {
        self.onPermissionChanged = onPermissionChanged

        if AccessibilityTextAdapter.isTrusted {
            close()
            onPermissionChanged()
            AccessibilityTextAdapter.openPermissionSettings()
            return
        }

        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension.lowercased() == "app" else {
            AccessibilityTextAdapter.requestPermission()
            AccessibilityTextAdapter.openPermissionSettings()
            return
        }

        AccessibilityTextAdapter.openPermissionSettings()
        showPanel(bundleURL: bundleURL, language: language)
        startTrackingSystemSettings()
    }

    func close() {
        trackingTask?.cancel()
        trackingTask = nil
        postDropTask?.cancel()
        postDropTask = nil
        panel?.close()
        panel = nil
    }

    func refreshPermission() {
        guard AccessibilityTextAdapter.isTrusted else { return }
        onPermissionChanged?()
        close()
    }

    private func showPanel(bundleURL: URL, language: InterfaceLanguage) {
        close()

        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Sayo"

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false

        panel.contentView = NSHostingView(rootView: AccessibilityPermissionGuideView(
            bundleURL: bundleURL,
            appName: appName,
            language: language,
            onClose: { [weak self] in self?.close() },
            onDrop: { [weak self] operation in
                if operation != [] { self?.waitForPermissionAfterDrop() }
            }
        ))

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panelSize.width - 24,
                y: visible.minY + 24
            ))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func waitForPermissionAfterDrop() {
        // The drop only adds the app to the TCC list. macOS may still show a
        // confirmation sheet and commit the grant a moment later, so keep a
        // short-lived watcher alive after hiding our guide panel.
        trackingTask?.cancel()
        trackingTask = nil
        panel?.orderOut(nil)

        postDropTask?.cancel()
        postDropTask = Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(12)

            while !Task.isCancelled, clock.now < deadline {
                if AccessibilityTextAdapter.isTrusted {
                    onPermissionChanged?()
                    close()
                    return
                }
                try? await Task.sleep(for: .milliseconds(120))
            }

            // Give TCC one final tick to commit after the system sheet closes.
            try? await Task.sleep(for: .milliseconds(200))
            refreshPermission()
            postDropTask = nil
        }
    }

    private func startTrackingSystemSettings() {
        trackingTask?.cancel()
        trackingTask = Task { [weak self] in
            guard let self else { return }
            var hasSeenSettings = false

            while !Task.isCancelled {
                if AccessibilityTextAdapter.isTrusted {
                    close()
                    return
                }

                if let settingsFrame = systemSettingsFrame() {
                    hasSeenSettings = true
                    dockPanel(near: settingsFrame)
                } else if hasSeenSettings {
                    close()
                    return
                }

                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func dockPanel(near coreGraphicsFrame: CGRect) {
        guard let panel else { return }
        let settingsFrame = appKitFrame(from: coreGraphicsFrame)
        let screen = NSScreen.screens.first { $0.frame.intersects(settingsFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? settingsFrame
        let inset: CGFloat = 16
        let x = min(
            max(settingsFrame.maxX - panel.frame.width - inset, visible.minX + 8),
            visible.maxX - panel.frame.width - 8
        )
        let y = min(
            max(settingsFrame.minY + inset, visible.minY + 8),
            visible.maxY - panel.frame.height - 8
        )
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }

    private func systemSettingsFrame() -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return nil
        }

        var bestFrame: CGRect?
        for window in windows {
            guard let ownerName = window[kCGWindowOwnerName] as? String,
                  ownerName == "System Settings" || ownerName == "System Preferences",
                  let layer = window[kCGWindowLayer] as? Int,
                  layer == 0,
                  let bounds = window[kCGWindowBounds] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 300,
                  frame.height >= 200
            else { continue }

            if bestFrame == nil || frame.width * frame.height > bestFrame!.width * bestFrame!.height {
                bestFrame = frame
            }
        }
        return bestFrame
    }

    private func appKitFrame(from coreGraphicsFrame: CGRect) -> NSRect {
        guard let primaryScreen = NSScreen.screens.first else { return coreGraphicsFrame }
        return NSRect(
            x: coreGraphicsFrame.origin.x,
            y: primaryScreen.frame.height - coreGraphicsFrame.origin.y - coreGraphicsFrame.height,
            width: coreGraphicsFrame.width,
            height: coreGraphicsFrame.height
        )
    }
}

private struct AccessibilityPermissionGuideView: View {
    let bundleURL: URL
    let appName: String
    let language: InterfaceLanguage
    let onClose: () -> Void
    let onDrop: (NSDragOperation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("Add Sayo to Accessibility", "将 Sayo 添加到辅助功能"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(language.text("Drag the app below into the Accessibility list.", "将下方应用拖入辅助功能列表。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 9) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(language.text("DROP INTO SYSTEM SETTINGS", "拖入系统设置"))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
            }

            DraggableAppBundleView(bundleURL: bundleURL, appName: appName, language: language, onDrop: onDrop)
                .frame(height: 48)

            Text(language.text(
                "After dropping, approve macOS if asked and make sure Sayo is switched on.",
                "拖入后，如果 macOS 弹出确认，请允许访问，并确保 Sayo 的开关已打开。"
            ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 330, height: 196, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.08))
        )
    }
}

private struct DraggableAppBundleView: NSViewRepresentable {
    let bundleURL: URL
    let appName: String
    let language: InterfaceLanguage
    let onDrop: (NSDragOperation) -> Void

    func makeNSView(context: Context) -> DraggableAppBundleNSView {
        DraggableAppBundleNSView(bundleURL: bundleURL, appName: appName, language: language, onDrop: onDrop)
    }

    func updateNSView(_ nsView: DraggableAppBundleNSView, context: Context) {
        nsView.onDrop = onDrop
        nsView.setLanguage(language)
    }
}

private final class DraggableAppBundleNSView: NSView, NSDraggingSource {
    private let bundleURL: URL
    private let iconView: NSImageView
    private let nameLabel: NSTextField
    private let dragHint: NSTextField
    private var mouseDownEvent: NSEvent?
    private var hasStartedDrag = false
    var onDrop: (NSDragOperation) -> Void

    init(bundleURL: URL, appName: String, language: InterfaceLanguage, onDrop: @escaping (NSDragOperation) -> Void) {
        self.bundleURL = bundleURL
        self.onDrop = onDrop

        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icon.size = NSSize(width: 32, height: 32)
        iconView = NSImageView(image: icon)
        nameLabel = NSTextField(labelWithString: appName)
        dragHint = NSTextField(labelWithString: language.text("Drag", "拖动"))

        super.init(frame: NSRect(x: 0, y: 0, width: 294, height: 48))
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        dragHint.font = .systemFont(ofSize: 10, weight: .medium)
        dragHint.textColor = .secondaryLabelColor
        dragHint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragHint)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            dragHint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dragHint.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: dragHint.leadingAnchor, constant: -10)
        ])
    }

    func setLanguage(_ language: InterfaceLanguage) {
        dragHint.stringValue = language.text("Drag", "拖动")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 48)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        hasStartedDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownEvent, !hasStartedDrag else { return }
        let dx = event.locationInWindow.x - mouseDownEvent.locationInWindow.x
        let dy = event.locationInWindow.y - mouseDownEvent.locationInWindow.y
        guard hypot(dx, dy) >= 3 else { return }
        hasStartedDrag = true

        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: snapshot() ?? iconView.image)
        let session = beginDraggingSession(with: [item], event: mouseDownEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        hasStartedDrag = false
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        mouseDownEvent = nil
        hasStartedDrag = false
        onDrop(operation)
    }

    private func snapshot() -> NSImage? {
        guard bounds.width > 1, bounds.height > 1,
              let representation = bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }

        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }
}

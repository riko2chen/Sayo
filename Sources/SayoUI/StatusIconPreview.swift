import AppKit
import AVFoundation
import SwiftUI
import SayoCore

enum StatusIconTransition: Equatable {
    case brandToMonochrome
    case monochromeToBrand

    init?(from: StatusBarIconStyle, to: StatusBarIconStyle) {
        switch (from, to) {
        case (.brand, .monochrome): self = .brandToMonochrome
        case (.monochrome, .brand): self = .monochromeToBrand
        default: return nil
        }
    }

    var destination: StatusBarIconStyle {
        switch self {
        case .brandToMonochrome: return .monochrome
        case .monochromeToBrand: return .brand
        }
    }

    var resourceName: String {
        switch self {
        case .brandToMonochrome: return "StatusIconBrandToMonochrome"
        case .monochromeToBrand: return "StatusIconMonochromeToBrand"
        }
    }
}

struct StatusIconPreviewState: Equatable {
    private(set) var displayedStyle: StatusBarIconStyle
    private(set) var desiredStyle: StatusBarIconStyle
    private(set) var activeTransition: StatusIconTransition?

    init(initialStyle: StatusBarIconStyle) {
        displayedStyle = initialStyle
        desiredStyle = initialStyle
    }

    mutating func select(_ style: StatusBarIconStyle) -> StatusIconTransition? {
        desiredStyle = style
        return startTransitionIfNeeded()
    }

    mutating func finishPlayback() -> StatusIconTransition? {
        guard let completed = activeTransition else { return nil }
        displayedStyle = completed.destination
        activeTransition = nil
        return startTransitionIfNeeded()
    }

    private mutating func startTransitionIfNeeded() -> StatusIconTransition? {
        guard activeTransition == nil,
              let transition = StatusIconTransition(from: displayedStyle, to: desiredStyle) else {
            return nil
        }
        activeTransition = transition
        return transition
    }
}

private struct StatusIconPlayback: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

@MainActor
private final class StatusIconPreviewModel: ObservableObject {
    @Published private(set) var displayedStyle: StatusBarIconStyle
    @Published private(set) var playback: StatusIconPlayback?

    private var state: StatusIconPreviewState

    init(initialStyle: StatusBarIconStyle) {
        state = StatusIconPreviewState(initialStyle: initialStyle)
        displayedStyle = initialStyle
    }

    func selectionChanged(to style: StatusBarIconStyle) {
        guard let transition = state.select(style) else { return }
        begin(transition)
    }

    func playbackFinished(id: UUID) {
        guard playback?.id == id else { return }
        let nextTransition = state.finishPlayback()
        displayedStyle = state.displayedStyle
        playback = nextTransition.flatMap(Self.playback(for:))
    }

    private func begin(_ transition: StatusIconTransition) {
        playback = Self.playback(for: transition)
    }

    private static func playback(for transition: StatusIconTransition) -> StatusIconPlayback? {
        guard let url = Bundle.module.url(forResource: transition.resourceName, withExtension: "mp4") else {
            return nil
        }
        return StatusIconPlayback(url: url)
    }
}

struct StatusIconPreview: View {
    @Binding private var style: StatusBarIconStyle
    @StateObject private var model: StatusIconPreviewModel

    private static let brandImage = loadImage(named: "SayoLogo")
    private static let monochromeImage = loadImage(named: "StatusIconMonochrome")

    init(style: Binding<StatusBarIconStyle>) {
        _style = style
        _model = StateObject(wrappedValue: StatusIconPreviewModel(initialStyle: style.wrappedValue))
    }

    var body: some View {
        ZStack {
            previewBackdrop
            if showsMonochromeGlyph {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
            } else {
                staticImage(for: model.displayedStyle)
            }
            if let playback = model.playback {
                SilentStatusIconVideo(
                    url: playback.url,
                    playbackID: playback.id,
                    onFinished: { model.playbackFinished(id: playback.id) }
                )
                .id(playback.id)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style == .brand ? "Chameleon icon preview" : "Monochrome icon preview")
        .onAppear { model.selectionChanged(to: style) }
        .onChange(of: style) { _, newStyle in model.selectionChanged(to: newStyle) }
    }

    /// Settings-only: the monochrome asset is white-on-cream and vanishes on the card.
    private var showsMonochromeGlyph: Bool {
        model.displayedStyle == .monochrome
    }

    private var previewBackdrop: Color {
        showsMonochromeGlyph ? SayoStyle.ink : .clear
    }

    @ViewBuilder
    private func staticImage(for style: StatusBarIconStyle) -> some View {
        if let image = style == .brand ? Self.brandImage : Self.monochromeImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            Color.clear
        }
    }

    private static func loadImage(named name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

private struct SilentStatusIconVideo: NSViewRepresentable {
    let url: URL
    let playbackID: UUID
    let onFinished: () -> Void

    func makeNSView(context: Context) -> StatusIconPlayerView {
        StatusIconPlayerView()
    }

    func updateNSView(_ view: StatusIconPlayerView, context: Context) {
        view.play(url: url, playbackID: playbackID, onFinished: onFinished)
    }

    static func dismantleNSView(_ view: StatusIconPlayerView, coordinator: ()) {
        view.stop()
    }
}

private final class StatusIconPlayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var player: AVPlayer?
    private var playbackID: UUID?
    private var readyObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.isHidden = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func play(url: URL, playbackID: UUID, onFinished: @escaping () -> Void) {
        guard self.playbackID != playbackID else { return }
        stop()
        self.playbackID = playbackID

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        self.player = player
        playerLayer.player = player
        playerLayer.isHidden = true

        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay, self?.playbackID == playbackID else { return }
            DispatchQueue.main.async {
                guard self?.playbackID == playbackID else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self?.playerLayer.isHidden = false
                CATransaction.commit()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard self?.playbackID == playbackID else { return }
            onFinished()
        }

        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished, self?.playbackID == playbackID else { return }
            player.play()
        }
    }

    func stop() {
        player?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        readyObservation = nil
        playerLayer.player = nil
        playerLayer.isHidden = true
        player = nil
        playbackID = nil
    }

    deinit {
        stop()
    }
}

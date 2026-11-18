import SwiftUI
import AppKit
import ImageIO

/// A new screenshot drops out from under the notch on a short thread, swings, hangs for a few seconds and tucks back.
/// It lives in its own small window: the island is clipped to the notch, ignores clicks outside it, and
/// a separate window can be kept out of the next screenshot.
final class ScreenshotDrop: ObservableObject {
    static let shared = ScreenshotDrop()

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let image: NSImage
        let size: CGSize
    }
    enum Phase { case hidden, hanging, lifted, copied }

    @Published private(set) var item: Item?
    @Published private(set) var phase: Phase = .hidden
    /// Degrees the thumbnail is tilted; set to ±7 at the drop and sprung back to 0.
    @Published var tilt = 0.0

    static let hangFor: TimeInterval = 5
    /// The gap, and the thread, between notch and thumbnail.
    static let string: CGFloat = 8
    /// Room for the shadow around the thumbnail.
    static let margin: CGFloat = 22
    /// Room for the caption under the thumbnail.
    static let caption: CGFloat = 20

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    private var releaseWatch: Timer?
    /// Alternates the swing's direction from one screenshot to the next.
    private var flip = false

    private init() {}

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Showing

    func present(fileAt url: URL) {
        guard IslandFeature.screenshotDrop.isOn, IslandState.shared.canPeek else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 480]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return }
            // The thumbnail keeps the picture's shape, rotation included.
            let pixels = CGSize(width: thumbnail.width, height: thumbnail.height)
            let image = NSImage(cgImage: thumbnail, size: .zero)
            DispatchQueue.main.async { self?.show(Item(url: url, image: image, size: Self.thumbSize(for: pixels))) }
        }
    }

    private func show(_ new: Item) {
        guard IslandState.shared.canPeek else { return }
        dismissWork?.cancel()
        releaseWatch?.invalidate()
        releaseWatch = nil
        // A newer screenshot replaces the one hanging and drops afresh.
        phase = .hidden
        item = new
        flip.toggle()
        tilt = reduceMotion ? 0 : (flip ? 7 : -7)
        place(new)
        panel?.orderFrontRegardless()

        DispatchQueue.main.async { [self] in
            guard item?.id == new.id else { return }
            if reduceMotion {
                withAnimation(IslandMotion.reduced) { phase = .hanging }
            } else {
                withAnimation(IslandMotion.drop) { phase = .hanging }
                withAnimation(IslandMotion.swing) { tilt = 0 }
            }
        }
        // "Kept" means it is in clipboard history; it is not on the clipboard until the thumbnail is clicked.
        IslandState.shared.post(Peek(kind: .screenshot, icon: "camera.viewfinder", title: "Screenshot",
                                     value: ClipboardModule.shared.enabled ? "Kept" : "Saved"))
        scheduleDismiss(after: Self.hangFor)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // One below the island, so the notch covers the thumbnail's top as it emerges.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // Kept out of the next screenshot.
        panel.sharingType = .none
        panel.contentView = FirstMouseHostingView(rootView: ScreenshotDropView())
        return panel
    }

    /// The window's top edge is the notch's bottom edge, so the picture seems to come out of the notch.
    private func place(_ item: Item) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = PanelController.notchScreen()
        let width = item.size.width + 2 * Self.margin
        let height = Self.string + item.size.height + Self.margin + Self.caption
        let top = screen.frame.maxY - IslandState.shared.inset - IslandState.restingOverhang
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height), display: true)
    }

    // MARK: Leaving

    func dismiss() {
        guard let current = item else { return }
        dismissWork?.cancel()
        dismissWork = nil
        releaseWatch?.invalidate()
        releaseWatch = nil
        withAnimation(reduceMotion ? IslandMotion.reduced : IslandMotion.tuck) { phase = .hidden }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.item?.id == current.id, self.phase == .hidden else { return }
            self.panel?.orderOut(nil)
            self.item = nil
        }
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Pointing at the thumbnail keeps it; leaving gives it two more seconds.
    func hover(_ inside: Bool) {
        if inside {
            dismissWork?.cancel()
        } else if phase == .hanging {
            scheduleDismiss(after: 2)
        }
    }

    /// A drag began: wait for the button to come up, wherever the file went, then tuck away.
    func lifted() {
        phase = .lifted
        dismissWork?.cancel()
        releaseWatch?.invalidate()
        releaseWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            self?.dismiss()
        }
    }

    func copy() {
        guard let item else { return }
        ClipboardModule.shared.copyImage(at: item.url)
        withAnimation(IslandMotion.confirm) { phase = .copied }
        Haptics.tap()
        scheduleDismiss(after: 0.9)
    }

    func trash() {
        guard let item else { return }
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        dismiss()
    }

    /// Whether a screen point is on the hanging thumbnail's window.
    func contains(_ point: NSPoint) -> Bool {
        guard item != nil, let panel, panel.isVisible else { return false }
        return panel.frame.contains(point)
    }

    /// The thumbnail's size on screen for a picture of `pixels`: within 180 x 112, never thinner than 64 x 40. Pure, for tests.
    static func thumbSize(for pixels: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0 else { return CGSize(width: 180, height: 112) }
        let aspect = pixels.width / pixels.height
        let scale = min(180 / pixels.width, 112 / pixels.height)
        var width = pixels.width * scale
        var height = pixels.height * scale
        // Very tall or very wide strips are cropped to fill.
        if width < 64 { width = 64; height = min(112, 64 / aspect) }
        if height < 40 { height = 40; width = min(180, 40 * aspect) }
        return CGSize(width: width.rounded(), height: height.rounded())
    }
}

/// The hanging thumbnail: a thread from the notch, the picture, and a caption while pointed at.
private struct ScreenshotDropView: View {
    @ObservedObject private var drop = ScreenshotDrop.shared
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if let item = drop.item {
                let hidden = drop.phase == .hidden
                VStack(spacing: 6) {
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.white.opacity(0.45))
                            .frame(width: 1.5, height: ScreenshotDrop.string)
                        thumbnail(item)
                    }
                    // The pendulum pivots where the thread meets the notch.
                    .rotationEffect(.degrees(drop.tilt), anchor: .top)
                    .offset(y: hidden && !reduceMotion ? -(ScreenshotDrop.string + item.size.height + 14) : 0)
                    .scaleEffect(reduceMotion ? 1 : hidden ? 0.92 : hovering ? 1.04 : 1, anchor: .top)
                    .opacity(hidden && reduceMotion ? 0 : drop.phase == .lifted ? 0.3 : 1)

                    if hovering && drop.phase == .hanging {
                        Text("Click to copy · drag to use")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.75)))
                            .transition(reduceMotion ? .opacity : .focus(4))
                    }
                }
                .animation(reduceMotion ? IslandMotion.reduced : IslandMotion.quick, value: hovering)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    private func thumbnail(_ item: ScreenshotDrop.Item) -> some View {
        let copied = drop.phase == .copied
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { drop.copy() } label: {
            ZStack {
                Image(nsImage: item.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: item.size.width, height: item.size.height)
                    .blur(radius: copied ? 6 : 0)
                    .opacity(copied ? 0.4 : 1)
                if copied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(width: item.size.width, height: item.size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 12, y: 7)
            .contentShape(shape)
        }
        .buttonStyle(IslandPressStyle(highlight: false))
        .onDrag {
            drop.lifted()
            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        }
        .onHover { inside in
            hovering = inside
            drop.hover(inside)
        }
        .contextMenu {
            Button("Copy") { drop.copy() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Move to Trash", role: .destructive) { drop.trash() }
        }
        .help("Click to copy. Drag it into an app.")
        .accessibilityLabel("New screenshot")
        .accessibilityHint("Click to copy it, or drag it into an app.")
    }
}

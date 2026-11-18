import SwiftUI
import AppKit
import AVFoundation

// MARK: - Mirror

/// Runs the camera only while the Mirror tab is on screen. Nothing is recorded or saved.
final class MirrorModule: ObservableObject {
    static let shared = MirrorModule()

    @Published private(set) var status = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var unavailable = false
    @Published private(set) var cameraName = ""
    @Published private(set) var cameraCount = 1
    /// Flipped like a mirror (the default), or the way other people see you.
    @Published var mirrored: Bool {
        didSet { UserDefaults.standard.set(mirrored, forKey: "mirrorMirrored") }
    }
    let session = AVCaptureSession()
    private var current: AVCaptureDevice?
    private let queue = DispatchQueue(label: "qolnotch.mirror")

    private init() {
        mirrored = UserDefaults.standard.object(forKey: "mirrorMirrored") as? Bool ?? true
    }

    private static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            DispatchQueue.main.async {
                self?.status = AVCaptureDevice.authorizationStatus(for: .video)
                self?.start()
            }
        }
    }

    func start() {
        guard status == .authorized else { return }
        queue.async { [self] in
            let all = Self.cameras()
            if current == nil, let camera = AVCaptureDevice.default(for: .video) ?? all.first { use(camera) }
            let found = current != nil
            DispatchQueue.main.async {
                self.cameraCount = all.count
                self.unavailable = !found
            }
            if found, !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Moves to the next camera, for a Mac with more than one (an iPhone or a webcam).
    func switchCamera() {
        queue.async { [self] in
            let all = Self.cameras()
            guard all.count > 1 else { return }
            let index = all.firstIndex { $0.uniqueID == current?.uniqueID } ?? -1
            use(all[(index + 1) % all.count])
        }
    }

    /// Must run on `queue`.
    private func use(_ camera: AVCaptureDevice) {
        guard let input = try? AVCaptureDeviceInput(device: camera) else { return }
        session.beginConfiguration()
        let old = session.inputs
        old.forEach { session.removeInput($0) }
        if session.canAddInput(input) {
            session.sessionPreset = .medium
            session.addInput(input)
            current = camera
        } else {
            old.forEach { if session.canAddInput($0) { session.addInput($0) } }
        }
        session.commitConfiguration()
        let name = current?.localizedName ?? ""
        DispatchQueue.main.async { self.cameraName = name }
    }
}

/// Hosts the live picture in a sublayer so it can be flipped without AppKit undoing it.
private final class CameraView: NSView {
    private let picture: AVCaptureVideoPreviewLayer
    var mirrored = true { didSet { if mirrored != oldValue { needsLayout = true } } }

    init(session: AVCaptureSession) {
        picture = AVCaptureVideoPreviewLayer(session: session)
        picture.videoGravity = .resizeAspectFill
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(picture)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.setAffineTransform(.identity)
        picture.frame = bounds
        picture.setAffineTransform(CGAffineTransform(scaleX: mirrored ? -1 : 1, y: 1))
        CATransaction.commit()
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool

    func makeNSView(context: Context) -> CameraView {
        let view = CameraView(session: session)
        view.mirrored = mirrored
        return view
    }

    func updateNSView(_ view: CameraView, context: Context) { view.mirrored = mirrored }
}

struct MirrorTab: View {
    @Environment(\.islandPalette) private var look
    @ObservedObject private var mirror = MirrorModule.shared

    var body: some View {
        Group {
            if mirror.status == .authorized && !mirror.unavailable {
                HStack(spacing: 10) {
                    CameraPreview(session: mirror.session, mirrored: mirror.mirrored)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: look.tileRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: look.tileRadius, style: .continuous)
                            .strokeBorder(look.hairline, lineWidth: 0.5))
                    Group {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(mirror.mirrored ? "Mirror view" : "As others see you")
                                .font(look.font(13, .semibold)).foregroundStyle(look.text)
                            Text(mirror.cameraName.isEmpty ? "Nothing is recorded." : "\(mirror.cameraName). Nothing is recorded.")
                                .font(look.font(11)).foregroundStyle(look.secondary).lineLimit(2)
                            Spacer(minLength: 0)
                            HStack(spacing: 6) {
                                Button { mirror.mirrored.toggle() } label: {
                                    Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                                }
                                .buttonStyle(IslandChipStyle(prominent: true))
                                .help("Flip the picture left to right: a mirror, or the way other people see you.")
                                if mirror.cameraCount > 1 {
                                    Button { mirror.switchCamera() } label: {
                                        Label("Camera", systemImage: "arrow.triangle.2.circlepath.camera")
                                    }
                                    .buttonStyle(IslandChipStyle())
                                    .help("Switch to your next camera.")
                                }
                            }
                        }
                    }
                }
            } else {
                IslandNotice(icon: message.icon, title: message.title, detail: message.detail,
                             button: mirror.status == .notDetermined && !mirror.unavailable ? "Turn On Camera" : nil) {
                    mirror.requestAccess()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .onAppear { mirror.start() }
        .onDisappear { mirror.stop() }
    }

    private var message: (icon: String, title: String, detail: String) {
        if mirror.unavailable { return ("video.slash", "No camera found.", "Connect a camera, then open this tab again.") }
        if mirror.status == .notDetermined {
            return ("person.crop.square", "Check how you look before you start.",
                    "The camera only runs while this tab is open. Nothing is recorded.")
        }
        return ("video.slash", "Camera access is off.", "Turn it on in System Settings → Privacy & Security → Camera.")
    }
}

// MARK: - Notes

/// One scratch note that survives restarts and can be sent to the prompter as the script.
final class NotesModule: ObservableObject {
    static let shared = NotesModule()

    @Published var text: String {
        didSet { UserDefaults.standard.set(text, forKey: "quickNote") }
    }

    private init() { text = UserDefaults.standard.string(forKey: "quickNote") ?? "" }
}

struct NotesTab: View {
    @Environment(\.islandPalette) private var look
    @ObservedObject private var notes = NotesModule.shared
    @ObservedObject private var island = IslandState.shared
    @ObservedObject var model: PrompterModel
    @FocusState private var typing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $notes.text)
                    .font(look.font(13))
                    .foregroundStyle(look.text)
                    .scrollContentBackground(.hidden)
                    .focused($typing)
                if notes.text.isEmpty {
                    Text("What's on your mind?")
                        .font(look.font(13)).foregroundStyle(look.secondary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .islandTile(look)

            VStack(alignment: .leading, spacing: 6) {
                if typing {
                    Button("Done") { typing = false }.buttonStyle(IslandChipStyle(prominent: true))
                        .help("Stop typing. The island can close again.")
                }
                Button("Use as Script") {
                    typing = false
                    model.text = notes.text
                    island.tab = .prompter
                }
                .buttonStyle(IslandChipStyle())
                .disabled(notes.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Replace the prompter's script with this note.")
                Button("Clear") { notes.text = "" }.buttonStyle(IslandChipStyle())
                    .disabled(notes.text.isEmpty)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .onChange(of: typing) { _, now in island.editing = now }
        .onDisappear { island.editing = false }
    }
}

// MARK: - Glass

/// The blurred desktop behind the island when a theme turns frosted glass on.
struct GlassBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

import SwiftUI
import AppKit
import CryptoKit

/// One thing that was copied: a piece of text, or a picture such as a screenshot.
struct Clip: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String?
    /// File name of the saved PNG, for a picture.
    var image: String?
    /// Tells two copies of the same thing apart from two different things.
    var fingerprint: String
    var date = Date()

    var isImage: Bool { image != nil }
}

/// Recent copies, text and pictures, kept on this Mac so they are still there after a restart.
/// Entries that password managers mark as private are never recorded.
final class ClipboardModule: ObservableObject {
    static let shared = ClipboardModule(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QoL Notch/Clipboard", isDirectory: true),
        watching: true)
    static let limit = 30

    @Published private(set) var items: [Clip] = []
    /// Set when macOS refuses to let QoL Notch read the folder screenshots are saved in.
    @Published private(set) var blockedFolder: URL?
    @Published var enabled: Bool {
        didSet {
            guard watching else { return }
            UserDefaults.standard.set(enabled, forKey: "clipboardHistory")
            refreshWatching()
        }
    }

    private let directory: URL
    private let watching: Bool
    private var timer: Timer?
    private var screenshots: NSMetadataQuery?
    private var screenshotObserver: NSObjectProtocol?
    private var lastChange = NSPasteboard.general.changeCount
    private let thumbnails = NSCache<NSString, NSImage>()
    /// Markers password managers put on the clipboard so history tools skip the entry.
    private static let privateTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"]

    /// `watching` is false in tests, which add clips by hand and never touch the real clipboard.
    init(directory: URL, watching: Bool) {
        self.directory = directory
        self.watching = watching
        enabled = watching ? UserDefaults.standard.bool(forKey: "clipboardHistory") : true
        load()
        refreshWatching()
    }

    // MARK: Watching the clipboard

    /// New screenshots are wanted for history, or for the drop under the notch; either switch is enough.
    private var wantsScreenshots: Bool { watching && (enabled || IslandFeature.screenshotDrop.isOn) }

    /// Starts or stops watching the clipboard and new screenshots to match the two settings.
    func refreshWatching() {
        guard watching else { return }
        if enabled {
            if timer == nil {
                lastChange = NSPasteboard.general.changeCount
                timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.check() }
            }
            // Only history asks about the folder up front; the drop alone waits for the first screenshot.
            checkScreenshotFolder()
        } else {
            timer?.invalidate()
            timer = nil
            blockedFolder = nil
        }
        if wantsScreenshots {
            watchScreenshots()
        } else {
            screenshots?.stop()
            screenshots = nil
            if let screenshotObserver { NotificationCenter.default.removeObserver(screenshotObserver) }
            screenshotObserver = nil
        }
    }

    /// A plain screenshot (Shift-Command-3 or 4) is saved as a file and never reaches the clipboard.
    /// Spotlight marks those files, wherever they are saved, so new ones can be picked up from there.
    private func watchScreenshots() {
        guard screenshots == nil else { return }
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate > %@", Date() as NSDate)
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        screenshotObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query,
                                                                    queue: .main) { [weak self] note in
            let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            for item in added {
                guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                // Give macOS a moment to finish writing the file.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.addScreenshot(at: URL(fileURLWithPath: path)) }
            }
        }
        query.start()
        screenshots = query
    }

    /// Where macOS saves screenshots: the folder chosen in the Screenshot app, else the Desktop.
    static var screenshotFolder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// Reading the folder once is what makes macOS ask for permission, if it is going to;
    /// if it refuses, the Clipboard tab says so and offers a way to allow it.
    private func checkScreenshotFolder() {
        let folder = Self.screenshotFolder
        DispatchQueue.global(qos: .utility).async {
            let readable = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
            DispatchQueue.main.async { self.blockedFolder = readable ? nil : folder }
        }
    }

    /// Picture types a screen capture is saved as; screen recordings carry the same Spotlight mark and are skipped.
    private static let pictureExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]

    private func addScreenshot(at url: URL, attempt: Int = 0) {
        guard wantsScreenshots, Self.pictureExtensions.contains(url.pathExtension.lowercased()) else { return }
        do {
            let data = try Data(contentsOf: url)
            blockedFolder = nil
            if enabled, let png = Self.png(fromFile: data, at: url) { add(png: png) }
            ScreenshotDrop.shared.present(fileAt: url)
        } catch {
            let error = error as NSError
            let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
            if error.code == NSFileReadNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES) {
                blockedFolder = url.deletingLastPathComponent()
            } else if attempt < 5 {
                // The file is not finished, or was just renamed: try again shortly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.addScreenshot(at: url, attempt: attempt + 1) }
            }
        }
    }

    /// Choosing the folder in an Open panel lets QoL Notch read it. If that is not enough,
    /// System Settings opens at Full Disk Access.
    func allowScreenshotFolder() {
        let folder = blockedFolder ?? Self.screenshotFolder
        let panel = NSOpenPanel()
        panel.directoryURL = folder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Allow"
        panel.message = "Choose the folder your screenshots are saved in so QoL Notch can add them to clipboard history."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        if (try? FileManager.default.contentsOfDirectory(atPath: chosen.path)) != nil {
            blockedFolder = nil
        } else if let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(settings)
        }
    }

    private func check() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        let types = board.types?.map(\.rawValue) ?? []
        guard !types.contains(where: Self.privateTypes.contains) else { return }
        if let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            add(text: text)
        } else if let png = Self.png(from: board) {
            add(png: png)
        }
    }

    /// A screenshot sent to the clipboard arrives as PNG or TIFF; either way it is kept as PNG.
    private static func png(from board: NSPasteboard) -> Data? {
        if let data = board.data(forType: .png) { return data }
        guard let tiff = board.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: Adding and removing

    func add(text: String) {
        insert(Clip(text: text, fingerprint: Self.fingerprint(Data(text.utf8))))
    }

    func add(png: Data) {
        let print = Self.fingerprint(png)
        // The same picture copied again only moves to the front; its file is already there.
        if let existing = items.first(where: { $0.fingerprint == print }) { return insert(existing) }
        let name = UUID().uuidString + ".png"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard (try? png.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil else { return }
        insert(Clip(image: name, fingerprint: print))
    }

    private func insert(_ clip: Clip) {
        var fresh = clip
        fresh.date = Date()
        items.removeAll { $0.fingerprint == clip.fingerprint }
        items.insert(fresh, at: 0)
        for dropped in items.dropFirst(Self.limit) { deleteFile(of: dropped) }
        items = Array(items.prefix(Self.limit))
        save()
    }

    func remove(_ clip: Clip) {
        items.removeAll { $0.id == clip.id }
        deleteFile(of: clip)
        save()
    }

    func clear() {
        items.forEach(deleteFile)
        items = []
        save()
    }

    private func deleteFile(of clip: Clip) {
        guard let url = imageURL(clip) else { return }
        try? FileManager.default.removeItem(at: url)
        thumbnails.removeObject(forKey: url.path as NSString)
    }

    // MARK: Using a clip

    /// Puts a clip back on the clipboard and moves it to the front.
    func copy(_ clip: Clip) {
        let board = NSPasteboard.general
        board.clearContents()
        if let text = clip.text {
            board.setString(text, forType: .string)
        } else if let url = imageURL(clip), let data = try? Data(contentsOf: url) {
            board.setData(data, forType: .png)
        }
        lastChange = board.changeCount
        insert(clip)
    }

    /// Puts a picture file on the clipboard, as PNG, and keeps it in history when that is on.
    func copyImage(at url: URL) {
        guard let data = try? Data(contentsOf: url), let png = Self.png(fromFile: data, at: url) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
        lastChange = board.changeCount
        if enabled { add(png: png) }
    }

    private static func png(fromFile data: Data, at url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    func imageURL(_ clip: Clip) -> URL? { clip.image.map { directory.appendingPathComponent($0) } }

    func thumbnail(_ clip: Clip) -> NSImage? {
        guard let url = imageURL(clip) else { return nil }
        if let cached = thumbnails.object(forKey: url.path as NSString) { return cached }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 420]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: .zero)
        thumbnails.setObject(thumbnail, forKey: url.path as NSString)
        return thumbnail
    }

    // MARK: Saving

    private var index: URL { directory.appendingPathComponent("history.json") }

    private func load() {
        guard let data = try? Data(contentsOf: index),
              let saved = try? JSONDecoder().decode([Clip].self, from: data) else { return }
        // Drop pictures whose file has gone missing.
        items = saved.filter { clip in
            imageURL(clip).map { FileManager.default.fileExists(atPath: $0.path) } ?? (clip.text != nil)
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: index, options: .atomic)
        // Only this user can read the history.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Recent copies as a row of cards: click one to copy it again, drag it out, or right-click to delete.
struct ClipboardTab: View {
    @Environment(\.islandPalette) private var look
    @ObservedObject private var clipboard = ClipboardModule.shared
    /// The card that was just copied, so it can say so for a moment.
    @State private var justCopied: UUID?

    var body: some View {
        Group {
            if !clipboard.enabled {
                IslandNotice(icon: "doc.on.clipboard", title: "Clipboard history is off.",
                             detail: "When on, QoL Notch keeps the last \(ClipboardModule.limit) things you copy, text and screenshots, on this Mac. Entries from password managers are skipped.",
                             button: "Turn On") { clipboard.enabled = true }
            } else if let folder = clipboard.blockedFolder, clipboard.items.isEmpty {
                screenshotNotice(folder)
            } else if clipboard.items.isEmpty {
                IslandNotice(icon: "doc.on.clipboard", title: "Nothing copied yet.",
                             detail: "Copy some text, or take a screenshot to the clipboard with Control-Shift-Command-4, and it appears here.",
                             button: "Turn Off") { clipboard.enabled = false }
            } else {
                HStack(spacing: 8) {
                    if let folder = clipboard.blockedFolder {
                        // History still works for text; this only explains why screenshots are missing.
                        Button { clipboard.allowScreenshotFolder() } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "lock").font(.system(size: 16, weight: .medium))
                                Text("Allow\nscreenshots").font(look.font(10, .medium)).multilineTextAlignment(.center)
                            }
                            .foregroundStyle(look.accent)
                            .frame(width: 92)
                            .frame(maxHeight: .infinity)
                            .background(RoundedRectangle(cornerRadius: look.tileRadius, style: .continuous).fill(look.accent.opacity(0.14)))
                        }
                        .buttonStyle(IslandPressStyle(highlight: false))
                        .help("macOS is blocking QoL Notch from \(folder.lastPathComponent), where screenshots are saved. Click to allow it.")
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(clipboard.items) { clip in card(clip) }
                        }
                    }
                    .contentMargins(.horizontal, 10, for: .scrollContent)
                    .fadedEdges()
                    VStack(spacing: 6) {
                        sideButton("trash", "Delete all history") { clipboard.clear() }
                        sideButton("power", "Turn clipboard history off") { clipboard.enabled = false }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func screenshotNotice(_ folder: URL) -> some View {
        IslandNotice(icon: "lock", title: "Screenshots can't be read yet.",
                     detail: "macOS is blocking QoL Notch from the \(folder.lastPathComponent) folder, where your screenshots are saved. Copied text and pictures still work.",
                     button: "Allow…") { clipboard.allowScreenshotFolder() }
    }

    private func card(_ clip: Clip) -> some View {
        let copied = justCopied == clip.id
        return Button {
            clipboard.copy(clip)
            withAnimation(.easeOut(duration: 0.18)) { justCopied = clip.id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                withAnimation(.easeOut(duration: 0.25)) { if justCopied == clip.id { justCopied = nil } }
            }
        } label: {
            ZStack {
                Group {
                    if let image = clipboard.thumbnail(clip) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Text(clip.text ?? "")
                            .font(look.font(11))
                            .foregroundStyle(look.text.opacity(0.9))
                            .lineLimit(6)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(9)
                    }
                }
                .blur(radius: copied ? 6 : 0)
                .opacity(copied ? 0.35 : 1)
                if copied {
                    Label("Copied", systemImage: "checkmark")
                        .font(look.font(13, .semibold)).foregroundStyle(look.text)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(width: 138)
            .frame(maxHeight: .infinity)
            .background(look.fill)
            .clipShape(RoundedRectangle(cornerRadius: look.tileRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: look.tileRadius, style: .continuous).strokeBorder(look.hairline, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag {
            if let url = clipboard.imageURL(clip) { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            return NSItemProvider(object: (clip.text ?? "") as NSString)
        }
        .contextMenu {
            Button("Copy") { clipboard.copy(clip) }
            if let url = clipboard.imageURL(clip) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Delete", role: .destructive) { clipboard.remove(clip) }
        }
        .help(clip.isImage ? "Click to copy this picture. Drag it out to use it." : "Click to copy again.")
        .accessibilityLabel(clip.isImage ? "Picture copied \(clip.date.formatted(date: .omitted, time: .shortened))" : (clip.text ?? ""))
    }

    private func sideButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(look.secondary)
                .frame(width: 30)
                .frame(maxHeight: .infinity)
                .islandTile(look, radius: min(look.tileRadius, 10))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

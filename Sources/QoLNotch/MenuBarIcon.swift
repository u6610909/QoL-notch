import SwiftUI
import AppKit

/// The one-colour logo for the menu bar: the tile, with the bezel and island cut out
/// and the coral "current word" bar left solid. Drawn in code from the same numbers as
/// Branding/logo-mark-mono-black.svg, so it stays sharp at any scale.
enum MenuBarIcon {
    static let image: NSImage = {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The logo's 1024 artboard has the tile at 100...924; fit that tile into 1...17.
            let scale = (size - 2) / 824
            context.translateBy(x: 1 - 100 * scale, y: 1 - 100 * scale)
            context.scaleBy(x: scale, y: scale)

            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()

            // Knock out the bezel and the island.
            context.setBlendMode(.clear)
            NSBezierPath(rect: NSRect(x: 100, y: 100, width: 824, height: 96)).fill()
            island().fill()

            context.setBlendMode(.normal)
            NSBezierPath(roundedRect: NSRect(x: 312, y: 354, width: 400, height: 88), xRadius: 44, yRadius: 44).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "QoL Notch"
        return image
    }()

    /// The island with its ears, as in the small logo.
    private static func island() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 188, y: 196))
        p.curve(to: NSPoint(x: 232, y: 240), controlPoint1: NSPoint(x: 215.28, y: 196), controlPoint2: NSPoint(x: 232, y: 212.72))
        p.line(to: NSPoint(x: 232, y: 480))
        p.curve(to: NSPoint(x: 352, y: 600), controlPoint: NSPoint(x: 232, y: 600))
        p.line(to: NSPoint(x: 672, y: 600))
        p.curve(to: NSPoint(x: 792, y: 480), controlPoint: NSPoint(x: 792, y: 600))
        p.line(to: NSPoint(x: 792, y: 240))
        p.curve(to: NSPoint(x: 836, y: 196), controlPoint1: NSPoint(x: 792, y: 212.72), controlPoint2: NSPoint(x: 808.72, y: 196))
        p.close()
        return p
    }
}

/// What opens from the menu bar icon.
struct MenuBarMenu: View {
    @ObservedObject var model: PrompterModel
    let toggleListening: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open QoL Notch") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button(model.listening ? "Pause Listening" : "Start Listening", action: toggleListening)
        Button(model.panelVisible ? "Hide Prompter" : "Show Prompter") { model.panelVisible.toggle() }
        Menu("Island") {
            ForEach(IslandTab.allCases) { tab in
                Button(tab.title) { IslandState.shared.open(tab) }
            }
            Divider()
            Button("Play Welcome") { IslandState.shared.greet() }
            Button("Close Island") { IslandState.shared.collapse() }
        }
        Divider()
        Button("Quit QoL Notch") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

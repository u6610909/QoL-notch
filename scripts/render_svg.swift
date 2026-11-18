// Renders an SVG to a PNG of an exact pixel size with WebKit, keeping transparency.
// Usage: swift scripts/render_svg.swift <in.svg> <width> <height> <out.png> [more jobs: in w h out ...]
import AppKit
import WebKit

final class Renderer: NSObject, WKNavigationDelegate {
    var jobs: [(URL, Int, Int, URL)]
    let view: WKWebView

    init(jobs: [(URL, Int, Int, URL)]) {
        self.jobs = jobs
        view = WKWebView(frame: .zero)
        view.setValue(false, forKey: "drawsBackground")
        super.init()
        view.navigationDelegate = self
    }

    func next() {
        guard let job = jobs.first else { NSApp.terminate(nil); return }
        let (input, width, height, _) = job
        // Draw at the SVG's own size in points, then snapshot at the wanted pixel width.
        let svg = (try? String(contentsOf: input, encoding: .utf8)) ?? ""
        let html = """
        <html><head><style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}
        svg{display:block;width:\(width)px;height:\(height)px}</style></head><body>\(svg)</body></html>
        """
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.loadHTMLString(html, baseURL: input.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let (_, width, height, output) = jobs.removeFirst()
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: width, height: height)
        config.snapshotWidth = NSNumber(value: width)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            webView.takeSnapshot(with: config) { image, error in
                guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    FileHandle.standardError.write("Could not render \(output.path): \(String(describing: error))\n".data(using: .utf8)!)
                    exit(1)
                }
                // Redraw into a bitmap of exactly width x height pixels.
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current?.imageInterpolation = .high
                NSImage(cgImage: cg, size: .zero).draw(in: NSRect(x: 0, y: 0, width: width, height: height))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: output)
                self.next()
            }
        }
    }
}

var args = Array(CommandLine.arguments.dropFirst())
var jobs: [(URL, Int, Int, URL)] = []
while args.count >= 4 {
    jobs.append((URL(fileURLWithPath: args[0]), Int(args[1])!, Int(args[2])!, URL(fileURLWithPath: args[3])))
    args.removeFirst(4)
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer(jobs: jobs)
DispatchQueue.main.async { renderer.next() }
app.run()

import Foundation
import Network
import AppKit
import CoreImage.CIFilterBuiltins

/// A tiny web server on the local network so a phone's browser can control the prompter.
/// Every request must carry the random token shown in the QR code.
final class RemoteServer {
    private var listener: NWListener?
    let token: String = {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<8).map { _ in alphabet.randomElement()! })
    }()
    private(set) var port: UInt16 = 0

    var stateProvider: () -> [String: Any] = { [:] }
    var onCommand: (String) -> Void = { _ in }
    var onReady: (UInt16) -> Void = { _ in }
    var onFailure: (String) -> Void = { _ in }

    func start() {
        stop()
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = listener.port?.rawValue ?? 0
                    self.onReady(self.port)
                case .failed(let error):
                    self.onFailure(error.localizedDescription)
                default:
                    break
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            onFailure(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let response = self.respond(to: request)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// Handles one request and returns the full HTTP response. Internal so tests can call it.
    func respond(to request: String) -> Data {
        let parts = (request.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
        guard parts.count >= 2, let components = URLComponents(string: String(parts[1])) else {
            return Self.http(400, "text/plain", "Bad request")
        }
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        guard query["t"] == token else {
            return Self.http(403, "text/plain", "Scan the QR code in QoL Notch to open the remote.")
        }
        switch components.path {
        case "/":
            return Self.http(200, "text/html; charset=utf-8", Self.page(token: token))
        case "/state":
            let json = (try? JSONSerialization.data(withJSONObject: stateProvider())) ?? Data("{}".utf8)
            return Self.http(200, "application/json", json)
        case "/cmd":
            if let action = query["a"] { onCommand(action) }
            return Self.http(200, "application/json", "{\"ok\":true}")
        default:
            return Self.http(404, "text/plain", "Not found")
        }
    }

    private static func http(_ status: Int, _ type: String, _ body: String) -> Data {
        http(status, type, Data(body.utf8))
    }

    private static func http(_ status: Int, _ type: String, _ body: Data) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found"][status] ?? "OK"
        var data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    private static func page(token: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
        <title>QoL Notch Remote</title>
        <style>
        :root{color-scheme:dark}
        body{margin:0;padding:20px 16px;background:#0b0b10;color:#f2f2f5;font:16px -apple-system,system-ui,sans-serif;-webkit-user-select:none;user-select:none}
        #script{min-height:132px;padding:16px;border-radius:18px;background:#15151d;font-size:19px;line-height:1.45}
        #before{color:#6b6b78}#now{color:#fff;background:#3340ff;border-radius:6px;padding:0 4px}#after{color:#c9c9d4}
        #meta{display:flex;justify-content:space-between;color:#8a8a96;font-size:14px;margin:10px 4px 18px}
        .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}
        button{font:600 18px -apple-system,system-ui,sans-serif;color:#f2f2f5;background:#1d1d28;border:0;border-radius:16px;padding:20px 0;touch-action:manipulation}
        button:active{background:#2c2c3c}
        #toggle{grid-column:span 4;padding:28px 0;font-size:22px;background:#3340ff}
        #toggle.on{background:#e0672a}
        .wide{grid-column:span 2}
        #lost{display:none;color:#ff8a70;text-align:center;margin-top:16px}
        </style></head><body>
        <div id="script"><span id="before"></span> <span id="now"></span> <span id="after"></span></div>
        <div id="meta"><span id="progress">–</span><span id="time"></span></div>
        <div class="grid">
          <button id="toggle" onclick="cmd('toggle')">Start</button>
          <button onclick="cmd('back10')">&laquo; 10</button>
          <button onclick="cmd('back1')">&lsaquo; 1</button>
          <button onclick="cmd('fwd1')">1 &rsaquo;</button>
          <button onclick="cmd('fwd10')">10 &raquo;</button>
          <button class="wide speed" onclick="cmd('slower')">Slower</button>
          <button class="wide speed" onclick="cmd('faster')">Faster</button>
          <button class="wide" onclick="cmd('smaller')">A&minus;</button>
          <button class="wide" onclick="cmd('larger')">A+</button>
          <button class="wide" onclick="cmd('restart')">Restart</button>
          <button class="wide" onclick="cmd('snap')">Snap to notch</button>
        </div>
        <div id="lost">Lost connection to QoL Notch</div>
        <script>
        const t='\(token)';
        function cmd(a){fetch('/cmd?t='+t+'&a='+a).then(refresh).catch(()=>{})}
        function fmt(s){s=Math.round(s);return Math.floor(s/60)+':'+String(s%60).padStart(2,'0')}
        function refresh(){
          fetch('/state?t='+t).then(r=>r.json()).then(s=>{
            document.getElementById('lost').style.display='none';
            document.getElementById('before').textContent=s.before;
            document.getElementById('now').textContent=s.now;
            document.getElementById('after').textContent=s.after;
            document.getElementById('progress').textContent=s.current+' / '+s.total+' words';
            document.getElementById('time').textContent=s.elapsed>0?fmt(s.elapsed):'';
            const b=document.getElementById('toggle');
            b.textContent=s.listening?'Pause':'Start';b.className=s.listening?'on':'';
            document.querySelectorAll('.speed').forEach(e=>e.style.display=s.auto?'':'none');
          }).catch(()=>{document.getElementById('lost').style.display='block'});
        }
        setInterval(refresh,700);refresh();
        </script></body></html>
        """
    }
}

/// Owns the remote server and what the Remote tab shows.
final class RemoteController: ObservableObject {
    static let shared = RemoteController()

    @Published private(set) var url: String?
    @Published private(set) var qrCode: NSImage?
    @Published private(set) var error: String?
    @Published var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { server.start() } else { server.stop(); url = nil; qrCode = nil }
        }
    }

    let server = RemoteServer()

    private init() {
        server.onReady = { [weak self] port in
            guard let self else { return }
            guard let address = Self.localAddress() else {
                self.error = "Could not find this Mac's Wi-Fi address. Check that Wi-Fi is on."
                return
            }
            let link = "http://\(address):\(port)/?t=\(self.server.token)"
            self.error = nil
            self.url = link
            self.qrCode = Self.makeQRCode(link)
        }
        server.onFailure = { [weak self] message in
            self?.error = "Could not start the remote: \(message)"
            self?.url = nil
            self?.qrCode = nil
        }
    }

    /// This Mac's IPv4 address on the local network.
    static func localAddress() -> String? {
        var result: String?
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return nil }
        defer { freeifaddrs(pointer) }
        var cursor = pointer
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: host)
                if !address.hasPrefix("169.254") {
                    result = address
                    if name == "en0" { break }
                }
            }
        }
        return result
    }

    static func makeQRCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

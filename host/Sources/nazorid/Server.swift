import Foundation
import Network

/// Receives pen records over the wire and fans them out to the sinks.
///
/// TCP is the USB path (`adb reverse` puts the device's loopback here) and is
/// bound to loopback only. UDP is the Wi-Fi path and is off unless asked for,
/// because it is the only socket that would be reachable from the network.
final class Server {

    struct Options {
        var port: UInt16 = 40118
        var wsPort: UInt16 = 40119
        var enableWiFi = false
        var enableInject = true
        var dump = false
    }

    private let options: Options
    private let injector: TabletInjector
    private let ws: WebSocketHub
    private let queue = DispatchQueue(label: "nazori.server")

    private var tcp: NWListener?
    private var udp: NWListener?
    private var carry = Data()
    private var received: UInt64 = 0
    private var rejected: UInt64 = 0
    private var lastSeq: UInt32?
    private var gaps: UInt64 = 0
    private var beats: UInt64 = 0

    init(options: Options, injector: TabletInjector, ws: WebSocketHub) {
        self.options = options
        self.injector = injector
        self.ws = ws
    }

    func start() throws {
        try startTCP()
        if options.enableWiFi { try startUDP() }
    }

    private func startTCP() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                 port: NWEndpoint.Port(rawValue: options.port)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.greet(conn)
            self.pump(conn)
        }
        listener.start(queue: queue)
        tcp = listener
        FileHandle.standardError.write(
            Data("nazorid: TCP 127.0.0.1:\(options.port) で待機中 (USB)\n".utf8))
    }

    private func startUDP() throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params,
                                      on: NWEndpoint.Port(rawValue: options.port)!)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.pump(conn)
        }
        listener.start(queue: queue)
        udp = listener
        FileHandle.standardError.write(
            Data("nazorid: UDP 0.0.0.0:\(options.port) で待機中 (Wi-Fi)\n".utf8))
    }

    /// Tells a fresh client how big the target display is, so the device can
    /// letterbox its active area to the same shape.
    private func greet(_ conn: NWConnection) {
        injector.refreshDisplay()
        let b = injector.displayBounds
        let hello = PenRecord.hello(width: Float(b.width), height: Float(b.height))
        conn.send(content: hello, completion: .contentProcessed { _ in })
    }

    private func pump(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if isComplete || error != nil {
                self.injector.releaseStuckContact()
                conn.cancel()
                return
            }
            self.pump(conn)
        }
    }

    private func consume(_ data: Data) {
        carry.append(data)
        var offset = 0
        carry.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            while offset + PenRecord.byteCount <= raw.count {
                guard let rec = PenRecord.decode(raw, at: offset) else {
                    // Resynchronise a byte at a time rather than dropping the
                    // whole buffer: a single corrupt record should cost one
                    // sample, not the rest of the stroke.
                    rejected += 1
                    offset += 1
                    continue
                }
                offset += PenRecord.byteCount
                received += 1
                // Keepalives all carry seq 0, so they are excluded from the
                // gap count before it can accuse the link of dropping samples.
                if rec.kind != .heartbeat {
                    if let prev = lastSeq, rec.seq != prev &+ 1 { gaps += 1 }
                    lastSeq = rec.seq
                }
                deliver(rec)
            }
        }
        carry.removeFirst(offset)
    }

    private func deliver(_ rec: PenRecord) {
        // A keepalive exists only to prove the socket is alive; it must not
        // reach the event system or paint.
        if rec.kind == .heartbeat {
            beats += 1
            return
        }
        if options.enableInject { injector.handle(rec) }
        ws.broadcast(rec)
        if options.dump {
            let line = String(
                format: "%@ seq=%u x=%.4f y=%.4f p=%.3f tilt=(%.1f,%.1f) flags=0x%02X\n",
                String(describing: rec.kind), rec.seq, rec.x, rec.y, rec.pressure,
                rec.tiltXDegrees, rec.tiltYDegrees, rec.flags)
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }

    var stats: String {
        "受信 \(received)  不正 \(rejected)  seq跳び \(gaps)  鼓動 \(beats)"
    }
}

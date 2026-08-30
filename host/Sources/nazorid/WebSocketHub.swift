import Foundation
import Network

/// Re-broadcasts accepted records to local WebSocket clients -- the paint app.
///
/// This is the path that needs no driver and no system permission: paint gets
/// the raw pen data and turns it into its own input samples, so pressure and
/// tilt arrive intact regardless of what macOS does with the injected events.
final class WebSocketHub {
    private let port: UInt16
    private let queue = DispatchQueue(label: "nazori.ws")
    private var listener: NWListener?
    private var clients: [NWConnection] = []

    /// Supplies the target display size, so a joining client can be told the
    /// shape the device is letterboxed to and avoid distorting the mapping.
    var displaySize: (Float, Float) = (0, 0)

    init(port: UInt16) {
        self.port = port
    }

    var clientCount: Int { queue.sync { clients.count } }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                                 port: NWEndpoint.Port(rawValue: port)!)
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed:
                    self.queue.async { self.clients.removeAll { $0 === conn } }
                default:
                    break
                }
            }
            conn.start(queue: self.queue)
            self.queue.async {
                self.clients.append(conn)
                self.greet(conn)
            }
            self.drainIncoming(conn)
        }
        l.start(queue: queue)
        listener = l
        FileHandle.standardError.write(
            Data("nazorid: ws://127.0.0.1:\(port) を公開 (paint 用)\n".utf8))
    }

    /// The same HELLO the USB client gets, so both sides of the link learn the
    /// target geometry from one place.
    private func greet(_ conn: NWConnection) {
        let (w, h) = displaySize
        guard w > 0, h > 0 else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "hello", metadata: [meta])
        conn.send(content: PenRecord.hello(width: w, height: h),
                  contentContext: ctx, isComplete: true,
                  completion: .contentProcessed { _ in })
    }

    /// paint never talks back, but the receive loop has to run for the
    /// connection to notice a close.
    private func drainIncoming(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.drainIncoming(conn)
        }
    }

    func broadcast(_ rec: PenRecord) {
        queue.async {
            guard !self.clients.isEmpty else { return }
            let payload = rec.encode()
            let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
            let ctx = NWConnection.ContentContext(identifier: "pen", metadata: [meta])
            for c in self.clients {
                c.send(content: payload, contentContext: ctx, isComplete: true,
                       completion: .contentProcessed { _ in })
            }
        }
    }
}

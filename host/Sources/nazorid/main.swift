import ApplicationServices
import CoreGraphics
import Foundation

let usage = """
nazorid — Android のペン入力を Mac で受ける常駐

  --port <n>        ペン入力の待ち受けポート (既定 40118)
  --ws-port <n>     paint 向け WebSocket ポート (既定 40119)
  --display <id>    出力先ディスプレイ ID (既定はメイン)
  --list-displays   ディスプレイ ID を並べて終了
  --wifi            UDP も開く。LAN から届くようになる (既定は閉じている)
  --no-inject       OS へイベントを送らず、paint へ流すだけ
  --dump            受け取った記録を標準出力へ書き出す
  --help

USB で使うとき:  adb reverse tcp:40118 tcp:40118
"""

var opts = Server.Options()
var displayID = CGMainDisplayID()

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let a = args[i]
    func next() -> String? { i + 1 < args.count ? args[i + 1] : nil }
    switch a {
    case "--help", "-h":
        print(usage); exit(0)
    case "--list-displays":
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        for id in ids {
            let b = CGDisplayBounds(id)
            let main = id == CGMainDisplayID() ? "  (メイン)" : ""
            print("\(id)\t\(Int(b.width))x\(Int(b.height)) @ (\(Int(b.origin.x)),\(Int(b.origin.y)))\(main)")
        }
        exit(0)
    case "--port":
        guard let v = next(), let n = UInt16(v) else { print(usage); exit(2) }
        opts.port = n; i += 1
    case "--ws-port":
        guard let v = next(), let n = UInt16(v) else { print(usage); exit(2) }
        opts.wsPort = n; i += 1
    case "--display":
        guard let v = next(), let n = UInt32(v) else { print(usage); exit(2) }
        displayID = n; i += 1
    case "--wifi":
        opts.enableWiFi = true
    case "--no-inject":
        opts.enableInject = false
    case "--dump":
        opts.dump = true
    default:
        FileHandle.standardError.write(Data("不明な引数: \(a)\n".utf8))
        print(usage); exit(2)
    }
    i += 1
}

let injector = TabletInjector(displayID: displayID)
let bounds = injector.displayBounds
FileHandle.standardError.write(Data(
    "nazorid: 出力先 display \(displayID) \(Int(bounds.width))x\(Int(bounds.height))\n".utf8))

if opts.enableInject && !TabletInjector.hasAccessibilityTrust() {
    FileHandle.standardError.write(Data("""

    ⚠ アクセシビリティの許可がありません。この状態で CGEvent を送っても
      macOS は黙って捨てます (エラーは返りません)。

      システム設定 → プライバシーとセキュリティ → アクセシビリティ で
      このバイナリを許可してください:
        \(CommandLine.arguments[0])

      paint へ流すだけなら --no-inject を付ければ許可は要りません。

    """.utf8))
}

let hub = WebSocketHub(port: opts.wsPort)
hub.displaySize = (Float(bounds.width), Float(bounds.height))
let server = Server(options: opts, injector: injector, ws: hub)

do {
    try hub.start()
    try server.start()
} catch {
    FileHandle.standardError.write(Data("起動できません: \(error)\n".utf8))
    exit(1)
}

// A dropped link must not leave a mouse button held down somewhere.
signal(SIGINT) { _ in
    FileHandle.standardError.write(Data("\nnazorid: 終了\n".utf8))
    exit(0)
}

if opts.dump {
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
        FileHandle.standardError.write(
            Data("nazorid: \(server.stats)  ws client \(hub.clientCount)\n".utf8))
    }
}

RunLoop.main.run()

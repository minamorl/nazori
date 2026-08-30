// A small window that prints the tablet data an ordinary Cocoa app would see.
// Clicks are aimed here rather than at the desktop, so the measurement costs
// nothing outside this window.
import Cocoa

final class PenView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with e: NSEvent) { report("down", e) }
    override func mouseDragged(with e: NSEvent) { report("drag", e) }
    override func mouseUp(with e: NSEvent) { report("up", e) }
    override func mouseMoved(with e: NSEvent) { report("move", e) }
    override func tabletPoint(with e: NSEvent) { report("tabletPoint", e) }
    override func tabletProximity(with e: NSEvent) { report("proximity", e) }

    private func report(_ tag: String, _ e: NSEvent) {
        guard e.type == .tabletPoint || e.type == .tabletProximity
                || e.subtype == .tabletPoint || e.subtype == .tabletProximity else {
            print("\(tag): subtype=\(e.subtype.rawValue) — タブレットではない")
            return
        }
        if e.subtype == .tabletProximity || e.type == .tabletProximity {
            print("\(tag): proximity entering=\(e.isEnteringProximity) pointingDeviceType=\(e.pointingDeviceType.rawValue)")
            return
        }
        let t = e.tilt
        // Read the underlying CGEvent in the same breath as the NSEvent, so
        // "where did the pressure go" is answered without crossing a process
        // boundary and inviting a second explanation.
        var raw19 = -1.0, raw5 = -1.0, sub = -1
        if let cg = e.cgEvent {
            raw19 = cg.getDoubleValueField(CGEventField(rawValue: 19)!)
            raw5 = cg.getDoubleValueField(CGEventField(rawValue: 5)!)
            sub = Int(cg.getIntegerValueField(CGEventField(rawValue: 7)!))
        }
        print(String(format:
            "%@: NSEvent.pressure=%.4f  cg[19]=%.4f cg[5]=%.4f sub=%d  tilt=(%.4f, %.4f) deviceID=%d",
            tag, e.pressure, raw19, raw5, sub, t.x, t.y, e.deviceID))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
        dirtyRect.fill()
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let rect = NSRect(x: 0, y: 0, width: 720, height: 480)
let window = NSWindow(contentRect: rect,
                      styleMask: [.titled, .closable],
                      backing: .buffered, defer: false)
window.title = "nazori pentest"
window.contentView = PenView(frame: rect)
window.acceptsMouseMovedEvents = true
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

// Publish the aim point in CGEvent coordinates (top-left origin) so the
// sender can target the middle of this window without guessing.
if let screen = NSScreen.main {
    let f = window.frame
    let cx = f.midX
    let cy = screen.frame.height - f.midY
    print("AIM \(Int(cx)) \(Int(cy)) SCREEN \(Int(screen.frame.width)) \(Int(screen.frame.height))")
}
fflush(stdout)

app.run()

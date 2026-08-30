// One variable at a time: post the same stroke four ways and let penwindow say
// which one keeps the pressure. Nothing here is shared with TabletInjector, so
// a bug in the injector cannot make a variant look good.
import CoreGraphics
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)

let x = Double(CommandLine.arguments[1])!
let y = Double(CommandLine.arguments[2])!
let P = 0.375

func field(_ n: Int) -> CGEventField { CGEventField(rawValue: UInt32(n))! }

func decorate(_ e: CGEvent, pressure: Double) {
    e.setIntegerValueField(field(7), value: 1)          // subtype = tabletPoint
    e.setIntegerValueField(field(24), value: 0x0BAD)    // tabletEventDeviceID
    e.setIntegerValueField(field(15), value: 16384)
    e.setIntegerValueField(field(16), value: 12409)
    e.setDoubleValueField(field(19), value: pressure)   // tabletEventPointPressure
    e.setDoubleValueField(field(5), value: pressure)    // mouseEventPressure
    e.setDoubleValueField(field(20), value: 0.3333)
    e.setDoubleValueField(field(21), value: -0.5)
    e.setIntegerValueField(field(4), value: 1)          // clickState
}

func mouseStroke(tap: CGEventTapLocation, label: String) {
    print("--- \(label) ---")
    for (t, p) in [(CGEventType.leftMouseDown, P), (.leftMouseDragged, P), (.leftMouseUp, 0.0)] {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: t,
                              mouseCursorPosition: CGPoint(x: x, y: y),
                              mouseButton: .left) else { continue }
        decorate(e, pressure: p)
        e.post(tap: tap)
        usleep(60_000)
    }
    usleep(300_000)
}

/// The shape a real digitizer emits: a dedicated tabletPointer event rather
/// than a mouse event wearing a tablet subtype.
func nativeTabletStroke() {
    print("--- native tabletPointer @ hid ---")
    for p in [P, P, 0.0] {
        guard let e = CGEvent(source: nil) else { continue }
        e.type = .tabletPointer
        e.location = CGPoint(x: x, y: y)
        decorate(e, pressure: p)
        e.setIntegerValueField(field(18), value: p > 0 ? 1 : 0)  // tabletEventPointButtons
        e.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    usleep(300_000)
}

mouseStroke(tap: .cghidEventTap, label: "mouse+subtype @ cghidEventTap")
mouseStroke(tap: .cgSessionEventTap, label: "mouse+subtype @ cgSessionEventTap")
mouseStroke(tap: .cgAnnotatedSessionEventTap, label: "mouse+subtype @ cgAnnotatedSessionEventTap")
nativeTabletStroke()
print("expected pressure on down/drag = \(P)")

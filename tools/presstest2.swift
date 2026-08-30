// Why is kCGMouseEventPressure zero on arrival? Four candidate causes, one
// variable each. Everything else is held identical.
import CoreGraphics
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)

let x = Double(CommandLine.arguments[1])!
let y = Double(CommandLine.arguments[2])!
let P = 0.375
func fld(_ n: Int) -> CGEventField { CGEventField(rawValue: UInt32(n))! }

func stroke(_ label: String, source: CGEventSource?, decorate: (CGEvent, Double) -> Void) {
    print("--- \(label) ---")
    for (t, p) in [(CGEventType.leftMouseDown, P), (.leftMouseDragged, P), (.leftMouseUp, 0.0)] {
        guard let e = CGEvent(mouseEventSource: source, mouseType: t,
                              mouseCursorPosition: CGPoint(x: x, y: y),
                              mouseButton: .left) else { continue }
        decorate(e, p)
        e.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    usleep(400_000)
}

func common(_ e: CGEvent, _ p: Double) {
    e.setIntegerValueField(fld(7), value: 1)
    e.setIntegerValueField(fld(24), value: 0x0BAD)
    e.setDoubleValueField(fld(19), value: p)
    e.setDoubleValueField(fld(20), value: 0.3333)
    e.setDoubleValueField(fld(21), value: -0.5)
}

// A: mouse pressure written after every other field
stroke("A: field5 written last", source: nil) { e, p in
    common(e, p)
    e.setIntegerValueField(fld(4), value: 1)
    e.setDoubleValueField(fld(5), value: p)
}

// B: same, plus the tip-contact bit a real digitizer sets
stroke("B: field5 last + tabletPointButtons=1", source: nil) { e, p in
    common(e, p)
    e.setIntegerValueField(fld(18), value: p > 0 ? 1 : 0)
    e.setIntegerValueField(fld(4), value: 1)
    e.setDoubleValueField(fld(5), value: p)
}

// C: a private event source instead of the HID system state
stroke("C: privateState source", source: CGEventSource(stateID: .privateState)) { e, p in
    common(e, p)
    e.setIntegerValueField(fld(18), value: p > 0 ? 1 : 0)
    e.setDoubleValueField(fld(5), value: p)
}

// D: mouse pressure only -- maybe field 19 is what clobbers it
stroke("D: field5 only, no field19", source: nil) { e, p in
    e.setIntegerValueField(fld(7), value: 1)
    e.setIntegerValueField(fld(24), value: 0x0BAD)
    e.setDoubleValueField(fld(5), value: p)
}
print("expected 0.375 on down/drag")

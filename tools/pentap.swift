// Listen-only probe: reports what the window server actually delivers for
// tablet-tagged mouse events. Built separately from nazorid on purpose --
// the thing measuring the injector must not share code with it.
import ApplicationServices
import CoreGraphics
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)

func f(_ e: CGEvent, _ n: Int) -> Double { e.getDoubleValueField(CGEventField(rawValue: UInt32(n))!) }
func i(_ e: CGEvent, _ n: Int) -> Int64 { e.getIntegerValueField(CGEventField(rawValue: UInt32(n))!) }

let mask: CGEventMask =
    (1 << CGEventType.mouseMoved.rawValue) |
    (1 << CGEventType.leftMouseDown.rawValue) |
    (1 << CGEventType.leftMouseDragged.rawValue) |
    (1 << CGEventType.leftMouseUp.rawValue) |
    (1 << CGEventType.tabletPointer.rawValue) |
    (1 << CGEventType.tabletProximity.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .tailAppendEventTap,
    options: .listenOnly, eventsOfInterest: mask,
    callback: { _, type, event, _ in
        let subtype = i(event, 7)
        if subtype == 2 {
            print("PROXIMITY enter=\(i(event, 38)) pointerType=\(i(event, 37)) device=\(i(event, 31))")
        } else if subtype == 1 {
            let loc = event.location
            print(String(format:
                "POINT type=%d subtype=1 loc=(%.0f,%.0f) pressure=%.4f tiltX=%.4f tiltY=%.4f device=%d tabletXY=(%d,%d)",
                type.rawValue, loc.x, loc.y, f(event, 19), f(event, 20), f(event, 21),
                i(event, 24), i(event, 15), i(event, 16)))
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil)
else {
    FileHandle.standardError.write(Data("tap を作れません (アクセシビリティ未許可)\n".utf8))
    exit(1)
}

let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
FileHandle.standardError.write(Data("pentap: 監視中\n".utf8))
CFRunLoopRun()

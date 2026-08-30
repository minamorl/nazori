import ApplicationServices
import CoreGraphics
import Foundation
print("AXIsProcessTrusted = \(AXIsProcessTrusted())")
let before = CGEvent(source: nil)!.location
print("cursor before = \(before)")
let target = CGPoint(x: before.x + 37, y: before.y + 23)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
        mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(200_000)
let after = CGEvent(source: nil)!.location
print("cursor after  = \(after)")
print("moved = \(abs(after.x - target.x) < 2 && abs(after.y - target.y) < 2)")
// put it back
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
        mouseCursorPosition: before, mouseButton: .left)?.post(tap: .cghidEventTap)

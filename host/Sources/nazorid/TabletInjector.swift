import ApplicationServices
import CoreGraphics
import Foundation

/// Turns decoded pen records into macOS tablet events.
///
/// macOS carries stylus data on ordinary mouse events that are tagged with the
/// `TabletPoint` subtype; the pressure and tilt live in separate event fields
/// that `NSEvent` exposes as `pressure`, `tilt`, and `rotation`. Field numbers
/// are written out rather than taken from the Swift overlay's names, because
/// the numbers are the part that is actually pinned by the ABI.
final class TabletInjector {

    private enum Field {
        static let mouseEventPressure = CGEventField(rawValue: 5)!
        static let mouseEventClickState = CGEventField(rawValue: 4)!
        static let mouseEventSubtype = CGEventField(rawValue: 7)!

        static let tabletPointX = CGEventField(rawValue: 15)!
        static let tabletPointY = CGEventField(rawValue: 16)!
        static let tabletPointButtons = CGEventField(rawValue: 18)!
        static let tabletPointPressure = CGEventField(rawValue: 19)!
        static let tabletTiltX = CGEventField(rawValue: 20)!
        static let tabletTiltY = CGEventField(rawValue: 21)!
        static let tabletRotation = CGEventField(rawValue: 22)!
        static let tabletDeviceID = CGEventField(rawValue: 24)!

        static let proximityVendorID = CGEventField(rawValue: 28)!
        static let proximityTabletID = CGEventField(rawValue: 29)!
        static let proximityPointerID = CGEventField(rawValue: 30)!
        static let proximityDeviceID = CGEventField(rawValue: 31)!
        static let proximitySystemTabletID = CGEventField(rawValue: 32)!
        static let proximityVendorPointerType = CGEventField(rawValue: 33)!
        static let proximityVendorSerial = CGEventField(rawValue: 34)!
        static let proximityVendorUniqueID = CGEventField(rawValue: 35)!
        static let proximityCapabilityMask = CGEventField(rawValue: 36)!
        static let proximityPointerType = CGEventField(rawValue: 37)!
        static let proximityEnterProximity = CGEventField(rawValue: 38)!
    }

    private enum Subtype: Int64 {
        case tabletPoint = 1
        case tabletProximity = 2
    }

    /// Tablet-space resolution reported to the OS. Arbitrary but must be stable.
    private static let tabletExtent: Int64 = 32767

    /// Anything the OS uses to tell one tablet from another. Constant per run.
    private let deviceID: Int64 = 0x0BAD
    private let pointerID: Int64 = 1
    private let eraserPointerType: Int64 = 2
    private let penPointerType: Int64 = 1

    private var displayID: CGDirectDisplayID
    private var bounds: CGRect
    private var inContact = false
    private var contactButton: CGMouseButton = .left
    private var inProximity = false
    private var lastPoint = CGPoint(x: 0, y: 0)

    init(displayID: CGDirectDisplayID = CGMainDisplayID()) {
        self.displayID = displayID
        self.bounds = CGDisplayBounds(displayID)
    }

    var displayBounds: CGRect { bounds }

    func refreshDisplay() {
        bounds = CGDisplayBounds(displayID)
    }

    /// Posting synthetic events requires the Accessibility grant; without it
    /// `CGEvent.post` silently does nothing, which is the single most confusing
    /// failure mode here, so it is checked up front rather than discovered.
    static func hasAccessibilityTrust() -> Bool {
        AXIsProcessTrusted()
    }

    func handle(_ rec: PenRecord) {
        let point = CGPoint(
            x: bounds.origin.x + CGFloat(rec.x) * bounds.width,
            y: bounds.origin.y + CGFloat(rec.y) * bounds.height
        )
        lastPoint = point

        switch rec.kind {
        case .proximityIn:
            postProximity(entering: true, eraser: rec.eraser)
        case .proximityOut:
            if inContact { endContact(rec, at: point) }
            postProximity(entering: false, eraser: rec.eraser)
        case .hover:
            if !inProximity { postProximity(entering: true, eraser: rec.eraser) }
            postPointer(.mouseMoved, button: .left, rec: rec, at: point, pressure: 0)
        case .down:
            if !inProximity { postProximity(entering: true, eraser: rec.eraser) }
            // A held barrel button turns the whole stroke into a right-button
            // drag, which is what a Wacom's lower switch does by default.
            contactButton = rec.barrelButton ? .right : .left
            inContact = true
            postPointer(contactButton == .right ? .rightMouseDown : .leftMouseDown,
                        button: contactButton, rec: rec, at: point, pressure: rec.pressure)
        case .move:
            if inContact {
                postPointer(contactButton == .right ? .rightMouseDragged : .leftMouseDragged,
                            button: contactButton, rec: rec, at: point, pressure: rec.pressure)
            } else {
                postPointer(.mouseMoved, button: .left, rec: rec, at: point, pressure: 0)
            }
        case .up:
            endContact(rec, at: point)
        case .cancel:
            // There is no "undo this stroke" in the event stream, so the best
            // available repair is to lift the tip where it currently is.
            endContact(rec, at: point)
        }
    }

    /// Called when the link drops mid-stroke so the host is not left with a
    /// button stuck down.
    func releaseStuckContact() {
        guard inContact else { return }
        let up: CGEventType = contactButton == .right ? .rightMouseUp : .leftMouseUp
        if let e = CGEvent(mouseEventSource: nil, mouseType: up,
                           mouseCursorPosition: lastPoint, mouseButton: contactButton) {
            e.setIntegerValueField(Field.mouseEventClickState, value: 1)
            e.post(tap: .cghidEventTap)
        }
        inContact = false
    }

    private func endContact(_ rec: PenRecord, at point: CGPoint) {
        guard inContact else { return }
        inContact = false
        postPointer(contactButton == .right ? .rightMouseUp : .leftMouseUp,
                    button: contactButton, rec: rec, at: point, pressure: 0)
    }

    private func postPointer(
        _ type: CGEventType, button: CGMouseButton,
        rec: PenRecord, at point: CGPoint, pressure: Float
    ) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: point, mouseButton: button) else { return }

        // Order matters: the subtype has to be set before the tablet fields,
        // otherwise the fields have nowhere to land.
        e.setIntegerValueField(Field.mouseEventSubtype, value: Subtype.tabletPoint.rawValue)
        e.setIntegerValueField(Field.tabletDeviceID, value: deviceID)
        e.setIntegerValueField(Field.mouseEventClickState, value: 1)

        let tx = Int64((rec.x * Float(Self.tabletExtent)).rounded())
        let ty = Int64((rec.y * Float(Self.tabletExtent)).rounded())
        e.setIntegerValueField(Field.tabletPointX, value: tx)
        e.setIntegerValueField(Field.tabletPointY, value: ty)
        e.setIntegerValueField(Field.tabletPointButtons, value: rec.barrelButton ? 0b10 : 0)

        let p = Double(max(0, min(1, pressure)))
        e.setDoubleValueField(Field.tabletPointPressure, value: p)
        e.setDoubleValueField(Field.mouseEventPressure, value: p)

        // NSEvent.tilt is normalized to -1...1, not degrees.
        e.setDoubleValueField(Field.tabletTiltX, value: Double(rec.tiltXDegrees / 90))
        e.setDoubleValueField(Field.tabletTiltY, value: Double(rec.tiltYDegrees / 90))
        e.setDoubleValueField(Field.tabletRotation, value: Double(rec.twistDegrees))

        e.post(tap: .cghidEventTap)
    }

    private func postProximity(entering: Bool, eraser: Bool) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: lastPoint, mouseButton: .left) else { return }
        e.setIntegerValueField(Field.mouseEventSubtype, value: Subtype.tabletProximity.rawValue)
        e.setIntegerValueField(Field.proximityVendorID, value: 0x056A) // Wacom, so apps recognise us
        e.setIntegerValueField(Field.proximityTabletID, value: 1)
        e.setIntegerValueField(Field.proximityPointerID, value: pointerID)
        e.setIntegerValueField(Field.proximityDeviceID, value: deviceID)
        e.setIntegerValueField(Field.proximitySystemTabletID, value: 0)
        e.setIntegerValueField(Field.proximityVendorPointerType, value: 0x0802)
        e.setIntegerValueField(Field.proximityVendorSerial, value: 1)
        e.setIntegerValueField(Field.proximityVendorUniqueID, value: 1)
        // Bit mask of what this pointer reports: pressure, tilt, rotation.
        e.setIntegerValueField(Field.proximityCapabilityMask, value: 0x0F)
        e.setIntegerValueField(Field.proximityPointerType,
                               value: eraser ? eraserPointerType : penPointerType)
        e.setIntegerValueField(Field.proximityEnterProximity, value: entering ? 1 : 0)
        e.post(tap: .cghidEventTap)
        inProximity = entering
    }
}

import Foundation

/// The device-side record, decoded. See PROTOCOL.md.
struct PenRecord {
    enum Kind: UInt8 {
        case proximityOut = 0
        case proximityIn = 1
        case hover = 2
        case down = 3
        case move = 4
        case up = 5
        case cancel = 6
    }

    static let magic: UInt8 = 0xA7
    static let version: UInt8 = 1
    static let byteCount = 40
    static let helloByteCount = 16
    static let helloKind: UInt8 = 0x80

    var kind: Kind
    var flags: UInt8
    var seq: UInt32
    var deviceNanos: UInt64
    var x: Float
    var y: Float
    var pressure: Float
    var tiltXDegrees: Float
    var tiltYDegrees: Float
    var twistDegrees: Float

    var barrelButton: Bool { flags & 0x02 != 0 }
    var eraser: Bool { flags & 0x04 != 0 }

    /// Returns nil for anything that is not a well-formed record, so a garbled
    /// stream costs one dropped sample rather than a wild pointer jump.
    static func decode(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> PenRecord? {
        guard offset + byteCount <= bytes.count else { return nil }
        func u8(_ o: Int) -> UInt8 { bytes.load(fromByteOffset: offset + o, as: UInt8.self) }
        func u32(_ o: Int) -> UInt32 {
            UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + o, as: UInt32.self))
        }
        func u64(_ o: Int) -> UInt64 {
            UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + o, as: UInt64.self))
        }
        func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }

        guard u8(0) == magic, u8(1) == version else { return nil }
        guard let kind = Kind(rawValue: u8(2)) else { return nil }
        let rec = PenRecord(
            kind: kind, flags: u8(3), seq: u32(4), deviceNanos: u64(8),
            x: f32(16), y: f32(20), pressure: f32(24),
            tiltXDegrees: f32(28), tiltYDegrees: f32(32), twistDegrees: f32(36)
        )
        // Reject NaN and out-of-range geometry rather than letting it reach the
        // event system, where it would warp the cursor somewhere unrecoverable.
        guard rec.x.isFinite, rec.y.isFinite, rec.pressure.isFinite else { return nil }
        guard rec.x >= 0, rec.x <= 1, rec.y >= 0, rec.y <= 1 else { return nil }
        return rec
    }

    /// Re-encodes the record for the paint side. Going back through the
    /// encoder rather than forwarding the original bytes means a record that
    /// survived resynchronisation is guaranteed well-formed downstream.
    func encode() -> Data {
        var d = Data(capacity: PenRecord.byteCount)
        d.append(PenRecord.magic)
        d.append(PenRecord.version)
        d.append(kind.rawValue)
        d.append(flags)
        func put<T: FixedWidthInteger>(_ v: T) {
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        put(seq)
        put(deviceNanos)
        for f in [x, y, pressure, tiltXDegrees, tiltYDegrees, twistDegrees] {
            put(f.bitPattern)
        }
        return d
    }

    /// The reply a fresh TCP client gets: how big the target display is.
    static func hello(width: Float, height: Float) -> Data {
        var d = Data(capacity: helloByteCount)
        d.append(magic)
        d.append(version)
        d.append(helloKind)
        d.append(0)
        withUnsafeBytes(of: width.bitPattern.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: height.bitPattern.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0).littleEndian) { d.append(contentsOf: $0) }
        return d
    }
}

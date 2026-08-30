# nazori wire protocol v1

Android (pen source) -> Mac host daemon (`nazorid`).

Fixed-size 40-byte records, little-endian. No length prefix: framing is the
record size itself. Over TCP the stream is a concatenation of records; over UDP
one datagram carries one or more whole records.

| off | size | type | field    | meaning                                        |
|-----|------|------|----------|------------------------------------------------|
| 0   | 1    | u8   | magic    | always `0xA7`                                  |
| 1   | 1    | u8   | version  | always `1`                                     |
| 2   | 1    | u8   | type     | see below                                      |
| 3   | 1    | u8   | flags    | bit0 predicted, bit1 barrel button, bit2 eraser |
| 4   | 4    | u32  | seq      | monotonically increasing, wraps                |
| 8   | 8    | u64  | t_ns     | device monotonic nanoseconds (`System.nanoTime`)|
| 16  | 4    | f32  | x        | normalized `0..1` across the active area       |
| 20  | 4    | f32  | y        | normalized `0..1`, top-left origin             |
| 24  | 4    | f32  | pressure | `0..1`                                         |
| 28  | 4    | f32  | tilt_x   | degrees, `-90..90`, positive toward +X         |
| 32  | 4    | f32  | tilt_y   | degrees, `-90..90`, positive toward +Y         |
| 36  | 4    | f32  | twist    | degrees, `0..360`, barrel rotation             |

## type

| value | name           | meaning                                  |
|-------|----------------|------------------------------------------|
| 0     | PROXIMITY_OUT  | pen left hover range                     |
| 1     | PROXIMITY_IN   | pen entered hover range                  |
| 2     | HOVER          | moving above the surface, not touching   |
| 3     | DOWN           | tip contact begins                       |
| 4     | MOVE           | tip contact continues                    |
| 5     | UP             | tip contact ends                         |
| 6     | CANCEL         | gesture cancelled, drop the stroke       |

`PROXIMITY_IN` / `PROXIMITY_OUT` carry a valid position when known, otherwise
the last known position.

## flags

`predicted` marks a sample synthesized by `MotionEventPredictor`. Predicted
samples are for **local trail rendering only** and are never transmitted; the
bit exists so a receiver can reject them if a future version does send them.

## tilt convention

Android reports `AXIS_TILT` as the polar angle from the surface normal
(`0..pi/2`) and `AXIS_ORIENTATION` as the azimuth. The sender converts to the
Cartesian pair used by W3C Pointer Events and by macOS `NSEvent`:

    lean_x =  sin(orientation)
    lean_y = -cos(orientation)
    tilt_x = degrees(atan(lean_x * tan(tilt)))
    tilt_y = degrees(atan(lean_y * tan(tilt)))

macOS `NSEvent.tilt` is normalized to `-1..1`, so `nazorid` divides by 90.

## transports

- **USB (default).** `adb reverse tcp:40118 tcp:40118`. The app dials
  `127.0.0.1:40118` on the device; the connection surfaces on the Mac's
  loopback. `TCP_NODELAY` is set on both ends.
- **Wi-Fi (fallback).** UDP to `<host>:40118`. Lossy by design; `seq` lets the
  receiver notice drops. A dropped `UP` is repaired by the receiver's
  proximity timeout.

## host -> paint

`nazorid` re-broadcasts each accepted record verbatim as a single binary
WebSocket message on `ws://127.0.0.1:40119`. Same 40 bytes, same layout.

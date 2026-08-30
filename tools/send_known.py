#!/usr/bin/env python3
"""Feeds nazorid a stroke with values chosen to be unmistakable on the far side."""
import socket, struct, sys, time

MAGIC, VERSION = 0xA7, 1
PROX_IN, PROX_OUT, HOVER, DOWN, MOVE, UP = 1, 0, 2, 3, 4, 5

def rec(seq, kind, x, y, p, tx, ty, tw=0.0, flags=0):
    return struct.pack("<BBBBIQffffff", MAGIC, VERSION, kind, flags, seq,
                       int(time.monotonic_ns()), x, y, p, tx, ty, tw)

cx, cy, sw, sh = (float(v) for v in sys.argv[1:5])
nx, ny = cx / sw, cy / sh

s = socket.create_connection(("127.0.0.1", 40118))
s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
hello = s.recv(16)
print("HELLO:", struct.unpack("<BBBBff I"[:0] or "<BBBBffI", hello))

TILT_X, TILT_Y = 30.0, -45.0        # expect NSEvent tilt (0.3333, -0.5)
PRESSURES = [0.125, 0.375, 0.625, 0.875]

n = 0
def send(kind, p, dx=0.0):
    global n
    s.sendall(rec(n, kind, nx + dx, ny, p, TILT_X, TILT_Y)); n += 1
    time.sleep(0.03)

send(PROX_IN, 0.0)
send(HOVER, 0.0)
send(DOWN, PRESSURES[0])
for k, p in enumerate(PRESSURES[1:], start=1):
    send(MOVE, p, dx=0.01 * k)
send(UP, 0.0, dx=0.03)
send(PROX_OUT, 0.0, dx=0.03)
time.sleep(0.3)
s.close()
print(f"sent {n} records at ({cx},{cy}) -> normalized ({nx:.4f},{ny:.4f})")
print(f"expected: pressure {PRESSURES}, tilt ({TILT_X/90:.4f}, {TILT_Y/90:.4f})")

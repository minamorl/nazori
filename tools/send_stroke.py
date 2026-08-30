#!/usr/bin/env python3
"""A long, slow stroke across the middle of the active area."""
import socket, struct, sys, math, time

MAGIC, VERSION = 0xA7, 1
PROX_IN, PROX_OUT, DOWN, MOVE, UP = 1, 0, 3, 4, 5

def rec(seq, kind, x, y, p, tx=20.0, ty=-10.0):
    return struct.pack("<BBBBIQffffff", MAGIC, VERSION, kind, 0, seq,
                       int(time.monotonic_ns()), x, y, p, tx, ty, 0.0)

s = socket.create_connection(("127.0.0.1", 40118))
s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
s.recv(16)

N = 60
n = 0
def send(kind, x, y, p):
    global n
    s.sendall(rec(n, kind, x, y, p)); n += 1
    time.sleep(0.008)

send(PROX_IN, 0.2, 0.5, 0.0)
send(DOWN, 0.2, 0.5, 0.2)
for k in range(1, N + 1):
    t = k / N
    x = 0.2 + 0.6 * t
    y = 0.5 + 0.18 * math.sin(t * math.pi * 2)
    p = 0.15 + 0.8 * math.sin(t * math.pi)     # swells then thins
    send(MOVE, x, y, p)
send(UP, 0.8, 0.5, 0.0)
send(PROX_OUT, 0.8, 0.5, 0.0)
time.sleep(0.4)
s.close()
print(f"sent {n} records: 0.2 -> 0.8 across, pressure 0.15..0.95")

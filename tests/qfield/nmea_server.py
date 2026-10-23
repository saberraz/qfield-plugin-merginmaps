#!/usr/bin/env python3
"""Simulated GNSS receiver for QField's TCP positioning device: one RMC + GGA pair per second along a straight walk.
Timestamps follow the real clock, so a reconnecting client continues in time (like a real receiver).
Usage: python -I nmea_server.py <port>"""
import datetime, socket, sys, threading, time

def cs(s):
    c = 0
    for ch in s: c ^= ord(ch)
    return f"{c:02X}"

def dm(v, lat):
    a = abs(v); d = int(a); m = (a - d) * 60
    return (f"{d:02d}{m:07.4f}", "N") if lat else (f"{d:03d}{m:07.4f}", "E")

T0 = time.time()

def fix(now):
    i = now - T0
    la, ns = dm(46.8060 + i * 0.00002, True); lo, ew = dm(9.2580 + i * 0.00003, False)
    t = datetime.datetime.fromtimestamp(now, datetime.timezone.utc)
    hms, dmy = t.strftime("%H%M%S.%f")[:9], t.strftime("%d%m%y")
    rmc = f"GPRMC,{hms},A,{la},{ns},{lo},{ew},2.7,45.0,{dmy},,,A"
    gga = f"GPGGA,{hms},{la},{ns},{lo},{ew},1,12,0.8,{1020 + i * 0.1:.1f},M,47.0,M,,"
    return f"${rmc}*{cs(rmc)}\r\n${gga}*{cs(gga)}\r\n".encode()

def serve(conn):
    try:
        while True:
            now = time.time()
            conn.sendall(fix(int(now)))
            time.sleep(1 - (now % 1))
    except OSError:
        conn.close()

s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen()
while True:
    c, _ = s.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()

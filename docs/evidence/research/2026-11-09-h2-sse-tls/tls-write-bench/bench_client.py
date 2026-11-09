# /// script
# requires-python = ">=3.12"
# ///
"""N payloads over one TLS 1.3 connection to bench_server. Prints JSON per rep."""
import json
import socket
import ssl
import sys
import time

port, n, reps = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
for _ in range(reps):
    raw = socket.create_connection(("127.0.0.1", port), timeout=120)
    raw.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    sock = ctx.wrap_socket(raw, server_hostname="127.0.0.1")
    c0 = time.process_time()
    t0 = time.monotonic()
    sock.sendall(f"{n}\n".encode())
    got = 0
    buf = bytearray(1 << 20)
    while (k := sock.recv_into(buf)) > 0:
        got += k
    dt = time.monotonic() - t0
    print(json.dumps({"bytes": got, "seconds": round(dt, 4), "mb_s": round(got / dt / 1e6, 1),
                      "client_cpu_s": round(time.process_time() - c0, 4), "cipher": sock.cipher()[0]}))
    sock.close()

"""One client run: N pipelined HTTP/1.1 GETs on one connection, plain or TLS 1.3.

The TLS 1.3 suite comes from OPENSSL_CONF (Python's ssl cannot pick TLS 1.3
suites itself). Prints JSON: bytes, seconds, negotiated cipher.
"""
import json
import socket
import ssl
import sys
import time

port, path, n, tls = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4] == "tls"
one = f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n"
last = f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n"
raw = socket.create_connection(("127.0.0.1", port), timeout=120)
raw.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
sock, cipher = raw, None
if tls:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.set_alpn_protocols(["http/1.1"])
    sock = ctx.wrap_socket(raw, server_hostname="127.0.0.1")
    cipher = sock.cipher()[0]
started = time.monotonic()
sock.sendall((one * (n - 1) + last).encode())
got = 0
buf = bytearray(1 << 20)
while (k := sock.recv_into(buf)) > 0:
    got += k
print(json.dumps({"bytes": got, "seconds": time.monotonic() - started, "cipher": cipher}))

"""Guest side: one unix listener; each connection reads to EOF, then replies.
A request starting with B gets a 70,000-byte reply, any other gets the byte count."""
import os, socket, threading
PATH = "/tmp/probe.sock"
BIG = 70000
try:
    os.unlink(PATH)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX)
server.bind(PATH)
server.listen(64)
def handle(conn):
    data = b""
    while True:
        chunk = conn.recv(65536)
        if not chunk:
            break
        data += chunk
    with open("/tmp/eof.count", "a") as mark:
        mark.write("x")
    try:
        conn.sendall(b"x" * BIG if data[:1] == b"B" else str(len(data)).encode())
    except OSError:
        pass
    conn.close()
while True:
    conn, _ = server.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()

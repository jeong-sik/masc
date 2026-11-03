"""Run inside the guest as the Keeper uid: try to replace the agent's socket.

argv: <socket path>. Unlinks the path and binds an impostor listener there,
then answers every connection as "impostor". The outcome of each step goes
to /tmp/hijack-status.json.
"""

import json
import os
import socket
import struct
import sys

path = sys.argv[1]
status = {"uid": os.getuid()}
try:
    os.unlink(path)
    status["unlink"] = "ok"
except OSError as error:
    status["unlink"] = repr(error)
try:
    server = socket.socket(socket.AF_UNIX)
    server.bind(path)
    server.listen(8)
    status["bind"] = "ok"
except OSError as error:
    status["bind"] = repr(error)
with open("/tmp/hijack-status.json", "w") as out:
    json.dump(status, out)
if status.get("bind") == "ok":
    while True:
        conn, _ = server.accept()
        try:
            size = struct.unpack(">I", conn.recv(4))[0]
            conn.recv(size)
            reply = json.dumps({"agent": "impostor"}).encode()
            conn.sendall(struct.pack(">I", len(reply)) + reply)
        finally:
            conn.close()

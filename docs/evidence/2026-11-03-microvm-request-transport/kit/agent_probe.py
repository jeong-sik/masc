"""Guest side stand-in for a resident request agent.

argv: <socket path> <mode>
  mode same-uid  : started as the Keeper uid; binds wherever it is told.
  mode root-drop : started as root; makes the socket directory root-only,
                   binds, then drops to 502:20 and sets no_new_privs.
Each connection carries one length-prefixed request (4-byte big-endian
length, then the body) and gets one length-prefixed JSON reply. The client
keeps its write side open until the reply arrives. A body "sleep:<s>" makes
the reply wait <s> seconds. Status goes to /tmp/agent-status.json.
"""

import ctypes
import json
import os
import socket
import struct
import sys
import threading
import time

PR_SET_NO_NEW_PRIVS = 38
PR_GET_DUMPABLE = 3
PR_GET_NO_NEW_PRIVS = 39
KEEPER_UID = 502
KEEPER_GID = 20


def recv_exact(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise EOFError("peer closed")
        data += chunk
    return data


def main():
    path, mode = sys.argv[1], sys.argv[2]
    libc = ctypes.CDLL(None, use_errno=True)
    status = {"mode": mode, "start_uid": os.getuid()}
    directory = os.path.dirname(path)
    try:
        if mode in ("root-drop", "root-drop-ro"):
            os.makedirs(directory, exist_ok=True)
            os.chown(directory, 0, 0)
            os.chmod(directory, 0o700)
        else:
            os.makedirs(directory, exist_ok=True)
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        server = socket.socket(socket.AF_UNIX)
        server.bind(path)
        server.listen(64)
        if mode == "root-drop-ro":
            # Remount the container root read-only after the socket exists.
            MS_RDONLY, MS_REMOUNT, MS_BIND = 1, 32, 4096
            attempts = {}
            for label, flags in (("remount", MS_REMOUNT | MS_RDONLY), ("remount_bind", MS_REMOUNT | MS_BIND | MS_RDONLY)):
                rc = libc.mount(None, b"/", None, flags, None)
                attempts[label] = 0 if rc == 0 else os.strerror(ctypes.get_errno())
                if rc == 0:
                    break
            status["remount_ro"] = attempts
            mode = "root-drop"
        if mode == "root-drop":
            os.setgroups([])
            os.setgid(KEEPER_GID)
            os.setuid(KEEPER_UID)
            status["no_new_privs_set"] = libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)
        status.update(
            uid=os.getuid(), gid=os.getgid(),
            dumpable=libc.prctl(PR_GET_DUMPABLE, 0, 0, 0, 0),
            no_new_privs=libc.prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0),
            dir_mode=oct(os.stat(directory).st_mode & 0o7777) if mode == "root-drop" else None,
        )
        probe_path = "/var/tmp/agent-write-probe"
        try:
            with open(probe_path, "w") as probe:
                probe.write("x")
            status["rootfs_write_as_keeper"] = "ok"
        except OSError as error:
            status["rootfs_write_as_keeper"] = os.strerror(error.errno)
        status.update(
        )
    except Exception as error:  # report the failing step and stop
        status["error"] = repr(error)
        with open("/tmp/agent-status.json", "w") as out:
            json.dump(status, out)
        raise
    with open("/tmp/agent-status.json", "w") as out:
        json.dump(status, out)

    def note(event):
        with open("/tmp/agent-conn.log", "a") as log:
            log.write(f"{time.time():.3f} {event}\n")

    def handle(conn):
        note("accept")
        try:
            size = struct.unpack(">I", recv_exact(conn, 4))[0]
            note(f"header {size}")
            body = recv_exact(conn, size)
            if body.startswith(b"sleep:"):
                time.sleep(float(body[len(b"sleep:"):].decode()))
            reply = json.dumps({"agent": "genuine", "uid": os.getuid(), "size": size}).encode()
            conn.sendall(struct.pack(">I", len(reply)) + reply)
            note("replied")
        except (EOFError, OSError) as error:
            note(f"error {error!r}")
        finally:
            conn.close()

    while True:
        conn, _ = server.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()

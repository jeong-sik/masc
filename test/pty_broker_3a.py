#!/usr/bin/env python3
"""PTY broker for the task-3060 spectator-TUI harness.

Replaces script(1): runs the candidate TUI on a real pseudo-terminal, captures
all output bytes to a raw file, injects keys from its own stdin (a pipe the
harness writes), and — the reason it exists — answers the TUI's terminal
capability probe the way a real terminal would. Without these replies the TUI
refuses to draw images (Unsupported_protocol, no cell_pixels) and keeps the
"waiting for live screen" placeholder, which is why runs 17/18 showed no DOS
picture.

Probe (masc_tui_terminal_probe.ml) sends, in order:
  1. ESC [ 16 t                      cell size        -> ESC [ 6 ; h ; w t
  2. OSC 10 ; ?  /  OSC 11 ; ?       fg/bg colours    -> OSC 10 ; rgb:.. ST
  3. OSC 4 ; N ; ?  (x16 slots)      palette slots    -> OSC 4 ; N ; rgb:.. ST
  4. ESC _ G i=31,a=q,f=100;<png>    kitty graphics   -> ESC _ G i=31;OK ESC \

Usage: pty-broker.py <tui-executable> <raw-out> <workdir>   (keys on stdin)
"""
import fcntl, os, pty, re, select, signal, struct, sys, termios, time

tui_exe, raw_path, workdir = sys.argv[1:4]
env = dict(os.environ)
env["TERM"] = "xterm-256color"

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 60, 200, 0, 0))

pid = os.fork()
if pid == 0:
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    os.close(master)
    os.close(slave)
    os.chdir(workdir)
    os.execve(tui_exe, [tui_exe], env)
    os._exit(127)
os.close(slave)

fcntl.fcntl(0, fcntl.F_SETFL, os.O_NONBLOCK)  # keys come on stdin
raw = open(raw_path, "wb")

GRAPHICS_RE = re.compile(rb"\x1b_Gi=31,a=q")
CELL_RE = re.compile(rb"\x1b\[16t")
OSC10_RE = re.compile(rb"\x1b\]10;\?(\x1b\\|\x07)")
OSC11_RE = re.compile(rb"\x1b\]11;\?(\x1b\\|\x07)")
OSC4_RE = re.compile(rb"\x1b\]4;(\d+);\?(\x1b\\|\x07)")

tail = b""
keys_open = True
deadline = time.time() + 240

def reply(payload):
    os.write(master, payload)

while time.time() < deadline:
    watched = [master] + ([0] if keys_open else [])
    r, _, _ = select.select(watched, [], [], 0.001)
    if master in r:
        try:
            data = os.read(master, 65536)
        except OSError:
            data = b""
        if not data:
            break
        raw.write(data)
        raw.flush()
        tail = (tail + data)[-16384:]
        if GRAPHICS_RE.search(tail):
            reply(b"\x1b_Gi=31;OK\x1b\\")
        if CELL_RE.search(tail):
            # parse_cell_size wants CSI 6 ; height ; width t
            reply(b"\x1b[6;20;10t")
        if OSC10_RE.search(tail):
            reply(b"\x1b]10;rgb:c0c0/c0c0/c0c0\x1b\\")
        if OSC11_RE.search(tail):
            reply(b"\x1b]11;rgb:1010/1010/1010\x1b\\")
        for m in OSC4_RE.finditer(tail):
            slot = m.group(1)
            reply(b"\x1b]4;" + slot + b";rgb:8080/8080/8080\x1b\\")
        if (GRAPHICS_RE.search(tail) or CELL_RE.search(tail)
                or OSC10_RE.search(tail) or OSC11_RE.search(tail)
                or OSC4_RE.search(tail)):
            tail = b""
    if keys_open and 0 in r:
        try:
            chunk = os.read(0, 4096)
        except OSError:
            chunk = b""
        if chunk:
            os.write(master, chunk)
        else:
            keys_open = False
    try:
        done, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        break
    if done:
        while True:  # drain remaining output so the raw file is complete
            r2, _, _ = select.select([master], [], [], 0.2)
            if master not in r2:
                break
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            raw.write(data)
        raw.flush()
        sys.exit(os.waitstatus_to_exitcode(status))
raw.flush()
try:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
except (ProcessLookupError, ChildProcessError):
    pass
sys.exit(124)

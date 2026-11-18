# pyright: strict
"""Run a TUI in a pseudo-terminal, read what it draws and type keys into it.

The child gets its window size before it starts, SIGPIPE and SIGXFSZ back at
their defaults (Python ignores both and an exec keeps that), no blocked
signals (a caller may fork with its stop signals held, and an exec keeps the
mask), and exactly the environment the caller passes. Everything the TUI writes goes through a `Vte`,
and the answers the `Vte` gives to the TUI's terminal queries are written back.

A key is a `Press`, bytes typed as they are, or a `Jump`, a command palette
entry: `:` opens the palette, the entry is typed once its title is on screen,
and Enter runs it. The palette title is `Command palette` in both languages
(bin/masc_tui_render_overlays.ml).

`first_frame` waits for the TUI's first frame: every frame its presenter
writes opens with FRAME_START (bin/masc_tui_frame_presenter.ml). Waiting for
quiet alone is not enough, because a TUI starting from a cold disk cache can
stay silent for seconds before it draws.
"""
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import termios
import time

from vte import Vte

READ_BYTES = 65536
POLL_S = 0.02
EXEC_FAILED = 127
RESTORED_SIGNALS = (signal.SIGPIPE, signal.SIGXFSZ)
FRAME_START = b'\x1b[?7l'
PALETTE_KEY = b':'
PALETTE_TITLE = 'Command palette'
ENTER = b'\r'
KEY_GAP_S = 0.2
KEY_QUIET_S = 0.3
KEY_LIMIT_S = 1.0
PALETTE_OPEN_QUIET_S = 0.4
PALETTE_OPEN_LIMIT_S = 2.0
PALETTE_TYPED_QUIET_S = 0.3
PALETTE_TYPED_LIMIT_S = 1.5
JUMP_QUIET_S = 1.0
JUMP_LIMIT_S = 6.0


@dataclass(frozen=True, slots=True)
class Geometry:
    columns: int
    rows: int
    cell_width: int
    cell_height: int

    def winsize(self) -> bytes:
        return struct.pack('HHHH', self.rows, self.columns,
                           self.columns * self.cell_width, self.rows * self.cell_height)


@dataclass(frozen=True, slots=True)
class Child:
    pid: int
    fd: int
    started: float  # time.monotonic() just after the fork


@dataclass(frozen=True, slots=True)
class Press:
    key: bytes


@dataclass(frozen=True, slots=True)
class Jump:
    entry: str


type Key = Press | Jump


@dataclass(frozen=True, slots=True)
class Sent:
    key: str
    ok: bool
    note: str

    def report(self) -> dict[str, object]:
        return {'key': self.key, 'ok': self.ok, 'note': self.note}


@dataclass(frozen=True, slots=True)
class Exit:
    code: int  # os.waitstatus_to_exitcode: negative for a signal
    killed: bool  # SIGKILL after the grace period

    def report(self) -> dict[str, object]:
        return {'code': self.code, 'killed': self.killed}


def spawn(argv: Sequence[str], env: Mapping[str, str], geometry: Geometry) -> Child:
    pid, fd = pty.fork()
    if pid == 0:
        try:
            fcntl.ioctl(1, termios.TIOCSWINSZ, geometry.winsize())
            for restored in RESTORED_SIGNALS:
                signal.signal(restored, signal.SIG_DFL)
            signal.pthread_sigmask(signal.SIG_SETMASK, ())
            os.execve(argv[0], list(argv), dict(env))
        finally:
            os._exit(EXEC_FAILED)
    started = time.monotonic()
    fcntl.ioctl(fd, termios.TIOCSWINSZ, geometry.winsize())
    return Child(pid, fd, started)


def read_chunk(child: Child, timeout: float) -> bytes | None:
    """What the TUI wrote within `timeout` (b'' when nothing), or None once its terminal closed."""
    ready, _, _ = select.select([child.fd], [], [], timeout)
    if not ready:
        return b''
    try:
        chunk = os.read(child.fd, READ_BYTES)
    except OSError as exc:
        if exc.errno == errno.EIO:
            return None
        raise
    return chunk or None


def send(child: Child, data: bytes) -> bool:
    """Write `data` to the TUI's terminal. False once the terminal closed: the
    write then fails with EIO, as the read does in read_chunk."""
    try:
        os.write(child.fd, data)
    except OSError as exc:
        if exc.errno == errno.EIO:
            return False
        raise
    return True


def take(child: Child, vte: Vte, chunk: bytes) -> bool:
    """Feed `chunk` to the emulator and write back its answers to the TUI's
    queries. False once the terminal closed. The next read_chunk then returns
    None too, so a loop that reads on finds the close there."""
    replies = vte.feed(chunk)
    return send(child, replies) if replies else True


def first_frame(child: Child, vte: Vte, limit: float) -> bool:
    """Read until the TUI writes its first frame start. False when `limit`
    passed first or the terminal closed."""
    start = time.monotonic()
    tail = b''
    while time.monotonic() - start < limit:
        chunk = read_chunk(child, POLL_S)
        if chunk is None:
            return False
        if not chunk:
            continue
        take(child, vte, chunk)
        if FRAME_START in tail + chunk:
            return True
        tail = (tail + chunk)[-(len(FRAME_START) - 1):]
    return False


def settle(child: Child, vte: Vte, quiet: float, limit: float) -> bool:
    """Read until `quiet` seconds pass without output. False when `limit` passed
    first or the terminal closed."""
    start = last = time.monotonic()
    while True:
        now = time.monotonic()
        if now - last >= quiet:
            return True
        if now - start >= limit:
            return False
        chunk = read_chunk(child, POLL_S)
        if chunk is None:
            return False
        if chunk:
            take(child, vte, chunk)
            last = time.monotonic()


def press(child: Child, vte: Vte, key: Key) -> Sent:
    match key:
        case Press(raw):
            os.write(child.fd, raw)
            time.sleep(KEY_GAP_S)
            settle(child, vte, KEY_QUIET_S, KEY_LIMIT_S)
            return Sent(raw.decode('utf-8', 'backslashreplace'), True, 'sent')
        case Jump(entry):
            os.write(child.fd, PALETTE_KEY)
            settle(child, vte, PALETTE_OPEN_QUIET_S, PALETTE_OPEN_LIMIT_S)
            if PALETTE_TITLE not in vte.screen_text():
                return Sent(f':{entry}', False, 'palette-not-open')
            os.write(child.fd, entry.encode())
            settle(child, vte, PALETTE_TYPED_QUIET_S, PALETTE_TYPED_LIMIT_S)
            os.write(child.fd, ENTER)
            # The next key must reach the screen the jump opens, not the one it leaves.
            settle(child, vte, JUMP_QUIET_S, JUMP_LIMIT_S)
            return Sent(f':{entry}', True, 'sent')


def stop(child: Child, grace_s: float) -> Exit:
    """SIGTERM, then SIGKILL after `grace_s`. The terminal is read meanwhile: a
    TUI blocked writing to an unread terminal never reaches its exit path."""
    try:
        os.kill(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + grace_s
    status: int | None = None
    while time.monotonic() < deadline:
        reaped, code = os.waitpid(child.pid, os.WNOHANG)
        if reaped:
            status = code
            break
        if read_chunk(child, POLL_S) is None:
            time.sleep(POLL_S)
    killed = status is None
    if status is None:
        os.kill(child.pid, signal.SIGKILL)
        _, status = os.waitpid(child.pid, 0)
    # pty.fork made the TUI a session and process group leader. Anything it
    # started in that group and left running goes with it.
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    os.close(child.fd)
    return Exit(os.waitstatus_to_exitcode(status), killed)

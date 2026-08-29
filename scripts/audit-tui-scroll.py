#!/usr/bin/env python3
"""Ask every TUI surface whether j scrolls and whether k comes back.

Why this is not a two-line loop over the live TUI: nine keepers push events
while it draws, so a frame taken after a keypress differs from the one before
it whether or not anything scrolled. Four attempts at measuring against the
live server reported every surface healthy, including ones that were not.

So the tool records the real server's answers once, replays them from a fixed
server, and proves the screen has stopped moving before it presses anything.
The proof is the point: without it a "yes" means nothing.

  record   GET every endpoint the TUI reads, save the bodies
  serve    hand those bodies back, unchanging
  settle   watch the screen until two reads in a row match
  sweep    per surface: j x12, k x12, compare

A surface is only reported when two laps agree. The screen height is reported
beside the verdict because "j did nothing" is the correct answer for a list
that already fits -- on the live server three surfaces looked broken for
exactly that reason.

Usage:
  scripts/audit-tui-scroll.py record --port 8935 --out /tmp/tui-fixture.json
  scripts/audit-tui-scroll.py sweep  --fixture /tmp/tui-fixture.json
"""

from __future__ import annotations

import argparse
import collections
import fcntl
import json
import os
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from threading import Thread

ROWS, COLS = 45, 160
SETTLE_TRIES = 12
LAPS = 2
SURFACES = 19


# ---------------------------------------------------------------- record


def endpoint_paths(repo: Path) -> list[str]:
    """The GET paths the TUI reads, taken from its own HTTP module.

    Read from the source rather than listed here: a path added to the TUI
    and not to a list in this file would silently drop out of the sweep.
    """
    out = subprocess.run(
        ["rg", "-o", r'"/[a-z0-9/_-]+"', str(repo / "bin" / "masc_tui_http.ml")],
        capture_output=True,
        text=True,
        check=False,
    ).stdout
    paths = {p.strip('"') for p in out.split()}
    return sorted(p for p in paths if not p.endswith("/"))


def record(repo: Path, port: int, base_path: Path, out: Path) -> int:
    token_file = base_path / ".masc" / "auth" / "admin.token"
    if not token_file.exists():
        print(f"no operator token at {token_file}", file=sys.stderr)
        return 1
    token = token_file.read_text().strip()
    base = f"http://127.0.0.1:{port}"
    recorded: dict[str, dict] = {}
    for path in endpoint_paths(repo):
        req = urllib.request.Request(base + path, headers={"Authorization": f"Bearer {token}"})
        try:
            with urllib.request.urlopen(req, timeout=15) as response:
                recorded[path] = {"status": response.status,
                                  "body": response.read().decode("utf-8", "replace")}
        except urllib.error.HTTPError as err:
            recorded[path] = {"status": err.code,
                              "body": err.read().decode("utf-8", "replace")[:200_000]}
        except Exception as err:  # noqa: BLE001 - the reason is for the operator
            recorded[path] = {"status": 0, "body": "", "error": str(err)[:80]}
    out.write_text(json.dumps(recorded))
    ok = sum(1 for v in recorded.values() if v["status"] == 200)
    print(f"recorded {len(recorded)} paths, {ok} answered 200 -> {out}")
    # 405 is a POST-only route and 404 wants a path parameter; neither shows on
    # a surface the sweep visits, so they are not failures here.
    return 0 if ok else 1


# ---------------------------------------------------------------- serve


def serve(fixture: dict, port: int) -> HTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args, **_kw):  # quiet
            pass

        def _reply(self, path: str) -> None:
            hit = fixture.get(path)
            if hit is None:
                # /a/b/<id> style routes: answer with the longest recorded
                # prefix so a detail view still gets its list.
                prefixes = [p for p in fixture if path.startswith(p) and fixture[p]["status"] == 200]
                hit = fixture[max(prefixes, key=len)] if prefixes else None
            if hit is None or hit["status"] != 200:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"{}")
                return
            payload = hit["body"].encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):  # noqa: N802 - http.server's spelling
            self._reply(self.path.split("?")[0])

        def do_POST(self):  # noqa: N802
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')

    # Without this a second run inside the socket's TIME_WAIT window dies on
    # "address already in use", which reads as a broken harness rather than a
    # port still closing.
    HTTPServer.allow_reuse_address = True
    server = HTTPServer(("127.0.0.1", port), Handler)
    Thread(target=server.serve_forever, daemon=True).start()
    return server


# ---------------------------------------------------------------- screen

TIME = re.compile(r"\d{1,2}:\d{2}(:\d{2})?")
BADGE = re.compile(r"\[(connected|connecting\.\.\.|reconnecting\.\.\.|degraded|offline)\]")
FEED = re.compile(r"feed:? ?\S*")
COUNT = re.compile(r"\d+-\d+/\d+")
# Elapsed readings tick on their own: "7m25s" became "7m28s" between a
# keypress and the read after it, which the sweep first scored as scrolling.
ELAPSED = re.compile(r"\b\d+[dhms](\d+[hms])?\b")
# The spinner turns on a timer of its own, so its glyph differs between any
# two reads of a surface that has one running.
SPINNER = re.compile(r"[\u25d0-\u25d3\u25cf\u25cb\u25d4-\u25d7\u2596-\u259f]")


class Tui:
    """A TUI on a pty, read back through a terminal emulator.

    The TUI paints with cursor moves rather than newlines, so reading the pty
    as lines returns six of them. pyte replays the moves and hands back the
    grid the operator is looking at.
    """

    def __init__(self, exe: Path, port: int, base_path: Path):
        import pyte  # imported here so `record` runs without it

        self.screen = pyte.Screen(COLS, ROWS)
        self.stream = pyte.ByteStream(self.screen)
        pid, self.fd = pty.fork()
        if pid == 0:
            os.environ.update(TERM="xterm-256color", NO_COLOR="1")
            os.execv(str(exe), [exe.name, "--port", str(port), "--base-path", str(base_path)])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    def drain(self, seconds: float) -> None:
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.15)
            if ready:
                try:
                    self.stream.feed(os.read(self.fd, 262_144))
                except OSError:
                    return

    def press(self, keys: bytes, wait: float) -> None:
        os.write(self.fd, keys)
        self.drain(wait)

    def body(self) -> list[str]:
        """The screen with the parts that move on their own taken out.

        The clock, the connection badge and the feed marker change between any
        two reads. The event panel to the right of the divider is filled and
        emptied by the TUI itself, so a fixed server does not hold it still.

        Dropping that panel costs a surface: Overview's j scrolls the events
        when nothing else has focus, so this reads it as "j does nothing".
        Check the key handler before believing that verdict on a surface whose
        keys act on the right pane.
        """
        out = []
        for line in self.screen.display:
            if not line.strip():
                continue
            line = COUNT.sub("C", FEED.sub("feed", BADGE.sub("[B]", TIME.sub("T", line))))
            line = SPINNER.sub("*", ELAPSED.sub("E", line))
            if "│" in line:
                line = line.split("│")[0]
            out.append(" ".join(line.split()))
        return out

    def title(self) -> str:
        for line in self.screen.display:
            found = re.search(r"MASC ([A-Za-z][A-Za-z /]*)", line)
            if found:
                return found.group(1).strip()
        return "?"

    def close(self) -> None:
        try:
            os.write(self.fd, b"q")
            self.drain(1)
            os.close(self.fd)
        except OSError:
            pass


def settle(tui: Tui) -> bool:
    """Wait until two reads match. Returns False if the screen never stops.

    This is the control the whole sweep rests on: if the screen moves without
    a keypress then a difference after a keypress says nothing.
    """
    previous = tui.body()
    for _ in range(SETTLE_TRIES):
        tui.drain(2.0)
        current = tui.body()
        if current == previous and current:
            return True
        if os.environ.get("TUI_AUDIT_DEBUG"):
            # What is still moving, when the control refuses to hand over.
            diff = [(i, a, b) for i, (a, b) in enumerate(zip(previous, current)) if a != b]
            print(f"  settle: {len(diff)} rows still moving "
                  f"({len(previous)} vs {len(current)} rows)", file=sys.stderr)
            for i, a, b in diff[:2]:
                print(f"    row {i}: {a[:70]!r} -> {b[:70]!r}", file=sys.stderr)
        previous = current
    return False


# ---------------------------------------------------------------- sweep


def sweep(exe: Path, fixture_path: Path, port: int, base_path: Path) -> int:
    fixture = json.loads(fixture_path.read_text())
    server = serve(fixture, port)
    tui = Tui(exe, port, base_path)
    try:
        tui.drain(2)
        # Answer the terminal-capability probe so the TUI stops waiting on it.
        os.write(tui.fd, b"\x1b_Gi=31;ENOTSUPPORTED\x1b\\")
        tui.drain(15)
        if not settle(tui):
            print("screen never stopped moving; sweep would measure noise", file=sys.stderr)
            return 2
        observed: dict[str, list[tuple[str, str, int]]] = collections.OrderedDict()
        for _lap in range(LAPS):
            for _ in range(SURFACES):
                tui.drain(2.5)
                before, name = tui.body(), tui.title()
                tui.press(b"j" * 12, 1.5)
                middle = tui.body()
                tui.press(b"k" * 12, 1.5)
                after = tui.body()
                observed.setdefault(name, []).append(
                    ("yes" if middle != before else "no",
                     "yes" if after == before else "no",
                     len(before)))
                tui.press(b"\t", 1.0)
    finally:
        tui.close()
        server.shutdown()

    failures = 0
    print(f"  {'surface':22s} {'j':>6s} {'k back':>8s} {'rows':>5s}  verdict")
    for name, laps in observed.items():
        moved = "".join(o[0][0] for o in laps)
        back = "".join(o[1][0] for o in laps)
        rows = laps[0][2]
        stable = len({o[0] for o in laps}) == 1 and len({o[1] for o in laps}) == 1
        if not stable:
            verdict = "unstable - not reported"
        elif laps[0][0] == "no":
            # A list shorter than the body has nothing to scroll, and saying
            # nothing is then correct. Only a full screen that will not move
            # is a finding.
            if rows >= ROWS - 5:
                verdict = "J DOES NOTHING"
                failures += 1
            else:
                verdict = "nothing to scroll (fits on screen)"
        elif laps[0][1] == "no":
            verdict = "K DOES NOT COME BACK"
            failures += 1
        else:
            verdict = "ok"
        print(f"  {name[:20]:22s} {moved:>6s} {back:>8s} {rows:>5d}  {verdict}")
    return 1 if failures else 0


# ---------------------------------------------------------------- cli


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    rec = sub.add_parser("record", help="save the live server's answers")
    rec.add_argument("--port", type=int, default=8935)
    rec.add_argument("--base-path", type=Path, default=Path.home() / "me")
    rec.add_argument("--out", type=Path, default=Path("/tmp/tui-fixture.json"))

    swp = sub.add_parser("sweep", help="replay them and test every surface")
    swp.add_argument("--fixture", type=Path, default=Path("/tmp/tui-fixture.json"))
    swp.add_argument("--port", type=int, default=8977)
    swp.add_argument("--base-path", type=Path, default=Path.home() / "me")
    swp.add_argument("--exe", type=Path,
                     default=repo / "_build" / "default" / "bin" / "masc_tui.exe")

    args = parser.parse_args()
    if args.command == "record":
        return record(repo, args.port, args.base_path, args.out)
    return sweep(args.exe, args.fixture, args.port, args.base_path)


if __name__ == "__main__":
    sys.exit(main())

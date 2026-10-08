"""System keeps workspace and server identities readable across widths."""
import os
import sys

import tui_keyboard_harness as h

BASE_LABEL = b"  base "
# What the row draws for a masc root that sits under the base path: the label
# beside it, not the path again.
NESTED = b"masc <base>/.masc"
SERVER_LABEL = b"  server "
VERSION = "0.51.2"
COMMIT = "abcdef0123456789abcdef0123456789abcdef0123"


def identity_row(rows: dict[int, bytes], label: bytes, columns: int) -> bytes:
    index = h.screen_row_of(rows, label)
    if index < 0:
        raise AssertionError(f"at {columns} columns no row carries {label!r}")
    return rows[index].rstrip()


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures["/health"] = (200, {
        "version": VERSION,
        "build": {"binary_commit": COMMIT, "binary_commit_age_seconds": 7200},
    })

    def interact(process, fd, _slave, output, base_path):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go System", b"MASC System")
        port = process.args[process.args.index("--port") + 1].encode()
        for columns in (120, 100, 60):
            drawn = h.resize_and_wait(process, fd, output, rows=30,
                                      columns=columns, needle=BASE_LABEL,
                                      controls=(h.FULL_REDRAW,))
            rows = h.screen_rows(drawn)
            paths = identity_row(rows, BASE_LABEL, columns)
            server = identity_row(rows, SERVER_LABEL, columns)
            if NESTED not in paths:
                raise AssertionError(
                    f"at {columns} columns the masc root under the base path was "
                    f"lost or repeated the full base: {paths!r}")
            # The temporary directory's unique suffix distinguishes this
            # workspace even when the middle of its path is folded.
            suffix = os.path.basename(base_path).rsplit("-", 1)[-1].encode()
            if suffix not in paths:
                raise AssertionError(f"at {columns} columns the base path lost its identity: {paths!r}")
            for fact in (VERSION.encode(), COMMIT[:7].encode(), b":" + port, b"2h"):
                if fact not in server:
                    raise AssertionError(f"at {columns} columns server identity lost {fact!r}: {server!r}")
            for row in (paths, server):
                if h.fixture_cell_width(row.decode()) > columns:
                    raise AssertionError(f"at {columns} columns identity row overflows: {row!r}")
            if h.screen_row_of(rows, SERVER_LABEL) != h.screen_row_of(rows, BASE_LABEL) + 1:
                raise AssertionError(f"at {columns} columns the identity is not two adjacent rows")
            base = base_path.encode()
            if paths.count(base) > 1:
                raise AssertionError(
                    f"at {columns} columns the base path is drawn "
                    f"{paths.count(base)} times: {paths!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
                            description="System identity rows across widths",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("System identity rows preserve workspace and server facts: PASS")

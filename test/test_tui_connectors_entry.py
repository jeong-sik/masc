"""The transport list has a way in, and asking for it does not open the lane.

`Connectors` draws two screens behind one view: the transport list, and the
Browser Lane that `show_browser_lane` opens. Between #32242 and #36196 the
only code that set `view <- Connectors` was that same `show_browser_lane`, so
the list could not be reached at all -- no key, no Tab stop, no palette row --
while it kept advertising `b:bind  u:unbind` in its own footer.
"""

from __future__ import annotations

import os
from pathlib import Path
import signal
import subprocess
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_types.ml",
    "bin/masc_tui_render.ml",
)
CONNECTORS = "/api/v1/gate/connectors"
TITLE = b"MASC Connectors"


def fixtures() -> h.HttpFixtures:
    """An empty registry: the list draws its own note and asks for no pages.

    A connector row would make the loader walk three name directories per
    connector, which is a different reading from the one this proves.
    """
    served = h.overview_event_http_fixtures()
    served[CONNECTORS] = (200, {"connectors": [], "total": 0, "active_count": 0})
    return served


def the_transport_list_is_reachable(binary: str) -> None:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        try:
            landed = h.palette_go(
                process, master_fd, output, b"go Connectors", TITLE
            )
            plain = h.CSI_RE.sub(b"", landed)
            for needle in (
                b"MASC Connectors (0 of 0 available)",
                b"CONNECTOR",
                b"CHANNEL",
                b"(no connectors registered)",
            ):
                if needle not in plain:
                    raise AssertionError(
                        f"Connectors list omitted {needle!r}: {plain!r}"
                    )
            # The lane's own destination still goes to the lane, so the two
            # screens behind this view stay separately addressable.
            lane = h.palette_go(
                process, master_fd, output, b"go Browser Lane", b"MASC Browser Lane"
            )
            if TITLE + b" (" in h.CSI_RE.sub(b"", lane):
                raise AssertionError(f"Browser Lane drew the transport list: {lane!r}")
            # And back: with the lane on screen, asking for the list closes it.
            # This is the half the palette entry exists for -- a plain jump to
            # the view renders whichever screen the lane's visibility names.
            # The title carries its own styling, so "MASC Connectors (0 of 0
            # available)" is only one string once the escapes are off; the
            # wait reads the unstyled half and the count is read from the
            # stripped frame.
            again = h.CSI_RE.sub(
                b"", h.palette_go(process, master_fd, output, b"go Connectors", TITLE)
            )
            if b"MASC Browser Lane" in again:
                raise AssertionError(
                    f"the lane stayed on screen over the transport list: {again!r}"
                )
            if b"MASC Connectors (0 of 0 available)" not in again:
                raise AssertionError(
                    f"the transport list did not draw its count: {again!r}"
                )
        finally:
            os.killpg(process.pid, signal.SIGTERM)

    h.run_terminal_scenario(
        binary,
        description="the transport list is reachable and the lane does not cover it",
        interact=interact,
        confirm_exit=b"",
        http_fixtures=fixtures(),
    )


if __name__ == "__main__":
    executable = str(Path(sys.argv[1]).resolve())
    the_transport_list_is_reachable(executable)

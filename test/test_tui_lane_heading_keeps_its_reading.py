"""The standalone lanes heading keeps its own fact when the row is narrow."""
import os
import sys
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names, so without this a
# change to the drawn text below reaches main with no scenario run. The
# heading is built in masc_tui_render.ml; the words it used to repeat are the
# key table's, in masc_tui_keys.ml.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
    "bin/masc_tui_keys.ml",
    "bin/masc_tui_lane_addons.ml",
)

HEADING = "Lanes · observed ".encode()
# The row's own reading: when the standalone snapshot was read. Nothing else
# on the screen says it.
OWN = b"observed "
# The key table's words. The footer draws them from the table and the sheet
# explains them, so the heading repeating them cost cells that the frame then
# took off the tail -- which is where the reading above sits.
TABLE_WORDS = (b"Lane Add-ons", b"append slot")


def heading_row(rows: dict[int, bytes], columns: int) -> bytes:
    index = h.screen_row_of(rows, HEADING)
    if index < 0:
        raise AssertionError(f"at {columns} columns Lanes drew no standalone heading")
    return rows[index].rstrip()


def run(executable: str) -> None:
    # The standalone snapshot is what carries the observed clock, so the
    # scenario has to serve one; without it the heading has no reading of its
    # own to keep.
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.STANDALONE_LANES_PATH] = h.standalone_lanes_response()
    fixtures[h.RUNTIME_CONFIG_RAW_PATH] = h.standalone_lane_runtime_config_response()

    def interact(process, fd, _slave, output, _base_path):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        for columns in (110, 66):
            drawn = h.resize_and_wait(process, fd, output, rows=24,
                                      columns=columns, needle=HEADING,
                                      controls=(h.FULL_REDRAW,))
            rows = h.screen_rows(drawn)
            row = heading_row(rows, columns)
            if OWN not in row:
                raise AssertionError(
                    f"at {columns} columns the heading lost when the snapshot was "
                    f"read: {row!r}")
            for word in TABLE_WORDS:
                if word in row:
                    raise AssertionError(
                        f"at {columns} columns the heading repeats the key table's "
                        f"{word!r}: {row!r}")
            # And the reading did not leave the screen with the repetition:
            # the footer draws the same binding, from the table it belongs to.
            # Only at the width that has room for it -- the footer drops hints
            # from the back, which is the whole reason the heading must not be
            # where this binding is kept.
            # The frame slice a resize returns ends at the needle, above the
            # footer, so this reads everything the pane has written.
            if columns == 110 and b"A:Lane Add-ons" not in bytes(output):
                raise AssertionError("the footer stopped naming the Add-ons key")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
                            description="standalone lanes heading across widths",
                            interact=interact, http_fixtures=fixtures)


def run_unapplied_installations(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures[h.STANDALONE_LANES_PATH] = h.standalone_lanes_response()
    inventory = {
        "instances": [], "rows": [], "coverage": [],
        "configuration": {
            "directory": "/fixture/lane-addons", "complete": True,
            "declarations": [
                {"id": name, "source_path": f"/fixture/lane-addons/{name}.toml",
                 "desired_revision": name, "applied_revision": None, "instance_id": None}
                for name in ("dos-counter", "dos-output-statistics")
            ],
            "issues": [
                {"id": name, "source_path": f"/fixture/lane-addons/{name}.toml",
                 "message": "Docker image missing"}
                for name in ("dos-counter", "dos-output-statistics")
            ],
        },
    }
    fail_read = [False]

    def add_ons():
        return (503, {"error": "inventory unavailable"}) if fail_read[0] else (200, inventory)

    fixtures["/api/v1/lane-addons"] = add_ons

    def interact(process, fd, _slave, output, _base_path):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        # A opens the installation overview. Numeric section keys belong to
        # an installed worker's detail, so observe this overview's fetch instead.
        addon_start = len(output)
        h.send_and_wait(process, fd, output, b"A", b"Lane Add-ons")
        h.wait_for_output(process, fd, output, b"Lane Add-ons \xc2\xb7 2 declared",
                          start=addon_start, timeout=3.0)
        frame = h.send_and_wait(process, fd, output, b"\x1b", b"2 declared")
        reading = b"Lane Add-ons: 2 declared \xc2\xb7 0 active \xc2\xb7 2 config issues"
        if reading not in h.screen_text(frame):
            raise AssertionError("unapplied TOML was counted as an installed worker")
        fail_read[0] = True
        addon_start = len(output)
        h.send_and_wait(process, fd, output, b"A", b"Lane Add-ons")
        h.wait_for_output(process, fd, output, b"HTTP 503",
                          start=addon_start, timeout=3.0)
        stale = h.send_and_wait(process, fd, output, b"\x1b", b"STALE")
        if b"Lane Add-ons: STALE \xc2\xb7 2 declared" not in h.screen_text(stale):
            raise AssertionError("failed Add-on reread was shown as a current count")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
                            description="unapplied Add-ons are not active workers",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    run_unapplied_installations(os.path.abspath(sys.argv[1]))
    print("lanes heading and installation truth: PASS")

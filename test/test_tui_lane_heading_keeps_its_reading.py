"""The standalone lanes heading keeps its own fact when the row is narrow."""
import os
import sys
import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_keepers as _keyboard_keepers
import tui_keyboard_runtime as _keyboard_runtime



HEADING = "Lanes · observed ".encode()
# The row's own reading: when the standalone snapshot was read. Nothing else
# on the screen says it.
OWN = b"observed "
# The key table's words. The footer draws them from the table and the sheet
# explains them, so the heading repeating them cost cells that the frame then
# took off the tail -- which is where the reading above sits.
TABLE_WORDS = (b"Lane Add-ons", b"append slot")


def heading_row(rows: dict[int, bytes], columns: int) -> bytes:
    index = _keyboard_harness.screen_row_of(rows, HEADING)
    if index < 0:
        raise AssertionError(f"at {columns} columns Lanes drew no standalone heading")
    return rows[index].rstrip()


def run(executable: str) -> None:
    # The standalone snapshot is what carries the observed clock, so the
    # scenario has to serve one; without it the heading has no reading of its
    # own to keep.
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures[_keyboard_keepers.STANDALONE_LANES_PATH] = _keyboard_keepers.standalone_lanes_response()
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = _keyboard_keepers.standalone_lane_runtime_config_response()

    def interact(process, fd, _slave, output, _base_path):
        _keyboard_harness.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        for columns in (110, 66):
            drawn = _keyboard_harness.resize_and_wait(process, fd, output, rows=24,
                                      columns=columns, needle=HEADING,
                                      controls=(_keyboard_harness.FULL_REDRAW,))
            rows = _keyboard_harness.screen_rows(drawn)
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
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"MASC Dashboard")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable,
                            description="standalone lanes heading across widths",
                            interact=interact, http_fixtures=fixtures)


def run_unapplied_installations(executable: str) -> None:
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures[_keyboard_keepers.STANDALONE_LANES_PATH] = _keyboard_keepers.standalone_lanes_response()
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
        _keyboard_harness.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        # A opens the installation overview. Numeric section keys belong to
        # an installed worker's detail, so observe this overview's fetch instead.
        addon_start = len(output)
        _keyboard_harness.send_and_wait(process, fd, output, b"A", b"Lane Add-ons")
        _keyboard_harness.wait_for_output(process, fd, output, b"Lane Add-ons \xc2\xb7 2 declared",
                          start=addon_start, timeout=3.0)
        frame = _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"2 declared")
        reading = b"Lane Add-ons: 2 declared \xc2\xb7 0 active \xc2\xb7 2 config issues"
        if reading not in _keyboard_harness.screen_text(frame):
            raise AssertionError("unapplied TOML was counted as an installed worker")
        fail_read[0] = True
        addon_start = len(output)
        _keyboard_harness.send_and_wait(process, fd, output, b"A", b"Lane Add-ons")
        _keyboard_harness.wait_for_output(process, fd, output, b"HTTP 503",
                          start=addon_start, timeout=3.0)
        stale = _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"STALE")
        if b"Lane Add-ons: STALE \xc2\xb7 2 declared" not in _keyboard_harness.screen_text(stale):
            raise AssertionError("failed Add-on reread was shown as a current count")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(executable,
                            description="unapplied Add-ons are not active workers",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    run_unapplied_installations(os.path.abspath(sys.argv[1]))
    print("lanes heading and installation truth: PASS")

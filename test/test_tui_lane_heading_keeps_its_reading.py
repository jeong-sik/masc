"""The common Lane inventory heading keeps its own fact when the row is narrow."""
import os
import sys
import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_keepers as _keyboard_keepers
import tui_keyboard_runtime as _keyboard_runtime



HEADING = "All lanes · observed ".encode()
# The row's own reading: when the common inventory snapshot was read. Nothing else
# on the screen says it.
OWN = b"observed "
# The key table's words. The footer draws them from the table and the sheet
# explains them, so the heading repeating them cost cells that the frame then
# took off the tail -- which is where the reading above sits.
TABLE_WORDS = (b"Lane Add-ons", b"append slot")


def heading_row(rows: dict[int, bytes], columns: int) -> bytes:
    index = _keyboard_harness.screen_row_of(rows, HEADING)
    if index < 0:
        raise AssertionError(f"at {columns} columns Lanes drew no inventory heading")
    return rows[index].rstrip()


def run(executable: str) -> None:
    # The standalone snapshot is what carries the observed clock, so the
    # scenario has to serve one; without it the heading has no reading of its
    # own to keep.
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fixtures[_keyboard_keepers.LANE_INVENTORY_PATH] = _keyboard_keepers.lane_inventory_response()
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


def unapplied_inventory():
    rows = []
    for name in ("dos-counter", "dos-output-statistics"):
        path = f"/fixture/lane-addons/{name}.toml"
        rows.append({
            "id": "declaration/" + path, "label": name + ".toml",
            "purpose": "Package declaration and its owned observation workers.",
            "selection": {"kind": "declaration", "source_path": path},
            "state": {"kind": "package", "instances": [], "declaration": {
                "kind": "valid", "installation_id": name, "run_id": "fixture-world",
                "package_id": name, "title": name, "desired_revision": "revision-1",
            }},
        })
    return _keyboard_keepers.lane_inventory_response(package_rows=rows)


def run_unapplied_installations(executable: str) -> None:
    fixtures = _keyboard_harness.keeper_runtime_http_fixtures()
    fail_read = [False]
    requests = []

    def inventory():
        return (503, {"error": "inventory unavailable"}) if fail_read[0] else unapplied_inventory()

    fixtures[_keyboard_keepers.LANE_INVENTORY_PATH] = inventory

    def interact(process, fd, _slave, output, _base_path):
        _keyboard_harness.palette_go(process, fd, output, b"go lanes", b"MASC Lanes")
        _keyboard_harness.wait_for_output(process, fd, output, HEADING, start=0, timeout=10)
        _keyboard_harness.send_and_wait(process, fd, output, b"/dos-counter", b"dos-counter")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"j/k:move")
        _keyboard_harness.send_and_wait(process, fd, output, b"d", b"no worker observed")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        frame = _keyboard_harness.screen_text(bytes(output))
        if b"declaration valid" not in frame or b"no worker observed" not in frame:
            raise AssertionError(f"unapplied TOML lost its observed state: {frame!r}")
        if any(path.split("?", 1)[0] == "/api/v1/lane-addons" for path, _ in requests):
            raise AssertionError("first common inventory required opening the Add-ons surface")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"All lanes")
        fail_read[0] = True
        _keyboard_harness.send_and_wait(process, fd, output, b"r", b"inventory unavailable")
        _keyboard_harness.drain_until_quiet(process, fd, output)
        stale = _keyboard_harness.screen_text(bytes(output))
        if b"STALE" not in stale or b"dos-counter" not in stale:
            raise AssertionError(f"failed inventory read hid the retained declaration: {stale!r}")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable, description="unapplied declarations are observed before Add-ons is opened",
        interact=interact, http_fixtures=fixtures, http_requests=requests,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    run_unapplied_installations(os.path.abspath(sys.argv[1]))
    print("lanes heading and installation truth: PASS")

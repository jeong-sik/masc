"""The Config paths row names the base path once."""
import os
import sys
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names, so without this a
# change to the drawn text below reaches main with no scenario run. The row is
# built in masc_tui_render.ml.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
)

BASE_LABEL = b"  base "
# What the row draws for a masc root that sits under the base path: the label
# beside it, not the path again.
NESTED = b"masc <base>/.masc"
AGE_LABEL = b"binary "


def paths_row(rows: dict[int, bytes], columns: int) -> bytes:
    index = h.screen_row_of(rows, BASE_LABEL)
    if index < 0:
        raise AssertionError(f"at {columns} columns no row carries the base path")
    return rows[index].rstrip()


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()

    def interact(process, fd, _slave, output, base_path):
        h.wait_for_output(process, fd, output, b"Health: ", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go config", b"MASC Config")
        for columns in (120, 100):
            drawn = h.resize_and_wait(process, fd, output, rows=30,
                                      columns=columns, needle=BASE_LABEL,
                                      controls=(h.FULL_REDRAW,))
            row = paths_row(h.screen_rows(drawn), columns)
            if NESTED not in row:
                raise AssertionError(
                    f"at {columns} columns the masc root under the base path was "
                    f"spelled in full: {row!r}")
            # The collapse is there to give the base path room, not to take the
            # row's third fact with it.
            if AGE_LABEL not in row:
                raise AssertionError(
                    f"at {columns} columns the row lost the binary age: {row!r}")
            base = base_path.encode()
            if row.count(base) > 1:
                raise AssertionError(
                    f"at {columns} columns the base path is drawn "
                    f"{row.count(base)} times: {row!r}")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
                            description="Config paths row across widths",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Config paths row names the base once: PASS")

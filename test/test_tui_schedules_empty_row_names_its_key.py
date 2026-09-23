"""An empty Schedules list says which key fills it."""
import os
import sys
import test_tui_keyboard_input as h

# The sources this scenario stands over. scripts/ci/run-edited-tests.sh runs a
# suite when a pull request changes a path the suite names. The row is drawn
# in masc_tui_render.ml; the key it names is declared in masc_tui_keys.ml.
SOURCE_MODULES = (
    "bin/masc_tui_render.ml",
    "bin/masc_tui_keys.ml",
)

EMPTY = b"no scheduled automation"
# The key the table gives this surface for making a schedule. The footer sorts
# Navigate before Act and drops from the back, and this surface has four
# Navigate keys, so at every width measured the footer has already dropped
# every action it offers -- n among them. The empty row is what is left.
CREATE = b"n"


def empty_row(rows: dict[int, bytes]) -> bytes:
    index = h.screen_row_of(rows, EMPTY)
    if index < 0:
        raise AssertionError("Schedules drew no empty row")
    return rows[index].rstrip()


def run(executable: str) -> None:
    fixtures = h.keeper_runtime_http_fixtures()
    # A workspace with no schedules at all: the state this row exists for.
    fixtures[h.SCHEDULES_PATH] = (
        200,
        {
            "status": "ok",
            "schedule_store_read_error": None,
            "request_count": 0,
            "truncated": False,
            "fsm": {"next_due_at_iso": None},
            "requests": [],
        },
    )

    def interact(process, fd, _slave, output, _base_path):
        h.wait_for_output(process, fd, output, b"cluster-a", start=0, timeout=10)
        h.palette_go(process, fd, output, b"go schedules", b"MASC Keepers / Schedules")
        drawn = h.resize_and_wait(process, fd, output, rows=24, columns=110,
                                  needle=EMPTY, controls=(h.FULL_REDRAW,))
        row = empty_row(h.screen_rows(drawn))
        # Still says what it says: the list is empty, not unread and not
        # failed. Those are other rows with other words.
        if EMPTY not in row:
            raise AssertionError(f"the row stopped saying the list is empty: {row!r}")
        tail = row.split(EMPTY, 1)[1]
        if CREATE not in tail:
            raise AssertionError(
                f"the empty row does not say which key fills the list: {row!r}")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC ")
        os.write(fd, b"q")

    h.run_terminal_scenario(executable,
                            description="empty Schedules list",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("the empty Schedules row names its key: PASS")

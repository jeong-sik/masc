"""A memory fact's whole claim reads in a surface of its own.

Enter on the Memory fact browser used to be a no-op. The only reading of a
fact's full text was the narrow detail block under its row in the list, whose
width is the list's and whose top is whatever the row order left it. This
scenario drives the surface that Enter now opens: the claim is wrapped for the
terminal it was given, the window marker under it says how much of the claim is
on screen, j scrolls that window instead of the list behind it, and Esc gives
the list back whole.

SOURCE_MODULES names the files this scenario stands over. PR CI picks the suite
up from those paths, so a change to the key wiring, the surface state or the
overlay render has to pass here.
"""
import os
import re
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_keys.ml",
    "bin/masc_tui_render.ml",
    "bin/masc_tui_types.ml",
)

DETAIL_ROWS_RE = re.compile(rb"\[detail rows (\d+)-(\d+)/(\d+)\]")

# The list shows this claim in its own block; the point of the surface is that
# the whole claim no longer fits there, so a window and a scroll have to exist.
CLAIM = " ".join("clause-%04d" % i for i in range(1200))

# The fact browser's filter strip and the Activity side pane are what the
# surface has to cover: the reading owns the whole terminal, and only Esc gives
# either of them back.
LIST_STRIP = b"c/C:category"
LIST_DETAIL_HINT = b"Enter:detail"
SIDE_PANE = b"no events"


def screen_bytes(output: bytearray) -> bytes:
    end = output.rfind(h.FRAME_END)
    return bytes(output[: end + len(h.FRAME_END)]) if end >= 0 else bytes(output)


def plain_screen(output: bytearray) -> bytes:
    """The rendered screen, not the frame bytes.

    Every earlier frame is still in the stream, so a substring search over the
    raw output would report text this surface has already covered.
    """
    rows = h.screen_rows(screen_bytes(output))
    return b"\n".join(
        h.CSI_RE.sub(b"", rows[number]) for number in sorted(rows))


def detail_window(output: bytearray) -> tuple[int, int, int]:
    match = DETAIL_ROWS_RE.search(plain_screen(output))
    if match is None:
        raise AssertionError(
            "the detail surface printed no window marker: "
            f"{plain_screen(output)[-900:]!r}")
    return tuple(int(group) for group in match.groups())  # type: ignore[return-value]


def run(executable: str) -> None:
    fixtures = h.memory_facts_http_fixtures()
    status, payload = fixtures["/api/v1/keepers/alpha/memory-facts"]
    for fact in payload["ordinary"]["facts"]:
        fact["claim"] = CLAIM
    for fact in payload["source_bound"]["facts"]:
        fact["claim"] = CLAIM
    fixtures["/api/v1/keepers/alpha/memory-facts"] = (status, payload)

    def interact(process, master_fd, _slave_fd, output, _base_path):
        h.resize_and_wait(process, master_fd, output, rows=38, columns=150,
                          needle=b"MASC Overview", final_cursor=b"\x1b[?25l")
        h.drain_until_quiet(process, master_fd, output)
        h.tab_until(process, master_fd, output, b"MASC Memory")
        h.wait_for_output(process, master_fd, output, b"Total 3 facts",
                          start=0, timeout=5.0)
        h.send_and_wait(process, master_fd, output, b"\r",
                        b"\xe2\x96\xb8 alpha")
        # The listing lands async. Every claim in this fixture opens the same
        # way, so the needle does not depend on which row sorts first.
        h.wait_for_output(process, master_fd, output, b"clause-0000",
                          start=0, timeout=5.0)
        h.drain_until_quiet(process, master_fd, output)
        for needle in (LIST_STRIP, LIST_DETAIL_HINT, SIDE_PANE):
            if needle not in plain_screen(output):
                raise AssertionError(
                    f"the fact browser never drew {needle!r}: "
                    f"{plain_screen(output)[-900:]!r}")

        # Recency opens on the dropped row, whose facts carry no claim; one step
        # down lands on an ordinary fact, and the list's block under that row is
        # what a reading has to outgrow.
        h.send_and_wait(process, master_fd, output, b"j", b"Fact Detail")
        h.drain_until_quiet(process, master_fd, output)

        h.send_and_wait(process, master_fd, output, b"\r", b"FACT DETAIL")
        h.wait_for_output(process, master_fd, output, b"[detail rows",
                          start=0, timeout=5.0)
        h.drain_until_quiet(process, master_fd, output)
        plain = plain_screen(output)
        for needle in (LIST_STRIP, SIDE_PANE):
            if needle in plain:
                raise AssertionError(
                    f"the wide reading left {needle!r} on the screen instead of "
                    f"owning the terminal: {plain[-900:]!r}")
        first, last, total = detail_window(output)
        if total < 15:
            raise AssertionError(
                f"this claim needed no window at all: {first}-{last}/{total}")
        if first != 1 or last >= total:
            raise AssertionError(
                "a fresh reading did not open on the claim's head: "
                f"{first}-{last}/{total}")
        if b"clause-0000" not in plain:
            raise AssertionError("the reading did not wrap the claim's text")

        # j moves the window this surface owns, not the list it covers.
        os.write(master_fd, b"j" * 6)
        h.drain_until_quiet(process, master_fd, output)
        scrolled_first, scrolled_last, scrolled_total = detail_window(output)
        if scrolled_total != total or scrolled_first <= first:
            raise AssertionError(
                "j did not scroll the reading: "
                f"{first}-{last}/{total} then "
                f"{scrolled_first}-{scrolled_last}/{scrolled_total}")

        # k walks the window back the way j brought it.
        os.write(master_fd, b"k" * 2)
        h.drain_until_quiet(process, master_fd, output)
        back_first, _back_last, back_total = detail_window(output)
        if back_total != total or back_first >= scrolled_first:
            raise AssertionError(
                "k did not walk the reading back: "
                f"{scrolled_first}- then {back_first}-")

        # G opens the claim's tail in one step, the way g opens its head.
        os.write(master_fd, b"G")
        h.drain_until_quiet(process, master_fd, output)
        end_first, end_last, end_total = detail_window(output)
        if end_total != total or end_last != end_total or end_first == 1:
            raise AssertionError(
                "G did not open the claim's tail: "
                f"{end_first}-{end_last}/{end_total}")

        # Esc hands the list and its pane back whole.
        h.send_and_wait(process, master_fd, output, b"\x1b", LIST_STRIP)
        h.drain_until_quiet(process, master_fd, output)
        plain = plain_screen(output)
        if b"FACT DETAIL" in plain:
            raise AssertionError("Esc left the wide reading on the screen")
        for needle in (LIST_STRIP, LIST_DETAIL_HINT, SIDE_PANE):
            if needle not in plain:
                raise AssertionError(
                    f"Esc did not give {needle!r} back: {plain[-900:]!r}")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="A memory fact reads in the wide detail surface",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("memory fact detail surface: PASS")

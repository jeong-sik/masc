"""Memory prose and exact provenance remain readable in narrow detail frames."""
import os
import re
import sys
import test_tui_keyboard_input as h
import test_tui_memory_fact_detail_pty as detail


# Force overflow at both 80 and 30 columns in the short frame, while the
# full reading grows by the observed overflow, retaining the entire record.
CLAIM = "CLAIMHEAD\n\n" + "단어 " * 200 + "\nCLAIMTAIL"
ORIGIN = "keeper: " + "long-owner/" * 10 + " ENDORIGIN"
MEMORY_ID = "memory-" + "0123456789" * 10 + " ENDMEMORY"
PATH = "docs/" + "long-directory/" * 10 + " ENDPATH"
SHA = "0123456789abcdef" * 4


def compact(value):
    return re.sub(rb"\s+", b"", h.unwrapped(value))


def run(executable, source):
    fixtures = h.memory_facts_http_fixtures()
    status, payload = fixtures["/api/v1/keepers/alpha/memory-facts"]
    ordinary = payload["ordinary"]["facts"][0]
    source_fact = payload["source_bound"]["facts"][0]
    ordinary.update(claim=CLAIM, origin=ORIGIN, memory_id=MEMORY_ID)
    source_fact.update(claim=CLAIM, path=PATH, sha256=SHA)
    payload["ordinary"]["facts"] = [] if source else [ordinary]
    payload["source_bound"]["facts"] = [source_fact] if source else []
    payload["source_bound"]["invalidations"] = []
    fixtures["/api/v1/keepers/alpha/memory-facts"] = status, payload

    def interact(process, master_fd, _slave_fd, output, _base_path):
        h.palette_go(process, master_fd, output, b"go Memory", b"MASC Memory")
        h.wait_for_output(process, master_fd, output, b"Total 3 facts", start=0, timeout=10)
        h.send_and_wait(process, master_fd, output, b"\r", b"\xe2\x96\xb8 alpha")
        h.wait_for_output(process, master_fd, output, b"CLAIMHEAD", start=0, timeout=10)
        h.send_and_wait(process, master_fd, output, b"\r", b"FACT DETAIL")
        for width in (80, 30):
            # Keep the entire record visible to reconstruct exact fields,
            # then reduce height and verify its wrapped tail is scrollable.
            h.resize_and_wait(process, master_fd, output, rows=100, columns=width,
                              needle=b"CLAIMHEAD", final_cursor=b"\x1b[?25l")
            h.drain_until_quiet(process, master_fd, output)
            # At 30 columns the wrapped record can exceed the 100-row
            # viewport. Read its actual window instead of assuming a height.
            if b"[lines " in detail.plain_screen(output):
                first, last, total = detail.detail_window(output)
                full_rows = 100 + total - (last - first + 1)
                h.resize_and_wait(process, master_fd, output, rows=full_rows,
                                  columns=width, needle=b"CLAIMHEAD",
                                  final_cursor=b"\x1b[?25l")
                h.drain_until_quiet(process, master_fd, output)
            screen = compact(detail.plain_screen(output))
            expected = (PATH, SHA) if source else (ORIGIN, MEMORY_ID)
            for value in (CLAIM,) + expected:
                if compact(value.encode()) not in screen:
                    raise AssertionError(f"Memory content lost at {width} columns: {value!r}, {screen!r}")
            h.resize_and_wait(process, master_fd, output, rows=22, columns=width,
                              needle=b"CLAIMHEAD", final_cursor=b"\x1b[?25l")
            h.drain_until_quiet(process, master_fd, output)
            h.send_and_wait(process, master_fd, output, b"G", b"[lines ")
            h.drain_until_quiet(process, master_fd, output)
            first, last, total = detail.detail_window(output)
            if first <= 1 or last != total:
                raise AssertionError(f"wrapped tail cannot be reached: {first}-{last}/{total}")
            tail = compact(detail.plain_screen(output))
            final_value = SHA if source else "ENDMEMORY"
            if compact(final_value.encode()) not in tail:
                raise AssertionError(f"provenance tail missing after G: {tail!r}")
            h.send_and_wait(process, master_fd, output, b"g", b"CLAIMHEAD")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(executable,
        description="Narrow Memory source provenance" if source else "Narrow Memory ordinary provenance",
        interact=interact, http_fixtures=fixtures, terminal_rows=40)


if __name__ == "__main__":
    for source in (False, True):
        run(os.path.abspath(sys.argv[1]), source)
    print("Memory provenance layout: PASS")

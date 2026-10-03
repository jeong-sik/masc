"""Usage coverage remains reachable when a metric row exceeds the viewport."""
import os
import sys

import test_tui_keyboard_input as h




def run(executable):
    fixtures: h.HttpFixtures = {
        "/api/v1/dashboard/keeper-costs?window=1440": (200, {
            "cache": {"state": "fresh"}, "generated_at": 1,
            "window_minutes": 1440, "keepers": [{
                "keeper_name": "usage-layout-keeper", "sample_count": 12,
                "total_tokens": 9876, "total_cost_usd": 0.1234,
                "tokens_reported_samples": 9, "tokens_unreported_samples": 2,
                "tokens_unread_samples": 1, "cost_reported_samples": 8,
                "cost_unreported_samples": 3, "cost_unread_samples": 1,
                "metrics_read": {"state": "read", "malformed_rows": 7},
            }],
        }),
    }

    def interact(process, master_fd, _slave_fd, output, _base_path):
        h.palette_go(process, master_fd, output, b"go Usage", b"MASC Usage")
        h.send_and_wait(process, master_fd, output, b"v", b"Quota scope trend")
        h.send_and_wait(process, master_fd, output, b"v", b"usage-layout-keeper")
        for width in (80, 60, 120):
            frame = h.resize_and_wait(process, master_fd, output, rows=50, columns=width,
                                      needle=b"usage-layout-keeper", controls=(h.FULL_REDRAW,),
                                      final_cursor=b"\x1b[?25l")
            # Read this resize's completed frame so an earlier, wider screen
            # cannot supply coverage that disappeared at the current width.
            screen = h.unwrapped(h.screen_text(frame))
            for evidence in (b"Tokens 9876 \xc2\xb7 9 reported, 3 missing",
                             b"Cost $0.1234 \xc2\xb7 8 reported, 4 missing",
                             b"7 malformed rows"):
                if evidence not in screen:
                    raise AssertionError(f"Usage evidence lost at {width} columns: {evidence!r}, {screen!r}")
        # Make the wrapped content exceed the body, then reach its final row.
        frame = h.resize_and_wait(process, master_fd, output, rows=18, columns=30,
                                  needle=b"MASC Usage", final_cursor=b"\x1b[?25l")
        if b"4 missing" in h.unwrapped(h.screen_text(frame)):
            raise AssertionError("Usage fixture does not overflow the viewport")
        h.send_and_wait(process, master_fd, output, b"j" * 30, b"4 missing")
        h.drain_until_quiet(process, master_fd, output)
        screen = h.unwrapped(h.screen_text(bytes(output)))
        if b"7 malformed rows" not in screen:
            raise AssertionError(f"wrapped coverage is unreachable by scrolling: {screen!r}")
        os.write(master_fd, b"q")

    h.run_terminal_scenario(executable, description="Usage metric coverage survives resize and scroll",
                            interact=interact, http_fixtures=fixtures)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Usage row wrapping: PASS")

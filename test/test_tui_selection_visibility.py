"""Selected rows remain visible and Enter targets the displayed Runtime row."""

import os
import sys

import test_tui_keyboard_input as h

SOURCE_MODULES = ("bin/masc_tui.ml", "bin/masc_tui_render.ml")


def run_models(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    source = "\n".join(
        f"[models.model{i:02d}]\ntemperature = 0.7\n"
        f"[ollama_cloud.model{i:02d}]\nmax-tokens = 16384"
        for i in range(12)
    )
    fixtures[h.RUNTIME_CONFIG_RAW_PATH] = (
        200,
        {
            **h.runtime_config_read_metadata(),
            "path": "/workspace/config/runtime.toml",
            "source_text": source,
        },
    )

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC Config")
        h.wait_for_output(process, fd, output, b"temperature = ", start=0, timeout=3)
        h.send_and_wait(process, fd, output, b"p", b"MASC Models")
        for i in range(1, 12):
            h.send_and_wait(process, fd, output, b"j", f"model{i:02d}".encode())
        # The detail also names the model. Assert the marked TABLE row, not
        # merely a model name present somewhere in the output history.
        for rows in (20, 16, 30):
            h.resize_and_wait(
                process,
                fd,
                output,
                rows=rows,
                columns=100,
                needle=b"MASC Models",
                controls=(h.FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            screen = h.screen_text(bytes(output))
            if not any(
                b"> " in row and b"model11" in row for row in screen.splitlines()
            ):
                raise AssertionError(
                    f"selected model vanished at {rows} rows: {screen!r}"
                )
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Models selected row survives resize",
        interact=interact,
        http_fixtures=fixtures,
    )


def run_runtime(executable: str) -> None:
    fixtures = h.overview_event_http_fixtures()
    fixtures[h.RUNTIME_PROBE_PATH] = h.runtime_probe_response(fresh=True)
    fixtures[h.RUNTIME_RESOLVED_PATH] = h.runtime_resolved_response()

    def interact(process, fd, _slave, output, _base):
        h.tab_until(process, fd, output, b"MASC Config")
        h.send_and_wait(process, fd, output, b"9", b"1/2 runtime-a")
        h.send_and_wait(process, fd, output, b"p", b"All runtimes (5)")
        # Select catalog row 5: beyond the four rows of the lane listing.
        h.send_and_wait(process, fd, output, b"\x1b[F", b"runtime-e")
        h.send_and_wait(process, fd, output, b"\r", b"Runtime ID: runtime-e")
        h.send_and_wait(process, fd, output, b"\x1b", b"All runtimes (5)")
        h.send_and_wait(process, fd, output, b"p", b"MASC Lanes")
        h.send_and_wait(process, fd, output, b"p", b"Lanes (3 lanes, 4 slots)")
        h.send_and_wait(process, fd, output, b"\r", b"Runtime ID: runtime-a")
        os.write(fd, b"q")

    h.run_terminal_scenario(
        executable,
        description="Runtime mode resets selection with scroll",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run_models(os.path.abspath(sys.argv[1]))
    run_runtime(os.path.abspath(sys.argv[1]))
    print("TUI selection visibility: PASS")

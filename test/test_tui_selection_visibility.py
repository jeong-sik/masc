"""Selected rows remain visible and Enter targets the displayed Runtime row."""

import os
import sys

import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_runtime as _keyboard_runtime




def run_models(executable: str) -> None:
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    source = "\n".join(
        f"[models.model{i:02d}]\ntemperature = 0.7\n"
        f"[ollama_cloud.model{i:02d}]\nmax-tokens = 16384"
        for i in range(12)
    )
    fixtures[_keyboard_runtime.RUNTIME_CONFIG_RAW_PATH] = (
        200,
        {
            **_keyboard_runtime.runtime_config_read_metadata(),
            "path": "/workspace/config/runtime.toml",
            "source_text": source,
        },
    )

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC System")
        _keyboard_harness.wait_for_output(process, fd, output, b"temperature = ", start=0, timeout=3)
        _keyboard_harness.send_and_wait(process, fd, output, b"p", b"MASC Models")
        for i in range(1, 12):
            _keyboard_harness.send_and_wait(process, fd, output, b"j", f"model{i:02d}".encode())
        # The detail also names the model. Assert the marked TABLE row, not
        # merely a model name present somewhere in the output history.
        for rows in (20, 16, 30):
            _keyboard_harness.resize_and_wait(
                process,
                fd,
                output,
                rows=rows,
                columns=100,
                needle=b"MASC Models",
                controls=(_keyboard_harness.FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            screen = _keyboard_harness.screen_text(bytes(output))
            if not any(
                b"> " in row and b"model11" in row for row in screen.splitlines()
            ):
                raise AssertionError(
                    f"selected model vanished at {rows} rows: {screen!r}"
                )
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Models selected row survives resize",
        interact=interact,
        http_fixtures=fixtures,
    )


def run_runtime(executable: str) -> None:
    fixtures = _keyboard_harness.overview_event_http_fixtures()
    fixtures[_keyboard_runtime.RUNTIME_PROBE_PATH] = _keyboard_runtime.runtime_probe_response(fresh=True)
    fixtures[_keyboard_harness.RUNTIME_RESOLVED_PATH] = _keyboard_runtime.runtime_resolved_response()

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.tab_until(process, fd, output, b"MASC System")
        _keyboard_harness.send_and_wait(process, fd, output, b"9", b"1/2 runtime-a")
        _keyboard_harness.send_and_wait(process, fd, output, b"p", b"All runtimes (5)")
        # Select catalog row 5: beyond the four rows of the lane listing.
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b[F", b"runtime-e")
        _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"Runtime ID: runtime-e")
        _keyboard_harness.send_and_wait(process, fd, output, b"\x1b", b"All runtimes (5)")
        _keyboard_harness.send_and_wait(process, fd, output, b"p", b"MASC Lanes")
        # The tab strip may clip its count at this terminal width. Selection
        # restoration is proved by the actual lane row and the detail it opens.
        _keyboard_harness.send_and_wait(process, fd, output, b"p", b"1/2 runtime-a")
        _keyboard_harness.send_and_wait(process, fd, output, b"\r", b"Runtime ID: runtime-a")
        os.write(fd, b"q")

    _keyboard_harness.run_terminal_scenario(
        executable,
        description="Runtime mode resets selection with scroll",
        interact=interact,
        http_fixtures=fixtures,
    )


if __name__ == "__main__":
    run_models(os.path.abspath(sys.argv[1]))
    run_runtime(os.path.abspath(sys.argv[1]))
    print("TUI selection visibility: PASS")

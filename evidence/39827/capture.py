"""Capture real TUI /about and Keeper Info frames for #39827."""
from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "test"))
import test_tui_keyboard_input as h  # noqa: E402

binary = str(Path(sys.argv[1]).resolve())
out = Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
label = sys.argv[3]
digest = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
(out / f"{label}-binary.sha256").write_text(digest + "\n")


def write_screen(path: Path, output: bytearray) -> None:
    lines = h.screen_text(bytes(output)).decode("utf-8").splitlines()
    path.write_text("\n".join(line.rstrip() for line in lines) + "\n")


for cols in (80, 140):
    fixtures = h.keeper_runtime_http_fixtures()
    fixtures["/api/v1/keepers/alpha/chat/history"] = (200, [])

    def interact(process, fd, _slave, output, _base):
        h.send_and_wait(process, fd, output, b"2", b"MASC Keepers")
        h.select_keeper_row(process, fd, output, b"alpha")
        h.send_and_wait(process, fd, output, b"\r", "▸Info".encode())
        h.resize_and_wait(process, fd, output, rows=32, columns=cols,
                          needle=b"Identity")
        write_screen(out / f"{label}-info-{cols}x32.txt", output)
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Keepers")
        h.send_and_wait(process, fd, output, b"\x1b", b"MASC Overview")
        h.send_and_wait(process, fd, output, b"i", h.COMPOSER_FOCUSED)
        h.send_and_wait(process, fd, output, b"/about\r",
                        b"Multi-Agent Shared Context")
        h.resize_and_wait(process, fd, output, rows=32, columns=cols,
                          needle=h.FRAME_END)
        write_screen(out / f"{label}-about-{cols}x32.txt", output)
        os.write(fd, b"q")

    h.run_terminal_scenario(
        binary, description=f"#39827 {label} {cols}x32 capture",
        interact=interact, http_fixtures=fixtures, terminal_cols=cols,
    )
print(f"captured {label} 80x32 and 140x32 from {digest}", flush=True)

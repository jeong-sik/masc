"""Run the existing SGR wheel/click scenario and retain its measured frames."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "test"))
import tui_keyboard_harness as h
import tui_keyboard_keepers as keepers
import test_tui_keyboard_input as entry

original = keepers.send_and_wait
capture_dir = Path(__file__).resolve().parent
frame_number = 0


def retain_wheel_frame(process, master_fd, output, payload, needle, *args, **kwargs):
    global frame_number
    result = original(process, master_fd, output, payload, needle, *args, **kwargs)
    if payload in (b"\x1b[<65;5;5M", b"\x1b[<64;5;5M"):
        frame_number += 1
        frame = b"\n".join(line.rstrip() for line in h.screen_text(bytes(output)).splitlines()) + b"\n"
        (capture_dir / f"wheel-{frame_number}.txt").write_bytes(frame)
    return result


if __name__ == "__main__":
    keepers.send_and_wait = retain_wheel_frame
    entry.main(
        [sys.argv[1], "--scenario", "wheel scrolls, clicks do not"],
        entry.SCENARIO_FAMILIES,
        entry.KEYBOARD_FAMILY,
    )
    if frame_number != 3:
        raise AssertionError(f"expected three observed SGR wheel frames, got {frame_number}")

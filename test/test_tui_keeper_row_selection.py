"""Deterministic frame/keypress regressions for the PTY fixture's selector."""

from unittest import TestCase, main
from unittest.mock import Mock, patch

import test_tui_keyboard_input as h


def frame(selected: bytes | None, *, clear: bool = False) -> bytes:
    body = h.FULL_REDRAW if clear else b""
    if selected is None:
        body += b"\x1b[3;1H\x1b[2KMASC Keepers (0)"
    else:
        for row, name in ((9, b"alpha"), (10, b"beta")):
            body += f"\x1b[{row};1H\x1b[0m\x1b[2K".encode()
            body += b"\x1b[7m" if selected == name else b"\x1b[2m"
            body += b" - unread " + name + b"\x1b[0m"
    return h.FRAME_START + body + h.FRAME_END


class KeeperSelection(TestCase):
    def select(
        self,
        output: bytearray,
        *,
        arriving: bytes = b"",
        waited: tuple[bytes, ...] = (),
    ) -> list[bytes]:
        pending = [arriving]
        frames = iter(waited)

        def drain(_fd: int, target: bytearray) -> None:
            if pending:
                target.extend(pending.pop())

        def wait(*_args: object, **_kwargs: object) -> None:
            try:
                output.extend(next(frames))
            except StopIteration:
                self.fail("selector waited for a frame without a state transition")

        with (
            patch.object(h, "read_available", side_effect=drain),
            patch.object(h, "wait_for_output", side_effect=wait),
            patch.object(h.os, "write") as write,
        ):
            h.select_keeper_row(Mock(), 1, output, b"alpha")
        return [call.args[1] for call in write.call_args_list]

    def test_roster_arrives_during_drain_without_down_overshoot(self) -> None:
        output = bytearray(frame(None, clear=True))
        self.assertEqual(self.select(output, arriving=frame(b"alpha")), [])

    def test_empty_roster_waits_for_selection_before_sending_keys(self) -> None:
        output = bytearray(frame(None, clear=True))
        self.assertEqual(self.select(output, waited=(frame(b"alpha"),)), [])

    def test_stale_alpha_highlight_does_not_hide_current_beta_selection(self) -> None:
        output = bytearray(frame(b"alpha", clear=True) + frame(b"beta"))
        self.assertEqual(self.select(output, waited=(frame(b"alpha"),)), [b"\x1b[A"])

    def test_partial_new_frame_settles_before_using_old_selection(self) -> None:
        new = frame(b"beta")
        output = bytearray(frame(b"alpha", clear=True) + new[: -len(h.FRAME_END)])
        self.assertEqual(
            self.select(output, waited=(h.FRAME_END, frame(b"alpha"))), [b"\x1b[A"]
        )

    def test_unrelated_diff_frame_keeps_current_selected_row(self) -> None:
        output = bytearray(
            frame(b"alpha", clear=True)
            + h.FRAME_START
            + b"\x1b[3;1Hclock changed"
            + h.FRAME_END
        )
        self.assertEqual(self.select(output), [])


if __name__ == "__main__":
    main()

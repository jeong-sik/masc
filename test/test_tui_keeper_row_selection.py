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
        name: bytes = b"alpha",
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

        def poll(*_args: object, **_kwargs: object) -> bool:
            try:
                arriving = next(frames)
            except StopIteration:
                return False
            output.extend(arriving)
            return h.FRAME_END in arriving

        with (
            patch.object(h, "read_available", side_effect=drain),
            patch.object(h, "wait_for_output", side_effect=wait),
            patch.object(h, "poll_for_output", side_effect=poll),
            patch.object(h.os, "write") as write,
        ):
            h.select_keeper_row(Mock(), 1, output, name)
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

    def test_selected_last_row_needs_no_new_frame(self) -> None:
        output = bytearray(frame(b"beta", clear=True))
        self.assertEqual(self.select(output, name=b"beta"), [])

    def test_target_below_current_selection_moves_down(self) -> None:
        output = bytearray(frame(b"alpha", clear=True))
        self.assertEqual(
            self.select(output, name=b"beta", waited=(frame(b"beta"),)),
            [b"\x1b[B"],
        )

    def test_arrow_without_a_redraw_can_retry(self) -> None:
        output = bytearray(frame(b"beta", clear=True))
        self.assertEqual(
            self.select(output, waited=(b"", frame(b"alpha"))),
            [b"\x1b[A", b"\x1b[A"],
        )

    def test_intermediate_target_band_is_not_current_selection(self) -> None:
        output = bytearray(frame(b"beta", clear=True))
        self.assertEqual(
            self.select(
                output,
                waited=(frame(b"alpha") + frame(b"beta"), frame(b"alpha")),
            ),
            [b"\x1b[A", b"\x1b[A"],
        )

    def test_polled_partial_target_frame_must_finish(self) -> None:
        output = bytearray(frame(b"beta", clear=True))
        self.assertEqual(
            self.select(
                output, waited=(frame(b"alpha")[:-len(h.FRAME_END)], h.FRAME_END)
            ),
            [b"\x1b[A"],
        )

    def test_missing_target_at_last_row_exhausts_scan_not_frame_wait(self) -> None:
        output = bytearray(frame(b"beta", clear=True))
        with (
            patch.object(h, "read_available"),
            patch.object(h, "wait_for_output") as wait,
            patch.object(h, "poll_for_output", return_value=False) as poll,
            patch.object(h.os, "write") as write,
        ):
            with self.assertRaisesRegex(AssertionError, "gamma.*never became selected"):
                h.select_keeper_row(Mock(), 1, output, b"gamma")
        wait.assert_not_called()
        self.assertEqual(write.call_count, h.KEEPER_ROW_SCAN_BOUND)
        self.assertEqual(
            [call.args[1] for call in write.call_args_list],
            [b"\x1b[B"] * h.KEEPER_ROW_SCAN_BOUND,
        )
        self.assertTrue(all(
            call.kwargs["timeout"] == h.KEEPER_ROW_STEP_TIMEOUT_S
            for call in poll.call_args_list
        ))


if __name__ == "__main__":
    main()

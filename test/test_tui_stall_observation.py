"""Timeout diagnostics retain observations made before a wait starts."""

import os
import unittest
from unittest.mock import Mock, patch

import test_tui_keyboard_input as h

SOURCE_MODULES = ("test/test_tui_keyboard_input.py",)


class StallObservation(unittest.TestCase):
    def test_pre_wait_silence_and_cpu_baseline_survive_reads_and_waits(self):
        output = h.PtyOutput()
        output.pid = 42
        process = Mock(pid=42)
        process.poll.return_value = None
        reader, writer = os.pipe()
        os.set_blocking(reader, False)
        try:
            os.write(writer, b"first frame")
            with patch.object(h.time, "monotonic", return_value=10.0), \
                 patch.object(h, "_child_cpu_ticks", return_value=(100, 200)):
                h.read_available(reader, output)
            # A successful wait with no new bytes must not reset the baseline.
            with patch.object(h.time, "monotonic", return_value=14.0):
                h.wait_for_output(process, reader, output, b"first", start=0, timeout=3)
                h.read_available(reader, output)
            with patch.object(h.time, "monotonic", side_effect=[14., 14., 17., 17.]), \
                 patch.object(h, "_child_cpu_ticks", return_value=(300, 500)), \
                 patch.object(h.os, "sysconf", return_value=100):
                with self.assertRaises(AssertionError) as error:
                    h.wait_for_output(process, reader, output, b"missing", start=0, timeout=3)
            text = str(error.exception)
            self.assertIn("silence 7.00s (wait ran 3.00s", text)
            self.assertIn("at last byte 1.00s/2.00s", text)
            self.assertIn("delta +2.00s/+3.00s", text)
        finally:
            os.close(reader)
            os.close(writer)

    def test_sessions_do_not_share_observations(self):
        first, second = h.PtyOutput(), h.PtyOutput()
        first.last_byte_at = 10.0
        first.last_byte_ticks = (1, 2)
        self.assertIsNone(second.last_byte_at)
        self.assertIsNone(second.last_byte_ticks)
        with patch.object(h, "_child_cpu_ticks", return_value=(3, 4)):
            text = h._stall_line(Mock(pid=42), second, started_at=0,
                                 started_len=0, last_byte_at=None, last_byte_ticks=None)
        self.assertIn("last byte unavailable", text)
        self.assertIn("child utime/stime unavailable", text)


if __name__ == "__main__":
    unittest.main()

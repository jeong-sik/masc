"""The standalone confirmation CLI does not wait indefinitely for HTTP."""
import importlib.util
from pathlib import Path
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'goal_confirmation_deadline.py'
spec = importlib.util.spec_from_file_location('goal_confirmation_deadline', SCRIPT)
deadline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deadline)


class DeadlineTest(unittest.TestCase):
    def test_total_deadline_interrupts_a_stalled_operation(self):
        with self.assertRaises(TimeoutError):
            with deadline.request_deadline(0.02):
                time.sleep(0.2)


if __name__ == '__main__':
    unittest.main()

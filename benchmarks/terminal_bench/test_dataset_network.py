"""A verifier's isolation requirement must be respected before a long run."""
from pathlib import Path
import tempfile
import unittest

from dataset_plan import Capacity, TaskNeeds, plan, read_needs


class NetworkScope(unittest.TestCase):
    def test_separate_verifier_can_make_a_task_unrunnable(self):
        with tempfile.TemporaryDirectory() as root:
            task = Path(root) / "task"
            task.mkdir()
            (task / "task.toml").write_text('''
[task]
name = "separate-verifier"
[environment]
cpus = 2
[verifier.environment]
cpus = 2
allow_internet = false
''')
            needs = read_needs(Path(root))
        unsupported = plan(needs, Capacity(16, 16384, False), 1)
        self.assertEqual(unsupported.excluded_for_network, ("separate-verifier",))
        supported = plan(needs, Capacity(16, 16384, False, True), 1)
        self.assertEqual(supported.excluded_for_network, ())

    def test_unsupported_tasks_do_not_inflate_runnable_capacity(self):
        needs = [TaskNeeds("public", 2, 2048, 0),
                 TaskNeeds("isolated", 32, 65536, 0, True)]
        result = plan(needs, Capacity(4, 4096, False), 1)
        self.assertEqual(result.excluded_for_network, ("isolated",))
        self.assertEqual(result.over_capacity, ())


if __name__ == "__main__":
    unittest.main()

"""An essential behavior selection must name explicit suites; empty never means all."""
import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

CI = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CI))
load_profile = importlib.import_module("release_behavior").load_profile


class ReleaseBehavior(unittest.TestCase):
    def test_checked_in_profile_loads(self):
        profile = load_profile()
        self.assertTrue(profile["suites"])

    def test_empty_or_duplicate_selection_never_means_full_suite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profile.json"
            for suites in ([], ["test_one", "test_one"], [""], ["test_one,test_two"]):
                path.write_text(json.dumps({"profile": "release-essential-v1", "suites": suites}))
                with self.assertRaises(ValueError):
                    load_profile(path)


if __name__ == "__main__":
    unittest.main()

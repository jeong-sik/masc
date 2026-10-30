"""Run the operator quiz package's Python tests from the repository test lane."""
from pathlib import Path
import sys
import unittest

if __name__ == "__main__":
    tests = Path(__file__).resolve().parents[1] / "addons/tests"
    sys.path.insert(0, str(tests))
    suite = unittest.defaultTestLoader.discover(str(tests), pattern="test_operator_quiz_*.py",
                                                top_level_dir=str(tests))
    sys.exit(0 if unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful() else 1)

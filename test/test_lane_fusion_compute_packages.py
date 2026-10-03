"""Run isolated Fusion subprocess composition from the targeted CI lane."""
from pathlib import Path
import sys
import unittest

if __name__ == "__main__":
    directory = Path(__file__).resolve().parents[1] / "addons/tests"
    sys.path.insert(0, str(directory))
    suite = unittest.defaultTestLoader.discover(str(directory), pattern="test_fusion*.py")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)

"""Run the two quiz packages' stdio scenarios from the repository test lane."""
from pathlib import Path
import runpy
import sys

if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "addons/tests"))
    runpy.run_path(
        str(Path(__file__).resolve().parents[1] / "addons/tests/test_quiz_lane.py"),
        run_name="__main__",
    )

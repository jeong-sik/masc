"""Run the two quiz packages' stdio scenarios from the repository test lane."""
from pathlib import Path
import runpy

if __name__ == "__main__":
    runpy.run_path(
        str(Path(__file__).resolve().parents[1] / "addons/tests/test_quiz_lane.py"),
        run_name="__main__",
    )

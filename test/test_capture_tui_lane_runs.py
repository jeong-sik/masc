import importlib.util
import sys
import tempfile
import types
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "capture-tui-lane-runs.py"


def load_module():
    try:
        import playwright.sync_api  # noqa: F401
    except ModuleNotFoundError:
        playwright = types.ModuleType("playwright")
        sync_api = types.ModuleType("playwright.sync_api")
        sync_api.Browser = object
        sync_api.Page = object
        sync_api.sync_playwright = None
        playwright.sync_api = sync_api
        sys.modules["playwright"] = playwright
        sys.modules["playwright.sync_api"] = sync_api

    spec = importlib.util.spec_from_file_location("capture_tui_lane_runs", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


capture = load_module()


class CaptureTuiLaneRunsTest(unittest.TestCase):
    def test_lane_index_reads_only_matrix_rows(self):
        screen = "\n".join(
            [
                "Board Attention idle slots one active 0  runs 3  ok/fail/cancel 3/0/0",
                "Verifier idle slots two active 0  runs 2  ok/fail/cancel 1/1/0",
                "Verifier · selected-row detail is not another matrix row",
            ]
        )
        self.assertEqual(capture.standalone_lane_index(screen, "Verifier"), 1)

    def test_exact_run_index_does_not_require_a_retired_box_border(self):
        screen = "\n".join(
            [
                "STARTED SUBJECT STATUS ELAPSED SLOT RUN ID",
                "09-01 10:00:00 actor running — slot run-new",
                "09-01 09:59:00 actor succeeded 1.0s slot run-done",
            ]
        )
        self.assertEqual(capture.first_succeeded_row_index(screen), 1)

    def test_verifier_status_recovers_a_truncated_typed_label(self):
        screen = "\n".join(
            [
                "STARTED SUBJECT STATUS ELAPSED SLOT RUN ID",
                "09-01 10:00:00 task-1 running — slot run-new",
                "09-01 09:59:00 task-2 infrastruc~ 1.0s slot run-done",
            ]
        )
        self.assertEqual(
            capture.first_terminal_verifier_row(screen),
            (1, "infrastructure_unavailable"),
        )

    def test_split_heading_requires_both_titles_on_one_row(self):
        capture.require_split_heading(
            "INPUT · PROMPT PAYLOAD  1-4/4 │ OUTPUT · MODEL RESPONSE  1-2/2",
            "INPUT · PROMPT PAYLOAD",
            "OUTPUT · MODEL RESPONSE",
        )
        with self.assertRaises(capture.WaitFailed):
            capture.require_split_heading(
                "INPUT · PROMPT PAYLOAD\nOUTPUT · MODEL RESPONSE",
                "INPUT · PROMPT PAYLOAD",
                "OUTPUT · MODEL RESPONSE",
            )

    def test_executable_digest_is_recordable(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "masc_tui.exe"
            executable.write_bytes(b"exact-head-binary")
            self.assertEqual(
                capture.sha256_file(executable),
                "03ec85482967cdf3ba8c5643c48bc1069355a2af1c61e796853f7cb16f1257e8",
            )


if __name__ == "__main__":
    unittest.main()

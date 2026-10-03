import importlib.util
import sys
import subprocess
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "capture-tui-lane-runs.py"


def load_module():
    try:
        import playwright.sync_api  # noqa: F401
    except ModuleNotFoundError:
        playwright = types.ModuleType("playwright")
        sync_api = types.ModuleType("playwright.sync_api")
        sync_api.__dict__.update(Browser=object, Page=object, sync_playwright=None)
        playwright.__dict__["sync_api"] = sync_api
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
    def session(self, browser):
        return capture.ttyd_session(
            browser, REPO_ROOT, 1, 80, 24, "test", Path("/bin/cat"), None
        )

    def test_startup_log_is_file_backed_bounded_and_closed_on_failure(self):
        process = Mock()
        sinks = []

        def launch(*_args, **kwargs):
            sink = kwargs["stdout"]
            sinks.append(sink)
            sink.write(b"discarded-prefix" + b"x" * 5000 + b" startup-failure")
            sink.flush()
            return process

        with (
            patch.object(capture.subprocess, "Popen", side_effect=launch),
            patch.object(
                capture, "wait_port", side_effect=TimeoutError("ttyd did not listen")
            ),
        ):
            with self.assertRaises(TimeoutError) as raised:
                with self.session(Mock()):
                    self.fail("startup must fail")
        self.assertIn("startup-failure", str(raised.exception))
        self.assertNotIn("discarded-prefix", str(raised.exception))
        self.assertLess(len(str(raised.exception)), 4200)
        self.assertTrue(sinks[0].closed)
        process.terminate.assert_called_once()
        process.wait.assert_called_once_with(timeout=5)

    def test_startup_diagnostic_redacts_bearer_crossing_tail_boundary(self):
        process = Mock()
        bearer = "test-private-bearer"

        def launch(*_args, **kwargs):
            sink = kwargs["stdout"]
            sink.write(bearer.encode() + b"x" * 4090)
            sink.flush()
            return process

        with (
            patch.dict(capture.os.environ, {"MASC_TOKEN": bearer}),
            patch.object(capture.subprocess, "Popen", side_effect=launch),
            patch.object(
                capture, "wait_port", side_effect=RuntimeError("ttyd exited early")
            ),
        ):
            with self.assertRaises(RuntimeError) as raised:
                with self.session(Mock()):
                    self.fail("startup must fail")
        self.assertNotIn("bearer", str(raised.exception))
        self.assertNotIn(bearer, str(raised.exception))

    def test_cleanup_reaps_killed_process_even_when_browser_close_fails(self):
        process = Mock()
        process.wait.side_effect = [subprocess.TimeoutExpired("ttyd", 5), 0]
        browser = Mock()
        browser.new_context.return_value.close.side_effect = RuntimeError(
            "browser close failed"
        )
        with (
            patch.object(capture.subprocess, "Popen", return_value=process),
            patch.object(capture, "wait_port"),
        ):
            with self.assertRaisesRegex(RuntimeError, "browser close failed"):
                with self.session(browser):
                    pass
        process.terminate.assert_called_once()
        process.kill.assert_called_once()
        self.assertEqual(process.wait.call_count, 2)

    @unittest.skipUnless(capture.TTYD.is_file(), "installed ttyd required")
    def test_installed_ttyd_reaches_readiness_and_is_reaped(self):
        # No browser connection: ttyd never launches /bin/cat or contacts a runtime.
        processes = []
        real_popen = subprocess.Popen

        def launch(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            processes.append(process)
            return process

        with patch.object(capture.subprocess, "Popen", side_effect=launch):
            with self.session(Mock()):
                self.assertIsNone(processes[0].poll())
        self.assertIsNotNone(processes[0].returncode)

    def test_lane_index_reads_only_matrix_rows(self):
        screen = "\n".join(
            [
                "● Board Attention idle slots one active 0  runs 3  ok/fail/cancel 3/0/0",
                "⠋ HITL Auto Judge running 3.2s slots an-extremely-long-fallback-chain…",
                "● Librarian idle slots another-clipped-slot-list…",
                "● Verifier idle slots two active 0  runs 2  ok/fail/cancel 1/1/0",
                "Verifier · selected-row detail is not another matrix row",
            ]
        )
        labels = capture.standalone_lane_labels(screen)
        self.assertEqual(
            labels,
            ["Board Attention", "HITL Auto Judge", "Librarian", "Verifier"],
        )
        self.assertEqual(capture.standalone_lane_index(screen, "Verifier"), 3)
        self.assertEqual(capture.selected_standalone_label(screen, labels), "Verifier")

    def test_exact_run_index_does_not_require_a_retired_box_border(self):
        screen = "\n".join(
            [
                "STARTED SUBJECT STATUS ELAPSED SLOT",
                "09-01 10:00:00 actor running — slot",
                "09-01 09:59:00 actor succeeded 1.0s slot",
            ]
        )
        self.assertEqual(capture.first_succeeded_row_index(screen), 1)

    def test_verifier_status_recovers_a_truncated_typed_label(self):
        screen = "\n".join(
            [
                "STARTED SUBJECT STATUS ELAPSED SLOT",
                "09-01 10:00:00 task-1 running — slot",
                "09-01 09:59:00 task-2 infrastruc… 1.0s slot",
            ]
        )
        self.assertEqual(
            capture.first_terminal_verifier_row(screen),
            (1, "infrastructure_unavailable"),
        )

    def test_split_heading_requires_both_titles_on_one_row(self):
        capture.require_split_heading(
            "INPUT · RUN INPUT  1-4/4 │ OUTPUT · RUN RESULT  1-2/2",
            "INPUT · RUN INPUT",
            "OUTPUT · RUN RESULT",
        )
        with self.assertRaises(capture.WaitFailed):
            capture.require_split_heading(
                "INPUT · RUN INPUT\nOUTPUT · RUN RESULT",
                "INPUT · RUN INPUT",
                "OUTPUT · RUN RESULT",
            )

    def test_executable_digest_is_recordable(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "masc_tui.exe"
            executable.write_bytes(b"exact-head-binary")
            self.assertEqual(
                capture.sha256_file(executable),
                "03ec85482967cdf3ba8c5643c48bc1069355a2af1c61e796853f7cb16f1257e8",
            )

    def test_token_file_requires_exactly_one_non_empty_line(self):
        with tempfile.TemporaryDirectory() as directory:
            token_file = Path(directory) / "operator.token"
            token_file.write_text("secret-bearer\n", encoding="utf-8")
            self.assertEqual(capture.read_token_file(token_file), "secret-bearer")
            token_file.write_text("first\nsecond\n", encoding="utf-8")
            with self.assertRaises(ValueError):
                capture.read_token_file(token_file)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "goal_loop_live_replay.py"
FIXTURE_DIR = REPO_ROOT / "test" / "fixtures" / "goal_loop"

spec = importlib.util.spec_from_file_location("goal_loop_live_replay", SCRIPT_PATH)
assert spec is not None
goal_loop_live_replay = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = goal_loop_live_replay
spec.loader.exec_module(goal_loop_live_replay)


def read_json(path: Path) -> dict[str, object]:
    data = json.loads(path.read_text(encoding="utf-8"))
    assert isinstance(data, dict)
    return data


class GoalLoopLiveReplayTest(unittest.TestCase):
    def test_replay_writes_pass_artifacts_for_clean_log(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            log_path = root / "server.log"
            artifact_dir = root / "artifacts"
            log_path.write_text(
                "[INFO] provider_health_probe_completed provider=ollama\n",
                encoding="utf-8",
            )

            summary = goal_loop_live_replay.replay_logs(
                log_paths=[str(log_path)],
                artifact_dir=artifact_dir,
                duration_seconds=0,
                act_map_path=None,
                loop_iteration="test-clean",
                verify_policy="critical",
                max_samples=2,
                runtime_source="unit-test",
                base_path="/tmp/masc",
            )

            self.assertEqual(summary.verify_status, "PASS")
            self.assertEqual(summary.overall_status, "ok")
            self.assertTrue((artifact_dir / "metadata.json").is_file())
            self.assertTrue((artifact_dir / "observe.json").is_file())
            status = read_json(artifact_dir / "status.json")
            self.assertEqual(status["loop_iteration"], "test-clean")
            self.assertEqual(status["overall_status"], "ok")
            verify_summary = status["phases"]["verify"]["summary"]
            self.assertIs(verify_summary["post_act_verify"], True)
            self.assertEqual(verify_summary["evidence_kind"], "live_runtime_logs")
            self.assertIn("runtime_source=unit-test", verify_summary["evidence_source"])
            self.assertIsInstance(verify_summary["evidence_window_start"], str)
            self.assertIsInstance(verify_summary["evidence_window_end"], str)
            self.assertIsInstance(verify_summary["checked_at"], str)
            self.assertEqual(verify_summary["violation_kinds"], [])
            expected_base_path = goal_loop_live_replay.normalize_base_path("/tmp/masc")
            verify = read_json(artifact_dir / "verify.json")
            self.assertIs(verify["post_act_verify"], True)
            self.assertEqual(verify["evidence_kind"], "live_runtime_logs")
            self.assertIn("runtime_source=unit-test", verify["evidence_source"])
            self.assertIn(
                f"base_path={expected_base_path}", verify_summary["evidence_source"]
            )
            self.assertIn(f"base_path={expected_base_path}", verify["evidence_source"])
            self.assertIsInstance(verify["evidence_window_start"], str)
            self.assertIsInstance(verify["evidence_window_end"], str)
            self.assertIsInstance(verify["checked_at"], str)
            metadata = read_json(artifact_dir / "metadata.json")
            self.assertEqual(metadata["max_samples"], 2)
            self.assertEqual(metadata["max_samples_requested"], 2)
            self.assertEqual(metadata["max_samples_effective"], 2)

    def test_replay_metadata_records_requested_and_effective_max_samples(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            log_path = root / "server.log"
            artifact_dir = root / "artifacts"
            log_path.write_text(
                "[INFO] provider_health_probe_completed provider=ollama\n",
                encoding="utf-8",
            )

            goal_loop_live_replay.replay_logs(
                log_paths=[str(log_path)],
                artifact_dir=artifact_dir,
                duration_seconds=0,
                act_map_path=None,
                loop_iteration="test-negative-max-samples",
                verify_policy="critical",
                max_samples=-7,
                runtime_source="unit-test",
                base_path=None,
            )

            metadata = read_json(artifact_dir / "metadata.json")
            self.assertEqual(metadata["max_samples_requested"], -7)
            self.assertEqual(metadata["max_samples_effective"], 0)
            self.assertEqual(metadata["max_samples"], 0)

    def test_replay_can_publish_dashboard_status_for_base_path(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            log_path = root / "server.log"
            artifact_dir = root / "artifacts"
            base_path = root / "base"
            log_path.write_text(
                "[INFO] provider_health_probe_completed provider=ollama\n",
                encoding="utf-8",
            )

            summary = goal_loop_live_replay.replay_logs(
                log_paths=[str(log_path)],
                artifact_dir=artifact_dir,
                duration_seconds=0,
                act_map_path=None,
                loop_iteration="test-dashboard-publish",
                verify_policy="critical",
                max_samples=2,
                runtime_source="unit-test",
                base_path=str(base_path),
                publish_dashboard_status=True,
            )

            normalized_base_path = base_path.resolve(strict=False)
            dashboard_status_path = (
                normalized_base_path / ".masc" / "goal-loop" / "status.json"
            )
            self.assertEqual(summary.dashboard_status_json, str(dashboard_status_path))
            self.assertTrue(dashboard_status_path.is_file())
            self.assertEqual(
                read_json(dashboard_status_path),
                read_json(artifact_dir / "status.json"),
            )
            metadata = read_json(artifact_dir / "metadata.json")
            self.assertEqual(
                metadata["dashboard_status_json"], str(dashboard_status_path)
            )

    def test_replay_normalizes_tilde_base_path_for_dashboard_publish(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            home = root / "home"
            home.mkdir()
            log_path = root / "server.log"
            artifact_dir = root / "artifacts"
            log_path.write_text(
                "[INFO] provider_health_probe_completed provider=ollama\n",
                encoding="utf-8",
            )

            with mock.patch.dict(os.environ, {"HOME": str(home)}):
                summary = goal_loop_live_replay.replay_logs(
                    log_paths=[str(log_path)],
                    artifact_dir=artifact_dir,
                    duration_seconds=0,
                    act_map_path=None,
                    loop_iteration="test-dashboard-publish-tilde",
                    verify_policy="critical",
                    max_samples=2,
                    runtime_source="unit-test",
                    base_path="~/runtime",
                    publish_dashboard_status=True,
                )

            normalized_base_path = (home / "runtime").resolve(strict=False)
            dashboard_status_path = (
                normalized_base_path / ".masc" / "goal-loop" / "status.json"
            )
            self.assertEqual(summary.dashboard_status_json, str(dashboard_status_path))
            self.assertTrue(dashboard_status_path.is_file())
            metadata = read_json(artifact_dir / "metadata.json")
            self.assertEqual(metadata["base_path"], str(normalized_base_path))
            self.assertEqual(
                metadata["dashboard_status_json"], str(dashboard_status_path)
            )
            verify = read_json(artifact_dir / "verify.json")
            self.assertIn(
                f"base_path={normalized_base_path}", verify["evidence_source"]
            )

    def test_dashboard_status_publish_requires_base_path(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            log_path = root / "server.log"
            log_path.write_text(
                "[INFO] provider_health_probe_completed provider=ollama\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "requires --base-path"):
                goal_loop_live_replay.replay_logs(
                    log_paths=[str(log_path)],
                    artifact_dir=root / "artifacts",
                    duration_seconds=0,
                    act_map_path=None,
                    loop_iteration="test-dashboard-publish-missing-base",
                    verify_policy="critical",
                    max_samples=2,
                    runtime_source="unit-test",
                    base_path=None,
                    publish_dashboard_status=True,
                )

            with self.assertRaisesRegex(ValueError, "requires --base-path"):
                goal_loop_live_replay.replay_logs(
                    log_paths=[str(log_path)],
                    artifact_dir=root / "artifacts-blank",
                    duration_seconds=0,
                    act_map_path=None,
                    loop_iteration="test-dashboard-publish-blank-base",
                    verify_policy="critical",
                    max_samples=2,
                    runtime_source="unit-test",
                    base_path="   ",
                    publish_dashboard_status=True,
                )

    def test_normalize_base_path_resolves_absolute_segments(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            raw_path = root / "nested" / ".." / "runtime"

            self.assertEqual(
                goal_loop_live_replay.normalize_base_path(str(raw_path)),
                str((root / "runtime").resolve(strict=False)),
            )

    def test_write_json_atomic_ignores_predictable_temp_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            target = root / "status.json"
            victim = root / "victim.json"
            predictable_temp = target.with_name(f".{target.name}.{os.getpid()}.tmp")
            victim.write_text("do not clobber\n", encoding="utf-8")
            predictable_temp.symlink_to(victim)

            goal_loop_live_replay.write_json_atomic(target, {"ok": True})

            self.assertEqual(victim.read_text(encoding="utf-8"), "do not clobber\n")
            self.assertEqual(read_json(target), {"ok": True})
            self.assertTrue(predictable_temp.is_symlink())

    def test_write_json_atomic_keeps_recreated_temp_after_replace(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            target = root / "status.json"
            temp_path = root / ".status.json.fixed.tmp"
            original_replace = Path.replace

            def fake_mkstemp(
                *,
                prefix: str,
                suffix: str,
                dir: Path,
                text: bool,
            ) -> tuple[int, str]:
                self.assertTrue(prefix.startswith(".status.json."))
                self.assertEqual(suffix, ".tmp")
                self.assertEqual(Path(dir), root)
                self.assertTrue(text)
                fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                return fd, str(temp_path)

            def replace_and_recreate(self: Path, target_path: Path) -> Path:
                result = original_replace(self, target_path)
                if self == temp_path:
                    self.write_text("owned by another writer\n", encoding="utf-8")
                return result

            with (
                mock.patch.object(
                    goal_loop_live_replay.tempfile,
                    "mkstemp",
                    side_effect=fake_mkstemp,
                ),
                mock.patch.object(Path, "replace", replace_and_recreate),
            ):
                goal_loop_live_replay.write_json_atomic(target, {"ok": True})

            self.assertEqual(read_json(target), {"ok": True})
            self.assertEqual(
                temp_path.read_text(encoding="utf-8"),
                "owned by another writer\n",
            )

    def test_capture_window_reads_from_start_after_truncation(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            log_path = root / "server.log"
            artifact_dir = root / "artifacts"
            log_path.write_text("old line before capture\n", encoding="utf-8")

            def truncate_during_sleep(_duration: float) -> None:
                log_path.write_text("new\n", encoding="utf-8")

            with mock.patch.object(
                goal_loop_live_replay.time,
                "sleep",
                side_effect=truncate_during_sleep,
            ):
                captured = goal_loop_live_replay.capture_log_window(
                    [str(log_path)],
                    artifact_dir=artifact_dir,
                    duration_seconds=1.0,
                )

            captured_text = Path(captured[0]).read_text(encoding="utf-8")
            self.assertEqual(captured_text, "new\n")

    def test_replay_keeps_loop_red_when_critical_signature_remains(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            log_path = root / "server.log"
            artifact_dir = root / "artifacts"
            log_path.write_text(
                "[WARN] [Auth] archived credential sangsu.json "
                "(reason: bare-form keeper credential is dead after "
                "PR-3b1 starvation)\n",
                encoding="utf-8",
            )

            summary = goal_loop_live_replay.replay_logs(
                log_paths=[str(log_path)],
                artifact_dir=artifact_dir,
                duration_seconds=0,
                act_map_path=str(FIXTURE_DIR / "act-map.startup.json"),
                loop_iteration="test-fail",
                verify_policy="critical",
                max_samples=2,
                runtime_source="unit-test",
                base_path=None,
            )

            self.assertEqual(summary.verify_status, "FAIL")
            self.assertEqual(summary.overall_status, "critical")
            decide = read_json(artifact_dir / "decide.json")
            self.assertEqual(decide["act_missing_count"], 0)
            self.assertEqual(decide["act_linked_count"], 1)
            verify = read_json(artifact_dir / "verify.json")
            self.assertEqual(verify["failing_findings"][0]["finding_id"], "NF-2")
            self.assertIs(verify["post_act_verify"], True)

    def test_cli_fails_on_verify_and_writes_status_json(self) -> None:
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            log_path = root / "server.log"
            artifact_dir = root / "artifacts"
            log_path.write_text(
                "[WARN] [Keeper] executor: alive-but-stuck detected\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--log",
                    str(log_path),
                    "--artifact-dir",
                    str(artifact_dir),
                    "--act-map",
                    str(FIXTURE_DIR / "act-map.startup.json"),
                    "--loop-iteration",
                    "cli-fail",
                    "--runtime-source",
                    "cli-test",
                    "--base-path",
                    "/tmp/masc",
                    "--fail-on",
                    "verify",
                    "--format",
                    "text",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("GOAL LOOP Live Replay: critical", result.stdout)
            status = read_json(artifact_dir / "status.json")
            self.assertEqual(status["loop_iteration"], "cli-fail")
            self.assertEqual(status["overall_status"], "critical")
            verify_summary = status["phases"]["verify"]["summary"]
            self.assertIs(verify_summary["post_act_verify"], True)
            self.assertIn("runtime_source=cli-test", verify_summary["evidence_source"])
            expected_base_path = goal_loop_live_replay.normalize_base_path("/tmp/masc")
            self.assertIn(
                f"base_path={expected_base_path}", verify_summary["evidence_source"]
            )
            verify = read_json(artifact_dir / "verify.json")
            self.assertIn("runtime_source=cli-test", verify["evidence_source"])
            self.assertIn(f"base_path={expected_base_path}", verify["evidence_source"])

    def test_cli_publish_dashboard_status_writes_under_base_path(self) -> None:
        # Exercise --publish-dashboard-status end-to-end through the CLI so a
        # future refactor that drops the wiring (e.g., main() forgetting to
        # pass the flag through to replay_logs) would fail this test rather
        # than silently dropping the dashboard publish path.
        with tempfile.TemporaryDirectory() as raw_dir:
            root = Path(raw_dir)
            base_path = root / "base"
            base_path.mkdir()
            log_path = root / "server.log"
            artifact_dir = root / "artifacts"
            log_path.write_text(
                "[WARN] [Keeper] executor: alive-but-stuck detected\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--log",
                    str(log_path),
                    "--artifact-dir",
                    str(artifact_dir),
                    "--act-map",
                    str(FIXTURE_DIR / "act-map.startup.json"),
                    "--loop-iteration",
                    "cli-publish",
                    "--runtime-source",
                    "cli-test",
                    "--base-path",
                    str(base_path),
                    "--publish-dashboard-status",
                    "--format",
                    "text",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            published = base_path / ".masc" / "goal-loop" / "status.json"
            self.assertTrue(
                published.exists(),
                f"dashboard status not published: stdout={result.stdout} stderr={result.stderr}",
            )
            status = read_json(published)
            self.assertEqual(status["loop_iteration"], "cli-publish")


if __name__ == "__main__":
    unittest.main()

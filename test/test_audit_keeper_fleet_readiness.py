import importlib.util
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1] / "scripts" / "audit-keeper-fleet-readiness.py"
)


def load_audit_module():
    spec = importlib.util.spec_from_file_location(
        "audit_keeper_fleet_readiness", SCRIPT_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


audit = load_audit_module()


def audit_args(base_path: Path, expected_keepers: int):
    return SimpleNamespace(
        base_path=str(base_path),
        expected_keepers=expected_keepers,
        max_silence_hours=2400.0,
        require_board_evidence=True,
        require_pr_surface_evidence=False,
        require_pr_review_evidence=False,
        require_pr_create_evidence=False,
        require_git_push_evidence=False,
        require_pr_approve_evidence=False,
        require_pr_lifecycle_evidence=False,
        require_docker_pr_create_evidence=False,
        require_docker_git_push_evidence=False,
        require_docker_pr_approve_evidence=False,
        require_docker_pr_lifecycle_evidence=False,
    )


def write_ready_keeper(root: Path, name: str) -> None:
    config_dir = root / ".masc" / "config" / "keepers"
    runtime_dir = root / ".masc" / "keepers"
    credential_dir = root / ".masc" / "github-identities" / "anyang-keepers" / "gh"
    config_dir.mkdir(parents=True, exist_ok=True)
    runtime_dir.mkdir(parents=True, exist_ok=True)
    credential_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / f"{name}.toml").write_text(
        "\n".join(
            [
                "[keeper]",
                'sandbox_profile = "docker"',
                'network_mode = "inherit"',
                'tool_preset = "coding"',
                'github_identity = "anyang-keepers"',
                'git_identity_mode = "github_identity"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    (runtime_dir / f"{name}.json").write_text(
        json.dumps(
            {
                "sandbox_profile": "docker",
                "network_mode": "inherit",
                "tool_preset": "coding",
                "github_identity": "anyang-keepers",
                "git_identity_mode": "github_identity",
                "last_turn_ts": time.time(),
            }
        ),
        encoding="utf-8",
    )
    (runtime_dir / f"{name}.decisions.jsonl").write_text(
        json.dumps(
            {
                "ts_unix": time.time(),
                "event": "tool_exec",
                "tool": "keeper_board_post",
                "ok": True,
            }
        )
        + "\n",
        encoding="utf-8",
    )


class AuditKeeperFleetReadinessTest(unittest.TestCase):
    def test_iter_jsonl_streams_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log_path = root / "events.jsonl"
            log_path.write_text(
                json.dumps({"a": 1}) + "\n\n" + json.dumps({"b": 2}) + "\n",
                encoding="utf-8",
            )

            rows = audit.iter_jsonl(log_path)

            self.assertNotIsInstance(rows, list)
            self.assertEqual(next(rows), {"a": 1})
            self.assertEqual(next(rows), {"b": 2})
            with self.assertRaises(StopIteration):
                next(rows)
            self.assertEqual(list(audit.iter_jsonl(root / "missing.jsonl")), [])

    def test_pr_action_metric_paths_returns_newest_date_split_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metrics_root = root / ".masc" / "keepers" / "alpha" / "pr-action-metrics"
            for relative_path in (
                "2026-04/30.jsonl",
                "2026-05/05.jsonl",
                "2026-05/06.jsonl",
            ):
                path = metrics_root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("{}\n", encoding="utf-8")

            paths = audit.pr_action_metric_paths(root, "alpha")

        self.assertEqual(
            [path.relative_to(metrics_root).as_posix() for path in paths],
            ["2026-05/06.jsonl", "2026-05/05.jsonl", "2026-04/30.jsonl"],
        )

    def test_decision_lifecycle_evidence_ignores_git_push_markers(self):
        row = {
            "event": "tool_exec",
            "tool": "masc_code_git",
            "ok": True,
            "action": "push",
            "via": "docker",
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_decision(row)

        self.assertEqual(evidence, set())
        self.assertEqual(docker_evidence, set())

    def test_decision_lifecycle_evidence_handles_non_string_tool(self):
        row = {
            "event": "tool_exec",
            "tool": {"name": "keeper_shell"},
            "ok": True,
            "result_markers": ["gh pr create"],
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_decision(row)

        self.assertEqual(evidence, set())
        self.assertEqual(docker_evidence, set())

    def test_lifecycle_evidence_ignores_freeform_command_mentions(self):
        row = {
            "event": "tool_exec",
            "tool": "keeper_shell",
            "ok": True,
            "cmd": "echo gh pr create && echo git push && echo via=docker",
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_decision(row)

        self.assertEqual(evidence, set())
        self.assertEqual(docker_evidence, set())

    def test_lifecycle_evidence_uses_structured_markers(self):
        row = {
            "event": "tool_exec",
            "tool": "keeper_shell",
            "ok": True,
            "result_markers": ["gh pr create", "via=brokered"],
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_decision(row)

        self.assertEqual(evidence, {"pr_create:keeper_shell:gh_pr_create"})
        self.assertEqual(docker_evidence, {"pr_create:keeper_shell:gh_pr_create"})

    def test_lifecycle_evidence_does_not_treat_sandbox_as_docker_route(self):
        row = {
            "event": "tool_exec",
            "tool": "keeper_pr_create",
            "ok": True,
            "sandbox_profile": "docker",
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_decision(row)

        self.assertEqual(evidence, {"pr_create:keeper_pr_create"})
        self.assertEqual(docker_evidence, set())

    def test_lifecycle_evidence_does_not_treat_plain_docker_marker_as_route(self):
        row = {
            "event": "tool_exec",
            "tool": "keeper_pr_create",
            "ok": True,
            "result_markers": ["docker"],
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_decision(row)

        self.assertEqual(evidence, {"pr_create:keeper_pr_create"})
        self.assertEqual(docker_evidence, set())

    def test_action_metric_git_push_drives_lifecycle_evidence(self):
        row = {
            "ts_unix": 30.0,
            "metric_event": "keeper_pr_work_action",
            "tool_name": "masc_code_git",
            "pr_work_action": "GIT_PUSH",
            "pr_work_action_source": "masc_code_git",
            "pr_work_action_success": True,
            "route": {"via": "docker"},
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_action_metric(row)

        self.assertEqual(evidence, {"git_push:masc_code_git"})
        self.assertEqual(docker_evidence, {"git_push:masc_code_git"})

    def test_action_metric_brokered_route_counts_as_docker_backed(self):
        row = {
            "metric_event": "keeper_pr_work_action",
            "tool_name": "keeper_pr_create",
            "pr_work_action": "PR_CREATE",
            "pr_work_action_source": "keeper_pr_create",
            "pr_work_action_success": True,
            "route_via": "brokered",
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_action_metric(row)

        self.assertEqual(evidence, {"pr_create:keeper_pr_create"})
        self.assertEqual(docker_evidence, {"pr_create:keeper_pr_create"})

    def test_action_metric_does_not_treat_sandbox_as_docker_route(self):
        row = {
            "metric_event": "keeper_pr_work_action",
            "tool_name": "masc_code_git",
            "pr_work_action": "GIT_PUSH",
            "pr_work_action_source": "masc_code_git",
            "pr_work_action_success": True,
            "sandbox_profile": "docker",
        }

        evidence, docker_evidence = audit.pr_lifecycle_evidence_from_action_metric(row)

        self.assertEqual(evidence, {"git_push:masc_code_git"})
        self.assertEqual(docker_evidence, set())

    def test_scan_keeper_evidence_reads_rotated_decision_logs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            keepers_dir = root / ".masc" / "keepers"
            keepers_dir.mkdir(parents=True)
            base_row = {
                "ts_unix": 10.0,
                "event": "tool_exec",
                "tool": "keeper_pr_create",
                "ok": True,
            }
            rotated_row = {
                "ts_unix": 20.0,
                "event": "tool_exec",
                "tool": "keeper_pr_review_comment",
                "ok": True,
                "result_markers": ["event=APPROVE"],
            }
            (keepers_dir / "alpha.decisions.jsonl").write_text(
                json.dumps(base_row) + "\n",
                encoding="utf-8",
            )
            (keepers_dir / "alpha.decisions.jsonl.1").write_text(
                json.dumps(rotated_row) + "\n",
                encoding="utf-8",
            )

            latest_ts, tools, evidence, docker_evidence = audit.scan_keeper_evidence(
                root, "alpha"
            )

        self.assertEqual(latest_ts, 20.0)
        self.assertEqual(tools, {"keeper_pr_create", "keeper_pr_review_comment"})
        self.assertEqual(
            evidence,
            {"pr_create:keeper_pr_create", "pr_approve:keeper_pr_review_comment"},
        )
        self.assertEqual(docker_evidence, set())

    def test_scan_keeper_evidence_reads_pr_action_metrics(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metrics_dir = (
                root / ".masc" / "keepers" / "alpha" / "pr-action-metrics" / "2026-05"
            )
            metrics_dir.mkdir(parents=True)
            rows = [
                {
                    "ts_unix": 25.0,
                    "metric_event": "keeper_pr_work_action",
                    "tool_name": "keeper_shell",
                    "pr_work_action": "PR_CREATE",
                    "pr_work_action_source": "keeper_shell",
                    "pr_work_action_success": True,
                    "route_via": "brokered",
                },
                {
                    "ts_unix": 30.0,
                    "metric_event": "keeper_pr_work_action",
                    "tool_name": "masc_code_git",
                    "pr_work_action": "GIT_PUSH",
                    "pr_work_action_source": "masc_code_git",
                    "pr_work_action_success": True,
                    "route": {"via": "docker"},
                },
                {
                    "ts_unix": 35.0,
                    "metric_event": "keeper_pr_review_action",
                    "tool_name": "keeper_pr_review_comment",
                    "pr_review_action": "APPROVE",
                    "pr_review_action_success": True,
                    "execution_via": "docker",
                },
                {
                    "ts_unix": 40.0,
                    "metric_event": "keeper_pr_work_action",
                    "tool_name": "masc_code_git",
                    "pr_work_action": "GIT_PUSH",
                    "pr_work_action_source": "masc_code_git",
                    "pr_work_action_success": False,
                    "via": "docker",
                },
            ]
            (metrics_dir / "06.jsonl").write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )

            latest_ts, tools, evidence, docker_evidence = audit.scan_keeper_evidence(
                root, "alpha"
            )

        self.assertEqual(latest_ts, 40.0)
        self.assertEqual(
            tools, {"keeper_shell", "masc_code_git", "keeper_pr_review_comment"}
        )
        self.assertEqual(
            evidence,
            {
                "pr_create:keeper_shell",
                "git_push:masc_code_git",
                "pr_approve:keeper_pr_review_comment",
            },
        )
        self.assertEqual(docker_evidence, evidence)

    def test_pr_action_metric_paths_are_newest_first_and_cutoff(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metrics_dir = root / ".masc" / "keepers" / "alpha" / "pr-action-metrics"
            old_path = metrics_dir / "2026-04" / "30.jsonl"
            new_path = metrics_dir / "2026-05" / "06.jsonl"
            mid_path = metrics_dir / "2026-05" / "05.jsonl"
            for path in (old_path, new_path, mid_path):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("{}\n", encoding="utf-8")

            paths = audit.pr_action_metric_paths(root, "alpha", min_day_key=20260501)

        self.assertEqual(paths, [new_path, mid_path])

    def test_scan_keeper_evidence_skips_old_pr_action_metric_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            metrics_dir = root / ".masc" / "keepers" / "alpha" / "pr-action-metrics"
            old_dir = metrics_dir / "2026-05"
            old_dir.mkdir(parents=True)
            now = 1_778_064_000.0
            old_ts = now - (48 * 3600.0)
            recent_ts = now - 60.0
            (old_dir / "04.jsonl").write_text(
                json.dumps(
                    {
                        "ts_unix": old_ts,
                        "metric_event": "keeper_pr_work_action",
                        "tool_name": "masc_code_git",
                        "pr_work_action": "GIT_PUSH",
                        "pr_work_action_source": "masc_code_git",
                        "pr_work_action_success": True,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            (old_dir / "06.jsonl").write_text(
                json.dumps(
                    {
                        "ts_unix": recent_ts,
                        "metric_event": "keeper_pr_work_action",
                        "tool_name": "keeper_shell",
                        "pr_work_action": "PR_CREATE",
                        "pr_work_action_source": "keeper_shell",
                        "pr_work_action_success": True,
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            latest_ts, tools, evidence, docker_evidence = audit.scan_keeper_evidence(
                root,
                "alpha",
                max_silence_hours=24.0,
                now=now,
            )

        self.assertEqual(latest_ts, recent_ts)
        self.assertEqual(tools, {"keeper_shell"})
        self.assertEqual(evidence, {"pr_create:keeper_shell"})
        self.assertEqual(docker_evidence, set())

    def test_expected_keepers_is_minimum_not_exact_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha")
            write_ready_keeper(root, "bravo")

            report = audit.build_report(audit_args(root, expected_keepers=1))

        self.assertTrue(report["ok"])
        self.assertEqual(report["configured_keepers"], 2)
        self.assertEqual(report["fleet_failures"], [])

    def test_expected_keepers_fails_below_minimum(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write_ready_keeper(root, "alpha")

            report = audit.build_report(audit_args(root, expected_keepers=2))

        self.assertFalse(report["ok"])
        self.assertEqual(
            report["fleet_failures"], ["minimum_2_configured_keepers_got_1"]
        )


if __name__ == "__main__":
    unittest.main()

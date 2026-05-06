import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


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


class AuditKeeperFleetReadinessTest(unittest.TestCase):
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
            "route_markers": ["pr_create:keeper_shell:gh_pr_create"],
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
            "route_markers": ["pr_create:keeper_shell:gh_pr_create", "via=docker"],
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
                "route_markers": ["pr_approve:keeper_pr_review_comment"],
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
                    "route_markers": ["via=docker"],
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


if __name__ == "__main__":
    unittest.main()

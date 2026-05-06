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
                "tool": "keeper_shell",
                "ok": True,
                "route_markers": ["git_push:keeper_shell:git_push"],
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
        self.assertEqual(tools, {"keeper_pr_create", "keeper_shell"})
        self.assertEqual(
            evidence,
            {"pr_create:keeper_pr_create", "git_push:keeper_shell:git_push"},
        )
        self.assertEqual(docker_evidence, set())


if __name__ == "__main__":
    unittest.main()

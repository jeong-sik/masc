"""Deterministic fixture test for scripts/skill-usage-stats.py.

Builds a temporary workspace with two trace event logs and asserts the
cross-session rollup: per-skill totals, the instruction/composition split,
distinct-session counts, and detection of an installed-but-never-activated Skill.
"""

import contextlib
import importlib.util
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

import skill_activation_event_log_fixture as log_fixture

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "skill-usage-stats.py"

spec = importlib.util.spec_from_file_location("skill_usage_stats", SCRIPT)
assert spec is not None and spec.loader is not None
stats = importlib.util.module_from_spec(spec)
# Register before exec: @dataclass on Python 3.14 resolves cls.__module__ via
# sys.modules, which is None for an unregistered importlib module.
sys.modules["skill_usage_stats"] = stats
spec.loader.exec_module(stats)


def _activation(name, kind, at, runtime="r1", source="project-masc"):
    if kind == "composition":
        invocation = {
            "kind": kind,
            "origin": {"kind": "session_composition"},
            "tool_name": f"keeper_compose_{name}",
        }
    else:
        invocation = {
            "kind": kind,
            "origin": {"kind": "session_instruction"},
            "served_content": {"kind": "skill_body", "bytes": 4, "sha256": "e" * 64},
        }
    return {
        "identity": {"source_id": source, "package_id": name, "name": name},
        "content_revision": "c" * 64,
        "snapshot_revision": "d" * 64,
        "runtime_id": runtime,
        "agent_core_turn": 1,
        "invocation": invocation,
        "delivery": {
            "boundary": {"kind": "model_response", "agent_core_turn": 2},
            "runtime_id": runtime,
            "delivered_at": at,
            "content_bytes": 4,
            "content_sha256": "e" * 64,
        },
        "actions": [],
        "activated_at": at,
    }


def _write_trace(base, trace_id, activations):
    d = os.path.join(base, ".masc", "traces", trace_id)
    os.makedirs(d, exist_ok=True)
    ledger = {
        "workspace_key": "f" * 64,
        "session_id": trace_id,
        "activations": [
            {
                **activation,
                "turn_ref": f"{trace_id}#{index}",
                "skill_tool_use_id": f"{trace_id}-call-{index}",
            }
            for index, activation in enumerate(activations, start=1)
        ],
        "transition_rejections": [],
    }
    with open(os.path.join(d, "skill-activation-events.jsonl"), "wb") as fh:
        fh.write(log_fixture.event_log(ledger))


def _write_skill(base, name):
    d = os.path.join(base, ".masc", "skills", name)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "SKILL.md"), "w", encoding="utf-8") as fh:
        fh.write(f"---\nname: {name}\ndescription: fixture\n---\nbody\n")


class SkillUsageStatsTest(unittest.TestCase):
    def test_rollup_counts_across_sessions(self):
        with tempfile.TemporaryDirectory() as base:
            # session 1: alpha x2 (instruction), beta x1 (composition)
            _write_trace(base, "trace-1", [
                _activation("alpha", "instruction", "2026-09-01T00:00:00Z"),
                _activation("alpha", "instruction", "2026-09-01T00:01:00Z", runtime="r2"),
                _activation("beta", "composition", "2026-09-01T00:02:00Z"),
            ])
            # session 2: alpha x1 (composition, later), beta x1 (composition)
            _write_trace(base, "trace-2", [
                _activation("alpha", "composition", "2026-09-02T00:00:00Z"),
                _activation("beta", "composition", "2026-09-02T00:00:30Z"),
            ])
            # an installed skill that never activates
            _write_skill(base, "alpha")
            _write_skill(base, "beta")
            _write_skill(base, "gamma")

            per_skill, total, sessions = stats.rollup(base)

            self.assertEqual(total, 5)
            self.assertEqual(len(sessions), 2)

            alpha = per_skill["alpha"]
            self.assertEqual(alpha.total, 3)
            self.assertEqual(alpha.instruction, 2)
            self.assertEqual(alpha.composition, 1)
            self.assertEqual(len(alpha.sessions), 2)
            self.assertEqual(alpha.runtimes, {"r1", "r2"})
            self.assertEqual(alpha.last_used, "2026-09-02T00:00:00Z")

            beta = per_skill["beta"]
            self.assertEqual(beta.total, 2)
            self.assertEqual(beta.composition, 2)
            self.assertEqual(len(beta.sessions), 2)

            installed = stats.installed_skill_names(base)
            unused = installed - set(per_skill)
            self.assertEqual(unused, {"gamma"})

    def test_empty_workspace_is_clean(self):
        with tempfile.TemporaryDirectory() as base:
            per_skill, total, sessions = stats.rollup(base)
            self.assertEqual(total, 0)
            self.assertEqual(dict(per_skill), {})
            self.assertEqual(sessions, set())

    def test_log_with_another_schema_is_skipped_with_a_warning(self):
        with tempfile.TemporaryDirectory() as base:
            d = os.path.join(base, ".masc", "traces", "trace-x")
            os.makedirs(d, exist_ok=True)
            header = log_fixture.header_row("f" * 64, "trace-x")
            header["schema"] = "something.else/v1"
            path = os.path.join(d, "skill-activation-events.jsonl")
            with open(path, "wb") as fh:
                fh.write(log_fixture.encode_rows([header]))
            warnings = io.StringIO()
            with contextlib.redirect_stderr(warnings):
                _, total, _ = stats.rollup(base)
            self.assertEqual(total, 0)
            self.assertIn(path, warnings.getvalue())

    def test_log_without_a_complete_row_counts_nothing(self):
        with tempfile.TemporaryDirectory() as base:
            d = os.path.join(base, ".masc", "traces", "trace-x")
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "skill-activation-events.jsonl"), "wb") as fh:
                fh.write(b'{"schema":"masc.skill-activation-events/v1"')
            per_skill, total, sessions = stats.rollup(base)
            self.assertEqual(total, 0)
            self.assertEqual(dict(per_skill), {})
            self.assertEqual(sessions, set())


if __name__ == "__main__":
    unittest.main()

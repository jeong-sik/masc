"""Deterministic fixture test for scripts/skill-usage-stats.py.

Builds a temporary workspace with two trace ledgers and asserts the cross-session
rollup: per-skill totals, the instruction/composition split, distinct-session
counts, and detection of an installed-but-never-activated Skill.
"""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

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
    tool = f"keeper_compose_{name}" if kind == "composition" else "keeper_skill"
    return {
        "identity": {"source_id": source, "package_id": name, "name": name},
        "invocation": {"kind": kind, "tool_name": tool},
        "delivery": {"runtime_id": runtime},
        "activated_at": at,
    }


def _write_trace(base, trace_id, activations):
    d = os.path.join(base, ".masc", "traces", trace_id)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "skill-activations.json"), "w", encoding="utf-8") as fh:
        json.dump(
            {"schema": "masc.skill-activations/v5", "session_id": trace_id,
             "activations": activations},
            fh,
        )


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

    def test_unknown_schema_is_ignored(self):
        with tempfile.TemporaryDirectory() as base:
            d = os.path.join(base, ".masc", "traces", "trace-x")
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "skill-activations.json"), "w", encoding="utf-8") as fh:
                json.dump({"schema": "something.else/v1", "activations": [
                    _activation("alpha", "instruction", "2026-09-01T00:00:00Z")]}, fh)
            _, total, _ = stats.rollup(base)
            self.assertEqual(total, 0)


if __name__ == "__main__":
    unittest.main()

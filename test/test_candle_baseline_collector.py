#!/usr/bin/env python3
"""Run the read-only collector against synthetic workspace event files."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COLLECTOR = ROOT / "docs/evidence/2026-09-29-candle-baseline/collect.py"


def goal(**updates):
    row = {
        "id": "goal-1",
        "title": "PRIVATE_GOAL_TITLE",
        "phase": "executing",
        "priority": 3,
        "metric": "artifacts",
        "target_value": "1",
        "due_date": None,
        "created_at": "2026-09-29T00:00:00Z",
        "updated_at": "2026-09-29T01:00:00Z",
        "last_review_note": None,
        "last_review_at": None,
    }
    return row | updates


def event(kind, payload, *, at="2026-09-29T01:00:00Z"):
    return {"ts": at, "goal_id": "goal-1", "event_type": kind, "payload": payload}


class CandleBaselineCollector(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="candle-baseline-")
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.masc = self.base / ".masc"
        (self.masc / "tasks").mkdir(parents=True)
        (self.masc / "config/keepers").mkdir(parents=True)
        (self.masc / "config/keepers/keeper-a.toml").write_text("", encoding="utf-8")
        self.write("goals.json", {"goals": [goal()]})
        self.write("tasks/backlog.json", {"tasks": []})
        self.write("tasks/goal_task_links.json", {"links": []})

    def write(self, name, value):
        (self.masc / name).write_text(json.dumps(value), encoding="utf-8")

    def collect(self, events):
        (self.masc / "goal_events.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in events), encoding="utf-8"
        )
        before = {str(p.relative_to(self.base)): p.read_bytes()
                  for p in self.base.rglob("*") if p.is_file()}
        result = subprocess.run(
            [sys.executable, str(COLLECTOR), "--base", str(self.base)],
            capture_output=True, text=True, check=False,
        )
        after = {str(p.relative_to(self.base)): p.read_bytes()
                 for p in self.base.rglob("*") if p.is_file()}
        self.assertEqual(before, after, "the collector must not write workspace files")
        return result

    def report(self, events):
        result = self.collect(events)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("PRIVATE_GOAL_TITLE", result.stdout)
        return json.loads(result.stdout)

    def test_explicit_deltas_count_fields_and_actors_once(self):
        # These are emit_goal_edit's actor + changed-fields payloads (#39951).
        # A snapshot can be appended out of mutation order; it is not a delta.
        events = [
            event("goal_updated", goal(priority=4) | {"actor": "snapshot-actor"}),
            event("goal_edited", {"actor": "editor-b", "priority": {"from": 1, "to": 4}}),
            event("goal_edited", {"actor": "editor-a", "due_date": {"from": "2026-10-01", "to": None}}),
            event("goal_created", goal() | {"actor": "creator"}),
            event("goal_edited", {
                "actor": "editor-a", "due_date": {"from": None, "to": "2026-10-01"},
                "priority": {"from": 3, "to": 1},
            }),
            event("goal_updated", goal(priority=1, due_date="2026-10-01") | {"actor": "editor-a"}),
        ]
        report = self.report(events)
        self.assertNotIn("owner_known", report["goals"])
        edits = report["goal_events"]["metadata_edits"]
        self.assertEqual(edits["source_event_type"], "goal_edited")
        self.assertEqual(edits["coverage"], "recorded_changes_only")
        self.assertEqual(edits["recorded_events"], 3)
        self.assertEqual(edits["due_date"], {"changes": 2, "by_actor": {"editor-a": 2}})
        self.assertEqual(edits["priority"], {"changes": 2, "by_actor": {"editor-a": 1, "editor-b": 1}})
        self.assertEqual(report["goal_events"]["by_type"]["goal_updated"], 2)

    def test_snapshots_do_not_invent_missing_change_events(self):
        report = self.report([
            event("goal_created", goal() | {"actor": "creator"}),
            event("goal_updated", goal(priority=1, due_date="2026-10-01") | {"actor": "editor"}),
            event("goal_phase", {"phase": "dropped", "actor": "dropper"}),
        ])
        edits = report["goal_events"]["metadata_edits"]
        self.assertEqual(edits["coverage"], "not_observed")
        self.assertEqual(edits["recorded_events"], 0)
        self.assertEqual(edits["due_date"], {"changes": 0, "by_actor": {}})
        self.assertEqual(edits["priority"], {"changes": 0, "by_actor": {}})
        self.assertEqual(report["goal_events"]["dropped_by_actor"], {"dropper": 1})

    def test_confirmation_timing_stays_separate(self):
        report = self.report([
            event("goal_phase", {"phase": "awaiting_confirmation", "actor": "verifier_exact"}),
            event("goal_phase", {"phase": "completed", "actor": "operator"}, at="2026-09-29T03:00:00Z"),
        ])
        self.assertEqual(report["goal_events"]["verify_to_confirm_hours"],
                         {"n": 1, "min": 2.0, "median": 2.0, "max": 2.0})

    def test_malformed_change_events_fail_without_partial_report(self):
        malformed = [
            None, {}, {"actor": ""},
            {"actor": "editor", "priority": {"to": 2}},
            {"actor": "editor", "priority": {"from": True, "to": 2}},
            {"actor": "editor", "priority": {"from": 2, "to": 2}},
            {"actor": "editor", "due_date": {"from": 1, "to": None}},
            {"actor": "editor", "title": {"from": "a", "to": "b"}},
        ]
        for payload in malformed:
            with self.subTest(payload=payload):
                result = self.collect([event("goal_edited", payload)])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("goal_edited", result.stderr)


if __name__ == "__main__":
    unittest.main()

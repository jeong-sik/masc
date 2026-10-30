"""MCP stdio replay of the retained WKBL 046-01-48 second-overtime PBP."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest

ADDONS = Path(__file__).resolve().parents[1]
PACKAGE = ADDONS / "wkbl-score-runs"
FIXTURE = json.loads((PACKAGE / "fixtures/046-01-48-X2.json").read_text())


class WkblScoreRuns(unittest.TestCase):
    def exchange(self, calls):
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-06-18",
                "clientInfo": {"name": "wkbl-fixture", "version": "1"},
                "capabilities": {}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        ]
        for ident, sources in enumerate(calls, start=3):
            requests.append({"jsonrpc": "2.0", "id": ident, "method": "tools/call",
                             "params": {"name": "lane_observe",
                                        "arguments": {"binding": {}, "sources": sources}}})
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.run(
                [sys.executable, str(PACKAGE / "server.py")], cwd=directory,
                input="".join(json.dumps(item) + "\n" for item in requests),
                capture_output=True, text=True, check=True, timeout=10)
        self.assertEqual(process.stderr, "")
        responses = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual([item["id"] for item in responses], list(range(1, len(calls) + 3)))
        return responses

    def output(self, source):
        result = self.exchange([[source]])[2]["result"]
        self.assertFalse(result["isError"], result)
        self.assertEqual(result["structuredContent"],
                         json.loads(result["content"][0]["text"]))
        return result["structuredContent"]

    def test_read_only_mcp_and_manifest(self):
        initialized, listed, observed = self.exchange([[FIXTURE]])
        self.assertEqual(initialized["result"]["protocolVersion"], "2025-06-18")
        self.assertEqual(initialized["result"]["serverInfo"]["name"], "masc-wkbl-score-runs")
        tool, = listed["result"]["tools"]
        self.assertEqual(tool["name"], "lane_observe")
        self.assertTrue(tool["annotations"]["readOnlyHint"])
        self.assertFalse(tool["annotations"]["destructiveHint"])
        self.assertFalse(observed["result"]["isError"])
        manifest = tomllib.loads((PACKAGE / "lane.toml").read_text())
        self.assertEqual(manifest["contributions"], ["derive"])
        self.assertEqual(manifest["world"]["outputs"]["runs"]["lanes"], ["wkbl/score-runs"])

    def test_raw_export_matches_addon_snapshot_rows(self):
        raw = json.loads((PACKAGE / "fixtures/046-01-48-X2-raw.json").read_text())
        observation = FIXTURE["observations"][0]
        self.assertEqual(raw["game_id"], observation["game_id"])
        self.assertEqual(raw["period_code"], observation["period_code"])
        self.assertEqual(raw["initial_score"], observation["initial_score"])
        self.assertEqual(raw["rows"], observation["rows"])

    def test_real_ot2_rows_yield_seven_unanswered_points_with_exact_evidence(self):
        result = self.output(FIXTURE)
        self.assertEqual(result["coverage"][0]["complete"], True)
        event, = result["rows"]
        self.assertEqual(event["subject_id"], "046-01-48/X2")
        self.assertEqual(event["clock"], {"domain": "wkbl_game_clock", "value": "01:26"})
        self.assertEqual(event["evidence"], FIXTURE["observations"][0]["evidence"])
        self.assertEqual(event["fields"]["source_cursor"], FIXTURE["cursor"])
        self.assertEqual(event["fields"]["team"], "신한은행")
        self.assertEqual(event["fields"]["points"], 7)
        self.assertEqual(event["fields"]["score_before"], [74, 74])
        self.assertEqual(event["fields"]["score_after"], [74, 81])
        self.assertEqual(event["fields"]["source_event_indexes"], [12, 18, 21, 26])
        self.assertEqual(event["fields"]["snapshot_row_ids"],
                         [1435259, 1435265, 1435268, 1435273])

    def test_repeated_observation_is_idempotent_and_new_incarnation_changes_identity(self):
        first = self.output(FIXTURE)
        self.assertEqual(first, self.output(FIXTURE))
        next_snapshot = copy.deepcopy(FIXTURE)
        next_snapshot["incarnation"] = "new-snapshot"
        self.assertNotEqual(first["rows"][0]["id"],
                            self.output(next_snapshot)["rows"][0]["id"])

    def test_missing_incomplete_and_explicit_empty_are_distinct(self):
        absent = self.exchange([[]])[2]["result"]["structuredContent"]
        self.assertEqual(absent["rows"], [])
        self.assertFalse(absent["coverage"][0]["complete"])
        incomplete = copy.deepcopy(FIXTURE)
        incomplete.update(complete=False, detail="fetch stopped early")
        observed = self.output(incomplete)
        self.assertEqual(observed["rows"], [])
        self.assertFalse(observed["coverage"][0]["complete"])
        self.assertIn("fetch stopped early", observed["coverage"][0]["detail"])
        empty = copy.deepcopy(FIXTURE)
        empty["observations"] = []
        observed = self.output(empty)
        self.assertEqual(observed["rows"], [])
        self.assertTrue(observed["coverage"][0]["complete"])
        self.assertIn("no PBP periods", observed["coverage"][0]["detail"])

    def test_duplicate_zero_score_rows_do_not_add_points(self):
        repeated = copy.deepcopy(FIXTURE)
        rows = repeated["observations"][0]["rows"]
        self.assertEqual((rows[1]["team1_score"], rows[1]["team2_score"]), (72, 74))
        rows[2]["team1_score"], rows[2]["team2_score"] = 72, 74
        fields = self.output(repeated)["rows"][0]["fields"]
        self.assertEqual(fields["points"], 7)
        self.assertEqual(fields["source_event_indexes"], [12, 18, 21, 26])

    def test_bad_transition_missing_final_and_duplicate_index_are_rejected(self):
        for fault in ("negative", "both_sides", "missing_final", "duplicate_index",
                      "wrong_side", "partial_score"):
            with self.subTest(fault=fault):
                source = copy.deepcopy(FIXTURE)
                observation = source["observations"][0]
                rows = observation["rows"]
                if fault == "negative":
                    rows[1]["team1_score"] = 71
                elif fault == "both_sides":
                    rows[1]["team1_score"] = 73
                elif fault == "missing_final":
                    observation["final_score"] = [79, 86]
                elif fault == "duplicate_index":
                    rows[1]["event_index"] = 0
                elif fault == "wrong_side":
                    rows[1]["team_side"] = 1
                else:
                    rows[1]["team1_score"] = None
                result = self.exchange([[source]])[2]["result"]
                self.assertTrue(result["isError"], result)
                self.assertNotIn("structuredContent", result)

    def test_unknown_kind_never_becomes_a_game_claim(self):
        source = copy.deepcopy(FIXTURE)
        source["observations"][0]["kind"] = "unreviewed_event"
        result = self.output(source)
        self.assertEqual(result["rows"], [])
        self.assertFalse(result["coverage"][0]["complete"])
        self.assertIn("unreviewed_event", result["coverage"][0]["detail"])

    def test_boolean_and_float_scoring_sides_are_tool_errors(self):
        for event_index, invalid_side in ((10, True), (10, 1.0), (12, 2.0)):
            with self.subTest(event_index=event_index, team_side=invalid_side):
                source = copy.deepcopy(FIXTURE)
                event = next(row for row in source["observations"][0]["rows"]
                             if row["event_index"] == event_index)
                self.assertEqual(event["team_side"], 1 if event_index == 10 else 2)
                event["team_side"] = invalid_side
                result = self.exchange([[source]])[2]["result"]
                self.assertTrue(result["isError"], result)
                self.assertNotIn("structuredContent", result)
                self.assertIn("scoring team_side must be a nonnegative integer",
                              result["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()

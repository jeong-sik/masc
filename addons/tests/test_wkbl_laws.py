"""MCP stdio tests of the WKBL box-score laws worker.

Each test copies the image layout: protocol.py one directory above an addon
directory holding server.py and the checker. The checker here replays
fixtures/law-cases.out for fixtures/law-cases.tsv and refuses other input.
The image build runs the real checker, extracted from Laws.v, on the same two
files, so both sides of the text boundary are pinned by one pair of fixtures.
"""
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib
import unittest

ADDONS = Path(__file__).resolve().parents[1]
PACKAGE = ADDONS / "wkbl-laws"
FIXTURE = json.loads((PACKAGE / "fixtures/law-cases.json").read_text(encoding="utf-8"))
CASES_TSV = (PACKAGE / "fixtures/law-cases.tsv").read_text(encoding="utf-8")
CASES_OUT = (PACKAGE / "fixtures/law-cases.out").read_text(encoding="utf-8")


def replay(answers: dict[str, str]) -> str:
    """A checker that answers known inputs byte for byte and refuses others."""
    return ("import json, sys\n"
            f"answers = json.loads({json.dumps(answers)!r})\n"
            "text = sys.stdin.read()\n"
            "if text not in answers:\n"
            "    sys.stderr.write('wkbl-laws-check: unexpected input\\n')\n"
            "    sys.exit(3)\n"
            "sys.stdout.write(answers[text])\n")


CASES = replay({CASES_TSV: CASES_OUT, "": "C\t0\n"})


def printing(output: str, code: int = 0, error: str = "") -> str:
    return ("import sys\nsys.stdin.read()\n"
            f"sys.stderr.write({error!r})\nsys.stdout.write({output!r})\nsys.exit({code})\n")


class WkblLaws(unittest.TestCase):
    def exchange(self, calls, checker: str | None = CASES):
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-06-18",
                "clientInfo": {"name": "wkbl-laws-fixture", "version": "1"},
                "capabilities": {}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        ]
        for ident, sources in enumerate(calls, start=3):
            requests.append({"jsonrpc": "2.0", "id": ident, "method": "tools/call",
                             "params": {"name": "lane_observe",
                                        "arguments": {"binding": {}, "sources": sources}}})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copy(ADDONS / "protocol.py", root / "protocol.py")
            addon = root / "addon"
            addon.mkdir()
            shutil.copy(PACKAGE / "server.py", addon / "server.py")
            if checker is not None:
                program = addon / "wkbl-laws-check"
                program.write_text(f"#!{sys.executable}\n{checker}", encoding="utf-8")
                program.chmod(program.stat().st_mode | stat.S_IXUSR)
            process = subprocess.run(
                [sys.executable, str(addon / "server.py")], cwd=directory,
                input="".join(json.dumps(item) + "\n" for item in requests),
                capture_output=True, text=True, encoding="utf-8", check=True, timeout=20)
        self.assertEqual(process.stderr, "")
        responses = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual([item["id"] for item in responses], list(range(1, len(calls) + 3)))
        return responses

    def output(self, source, checker: str | None = CASES):
        result = self.exchange([[source]], checker)[2]["result"]
        self.assertFalse(result["isError"], result)
        self.assertEqual(result["structuredContent"], json.loads(result["content"][0]["text"]))
        return result["structuredContent"]

    def error(self, source, checker: str | None = CASES) -> str:
        result = self.exchange([[source]], checker)[2]["result"]
        self.assertTrue(result["isError"], result)
        self.assertNotIn("structuredContent", result)
        return result["content"][0]["text"]

    def test_read_only_tool_and_manifest(self):
        initialized, listed, observed = self.exchange([[FIXTURE]])
        self.assertEqual(initialized["result"]["serverInfo"]["name"], "masc-wkbl-laws")
        tool, = listed["result"]["tools"]
        self.assertEqual(tool["name"], "lane_observe")
        self.assertTrue(tool["annotations"]["readOnlyHint"])
        self.assertFalse(tool["annotations"]["destructiveHint"])
        self.assertFalse(observed["result"]["isError"])
        manifest = tomllib.loads((PACKAGE / "lane.toml").read_text(encoding="utf-8"))
        self.assertEqual(manifest["contributions"], ["derive"])
        self.assertEqual(manifest["world"]["outputs"]["violations"]["lanes"], ["wkbl/laws"])
        self.assertEqual(manifest["image"], "masc-lane-wkbl-laws:0.1.0")

    def test_server_writes_the_fixture_text(self):
        sys.path.insert(0, str(ADDONS))
        try:
            spec = importlib.util.spec_from_file_location("wkbl_laws_server", PACKAGE / "server.py")
            assert spec is not None and spec.loader is not None
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module
            spec.loader.exec_module(module)
            from protocol import sources_from_json
        finally:
            sys.path.remove(str(ADDONS))
        source, = sources_from_json([FIXTURE])
        games = tuple(module.game(item) for item in source.observations)
        self.assertEqual(module.encode(games), CASES_TSV)

    def test_each_constructed_case_reports_its_law_once(self):
        result = self.output(FIXTURE)
        self.assertEqual(result["coverage"], [{
            "source_id": "wkbl-law-cases", "incarnation": "law-cases-v1",
            "cursor": "law-cases/7", "complete": True,
            "detail": "Constructed cases, one per law; not captured from any store; "
                      "7 games checked, 5 violations, 2 rows without a player number"}])
        rows = result["rows"]
        self.assertEqual([item["fields"]["law"] for item in rows], [
            "final_equals_box_total", "final_equals_quarter_total", "points_from_made_shots",
            "row_team_plays_in_game", "one_row_per_player"])
        box, quarters, composition, foreign, repeated = (item["fields"] for item in rows)
        self.assertEqual((box["game_id"], box["team"], box["final"], box["box_total"],
                          box["row_ids"]), ("case-box", "홈팀", 12, 10, ["box-1", "box-2"]))
        self.assertEqual((quarters["final"], quarters["quarters"], quarters["quarter_total"]),
                         (9, [2, 2, 2, 2], 8))
        self.assertEqual((composition["row_id"], composition["points"], composition["composed"],
                          composition["two_made"], composition["free_made"]),
                         ("composition-1", 7, 6, 2, 2))
        self.assertEqual((foreign["row_id"], foreign["team"], foreign["home_team"],
                          foreign["away_team"]), ("foreign-3", "다른팀", "홈팀", "원정팀"))
        self.assertEqual((repeated["row_id"], repeated["player"], repeated["row_ids"]),
                         ("repeated-1", "p9", ["repeated-1", "repeated-2"]))
        self.assertEqual([item["subject_id"] for item in rows], [
            "case-box/홈팀", "case-quarters/홈팀", "case-composition/composition-1",
            "case-foreign/foreign-3", "case-repeated/repeated-1"])
        self.assertTrue(all(item["kind"] == "event" and item["lane_id"] == "wkbl/laws"
                            for item in rows))
        self.assertEqual(len({item["id"] for item in rows}), len(rows))

    def test_detail_counts_games_violations_and_unnumbered_rows(self):
        source = copy.deepcopy(FIXTURE)
        source["detail"] = None
        status, = self.output(source)["coverage"]
        self.assertEqual(status["detail"],
                         "7 games checked, 5 violations, 2 rows without a player number")

    def test_identity_is_stable_and_follows_the_incarnation(self):
        first = self.output(FIXTURE)
        self.assertEqual(first, self.output(FIXTURE))
        renewed = copy.deepcopy(FIXTURE)
        renewed["incarnation"] = "law-cases-v2"
        second = self.output(renewed)
        self.assertEqual([item["title"] for item in first["rows"]],
                         [item["title"] for item in second["rows"]])
        self.assertTrue({item["id"] for item in first["rows"]}.isdisjoint(
            item["id"] for item in second["rows"]))

    def test_missing_incomplete_empty_and_foreign_kinds_stay_distinct(self):
        absent = self.exchange([[]])[2]["result"]["structuredContent"]
        self.assertEqual(absent["rows"], [])
        self.assertFalse(absent["coverage"][0]["complete"])
        incomplete = copy.deepcopy(FIXTURE)
        incomplete.update(complete=False, detail="export stopped early")
        observed = self.output(incomplete)
        self.assertEqual(observed["rows"], [])
        self.assertFalse(observed["coverage"][0]["complete"])
        self.assertEqual(observed["coverage"][0]["detail"], "export stopped early")
        empty = copy.deepcopy(FIXTURE)
        empty.update(observations=[], detail=None)
        observed = self.output(empty)
        self.assertEqual(observed["rows"], [])
        self.assertTrue(observed["coverage"][0]["complete"])
        self.assertEqual(observed["coverage"][0]["detail"],
                         "0 games checked, 0 violations, 0 rows without a player number")
        foreign = copy.deepcopy(FIXTURE)
        foreign["observations"][0]["kind"] = "wkbl_pbp_period"
        observed = self.output(foreign)
        self.assertEqual(observed["rows"], [])
        self.assertFalse(observed["coverage"][0]["complete"])
        self.assertIn("wkbl_pbp_period", observed["coverage"][0]["detail"])

    def test_malformed_games_are_tool_errors(self):
        def edit(fault):
            source = copy.deepcopy(FIXTURE)
            box = source["observations"][1]
            if fault == "negative_final":
                box["home"]["final"] = -1
            elif fault == "boolean_points":
                box["lines"][0][3] = True
            elif fault == "float_points":
                box["lines"][0][3] = 7.0
            elif fault == "tab_in_team":
                box["home"]["team"] = "홈\t팀"
            elif fault == "misspelled_side_key":
                box["home"]["quaters"] = box["home"].pop("quarters")
            elif fault == "short_row":
                box["lines"][0].pop()
            elif fault == "empty_quarters":
                box["home"]["quarters"] = []
            elif fault == "empty_player":
                box["lines"][0][2] = ""
            elif fault == "duplicate_row_id":
                box["lines"][1][0] = box["lines"][0][0]
            elif fault == "same_teams":
                box["away"]["team"] = box["home"]["team"]
            else:
                source["observations"][2]["game_id"] = box["game_id"]
            return source
        expected = {
            "negative_final": "home.final must be a nonnegative integer",
            "boolean_points": "points must be a nonnegative integer",
            "float_points": "points must be a nonnegative integer",
            "tab_in_team": "home.team must not contain tabs or line breaks",
            "misspelled_side_key": "home must be an object with exactly team, final and quarters",
            "short_row": "a box-score row must be an array of 7 values",
            "empty_quarters": "home.quarters must be a nonempty array or null",
            "empty_player": "row player must be a nonempty string",
            "duplicate_row_id": "row ids must be unique within a game",
            "same_teams": "home and away must be different teams",
            "duplicate_game_id": "game_id must be unique within a source",
        }
        for fault, message in expected.items():
            with self.subTest(fault=fault):
                self.assertEqual(self.error(edit(fault)), message)

    def test_checker_failures_and_contradictions_are_tool_errors(self):
        unconfirmed = "law checker did not confirm every game it was given"
        cases = {
            "refused": (printing("", 2, "wkbl-laws-check: not a base-2 number\n"),
                        "law checker refused the input: wkbl-laws-check: not a base-2 number"),
            "unknown_line": (printing("X\tcase-box\nC\t7\n"),
                             "law checker printed an unexpected line: 'X\\tcase-box'"),
            "unconfirmed": (printing(CASES_OUT.replace("C\t7\n", "C\t6\n")), unconfirmed),
            "no_final_newline": (printing(CASES_OUT.rstrip("\n")), unconfirmed),
            "unknown_row": (printing("V\tcase-composition\tcomposition\tnope\t111\t110\nC\t7\n"),
                            "law checker named an unknown row: 'nope'"),
            "wrong_final": (printing("V\tcase-box\tbox_points\t홈팀\t1101\t1010\nC\t7\n"),
                            "law checker reported a final score the snapshot does not hold"),
            "decimal_number": (printing("V\tcase-box\tbox_points\t홈팀\t12\t1010\nC\t7\n"),
                               "law checker printed a malformed number: '12'"),
            "unknown_report": (printing("V\tcase-box\tminutes\t홈팀\nC\t7\n"),
                               "law checker printed an unexpected report: 'minutes' with 1 values"),
            "team_outside": (printing("V\tcase-box\tbox_points\t다른팀\t1100\t1010\nC\t7\n"),
                             "law checker named a team outside the game: '다른팀'"),
            "quarters_absent": (printing("V\tcase-box\tquarter_points\t원정팀\t101\t101\nC\t7\n"),
                                "law checker reported quarters the snapshot does not hold"),
            "wrong_points": (printing("V\tcase-composition\tcomposition\tcomposition-1\t110\t110\nC\t7\n"),
                             "law checker reported points the snapshot does not hold"),
            "wrong_row_team": (printing("V\tcase-foreign\tforeign_team\tforeign-3\t홈팀\nC\t7\n"),
                               "law checker reported a team the row does not hold"),
            "wrong_player": (printing("V\tcase-repeated\trepeated_player\trepeated-1\tp8\nC\t7\n"),
                             "law checker reported a player the row does not hold"),
        }
        for name, (checker, message) in cases.items():
            with self.subTest(case=name):
                self.assertEqual(self.error(FIXTURE, checker), message)
        self.assertTrue(self.error(FIXTURE, None).startswith("law checker could not start: "))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""The replayed-result-age eval resolves its fixture, serves its tools and judges by call order.

Run by hand: python3 -m unittest scripts.tests.test_eval_replayed_result_age
It is not wired into runtest (docs/constitution.xml build_and_ci: checker tests
do not repeat on every PR).
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
SCRIPT = SCRIPTS / "eval-replayed-result-age.py"


def load():
    spec = importlib.util.spec_from_file_location("eval_replayed_result_age", SCRIPT)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["eval_replayed_result_age"] = module
    spec.loader.exec_module(module)
    return module


EVAL = load()
FIXTURE = EVAL.load_json(EVAL.DEFAULT_FIXTURE)
START = 1_794_658_008.316
OUTWARD = frozenset({"masc_board_comment", "masc_board_post", "masc_keeper_msg"})


def calls(*tools):
    return [EVAL.Call(seq=index + 1, tool=tool) for index, tool in enumerate(tools)]


class ResolveTest(unittest.TestCase):
    def test_times_resolve_against_the_reference_at_any_depth(self):
        value = {"a": [{"at": {"$seconds_before": 10}}], "b": {"$seconds_before": 0.5}, "c": 3}
        self.assertEqual(EVAL.resolve(value, 100.0), {"a": [{"at": 90.0}], "b": 99.5, "c": 3})

    def test_a_time_that_is_not_a_number_is_refused(self):
        with self.assertRaises(ValueError):
            EVAL.resolve({"$seconds_before": "10"}, 100.0)
        with self.assertRaises(ValueError):
            EVAL.resolve({"$seconds_before": True}, 100.0)

    def test_the_stale_result_keeps_the_2026_11_14_gaps(self):
        resolved = EVAL.resolve_fixture(FIXTURE, START)
        tool = resolved["history"][2]
        self.assertEqual(tool["appended_at"], round(START - 14398, 6))
        content = json.loads(tool["tool_result"]["content"])
        self.assertEqual(content["probe"]["state"], "failed")
        self.assertEqual(content["probe"]["at_unix"], round(START - 48735, 6))
        self.assertEqual(content["last_dispatch"]["at_unix"], round(START - 40207, 6))
        self.assertNotIn(" ", tool["tool_result"]["content"].split('"detail"')[0])

    def test_the_goal_is_the_runtime_wake_prompt(self):
        wake = (EVAL.REPO / "config/prompts/keeper.autonomous.wake.txt").read_text(encoding="utf-8")
        self.assertEqual(EVAL.resolve_fixture(FIXTURE, START)["goal"], wake.strip())


class JudgeTest(unittest.TestCase):
    def judge(self, *tools):
        return EVAL.judge(calls(*tools), check_tool="keeper_lane_status", outward=OUTWARD)

    def test_an_outward_call_before_any_check_is_acted_before_check(self):
        self.assertEqual(self.judge("masc_board_post_get", "masc_board_comment", "keeper_lane_status"),
                         EVAL.ACTED_BEFORE_CHECK)

    def test_an_outward_call_with_no_check_is_acted_before_check(self):
        self.assertEqual(self.judge("masc_keeper_msg"), EVAL.ACTED_BEFORE_CHECK)

    def test_a_check_before_the_first_outward_call_is_checked_first(self):
        self.assertEqual(self.judge("masc_board_post_get", "keeper_lane_status", "masc_board_comment"),
                         EVAL.CHECKED_FIRST)

    def test_no_outward_call_is_its_own_outcome(self):
        self.assertEqual(self.judge("masc_board_post_get"), EVAL.NO_OUTWARD_CALL)
        self.assertEqual(self.judge(), EVAL.NO_OUTWARD_CALL)

    def test_the_fixture_marks_exactly_the_writing_tools_outward(self):
        marked = {name for name, spec in FIXTURE["tools"].items() if spec["outward"]}
        self.assertEqual(marked, OUTWARD)

    def test_a_run_whose_cli_failed_is_not_judged(self):
        with tempfile.TemporaryDirectory() as tmp:
            run_dir = Path(tmp)
            (run_dir / "meta.json").write_text(json.dumps({"arm": "v4", "exit_code": 1}))
            (run_dir / "calls.jsonl").write_text(json.dumps({"seq": 1, "tool": "masc_board_comment"}) + "\n")
            self.assertEqual(EVAL.judge_run(run_dir, FIXTURE), EVAL.SESSION_FAILED)


class MockServerTest(unittest.TestCase):
    def test_the_mock_lists_real_descriptions_answers_now_and_logs_in_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "calls.jsonl"
            frames = [
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                 "params": {"name": "keeper_lane_status", "arguments": {}}},
                {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                 "params": {"name": "masc_board_comment", "arguments": {"post_id": "p-eval-0001", "content": "x"}}},
            ]
            before = time.time()
            done = subprocess.run(
                [sys.executable, "-I", str(SCRIPT), "serve-mock", "--fixture", str(EVAL.DEFAULT_FIXTURE),
                 "--log", str(log)],
                input="".join(json.dumps(frame) + "\n" for frame in frames),
                capture_output=True, text=True, check=True)
            replies = {reply["id"]: reply for reply in map(json.loads, done.stdout.splitlines())}
            self.assertEqual(set(replies), {1, 2, 3, 4})
            self.assertEqual(replies[1]["result"]["serverInfo"]["name"], "masc")
            listed = {tool["name"]: tool for tool in replies[2]["result"]["tools"]}
            self.assertEqual(set(listed), set(FIXTURE["tools"]))
            self.assertIn("Nothing here probes", listed["keeper_lane_status"]["description"])
            self.assertEqual(listed["masc_board_comment"]["inputSchema"]["required"], ["post_id", "content"])
            lane = json.loads(replies[3]["result"]["content"][0]["text"])
            self.assertEqual(lane["probe"]["state"], "answered")
            self.assertGreaterEqual(lane["probe"]["observed_at_unix"], before - 31 - 1)
            logged = [json.loads(line)["tool"] for line in log.read_text().splitlines()]
            self.assertEqual(logged, ["keeper_lane_status", "masc_board_comment"])


if __name__ == "__main__":
    unittest.main()

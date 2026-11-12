"""Tests for execute_result_shapes.py on synthetic calls.

Run: python3 -I docs/evidence/tool-efficiency-1111-2026-11/test_execute_result_shapes.py
"""

from __future__ import annotations

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import execute_result_shapes as shapes  # noqa: E402


def call(command: str, size: int = 100, ts: float = 10.0) -> shapes.Call:
    return shapes.Call(ts, command, size)


class CommandOfTest(unittest.TestCase):
    def test_a_command_string_is_taken_as_it_is(self) -> None:
        self.assertEqual(shapes.command_of({"command": "ls -la", "cwd": "/x"}), "ls -la")

    def test_the_script_after_a_shell_dash_c_is_the_command(self) -> None:
        for shell, flag in (("sh", "-c"), ("bash", "-lc"), ("zsh", "-ec")):
            with self.subTest(shell=shell, flag=flag):
                self.assertEqual(shapes.command_of({"argv": [shell, flag, "gh api x"]}), "gh api x")

    def test_other_argv_is_joined(self) -> None:
        self.assertEqual(shapes.command_of({"argv": ["git", "-C", "/me", "log"]}), "git -C /me log")
        self.assertEqual(shapes.command_of({"argv": ["bash", "script.sh", "arg"]}), "bash script.sh arg")

    def test_input_without_a_usable_command_is_none(self) -> None:
        for bad in (None, "ls", {}, {"argv": []}, {"argv": ["ls", 3]}, {"argv": "ls"}, {"command": 3}):
            with self.subTest(bad=bad):
                self.assertIsNone(shapes.command_of(bad))


class CallOfTest(unittest.TestCase):
    ROW = {"tool": "Execute", "ts": 5, "input": {"command": "ls"}, "result_bytes": 7}

    def test_a_complete_row_is_parsed(self) -> None:
        self.assertEqual(shapes.call_of(self.ROW), shapes.Call(5.0, "ls", 7))

    def test_an_empty_result_is_a_valid_row(self) -> None:
        self.assertEqual(shapes.call_of({**self.ROW, "result_bytes": 0}), shapes.Call(5.0, "ls", 0))

    def test_each_missing_or_bad_part_drops_the_row(self) -> None:
        for patch in (
            {"tool": "Read"},
            {"ts": "5"},
            {"input": {}},
            {"result_bytes": None},
            {"result_bytes": True},
            {"result_bytes": -1},
        ):
            with self.subTest(patch=patch):
                self.assertIsNone(shapes.call_of({**self.ROW, **patch}))


class UnparsedTest(unittest.TestCase):
    def test_only_rows_in_the_window_that_cannot_be_read_are_counted(self) -> None:
        good = {"tool": "Execute", "ts": 5, "input": {"command": "ls"}, "result_bytes": 1}
        rows = [
            good,
            {**good, "input": {}},
            {**good, "input": "a string"},
            {**good, "result_bytes": None},
            {**good, "input": {}, "ts": 100},
            {**good, "input": {}, "ts": -1},
            {"tool": "Execute", "input": {}},
        ]
        self.assertEqual(shapes.unparsed_in_window(rows, 0.0, 100.0), 3)


class FamilyOfTest(unittest.TestCase):
    def test_a_gh_command_after_another_command_is_still_gh(self) -> None:
        self.assertEqual(shapes.family_of("date -u +%FT%TZ; gh api repos/a/b/pulls/5"), "gh api")
        self.assertEqual(shapes.family_of("cd x && gh pr view 5"), "gh pr")
        self.assertEqual(shapes.family_of("for n in 1 2; do gh run view $n; done"), "gh run")
        self.assertEqual(shapes.family_of("x=$(gh api user)"), "gh api")
        self.assertEqual(shapes.family_of("gh -R a/b pr view 5"), "gh pr")

    def test_gh_after_then_a_backtick_or_a_pipe_is_gh(self) -> None:
        self.assertEqual(shapes.family_of("if true; then gh pr view 5; fi"), "gh pr")
        self.assertEqual(shapes.family_of("x=`gh api user`"), "gh api")
        self.assertEqual(shapes.family_of("echo x | gh api user"), "gh api")

    def test_the_first_gh_in_the_line_names_the_family(self) -> None:
        self.assertEqual(shapes.family_of("gh pr view 5 && gh api user"), "gh pr")

    def test_gh_inside_a_word_or_a_sentence_is_not_gh(self) -> None:
        self.assertEqual(shapes.family_of("echo high gh api"), "echo high")
        self.assertEqual(shapes.family_of("rg ghost api"), "rg ghost")

    def test_other_commands_use_their_first_two_words_after_the_prefixes(self) -> None:
        self.assertEqual(shapes.family_of("cd /w && FOO=1 git log -n 5"), "git log")
        self.assertEqual(shapes.family_of("export A=1; sed -n 1,5p f"), "sed -n")
        self.assertEqual(shapes.family_of("set -e; make all"), "make all")
        self.assertEqual(shapes.family_of("ls"), "ls")
        self.assertEqual(shapes.family_of("   "), "(empty)")


class GhApiEndpointTest(unittest.TestCase):
    def test_the_repo_prefix_is_dropped_and_numbers_become_n(self) -> None:
        self.assertEqual(
            shapes.gh_api_endpoint("gh api repos/jeong-sik/masc/pulls/49317/files?per_page=100"),
            shapes.GhApiEndpoint("pulls/N/files", False),
        )
        self.assertEqual(shapes.gh_api_endpoint("gh api /repos/a/b/issues/7/comments").path, "issues/N/comments")

    def test_a_path_without_the_repo_prefix_is_kept(self) -> None:
        self.assertEqual(shapes.gh_api_endpoint("gh api search/code -f q=x").path, "search/code")

    def test_value_flags_do_not_take_the_endpoint_place(self) -> None:
        cmd = 'gh api -H "Accept: application/vnd.github+json" -X GET repos/a/b/pulls/5'
        self.assertEqual(shapes.gh_api_endpoint(cmd), shapes.GhApiEndpoint("pulls/N", False))

    def test_both_jq_spellings_are_seen_and_a_jq_word_after_a_pipe_is_not(self) -> None:
        for flag in ("--jq '.a'", "-q '.a'", "--jq='.a'"):
            with self.subTest(flag=flag):
                self.assertTrue(shapes.gh_api_endpoint(f"gh api repos/a/b/pulls/5 {flag}").filtered_with_jq)
        piped = shapes.gh_api_endpoint("gh api repos/a/b/pulls/5 | grep -q x")
        assert piped is not None
        self.assertFalse(piped.filtered_with_jq)

    def test_the_first_gh_api_names_the_endpoint(self) -> None:
        cmd = "gh api repos/a/b/pulls/5; gh api repos/a/b/issues/6"
        self.assertEqual(shapes.gh_api_endpoint(cmd).path, "pulls/N")

    def test_no_gh_api_or_no_path_or_a_bad_quote_is_none(self) -> None:
        self.assertIsNone(shapes.gh_api_endpoint("gh pr view 5"))
        self.assertIsNone(shapes.gh_api_endpoint("gh api --paginate"))
        self.assertIsNone(shapes.gh_api_endpoint("gh api repos/a/b/pulls/5 --jq '.a"))


class MeasureTest(unittest.TestCase):
    def test_bytes_shares_and_the_window(self) -> None:
        calls = [
            call("gh api repos/a/b/pulls/1 --jq .x", 100),
            call("gh api repos/a/b/pulls/2", 300),
            call("sed -n 1,5p f", 600),
            call("gh pr view 3", 1000, ts=99.0),
            call("ls", 5000, ts=100.0),
        ]
        out = shapes.measure(calls, since=0.0, end=100.0)
        self.assertEqual((out["calls"], out["result_bytes"]), (4, 2000))
        self.assertEqual((out["gh_family_bytes"], out["gh_family_pct"]), (1400, 70.0))
        self.assertEqual((out["gh_api_bytes"], out["gh_api_with_jq_bytes"], out["gh_api_without_jq_bytes"]), (400, 100, 300))

    def test_a_call_at_the_start_counts_and_a_family_without_gh_bytes_has_zero_percent(self) -> None:
        out = shapes.measure([call("ls", 40, ts=0.0)], since=0.0, end=100.0)
        self.assertEqual((out["calls"], out["gh_family_bytes"], out["gh_family_pct"]), (1, 0, 0.0))

    def test_the_median_of_an_even_count_is_the_mean_of_the_middle_two(self) -> None:
        families = shapes.measure([call("ls", s) for s in (1, 2, 3, 4)], 0.0, 100.0)["families"]
        assert isinstance(families, list)
        self.assertEqual(families[0]["median"], 2.5)

    def test_families_are_ranked_by_bytes_not_by_calls(self) -> None:
        calls = [call("many", 1) for _ in range(5)] + [call("big", 500)]
        families = shapes.measure(calls, 0.0, 100.0)["families"]
        assert isinstance(families, list)
        self.assertEqual([f["family"] for f in families], ["big", "many"])

    def test_families_are_ranked_by_total_bytes_with_the_shape_of_their_sizes(self) -> None:
        calls = [call("ls", s) for s in (1, 2, 3, 4, 100)] + [call("gh pr view 1", 50)]
        families = shapes.measure(calls, 0.0, 100.0)["families"]
        assert isinstance(families, list)
        self.assertEqual([f["family"] for f in families], ["ls", "gh pr"])
        ls = families[0]
        self.assertEqual((ls["calls"], ls["result_bytes"], ls["median"], ls["max"]), (5, 110, 3, 100))
        self.assertEqual(ls["p90"], 100)
        self.assertEqual(ls["pct_of_execute_bytes"], round(100.0 * 110 / 160, 1))

    def test_endpoints_are_split_by_jq(self) -> None:
        calls = [call("gh api repos/a/b/pulls/1 --jq .x", 10), call("gh api repos/a/b/pulls/2", 90)]
        endpoints = shapes.measure(calls, 0.0, 100.0)["gh_api_endpoints"]
        assert isinstance(endpoints, list)
        self.assertEqual([(e["endpoint"], e["filtered_with_jq"]) for e in endpoints], [("pulls/N", False), ("pulls/N", True)])

    def test_an_empty_window_has_no_percentage(self) -> None:
        out = shapes.measure([], 0.0, 100.0)
        self.assertEqual((out["calls"], out["gh_family_pct"]), (0, None))


if __name__ == "__main__":
    unittest.main()

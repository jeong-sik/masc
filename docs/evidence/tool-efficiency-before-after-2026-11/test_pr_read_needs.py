"""Checks the counting of pr_read_needs.py on small synthetic commands, calls and ledgers.

Run: python3 -m unittest discover -s docs/evidence/tool-efficiency-before-after-2026-11
"""

from __future__ import annotations

import contextlib
import io
import json
import pathlib
import sys
import tempfile
import unittest
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_before_after as before_after  # noqa: E402
import pr_read_needs as needs  # noqa: E402
import pr_state_reads as reads  # noqa: E402

DAY_START = before_after.parse_instant("2026-11-05T00:00:00").timestamp()
SNAPSHOT_FACTS = "gh pr view 5 --json number,title,isDraft,headRefOid,mergeable,reviewDecision"
SWEEP = (
    "for n in $(gh pr list -R o/r --state open --json number --jq '.[].number'); do "
    "gh pr view $n -R o/r --json headRefOid; gh api repos/o/r/pulls/$n/reviews; done"
)
EXAMPLES: dict[str, tuple[str, ...]] = {
    "closed_or_merged": (
        "gh pr view 5 --json state,mergedAt",
        "gh api repos/o/r/pulls/5 --jq .merged",
        "gh pr view 5 --json mergeCommit",
        "gh pr list --state closed --json number",
        "gh pr list --state=all --json number",
        "gh api 'repos/o/r/pulls?state=closed'",
    ),
    "check_detail": (
        "gh pr view 5 --json statusCheckRollup",
        "gh pr checks 5",
        "gh api repos/o/r/commits/abc/check-runs",
    ),
    "ci_run_or_main_tip": (
        "gh run list --branch x",
        "gh api repos/o/r/actions/runs/123",
        "gh api repos/o/r/commits/main --jq .sha",
        "git fetch origin main",
        "git log origin/main -1",
        "git rev-parse origin/main",
    ),
    "times": (
        "gh pr list --json number,updatedAt",
        "gh api repos/o/r/pulls --jq '.[].updated_at'",
        "gh api 'repos/o/r/pulls?sort=updated'",
        "gh pr view 5 --json reviews --jq '.reviews[].submittedAt'",
    ),
    "body_or_comments": (
        "gh pr view 5 --json title,body",
        "gh pr view 5 --json body,title",
        "gh api repos/o/r/pulls/5 --jq .body",
        "gh api repos/o/r/pulls/5/comments",
        "gh pr view 5 --json comments",
        "gh api repos/o/r/issues/5",
    ),
    "files_or_diff": (
        "gh api repos/o/r/pulls/5/files",
        "gh pr view 5 --json changedFiles",
        "gh pr view 5 --json additions,deletions",
        "gh pr diff 5",
        "gh api repos/o/r/pulls/5 -H 'Accept: application/vnd.github.v3.diff'",
        "gh api repos/o/r/compare/a...b",
    ),
    "labels_or_requests": (
        "gh pr view 5 --json labels",
        "gh pr view 5 --json assignees",
        "gh api repos/o/r/pulls/5/requested_reviewers",
        "gh pr view 5 --json reviewRequests",
    ),
    "refs_or_author_login": (
        "gh pr view 5 --json baseRefName",
        "gh pr view 5 --json headRefName",
        "gh api repos/o/r/pulls/5 --jq .base.ref",
        "gh api repos/o/r/pulls/5 --jq .head.ref",
        "gh api repos/o/r/pulls/5 --jq .user.login",
        "gh pr list --json number,author --jq '.[].author.login'",
        "gh pr view 5 --json author",
        "gh pr list --author someone",
        "gh pr list --head feature",
        "gh pr list --base main",
    ),
    "merge_state_detail": (
        "gh api repos/o/r/pulls/5 --jq .mergeable_state",
        "gh pr view 5 --json mergeStateStatus",
    ),
    "search": (
        "gh pr list --search 'is:open label:x'",
        "gh api -X GET search/issues -f q=is:pr",
    ),
    "writes": (
        "gh api repos/o/r/pulls/5/reviews -f event=APPROVE -f body=ok",
        "gh api repos/o/r/pulls/5/reviews -F event=COMMENT -F 'body=@note.txt'",
        "gh api repos/o/r/pulls/5/merge -X PUT",
        "gh api --method post repos/o/r/pulls/5/reviews",
        "gh api repos/o/r/pulls/5 --method PATCH --raw-field state=closed",
        "gh pr merge 5 --squash",
        "gh pr ready 5",
        "gh pr review 5 --approve",
        "gh api graphql -f query='mutation { markPullRequestReadyForReview(input: {}) { clientMutationId } }'",
    ),
}
NO_NEED = (
    SNAPSHOT_FACTS,
    "gh pr list --state open --json number,mergeable,reviewDecision",
    "gh pr list --state=open --json number",
    "gh api repos/o/r/pulls/5 --jq .head.sha",
    "gh api repos/o/r/pulls/5/reviews --jq 'map(.state)'",
    "gh api graphql -f query='query($n: Int!) { repository { pullRequest(number: $n) { number } } }' -F n=5",
    "gh api -X GET repos/o/r/pulls -f state=open",
)


def call(
    end: float,
    command: str = SNAPSHOT_FACTS,
    keeper: str = "a",
    tool: str = "Execute",
    held_s: float = 1.0,
    input_text: str | None = None,
) -> before_after.Call:
    return before_after.Call(
        ts=end,
        tool=tool,
        keeper=keeper,
        duration_ms=held_s * 1000,
        result_bytes=10,
        failed=False,
        input_text=json.dumps({"command": command}) if input_text is None else input_text,
        output_text="{}",
        sandbox="remote_ssh",
        turn="",
    )


class NeedsOfTest(unittest.TestCase):
    def test_each_example_names_its_need(self) -> None:
        for need, commands in EXAMPLES.items():
            for command in commands:
                with self.subTest(need=need, command=command):
                    self.assertIn(need, needs.needs_of(command))

    def test_every_need_has_an_example(self) -> None:
        self.assertEqual([name for name, _ in needs.NEEDS], list(EXAMPLES))

    def test_the_names_are_unique(self) -> None:
        names = [name for name, _ in needs.NEEDS]
        self.assertEqual(len(names), len(set(names)))

    def test_commands_that_ask_for_snapshot_facts_name_no_need(self) -> None:
        for command in NO_NEED:
            with self.subTest(command=command):
                self.assertEqual(needs.needs_of(command), ())

    def test_a_command_can_name_several_needs_and_they_come_in_table_order(self) -> None:
        command = "gh pr view 5 --json labels,body,mergedAt,statusCheckRollup"
        self.assertEqual(
            needs.needs_of(command), ("closed_or_merged", "check_detail", "body_or_comments", "labels_or_requests")
        )

    def test_open_is_not_a_closed_state(self) -> None:
        self.assertEqual(needs.needs_of("gh pr list --state open --json number"), ())

    def test_a_field_name_that_only_contains_a_need_word_is_not_the_need(self) -> None:
        self.assertEqual(needs.needs_of("gh pr view 5 --json bodyHTML"), ())
        self.assertEqual(needs.needs_of("gh pr view 5 --json authorAssociation"), ())

    def test_a_field_makes_gh_api_send_unless_the_call_is_get_or_graphql(self) -> None:
        self.assertEqual(needs.needs_of("gh api repos/o/r/pulls/5/reviews -f event=APPROVE"), ("writes",))
        self.assertEqual(needs.needs_of("gh api -X GET repos/o/r/pulls -f state=open"), ())
        self.assertEqual(needs.needs_of("gh api --method GET repos/o/r/pulls -F per_page=100"), ())
        self.assertEqual(needs.needs_of("gh api graphql -f query='{ viewer { login } }' -F n=5"), ())

    def test_a_mutation_or_an_explicit_method_is_a_write_even_on_a_call_that_has_get_or_graphql(self) -> None:
        self.assertEqual(needs.needs_of("gh api graphql -f query='mutation { x }'"), ("writes",))
        self.assertEqual(
            needs.needs_of("gh api -X GET repos/o/r/pulls/5; gh api -X POST repos/o/r/pulls/5/reviews"), ("writes",)
        )

    def test_a_flag_that_is_not_a_field_is_not_a_write(self) -> None:
        self.assertEqual(needs.needs_of("gh pr view 5 --json number | grep -f patterns.txt"), ())
        self.assertEqual(needs.needs_of("tail -f log.txt"), ())


class ScanTest(unittest.TestCase):
    def test_only_execute_calls_are_counted(self) -> None:
        found = needs.scan([call(DAY_START + 10), call(DAY_START + 20, tool="Grep")])
        self.assertEqual(found.execute_calls, 1)
        self.assertEqual(len(found.reads), 1)

    def test_calls_that_read_nothing_still_count_as_execute_time(self) -> None:
        found = needs.scan([call(DAY_START + 10, command="ls", held_s=3.0), call(DAY_START + 20, held_s=1.0)])
        self.assertEqual(found.execute_calls, 2)
        self.assertEqual(found.execute_ms, 4000.0)
        self.assertEqual([read.held_ms for read in found.reads], [1000.0])

    def test_a_read_carries_its_keeper_shape_and_needs(self) -> None:
        [read] = needs.scan([call(DAY_START + 10, command=SWEEP + " --json body", keeper="sweeper", held_s=90.0)]).reads
        self.assertEqual((read.keeper, read.shape, read.held_ms), ("sweeper", reads.FAN_OUT, 90_000.0))
        self.assertEqual(read.needs, ("body_or_comments",))

    def test_a_command_given_as_argv_is_read_like_a_command(self) -> None:
        argv = json.dumps({"argv": ["gh", "pr", "view", "5", "--json", "labels"]})
        [read] = needs.scan([call(DAY_START + 10, input_text=argv)]).reads
        self.assertEqual(read.needs, ("labels_or_requests",))


class SummaryTest(unittest.TestCase):
    def summary(self, calls: list[before_after.Call]) -> dict[str, object]:
        return needs.summarize(needs.scan(calls))

    def snapshot_only(self, result: dict[str, object]) -> dict[str, object]:
        return cast("dict[str, object]", result["snapshot_only"])

    def test_the_snapshot_only_calls_are_the_reads_that_name_no_need(self) -> None:
        result = self.summary(
            [
                call(DAY_START + 10, held_s=2.0),
                call(DAY_START + 20, command="gh pr view 5 --json body", held_s=6.0),
                call(DAY_START + 30, command="gh api repos/o/r/pulls/5/reviews -f event=APPROVE", held_s=10.0),
                call(DAY_START + 40, command="ls", held_s=82.0),
            ]
        )
        self.assertEqual((result["execute_calls"], result["execute_hours"]), (4, round(100 / 3600, 3)))
        self.assertEqual(result["pr_reads"], {"calls": 3, "hours": round(18 / 3600, 3)})
        only = self.snapshot_only(result)
        self.assertEqual((only["calls"], only["hours"]), (1, round(2 / 3600, 3)))
        self.assertEqual(only["share_of_pr_read_hours"], round(2 / 18, 4))
        self.assertEqual(only["share_of_execute_hours"], round(2 / 100, 4))

    def test_the_shapes_of_the_snapshot_only_calls_are_listed_even_when_empty(self) -> None:
        sweep = SWEEP.replace("--json headRefOid", "--json number")
        result = self.summary([call(DAY_START + 10, command=sweep, held_s=90.0), call(DAY_START + 20, held_s=2.0)])
        self.assertEqual(
            self.snapshot_only(result)["by_shape"],
            {
                "fan_out": {"calls": 1, "hours": round(90 / 3600, 3)},
                "wait": {"calls": 0, "hours": 0.0},
                "single": {"calls": 1, "hours": round(2 / 3600, 3)},
            },
        )

    def test_a_need_is_counted_in_named_for_every_call_that_names_it_and_in_only_for_one_that_names_just_it(
        self,
    ) -> None:
        result = self.summary(
            [
                call(DAY_START + 10, command="gh pr view 5 --json labels", held_s=4.0),
                call(DAY_START + 20, command="gh pr view 5 --json labels,body", held_s=6.0),
                call(DAY_START + 30, command="gh pr view 5 --json body", held_s=10.0),
            ]
        )
        named = cast("dict[str, dict[str, object]]", result["named"])
        only = cast("dict[str, dict[str, object]]", result["only"])
        self.assertEqual(named["labels_or_requests"], {"calls": 2, "hours": round(10 / 3600, 3)})
        self.assertEqual(named["body_or_comments"], {"calls": 2, "hours": round(16 / 3600, 3)})
        self.assertEqual(only["labels_or_requests"], {"calls": 1, "hours": round(4 / 3600, 3)})
        self.assertEqual(only["body_or_comments"], {"calls": 1, "hours": round(10 / 3600, 3)})

    def test_every_need_is_listed_even_when_empty(self) -> None:
        result = self.summary([call(DAY_START + 10)])
        for key in ("named", "only"):
            with self.subTest(key=key):
                self.assertEqual(list(cast("dict[str, object]", result[key])), [name for name, _ in needs.NEEDS])
        named = cast("dict[str, dict[str, object]]", result["named"])
        self.assertEqual(named["search"], {"calls": 0, "hours": 0.0})

    def test_shares_have_no_zero_division(self) -> None:
        only = self.snapshot_only(self.summary([]))
        self.assertEqual((only["share_of_pr_read_hours"], only["share_of_execute_hours"]), (None, None))
        only = self.snapshot_only(self.summary([call(DAY_START + 10, command="ls")]))
        self.assertEqual((only["share_of_pr_read_hours"], only["share_of_execute_hours"]), (None, 0.0))

    def test_the_keepers_are_ranked_by_held_hours_then_name_and_only_snapshot_only_calls_count(self) -> None:
        result = self.summary(
            [
                call(DAY_START + 10, keeper="small", held_s=1.0),
                call(DAY_START + 20, keeper="big", held_s=50.0),
                call(DAY_START + 30, keeper="b-tie", held_s=5.0),
                call(DAY_START + 40, keeper="a-tie", held_s=5.0),
                call(DAY_START + 50, keeper="needy", command="gh pr view 5 --json body", held_s=900.0),
            ]
        )
        top = cast("list[dict[str, object]]", self.snapshot_only(result)["top_keepers"])
        self.assertEqual([row["keeper"] for row in top], ["big", "a-tie", "b-tie", "small"])
        self.assertEqual(top[0], {"keeper": "big", "calls": 1, "hours": round(50 / 3600, 3)})

    def test_only_the_six_keepers_with_the_most_hours_are_listed(self) -> None:
        result = self.summary([call(DAY_START + 10 * i, keeper=f"k{i}", held_s=float(i)) for i in range(1, 9)])
        top = cast("list[dict[str, object]]", self.snapshot_only(result)["top_keepers"])
        self.assertEqual([row["keeper"] for row in top], ["k8", "k7", "k6", "k5", "k4", "k3"])


class MeasureTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.base = pathlib.Path(self.dir.name)

    def write_ledger(self, rows: list[dict[str, object]], lines: list[str] | None = None) -> None:
        folder = self.base / ".masc" / "tool_calls" / "2026-11"
        folder.mkdir(parents=True)
        body = "".join(json.dumps(row) + "\n" for row in rows) + "".join(line + "\n" for line in lines or [])
        (folder / "05.jsonl").write_text(body, encoding="utf-8")

    def row(self, end: float, command: str, tool: str = "Execute") -> dict[str, object]:
        return {
            "record_kind": "tool_call",
            "ts": end,
            "tool": tool,
            "keeper": "k",
            "duration_ms": 2000,
            "result_bytes": 10,
            "disposition": "ok",
            "input": json.dumps({"command": command}),
            "output": "{}",
        }

    def run_main(self, *extra: str) -> tuple[int, pathlib.Path, str]:
        out = self.base / "result.json"
        argv = [
            "--base-path",
            str(self.base),
            "--since",
            "2026-11-05T00:00:00",
            "--end",
            "2026-11-05T01:00:00",
            "--json-out",
            str(out),
            *extra,
        ]
        shown = io.StringIO()
        with contextlib.redirect_stdout(shown), contextlib.redirect_stderr(io.StringIO()):
            code = needs.main(argv)
        return code, out, shown.getvalue()

    def test_the_window_holds_the_calls_from_the_ledger(self) -> None:
        self.write_ledger(
            [
                self.row(DAY_START + 100, SNAPSHOT_FACTS),
                self.row(DAY_START + 200, "gh pr view 5 --json body"),
                self.row(DAY_START + 300, "ls"),
                self.row(DAY_START + 400, SNAPSHOT_FACTS, tool="Grep"),
                self.row(DAY_START + 3_600, SNAPSHOT_FACTS),
            ],
            lines=["not json"],
        )
        code, out, shown = self.run_main()
        result = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(code, 0)
        self.assertEqual(result["window"], ["2026-11-05T00:00:00+00:00", "2026-11-05T01:00:00+00:00"])
        self.assertEqual((result["files"], result["skipped"]), (1, {"bad_lines": 1}))
        self.assertEqual((result["execute_calls"], result["pr_reads"]["calls"]), (3, 2))
        self.assertEqual(result["snapshot_only"]["calls"], 1)
        self.assertEqual(result["only"]["body_or_comments"]["calls"], 1)
        self.assertEqual(json.loads(shown), result)

    def test_no_file_is_written_without_json_out(self) -> None:
        self.write_ledger([])
        shown = io.StringIO()
        with contextlib.redirect_stdout(shown), contextlib.redirect_stderr(io.StringIO()):
            code = needs.main(
                ["--base-path", str(self.base), "--since", "2026-11-05T00:00:00", "--end", "2026-11-05T01:00:00"]
            )
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(shown.getvalue())["execute_calls"], 0)
        self.assertEqual(sorted(path.name for path in self.base.iterdir()), [".masc"])

    def test_a_reversed_window_is_refused(self) -> None:
        self.write_ledger([])
        out = self.base / "result.json"
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = needs.main(
                [
                    "--base-path",
                    str(self.base),
                    "--since",
                    "2026-11-05T01:00:00",
                    "--end",
                    "2026-11-05T01:00:00",
                    "--json-out",
                    str(out),
                ]
            )
        self.assertEqual(code, 2)
        self.assertFalse(out.exists())

    def test_a_window_longer_than_the_limit_is_refused(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = needs.main(
                ["--base-path", str(self.base), "--since", "2025-01-01T00:00:00", "--end", "2026-11-05T01:00:00"]
            )
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()

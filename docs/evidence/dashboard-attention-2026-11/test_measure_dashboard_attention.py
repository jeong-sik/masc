"""Checks measure_dashboard_attention.py on small synthetic dashboard texts, ledgers and blobs.

Run: python3 -m unittest discover -s docs/evidence/dashboard-attention-2026-11
"""

from __future__ import annotations

import contextlib
import datetime
import hashlib
import io
import json
import pathlib
import sys
import tempfile
import unittest
from collections.abc import Sequence
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_dashboard_attention as dash  # noqa: E402

UTC = datetime.timezone.utc
Json = dict[str, object]
STUCK = "masc_agent_timeline"
HELD = "inspect the task owner before choosing recovery"
IDLE = "masc_add_task"
RULE = "---------------------------------------------"
CEILING = 16_384
# Writing the action once drops one 6 + 3 + len(action) + 1 byte line for each item after the first of a run
# and adds " (N items above)", 16 bytes for N below 10. The sample has a run of 2 stuck agents (action of 19
# bytes) and a run of 3 held tasks (action of 47 bytes).
SAVED = (6 + 3 + 19 + 1 - 16) + (2 * (6 + 3 + 47 + 1) - 16)


def at(day: int, hour: int = 0) -> float:
    return datetime.datetime(2026, 11, day, hour, tzinfo=UTC).timestamp()


def held_pair(number: int, title: str, owner: str) -> list[str]:
    return [f"  [~] task-{number} · {title}: held by {owner}, which has no Keeper queue", f"      -> {HELD}"]


def dashboard(workspace: str = "workspace") -> str:
    """The sections of a dashboard text. The third held title is printed after the Tasks section, not in it."""
    return "\n".join(
        [
            "========================================",
            "   MASC Dashboard   2026-11-07 21:45:06",
            f"   Workspace: {workspace} | 3 agents",
            "   Keepers: 12",
            "========================================",
            "",
            "== Attention Required =======================",
            "  [!] Agent stuck: a (10m)",
            f"      -> {STUCK}",
            "  [!] Agent stuck: b (11m, task: task-9)",
            f"      -> {STUCK}",
            *held_pair(1, "파서를 고친다", "claude-1"),
            *held_pair(2, "Fix the printer", "claude-2"),
            *held_pair(3, "Only in messages", "claude-3"),
            "  [i] 2 idle agents with 3 pending tasks",
            f"      -> {IDLE}",
            RULE,
            "",
            "== Agents ===================================",
            "  Working:",
            "    a   0s ago     (unassigned)",
            RULE,
            "",
            "== Tasks ====================================",
            "  [P2] 파서를 고친다 (@claude-1)",
            "  [P2] Fix the printer (@claude-2)",
            "  [P3] Unrelated (@someone)",
            RULE,
            "",
            "== Recent Messages ==========================",
            "  Only in messages (@claude-3)",
            RULE,
        ]
    )


def padded(total: int) -> str:
    """The sample with its workspace name stretched until the text is `total` bytes long."""
    filler = total - len(dashboard("").encode("utf-8"))
    assert filler >= 0
    return dashboard("w" * filler)


def section_of(text: str) -> dash.Section:
    section = dash.split_section(text)
    assert not isinstance(section, str), section
    return section


def stored_call(*, ts: float | bool = at(5), tool: str = "masc_dashboard", kind: str = "tool_call", keeper: str | None = "k1", result_bytes: object = 100, output: object = "") -> Json:
    row: Json = {"record_kind": kind, "tool": tool, "ts": ts, "result_bytes": result_bytes, "output": output}
    if keeper is not None:
        row["keeper"] = keeper
    return row


def write_ledger(base: pathlib.Path, month: str, name: str, lines: Sequence[str]) -> pathlib.Path:
    folder = base / ".masc" / "tool_calls" / month
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / name
    path.write_text("".join(f"{line}\n" for line in lines), encoding="utf-8")
    return path


def as_line(row: Json) -> str:
    return json.dumps(row, ensure_ascii=False)


def store_blob(base: pathlib.Path, text: str) -> str:
    sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
    folder = base / ".masc" / "tool_blobs" / sha[:2]
    folder.mkdir(parents=True, exist_ok=True)
    (folder / sha).write_text(text, encoding="utf-8")
    return sha


def blob_output(sha: str) -> Json:
    return {"_blob": {"sha256": sha, "bytes": 1, "mime": "text/plain", "preview": "p"}}


class SplitTests(unittest.TestCase):
    def test_sample_is_cut_into_head_items_and_tail(self) -> None:
        section = section_of(dashboard())
        self.assertEqual(len(section.head), 7)
        self.assertEqual(section.head[-1], "== Attention Required =======================")
        self.assertEqual([item.action for item in section.items], [STUCK, STUCK, HELD, HELD, HELD, IDLE])
        self.assertEqual(section.items[-1].line, "  [i] 2 idle agents with 3 pending tasks")
        self.assertEqual(section.tail[0], RULE)

    def test_a_body_that_is_not_pairs_is_refused_with_its_reason(self) -> None:
        header = "== Attention Required ==="
        item = "  [!] stuck"
        action = "      -> masc_agent_timeline"
        self.assertEqual(dash.split_section("no section here\n  [!] stuck"), "no_attention_section")
        self.assertEqual(dash.split_section("\n".join([header, item, action, item])), "body_not_pairs")
        self.assertEqual(dash.split_section("\n".join([header, item, item])), "body_not_pairs")
        self.assertEqual(dash.split_section("\n".join([header, action, item])), "body_not_pairs")

    def test_an_empty_body_is_a_section_without_items(self) -> None:
        section = section_of("== Attention Required ===\n  No action needed\n" + RULE)
        self.assertEqual(section.items, ())
        self.assertEqual(section.tail[0], "  No action needed")

    def test_the_info_icon_is_an_item_line(self) -> None:
        self.assertIsNotNone(dash.ITEM_LINE.match("  [i] idle"))
        self.assertIsNone(dash.ITEM_LINE.match("  [P2] a task"))


class RegroupTests(unittest.TestCase):
    def test_a_shared_action_is_written_once_after_its_run(self) -> None:
        text = dashboard()
        after = dash.regroup(section_of(text))
        expected_body = [
            "  [!] Agent stuck: a (10m)",
            "  [!] Agent stuck: b (11m, task: task-9)",
            f"      -> {STUCK} (2 items above)",
            *[line for number, title, owner in [(1, "파서를 고친다", "claude-1"), (2, "Fix the printer", "claude-2"), (3, "Only in messages", "claude-3")] for line in held_pair(number, title, owner)[:1]],
            f"      -> {HELD} (3 items above)",
            "  [i] 2 idle agents with 3 pending tasks",
            f"      -> {IDLE}",
        ]
        lines = after.split("\n")
        head = 7
        self.assertEqual(lines[head : head + len(expected_body)], expected_body)
        self.assertEqual(lines[:head], text.split("\n")[:head])
        self.assertEqual(lines[head + len(expected_body) :], text.split("\n")[head + 12 :])
        self.assertEqual(len(text.encode("utf-8")) - len(after.encode("utf-8")), SAVED)

    def test_runs_are_neighbours_only(self) -> None:
        items = [dash.Item(f"  [~] {name}", action) for name, action in [("a", "x"), ("b", "x"), ("c", "y"), ("d", "x")]]
        self.assertEqual(
            dash.render(items),
            ["  [~] a", "  [~] b", f"{dash.ACTION_PREFIX}x (2 items above)", "  [~] c", f"{dash.ACTION_PREFIX}y", "  [~] d", f"{dash.ACTION_PREFIX}x"],
        )

    def test_no_items_render_no_lines(self) -> None:
        self.assertEqual(dash.render([]), [])
        self.assertEqual(dash.runs_of([]), [])

    def test_original_is_the_text_the_section_was_cut_from(self) -> None:
        text = dashboard()
        self.assertEqual(dash.original(section_of(text)), text)


class ChecksTests(unittest.TestCase):
    def setUp(self) -> None:
        self.text = dashboard()
        self.section = section_of(self.text)
        self.after = dash.regroup(self.section)

    def failed(self, after: str, text: str | None = None) -> set[str]:
        return {name for name, held in dash.checks_hold(self.text if text is None else text, self.section, after).items() if not held}

    def test_a_regrouped_text_passes_every_check(self) -> None:
        self.assertEqual(self.failed(self.after), set())

    def test_a_dropped_item_line_is_found(self) -> None:
        dropped = self.after.replace("  [~] task-2 · Fix the printer: held by claude-2, which has no Keeper queue\n", "")
        self.assertIn("item_lines_kept_in_order", self.failed(dropped))

    def test_a_wrong_or_missing_count_is_found(self) -> None:
        self.assertIn("every_run_closed_by_one_action_line", self.failed(self.after.replace("(3 items above)", "(2 items above)")))
        self.assertIn("every_run_closed_by_one_action_line", self.failed(self.after.replace(" (2 items above)", "")))
        self.assertIn("every_run_closed_by_one_action_line", self.failed(self.after.replace(f"      -> {IDLE}", f"      -> {IDLE} (1 items above)")))

    def test_a_run_split_in_two_with_one_action_is_found(self) -> None:
        split = self.after.replace("  [~] task-3", f"      -> {HELD} (2 items above)\n  [~] task-3").replace(" (3 items above)", "")
        self.assertIn("every_run_closed_by_one_action_line", self.failed(split))

    def test_an_action_the_items_did_not_suggest_is_found(self) -> None:
        self.assertIn("every_run_closed_by_one_action_line", self.failed(self.after.replace(f"-> {STUCK} (2", "-> masc_other (2")))

    def test_an_action_line_without_items_before_it_is_found(self) -> None:
        for action in (f"      -> {IDLE}", f"      -> {IDLE} (0 items above)"):
            lead = self.after.replace("  [!] Agent stuck: a (10m)\n", f"{action}\n  [!] Agent stuck: a (10m)\n")
            self.assertIn("every_run_closed_by_one_action_line", self.failed(lead), action)

    def test_item_lines_left_without_an_action_line_are_found(self) -> None:
        open_end = self.after.replace(f"      -> {IDLE}\n", f"      -> {IDLE}\n  [i] extra\n")
        self.assertIn("every_run_closed_by_one_action_line", self.failed(open_end))
        lost_last = self.after.replace(f"      -> {IDLE}\n", "")
        self.assertIn("every_run_closed_by_one_action_line", self.failed(lost_last))

    def test_a_text_without_a_shared_action_stays_as_it_was(self) -> None:
        text = "\n".join(["== Attention Required ===", "  [!] a", "      -> x", "  [~] b", "      -> y", RULE])
        section = section_of(text)
        after = dash.regroup(section)
        self.assertEqual(after, text)
        self.assertEqual({name for name, held in dash.checks_hold(text, section, after).items() if not held}, set())

    def test_changed_text_outside_the_body_is_found(self) -> None:
        self.assertIn("text_outside_the_body_unchanged", self.failed(self.after.replace("== Agents", "== Agent")))
        self.assertIn("text_outside_the_body_unchanged", self.failed(self.after.replace("MASC Dashboard", "MASC Board")))

    def test_a_longer_text_is_found(self) -> None:
        self.assertIn("not_longer", self.failed(self.text + "xx"))

    def test_a_text_the_section_was_not_cut_from_is_found(self) -> None:
        self.assertIn("split_round_trips", self.failed(self.after, text="another text"))


class TextOfTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name)
        self.blobs = self.base / ".masc" / "tool_blobs"

    def test_a_blob_is_read_whole(self) -> None:
        sha = store_blob(self.base, "첫 줄\n둘째 줄")
        self.assertEqual(dash.text_of(blob_output(sha), 0, self.blobs), ("첫 줄\n둘째 줄", ""))

    def test_a_blob_that_cannot_be_found_is_named(self) -> None:
        self.assertEqual(dash.text_of(blob_output("ab" + "0" * 62), 0, self.blobs), (None, "blob_missing"))
        outputs: list[object] = [{"_blob": {}}, {"_blob": {"sha256": "a"}}, {"_blob": "x"}, {}]
        for output in outputs:
            self.assertEqual(dash.text_of(output, 0, self.blobs), (None, "no_blob_sha"))

    def test_an_inline_text_counts_when_it_is_whole(self) -> None:
        text = "한글 text"
        self.assertEqual(dash.text_of(text, len(text.encode("utf-8")), self.blobs), (text, ""))

    def test_a_cut_inline_text_does_not_count(self) -> None:
        text = "한글 text"
        self.assertEqual(dash.text_of(text, len(text), self.blobs), (None, "cut_excerpt"))
        self.assertEqual(dash.text_of(text + " _truncated", len((text + " _truncated").encode("utf-8")), self.blobs), (None, "cut_excerpt"))

    def test_an_output_of_another_kind_is_named(self) -> None:
        outputs: list[object] = [None, 5, []]
        for output in outputs:
            self.assertEqual(dash.text_of(output, 0, self.blobs), (None, "no_output"))


class LedgerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name)

    def test_ledger_files_of_the_days_the_window_touches(self) -> None:
        for month, name in [("2026-09", "30.jsonl"), ("2026-10", "01.jsonl"), ("2026-10", "01.002.jsonl"), ("2026-10", "02.jsonl"), ("2026-10", "03.jsonl"), ("2026-10", "01.txt"), ("2026-10", "x.jsonl")]:
            write_ledger(self.base, month, name, [])
        since = datetime.datetime(2026, 9, 30, 12, tzinfo=UTC)
        until = datetime.datetime(2026, 10, 2, 1, tzinfo=UTC)
        found = [path.parent.name + "/" + path.name for path in dash.ledger_files(self.base, since, until)]
        self.assertEqual(found, ["2026-09/30.jsonl", "2026-10/01.002.jsonl", "2026-10/01.jsonl", "2026-10/02.jsonl"])

    def test_read_calls_keeps_dashboard_tool_calls_inside_the_window(self) -> None:
        text = "hello 한글"
        rows = [
            as_line(stored_call(ts=at(5, 6), output=text, result_bytes=len(text.encode("utf-8")))),
            as_line(stored_call(ts=at(5, 0), keeper="k2", output=text, result_bytes=len(text.encode("utf-8")))),
            as_line(stored_call(ts=int(at(5, 3)), keeper=None, output="abc", result_bytes="9")),
            as_line(stored_call(ts=at(5, 4), keeper="k3", output="abc", result_bytes=True)),
            as_line(stored_call(ts=at(5, 6), tool="masc_task_list") | {"input": "masc_dashboard"}),
            as_line(stored_call(ts=at(5, 6), kind="turn")),
            as_line(stored_call(ts=at(5, 12))),
            as_line(stored_call(ts=at(4, 23))),
            as_line(stored_call(ts=True)),
            '{"tool": "masc_dashboard", "ts": ',
            '["masc_dashboard"]',
        ]
        path = write_ledger(self.base, "2026-11", "05.jsonl", rows)
        calls = list(dash.read_calls([path], at(5, 0), at(5, 12), self.base / ".masc" / "tool_blobs"))
        self.assertEqual(
            calls,
            [
                dash.Call(keeper="k1", result_bytes=len(text.encode("utf-8")), text=text, unreadable=""),
                dash.Call(keeper="k2", result_bytes=len(text.encode("utf-8")), text=text, unreadable=""),
                dash.Call(keeper="", result_bytes=0, text=None, unreadable="cut_excerpt"),
                dash.Call(keeper="k3", result_bytes=0, text=None, unreadable="cut_excerpt"),
            ],
        )

    def test_a_boolean_is_not_a_time(self) -> None:
        # True is the integer 1, a second inside this window, so only the type check keeps it out.
        rows = [as_line(stored_call(ts=True, result_bytes=7, output="abc")), as_line(stored_call(ts=5, result_bytes=3, output="abc"))]
        path = write_ledger(self.base, "2026-11", "05.jsonl", rows)
        calls = list(dash.read_calls([path], 0.0, 10.0, self.base / ".masc" / "tool_blobs"))
        self.assertEqual([call.result_bytes for call in calls], [3])
        self.assertEqual(dash.window_bytes([path], 0.0, 10.0), 3)

    def test_window_bytes_sums_every_tool_call_in_the_window(self) -> None:
        rows = [
            as_line(stored_call(ts=at(5, 6), tool="masc_dashboard", result_bytes=10)),
            as_line(stored_call(ts=at(5, 7), tool="masc_task_list", result_bytes=20)),
            as_line(stored_call(ts=at(5, 0), tool="Grep", result_bytes=30)),
            as_line(stored_call(ts=at(5, 12), result_bytes=1000)),
            as_line(stored_call(ts=at(4, 23), result_bytes=1000)),
            as_line(stored_call(ts=at(5, 6), kind="turn", result_bytes=1000)),
            as_line(stored_call(ts=True, result_bytes=1000)),
            as_line(stored_call(ts=at(5, 6), result_bytes="5")),
            as_line(stored_call(ts=at(5, 6), result_bytes=True)),
            '{"result_bytes": 7',
            '["result_bytes"]',
        ]
        path = write_ledger(self.base, "2026-11", "05.jsonl", rows)
        self.assertEqual(dash.window_bytes([path], at(5, 0), at(5, 12)), 60)


class TitleTests(unittest.TestCase):
    def test_held_titles_keep_a_colon_inside_the_title(self) -> None:
        lines = "\n".join(
            [
                "  [~] task-1 · RFC: 계약을 정한다: held by claude-1, which has no Keeper queue",
                "  [!] task-2 · severity is not a warning: held by claude-2, which has no Keeper queue",
                "  [~] task-3: held by claude-3, which has no Keeper queue",
                "  [~] task-4 · other text: the Keeper record for k does not decode — why",
            ]
        )
        self.assertEqual(dash.held_titles(lines), ["RFC: 계약을 정한다"])

    def test_tasks_section_ends_at_a_separator_or_the_next_header(self) -> None:
        self.assertEqual(dash.tasks_section("== Tasks ==\n  a\n  b\n---\n  c"), "  a\n  b")
        self.assertEqual(dash.tasks_section("== Tasks ==\n  a\n== Agents ==\n  c"), "  a")
        self.assertEqual(dash.tasks_section("== Agents ==\n  c"), "")

    def test_repeated_title_bytes_counts_titles_the_tasks_section_prints_again(self) -> None:
        # The first title is 6 Hangul syllables at 3 bytes and one space, the second 15 ASCII bytes. The third
        # title is printed after the Tasks section.
        self.assertEqual(dash.repeated_title_bytes(dashboard()), 19 + 15)
        self.assertEqual(dash.repeated_title_bytes("no sections"), 0)


class SummaryTests(unittest.TestCase):
    def test_spread_takes_the_element_at_floor_of_half_of_n_minus_one(self) -> None:
        self.assertEqual(dash.spread([]), {"min": 0, "p50": 0, "max": 0})
        self.assertEqual(dash.spread([5, 1, 3, 2]), {"min": 1, "p50": 2, "max": 5})
        self.assertEqual(dash.spread([9, 4, 7]), {"min": 4, "p50": 7, "max": 9})

    def test_summarize_counts_each_ceiling_at_its_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            base = pathlib.Path(name)
            lane = {32_768: padded(32_768 + SAVED)}
            rows = [
                # before is over 16,384 and after is exactly 16,384
                stored_call(keeper="k1", result_bytes=CEILING + 1, output=blob_output(store_blob(base, padded(CEILING + SAVED)))),
                # before is exactly 16,384
                stored_call(keeper="k1", result_bytes=CEILING, output=blob_output(store_blob(base, padded(CEILING)))),
                # before is over 32,768 and after is exactly 32,768
                stored_call(keeper="k2", result_bytes=32_768 + SAVED, output=blob_output(store_blob(base, lane[32_768]))),
                # a blob that is gone
                stored_call(keeper="k2", result_bytes=40_000, output=blob_output("cd" + "0" * 62)),
                # a text without the section
                stored_call(keeper="k3", result_bytes=len("no section"), output="no section"),
            ]
            path = write_ledger(base, "2026-11", "05.jsonl", [as_line(row) for row in rows])
            summary = dash.summarize(dash.read_calls([path], at(5, 0), at(6, 0), base / ".masc" / "tool_blobs"))
        self.assertEqual(summary["calls"], 5)
        self.assertEqual(summary["keepers"], {"k1": 2, "k2": 2, "k3": 1})
        self.assertEqual(summary["unreadable"], {"blob_missing": 1})
        self.assertEqual(summary["not_split"], {"no_attention_section": 1})
        self.assertEqual(summary["measured_calls"], 3)
        self.assertEqual(summary["bytes_before"], {"sum": (CEILING + SAVED) + CEILING + (32_768 + SAVED), "min": CEILING, "p50": CEILING + SAVED, "max": 32_768 + SAVED})
        self.assertEqual(summary["bytes_after"], {"sum": CEILING + (CEILING - SAVED) + 32_768, "min": CEILING - SAVED, "p50": CEILING, "max": 32_768})
        self.assertEqual(summary["above_ceiling_before"], {"16384": 2, "32768": 1, "65536": 0})
        self.assertEqual(summary["above_ceiling_after"], {"16384": 1, "32768": 0, "65536": 0})
        self.assertEqual(summary["above_ceiling_by_ledger_result_bytes"], {"16384": 3, "32768": 2, "65536": 0})
        self.assertEqual(summary["attention_items"], {"min": 6, "p50": 6, "max": 6})
        self.assertEqual(summary["attention_runs"], {"min": 3, "p50": 3, "max": 3})
        self.assertEqual(summary["held_items"], {"min": 3, "p50": 3, "max": 3})
        self.assertEqual(summary["repeated_title_bytes"], {"min": 34, "p50": 34, "max": 34})
        self.assertEqual(summary["checks_failed"], {})

    def test_summarize_names_a_text_that_cannot_be_cut(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            base = pathlib.Path(name)
            odd = "== Attention Required ===\n  [!] stuck\n"
            rows = [stored_call(result_bytes=len(odd.encode("utf-8")), output=blob_output(store_blob(base, odd)))]
            path = write_ledger(base, "2026-11", "05.jsonl", [as_line(row) for row in rows])
            summary = dash.summarize(dash.read_calls([path], at(5, 0), at(6, 0), base / ".masc" / "tool_blobs"))
        self.assertEqual(summary["not_split"], {"body_not_pairs": 1})
        self.assertEqual(summary["measured_calls"], 0)

    def test_main_writes_the_summary_and_the_window(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            base = pathlib.Path(name)
            text = padded(CEILING)
            rows = [
                stored_call(ts=at(5, 6), result_bytes=CEILING, output=blob_output(store_blob(base, text))),
                stored_call(ts=at(5, 7), tool="Grep", result_bytes=500),
                stored_call(ts=at(6, 7), tool="Grep", result_bytes=9999),
            ]
            write_ledger(base, "2026-11", "05.jsonl", [as_line(row) for row in rows])
            out = base / "result.json"
            printed = io.StringIO()
            with contextlib.redirect_stdout(printed):
                code = dash.main(["--base-path", str(base), "--since", "2026-11-05T00:00:00", "--until", "2026-11-05T12:00:00+00:00", "--json-out", str(out)])
            written = cast("Json", json.loads(out.read_text(encoding="utf-8")))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(printed.getvalue()), written)
        self.assertEqual(written["window_result_bytes_any_tool"], CEILING + 500)
        self.assertEqual(written["window"], {"since": "2026-11-05T00:00:00+00:00", "until": "2026-11-05T12:00:00+00:00", "ledger_files": 1})
        self.assertEqual(written["calls"], 1)

    def test_parse_instant_reads_a_naive_time_as_utc_and_converts_an_offset(self) -> None:
        self.assertEqual(dash.parse_instant("2026-11-03T00:00:00"), datetime.datetime(2026, 11, 3, tzinfo=UTC))
        self.assertEqual(dash.parse_instant("2026-11-03T09:00:00+09:00"), datetime.datetime(2026, 11, 3, tzinfo=UTC))


if __name__ == "__main__":
    unittest.main()

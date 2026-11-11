"""Checks long_turn_shapes.py on small synthetic ledgers.

Run: python3 -m unittest discover -s docs/evidence/tool-efficiency-1111-2026-11
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import pathlib
import sys
import tempfile
import unittest
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import long_turn_shapes as shapes  # noqa: E402

SINCE = "2026-11-10T00:00:00Z"
END = "2026-11-11T00:00:00Z"
START = shapes.ledger.parse_utc("2026-11-10T12:00:00Z")


class Ledger:
    def __init__(self, base: pathlib.Path) -> None:
        self.base = base
        self.clock = START
        self.rows: list[dict[str, object]] = []

    def call(
        self,
        turn: str,
        tool: str = "Execute",
        text: str = "",
        fingerprint: str | None = None,
        size: int = 0,
        keeper: str = "k1",
        ts: float | None = None,
        trace: str = "trace",
    ) -> None:
        self.clock += 1
        row: dict[str, object] = {
            "ts": self.clock if ts is None else ts,
            "record_kind": "tool_call",
            "keeper": keeper,
            "tool": tool,
            "input": {"command": text},
            "result_bytes": size,
            "trace_id": trace,
            "keeper_turn_id": turn,
        }
        if fingerprint is not None:
            row["input_fingerprint"] = fingerprint
        self.rows.append(row)

    def write(self) -> None:
        folder = self.base / ".masc" / "tool_calls" / "2026-11"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / "10.jsonl"
        compact = (json.dumps(row, separators=(",", ":")) for row in self.rows)
        path.write_text("\n".join(compact) + "\n", encoding="utf-8")
        os.utime(path, (self.clock, self.clock))


def run(base: pathlib.Path, *extra: str) -> dict[str, object]:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = shapes.main(["--base-path", str(base), "--since", SINCE, "--end", END, *extra])
    assert code == 0
    return cast(dict[str, object], json.loads(out.getvalue()))


class LongTurnShapesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.base = pathlib.Path(self.directory.name)
        self.ledger = Ledger(self.base)

    def keeper_row(self, result: dict[str, object], name: str = "k1") -> dict[str, object]:
        rows = cast(list[dict[str, object]], result["keepers_by_long_turn_calls"])
        return next(row for row in rows if row["keeper"] == name)

    def test_pr_mentions_are_distinct_per_turn_and_only_in_pr_shaped_text(self) -> None:
        self.ledger.call("long", text="gh pr view 51111 --json state")
        self.ledger.call("long", text="gh api repos/o/r/pulls/51112")
        self.ledger.call("long", text="gh pr view 51111 --json files")
        self.ledger.call("long", text="curl https://x/pull/51113/files then #51114")
        self.ledger.call("long", text="wc -c 51115 and 123456 and #1234 and #1234567 and run 12345678901")
        self.ledger.call("long", text="gh api repos/o/r/issues/51116")
        self.ledger.call("short", text="echo done")
        self.ledger.write()
        row = self.keeper_row(run(self.base, "--long-calls", "6"))
        self.assertEqual(row["long_turns"], 1)
        self.assertEqual(row["long_turn_calls"], 6)
        self.assertEqual(row["calls"], 7)
        self.assertEqual(row["long_turn_call_share"], round(6 / 7, 4))
        self.assertEqual(row["calls_per_turn"], {"n": 2, "median": 3.5, "p90": 6, "max": 6})
        self.assertEqual(cast(dict[str, int], row["prs_per_long_turn"])["median"], 5)
        self.assertEqual(cast(dict[str, int], row["prs_per_short_turn"])["median"], 0)
        self.assertEqual(row["short_turns_without_pr_mention"], 1)

    def test_long_calls_moves_the_split_and_nothing_else(self) -> None:
        for index in range(4):
            self.ledger.call("t", text=f"gh pr view {51000 + index}")
        self.ledger.write()
        low = self.keeper_row(run(self.base, "--long-calls", "4"))
        high = self.keeper_row(run(self.base, "--long-calls", "5"))
        self.assertEqual((low["long_turns"], high["long_turns"]), (1, 0))
        self.assertEqual(low["calls"], high["calls"])

    def test_superseded_is_every_call_but_the_last_of_the_same_input_in_range(self) -> None:
        for size in (1000, 3000, 4000, 5000):
            self.ledger.call("t1", fingerprint="same", size=size)
        self.ledger.call("t1", fingerprint="other", size=9000)
        self.ledger.call("t2", fingerprint="same", size=6000)
        self.ledger.write()
        result = run(self.base)
        sup = cast(dict[str, object], result["superseded"])
        self.assertEqual(sup["superseded_bytes"], 7000)
        self.assertEqual(sup["superseded_calls"], 2)
        self.assertEqual(sup["result_bytes_in_range"], 3000 + 4000 + 5000 + 9000 + 6000)
        self.assertEqual(sup["by_tool"], [["Execute", 7000]])

    def test_a_result_outside_the_byte_range_is_not_counted_even_when_replaced(self) -> None:
        for size in (2047, 65537, 2048, 65536):
            self.ledger.call("t", fingerprint="same", size=size)
        self.ledger.call("t", fingerprint="same", size=70000)
        self.ledger.write()
        sup = cast(dict[str, object], run(self.base)["superseded"])
        self.assertEqual(sup["superseded_bytes"], 2048 + 65536)
        self.assertEqual(sup["superseded_calls"], 2)
        self.assertEqual(sup["result_bytes_in_range"], 2048 + 65536)

    def test_the_last_call_is_chosen_by_time_not_by_file_order(self) -> None:
        self.ledger.call("t", fingerprint="same", size=9000, ts=START + 50)
        self.ledger.call("t", fingerprint="same", size=3000, ts=START + 10)
        self.ledger.write()
        sup = cast(dict[str, object], run(self.base)["superseded"])
        self.assertEqual(sup["superseded_bytes"], 3000)

    def test_a_call_without_a_fingerprint_is_never_replaced(self) -> None:
        self.ledger.call("t", size=4000)
        self.ledger.call("t", size=4000)
        self.ledger.write()
        sup = cast(dict[str, object], run(self.base)["superseded"])
        self.assertEqual(sup["superseded_calls"], 0)

    def test_rows_outside_the_window_are_left_out(self) -> None:
        self.ledger.call("t", text="gh pr view 51111", ts=shapes.ledger.parse_utc("2026-11-09T23:59:59Z"))
        self.ledger.call("t", text="gh pr view 51112", ts=shapes.ledger.parse_utc("2026-11-11T00:00:00Z"))
        self.ledger.call("t", text="gh pr view 51113", ts=shapes.ledger.parse_utc("2026-11-10T00:00:00Z"))
        self.ledger.write()
        result = run(self.base)
        self.assertEqual(result["calls"], 1)

    def test_keepers_are_ranked_by_calls_in_long_turns(self) -> None:
        for _ in range(3):
            self.ledger.call("a", keeper="few")
        for _ in range(6):
            self.ledger.call("b", keeper="many")
        self.ledger.write()
        rows = cast(
            list[dict[str, object]],
            run(self.base, "--long-calls", "3")["keepers_by_long_turn_calls"],
        )
        self.assertEqual([row["keeper"] for row in rows], ["many", "few"])

    def test_the_same_fingerprint_on_another_tool_is_another_input(self) -> None:
        self.ledger.call("t", tool="Execute", fingerprint="same", size=4000)
        self.ledger.call("t", tool="Grep", fingerprint="same", size=4000)
        self.ledger.write()
        sup = cast(dict[str, object], run(self.base)["superseded"])
        self.assertEqual(sup["superseded_calls"], 0)

    def test_a_turn_is_the_pair_of_trace_and_turn_id(self) -> None:
        self.ledger.call("1", fingerprint="same", size=4000, trace="a")
        self.ledger.call("1", fingerprint="same", size=4000, trace="b")
        self.ledger.write()
        result = run(self.base)
        self.assertEqual(result["turns"], 2)
        self.assertEqual(cast(dict[str, object], result["superseded"])["superseded_calls"], 0)

    def test_superseded_is_split_by_tool_and_keeper(self) -> None:
        self.ledger.call("t", tool="Grep", fingerprint="g", size=3000, keeper="a")
        self.ledger.call("t", tool="Grep", fingerprint="g", size=3000, keeper="a")
        self.ledger.call("u", tool="Execute", fingerprint="e", size=5000, keeper="b")
        self.ledger.call("u", tool="Execute", fingerprint="e", size=5000, keeper="b")
        self.ledger.write()
        sup = cast(dict[str, object], run(self.base)["superseded"])
        self.assertEqual(sup["by_tool"], [["Execute", 5000], ["Grep", 3000]])
        self.assertEqual(sup["by_keeper"], [["b", 5000], ["a", 3000]])
        self.assertEqual(sup["superseded_share"], round(8000 / 16000, 4))

    def test_superseded_share_is_replaced_bytes_over_bytes_in_range(self) -> None:
        self.ledger.call("t", fingerprint="same", size=2048)
        self.ledger.call("t", fingerprint="same", size=2048)
        self.ledger.write()
        sup = cast(dict[str, object], run(self.base)["superseded"])
        self.assertEqual((sup["superseded_bytes"], sup["result_bytes_in_range"]), (2048, 4096))
        self.assertEqual(sup["superseded_share"], 0.5)

    def test_a_row_without_a_tool_name_is_left_out(self) -> None:
        self.ledger.call("t")
        self.ledger.rows.append(
            {
                "ts": START + 99,
                "record_kind": "tool_call",
                "keeper": "k1",
                "input": {},
                "trace_id": "trace",
                "keeper_turn_id": "t",
            }
        )
        self.ledger.write()
        self.assertEqual(run(self.base)["calls"], 1)

    def test_the_summary_counts_long_turns_and_their_share_of_calls(self) -> None:
        for _ in range(4):
            self.ledger.call("long")
        self.ledger.call("short")
        self.ledger.write()
        result = run(self.base, "--long-calls", "4")
        self.assertEqual(result["long_turns"], {"turns": 1, "calls": 4, "share_of_calls": 0.8})
        self.assertEqual(result["turns"], 2)
        self.assertEqual(result["calls"], 5)
        self.assertEqual(result["params"], {"long_calls": 4, "min_bytes": 2048, "max_bytes": 65536})

    def test_ties_in_long_turn_calls_are_ordered_by_keeper_name(self) -> None:
        for _ in range(2):
            self.ledger.call("z-turn", keeper="zed")
        for _ in range(2):
            self.ledger.call("a-turn", keeper="abe")
        self.ledger.write()
        rows = cast(list[dict[str, object]], run(self.base, "--long-calls", "2")["keepers_by_long_turn_calls"])
        self.assertEqual([row["keeper"] for row in rows], ["abe", "zed"])

    def test_top_limits_the_keeper_rows(self) -> None:
        for name in ("a", "b", "c"):
            self.ledger.call(name, keeper=name)
        self.ledger.write()
        rows = cast(list[dict[str, object]], run(self.base, "--top", "2")["keepers_by_long_turn_calls"])
        self.assertEqual(len(rows), 2)

    def test_quantiles_use_the_mean_of_the_middle_pair_and_the_p90_index(self) -> None:
        self.assertEqual(shapes.quantiles([]), {"n": 0})
        self.assertEqual(shapes.quantiles([7]), {"n": 1, "median": 7, "p90": 7, "max": 7})
        self.assertEqual(shapes.quantiles(list(range(10, 0, -1))), {"n": 10, "median": 5.5, "p90": 10, "max": 10})
        self.assertEqual(shapes.quantiles([4, 4]), {"n": 2, "median": 4, "p90": 4, "max": 4})
        self.assertEqual(
            shapes.quantiles(list(range(1, 22))), {"n": 21, "median": 11, "p90": 19, "max": 21}
        )

    def test_json_out_is_written(self) -> None:
        self.ledger.call("t", text="gh pr view 51111")
        self.ledger.write()
        out = self.base / "result.json"
        run(self.base, "--json-out", str(out))
        written = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(written["turns"], 1)
        self.assertEqual(written["window"], {"since": SINCE, "end": END})


if __name__ == "__main__":
    unittest.main()

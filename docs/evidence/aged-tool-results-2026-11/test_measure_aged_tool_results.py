"""Checks the arithmetic of measure_aged_tool_results.py on small synthetic stores.

Run: python3 -m unittest discover -s docs/evidence/aged-tool-results-2026-11
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

import measure_aged_tool_results as aged_tool  # noqa: E402

DAY = "2026-11-02"
MARKER = 100
THRESHOLDS = (500, 1000)
HEADLINE = 500
Spec = tuple[str, int] | tuple[str, int, bool]


def entry(position: int, spec: Spec) -> dict[str, object]:
    role, size = spec[0], spec[1]
    media: list[object] = [{"type": "image"}] if len(spec) == 3 and spec[2] else []
    return {"index": position, "role": role, "artifact": {"bytes": size}, "media": media}


def row(specs: list[Spec], system: int = 0, schemas: tuple[int, ...] = ()) -> dict[str, object]:
    return {
        "messages": [entry(position, spec) for position, spec in enumerate(specs)],
        "system_prompt": {"bytes": system},
        "tool_schemas": [{"artifact": {"bytes": size}} for size in schemas],
    }


def write_rows(
    base: pathlib.Path, keeper: str, day: str, rows: list[object], name: str | None = None
) -> pathlib.Path:
    month, number = day[:7], day[8:]
    folder = base / ".masc" / "keepers" / keeper / "provider-inputs" / month
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / (name or f"{number}.jsonl")
    path.write_text("\n".join(json.dumps(item) for item in rows) + "\n", encoding="utf-8")
    return path


def measure(
    base: pathlib.Path,
    first: str = DAY,
    last: str = DAY,
    excluded: tuple[str, ...] = (),
) -> tuple[aged_tool.Tally, aged_tool.Skipped]:
    return aged_tool.measure(base, first, last, THRESHOLDS, MARKER, HEADLINE, excluded)


def report(
    base: pathlib.Path,
    first: str = DAY,
    last: str = DAY,
    excluded: tuple[str, ...] = (),
) -> dict[str, object]:
    tally, skipped = measure(base, first, last, excluded)
    return aged_tool.report(tally, skipped, THRESHOLDS, MARKER, HEADLINE, 12)


def obj(value: object) -> dict[str, object]:
    return cast(dict[str, object], value)


# user(10) assistant(20) tool(5000) | user(30) assistant(40) tool(700)
TWO_TURNS: list[Spec] = [("user", 10), ("assistant", 20), ("tool", 5000), ("user", 30), ("assistant", 40), ("tool", 700)]


class CutTests(unittest.TestCase):
    def messages(self, specs: list[Spec]) -> tuple[aged_tool.Message, ...]:
        return tuple(aged_tool.Message(s[0], s[1], len(s) == 3 and s[2]) for s in specs)

    def test_only_results_before_the_cut_age(self) -> None:
        result = aged_tool.apply_cut(self.messages(TWO_TURNS), 3, THRESHOLDS, MARKER)
        self.assertEqual(result.aged_bytes, 5000)
        self.assertEqual(result.saved, (4900, 4900))

    def test_the_cut_message_itself_is_not_aged(self) -> None:
        specs: list[Spec] = [("tool", 5000), ("tool", 6000)]
        result = aged_tool.apply_cut(self.messages(specs), 1, THRESHOLDS, MARKER)
        self.assertEqual(result.aged_bytes, 5000)

    def test_exposed_bytes_start_at_the_cut_message(self) -> None:
        result = aged_tool.apply_cut(self.messages(TWO_TURNS), 3, THRESHOLDS, MARKER)
        self.assertEqual(result.exposed_bytes, 30 + 40 + 700)

    def test_threshold_is_inclusive(self) -> None:
        specs: list[Spec] = [("tool", 499), ("tool", 500), ("user", 1)]
        result = aged_tool.apply_cut(self.messages(specs), 2, (500,), MARKER)
        self.assertEqual(result.saved, (400,))

    def test_a_result_no_larger_than_the_marker_saves_nothing(self) -> None:
        specs: list[Spec] = [("tool", MARKER - 60), ("tool", MARKER), ("tool", MARKER + 1), ("user", 1)]
        result = aged_tool.apply_cut(self.messages(specs), 3, (0,), MARKER)
        self.assertEqual(result.saved, (1,))

    def test_results_with_media_are_left_alone(self) -> None:
        specs: list[Spec] = [("tool", 5000, True), ("tool", 3000), ("user", 1)]
        result = aged_tool.apply_cut(self.messages(specs), 2, THRESHOLDS, MARKER)
        self.assertEqual(result.aged_bytes, 3000)
        self.assertEqual(result.saved, (2900, 2900))

    def test_other_roles_do_not_age(self) -> None:
        specs: list[Spec] = [("assistant", 9000), ("user", 9000), ("system", 9000), ("tool", 800), ("user", 1)]
        result = aged_tool.apply_cut(self.messages(specs), 4, THRESHOLDS, MARKER)
        self.assertEqual(result.aged_bytes, 800)

    def test_each_threshold_counts_its_own_results(self) -> None:
        specs: list[Spec] = [("tool", 600), ("tool", 1500), ("user", 1)]
        result = aged_tool.apply_cut(self.messages(specs), 2, THRESHOLDS, MARKER)
        self.assertEqual(result.saved, (500 + 1400, 1400))


class QuantileTests(unittest.TestCase):
    def test_nearest_rank(self) -> None:
        values = [0.1, 0.2, 0.3, 0.4]
        self.assertEqual([aged_tool.quantile(values, q) for q in (0.25, 0.5, 0.75, 0.9, 1.0)], [0.1, 0.2, 0.3, 0.4, 0.4])

    def test_one_value_answers_every_quantile(self) -> None:
        self.assertEqual(aged_tool.quantile([0.7], 0.25), 0.7)

    def test_a_tiny_quantile_picks_the_first_value(self) -> None:
        self.assertEqual(aged_tool.quantile([0.1, 0.2], 0.01), 0.1)


class MeasureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.base = pathlib.Path(self.directory.name)

    def test_rules_cut_at_the_last_and_the_one_before(self) -> None:
        specs: list[Spec] = [("user", 1), ("tool", 5000), ("user", 1), ("tool", 3000), ("user", 1), ("tool", 800)]
        write_rows(self.base, "k", DAY, [row(specs)])
        rules = obj(report(self.base)["rules"])
        current, previous = obj(rules["before_current_turn"]), obj(rules["before_previous_turn"])
        self.assertEqual(current["aged_tool_bytes"], 5000 + 3000)
        self.assertEqual(previous["aged_tool_bytes"], 5000)
        self.assertEqual(obj(current["saved_bytes_by_threshold"]), {"500": 4900 + 2900, "1000": 4900 + 2900})
        self.assertEqual(obj(previous["saved_bytes_by_threshold"]), {"500": 4900, "1000": 4900})

    def test_aged_and_exposed_shares_are_over_prompt_bytes(self) -> None:
        specs: list[Spec] = [("user", 1), ("tool", 5000), ("user", 2), ("tool", 3000), ("user", 4), ("tool", 800)]
        write_rows(self.base, "k", DAY, [row(specs, system=1000, schemas=(2000,))])
        rules = obj(report(self.base)["rules"])
        current, previous = obj(rules["before_current_turn"]), obj(rules["before_previous_turn"])
        prompt = 1 + 5000 + 2 + 3000 + 4 + 800 + 1000 + 2000
        self.assertEqual(current["aged_tool_share"], round(8000 / prompt, 4))
        self.assertEqual(current["exposed_share"], round(804 / prompt, 4))
        self.assertEqual(previous["aged_tool_share"], round(5000 / prompt, 4))
        self.assertEqual(previous["exposed_share"], round(3806 / prompt, 4))

    def test_exposed_bytes_follow_the_cut_of_each_rule(self) -> None:
        specs: list[Spec] = [("user", 1), ("tool", 5000), ("user", 2), ("tool", 3000), ("user", 4), ("tool", 800)]
        write_rows(self.base, "k", DAY, [row(specs)])
        rules = obj(report(self.base)["rules"])
        self.assertEqual(obj(rules["before_current_turn"])["exposed_bytes"], 4 + 800)
        self.assertEqual(obj(rules["before_previous_turn"])["exposed_bytes"], 2 + 3000 + 4 + 800)

    def test_prompt_bytes_add_system_prompt_and_tool_schemas(self) -> None:
        write_rows(self.base, "k", DAY, [row(TWO_TURNS, system=1000, schemas=(300, 200))])
        result = report(self.base)
        self.assertEqual(result["prompt_bytes"], 10 + 20 + 5000 + 30 + 40 + 700 + 1000 + 500)
        shares = obj(result["shares_of_prompt"])
        self.assertEqual(shares["system_prompt"], round(1000 / 7300, 4))
        self.assertEqual(shares["tool_schemas"], round(500 / 7300, 4))
        self.assertEqual(shares["tool_messages"], round(5700 / 7300, 4))

    def test_saved_share_is_over_prompt_bytes(self) -> None:
        write_rows(self.base, "k", DAY, [row(TWO_TURNS, system=1000)])
        current = obj(obj(report(self.base)["rules"])["before_current_turn"])
        self.assertEqual(obj(current["saved_share_by_threshold"])["500"], round(4900 / 6800, 4))

    def test_a_request_without_a_previous_turn_is_counted_apart(self) -> None:
        one_turn: list[Spec] = [("user", 1), ("tool", 5000)]
        write_rows(self.base, "k", DAY, [row(one_turn), row(TWO_TURNS)])
        result = report(self.base)
        self.assertEqual(obj(result["requests"])["counted"], 1)
        self.assertEqual(obj(result["requests"])["no_boundary"], 1)
        self.assertEqual(result["prompt_bytes"], 5800)

    def test_messages_are_ordered_by_index(self) -> None:
        shuffled = row(TWO_TURNS)
        messages = cast(list[object], shuffled["messages"])
        messages.reverse()
        write_rows(self.base, "k", DAY, [shuffled])
        current = obj(obj(report(self.base)["rules"])["before_current_turn"])
        self.assertEqual(current["aged_tool_bytes"], 5000)

    def test_a_message_without_an_index_keeps_its_place(self) -> None:
        plain = row(TWO_TURNS)
        for message in cast(list[dict[str, object]], plain["messages"]):
            del message["index"]
        write_rows(self.base, "k", DAY, [plain])
        current = obj(obj(report(self.base)["rules"])["before_current_turn"])
        self.assertEqual(current["aged_tool_bytes"], 5000)

    def test_unusable_entries_and_lines_are_counted_and_skipped(self) -> None:
        broken = row(TWO_TURNS)
        cast(list[object], broken["messages"]).extend([{"role": "tool"}, "text", {"index": 9, "artifact": {"bytes": 5}}])
        path = write_rows(self.base, "k", DAY, [broken])
        with path.open("a", encoding="utf-8") as handle:
            handle.write("not json\n[1]\n{\"messages\": 3}\n")
        requests = obj(report(self.base)["requests"])
        self.assertEqual(requests["bad_message_entries"], 3)
        self.assertEqual(requests["bad_lines"], 3)
        self.assertEqual(requests["counted"], 1)

    def test_a_boolean_size_is_not_a_size(self) -> None:
        specs = row(TWO_TURNS)
        cast(list[dict[str, object]], specs["messages"])[2]["artifact"] = {"bytes": True}
        write_rows(self.base, "k", DAY, [specs])
        self.assertEqual(obj(report(self.base)["requests"])["bad_message_entries"], 1)

    def test_media_results_are_counted_but_never_saved(self) -> None:
        specs: list[Spec] = [("user", 1), ("tool", 5000, True), ("user", 1), ("tool", 100), ("user", 1)]
        write_rows(self.base, "k", DAY, [row(specs)])
        result = report(self.base)
        self.assertEqual(obj(result["tool_messages"]), {"count": 2, "with_media": 1})
        current = obj(obj(result["rules"])["before_current_turn"])
        self.assertEqual(current["aged_tool_bytes"], 100)

    def test_days_outside_the_window_are_ignored(self) -> None:
        write_rows(self.base, "k", "2026-11-01", [row(TWO_TURNS)])
        write_rows(self.base, "k", "2026-11-03", [row(TWO_TURNS)])
        write_rows(self.base, "k", DAY, [row(TWO_TURNS)])
        self.assertEqual(obj(report(self.base)["requests"])["counted"], 1)
        self.assertEqual(obj(report(self.base, first="2026-11-01", last="2026-11-03")["requests"])["counted"], 3)

    def test_a_file_that_is_not_a_day_is_ignored(self) -> None:
        write_rows(self.base, "k", DAY, [row(TWO_TURNS)], name="02.001.jsonl")
        self.assertEqual(obj(report(self.base, last="2026-11-03")["requests"])["counted"], 0)

    def test_an_excluded_keeper_is_not_read(self) -> None:
        write_rows(self.base, "kept", DAY, [row(TWO_TURNS)])
        write_rows(self.base, "left-out", DAY, [row(TWO_TURNS), row(TWO_TURNS)])
        result = report(self.base, excluded=("left-out",))
        self.assertEqual(obj(result["requests"])["counted"], 1)
        self.assertEqual([item["keeper"] for item in cast(list[dict[str, object]], result["by_keeper"])], ["kept"])

    def test_keepers_are_ordered_by_prompt_bytes(self) -> None:
        small: list[Spec] = [("user", 1), ("user", 1)]
        write_rows(self.base, "small", DAY, [row(small)])
        write_rows(self.base, "large", DAY, [row(TWO_TURNS)])
        write_rows(self.base, "medium", DAY, [row([("user", 1), ("tool", 900), ("user", 1)])])
        names = [item["keeper"] for item in cast(list[dict[str, object]], report(self.base)["by_keeper"])]
        self.assertEqual(names, ["large", "medium", "small"])

    def test_keeper_share_uses_the_headline_threshold_and_the_current_turn(self) -> None:
        write_rows(self.base, "k", DAY, [row(TWO_TURNS)])
        keeper = cast(list[dict[str, object]], report(self.base)["by_keeper"])[0]
        self.assertEqual(keeper["saved_share_before_current_turn_at_headline"], round(4900 / 5800, 4))
        self.assertEqual(keeper["requests"], 1)

    def test_each_keeper_share_is_over_its_own_prompt(self) -> None:
        padded = row(TWO_TURNS, system=5800)
        write_rows(self.base, "padded", DAY, [padded])
        write_rows(self.base, "plain", DAY, [row(TWO_TURNS)])
        shares = {
            item["keeper"]: item["saved_share_before_current_turn_at_headline"]
            for item in cast(list[dict[str, object]], report(self.base)["by_keeper"])
        }
        self.assertEqual(shares, {"padded": round(4900 / 11600, 4), "plain": round(4900 / 5800, 4)})

    def test_per_request_quantiles_come_from_each_request(self) -> None:
        none: list[Spec] = [("user", 1), ("tool", 50), ("user", 1), ("user", 1)]
        write_rows(self.base, "k", DAY, [row(TWO_TURNS, system=1000), row(none)])
        current = obj(obj(report(self.base)["rules"])["before_current_turn"])
        quantiles = obj(current["per_request_saved_share_at_headline"])
        self.assertEqual(quantiles["p25"], 0.0)
        self.assertEqual(quantiles["p90"], round(4900 / 6800, 4))

    def test_the_headline_threshold_picks_the_quantile_series(self) -> None:
        specs: list[Spec] = [("user", 1), ("tool", 700), ("user", 1), ("user", 1)]
        write_rows(self.base, "k", DAY, [row(specs)])
        tally, skipped = aged_tool.measure(self.base, DAY, DAY, THRESHOLDS, MARKER, 1000, ())
        result = aged_tool.report(tally, skipped, THRESHOLDS, MARKER, 1000, 12)
        current = obj(obj(result["rules"])["before_current_turn"])
        self.assertEqual(obj(current["per_request_saved_share_at_headline"])["p50"], 0.0)
        keeper = cast(list[dict[str, object]], result["by_keeper"])[0]
        self.assertEqual(keeper["saved_share_before_current_turn_at_headline"], 0.0)

    def test_requests_fall_into_prompt_size_bands(self) -> None:
        def sized(total: int) -> dict[str, object]:
            return row([("user", 1), ("tool", total - 3), ("user", 1), ("user", 1)])

        write_rows(self.base, "k", DAY, [sized(99_999), sized(100_000), sized(999_999), sized(1_000_000), sized(4_999_999), sized(5_000_000)])
        bands = cast(list[dict[str, object]], report(self.base)["by_prompt_size"])
        self.assertEqual([band["prompt_bytes_below"] for band in bands], [100_000, 1_000_000, 5_000_000, None])
        self.assertEqual([band["requests"] for band in bands], [1, 2, 2, 1])

    def test_band_shares_are_over_the_band_and_over_all_requests(self) -> None:
        small = row([("user", 1), ("tool", 4000), ("user", 1), ("user", 1)])
        large = row([("user", 1), ("tool", 200_000), ("user", 1), ("user", 1)])
        write_rows(self.base, "k", DAY, [small, large])
        low, middle = cast(list[dict[str, object]], report(self.base)["by_prompt_size"])[:2]
        total = 4003 + 200_003
        self.assertEqual(low["prompt_share"], round(4003 / total, 4))
        self.assertEqual(low["saved_share_of_band"], round(3900 / 4003, 4))
        self.assertEqual(low["saved_share_of_total"], round(3900 / total, 4))
        self.assertEqual(middle["prompt_share"], round(200_003 / total, 4))
        self.assertEqual(middle["saved_share_of_band"], round(199_900 / 200_003, 4))
        self.assertEqual(middle["saved_share_of_total"], round(199_900 / total, 4))

    def test_band_savings_use_the_headline_threshold_and_the_current_turn(self) -> None:
        write_rows(self.base, "k", DAY, [row([("user", 1), ("tool", 700), ("user", 1), ("tool", 9000), ("user", 1)])])
        tally, skipped = aged_tool.measure(self.base, DAY, DAY, THRESHOLDS, MARKER, 1000, ())
        result = aged_tool.report(tally, skipped, THRESHOLDS, MARKER, 1000, 12)
        first = cast(list[dict[str, object]], result["by_prompt_size"])[0]
        self.assertEqual(first["saved_share_of_total"], round(8900 / 9703, 4))

    def test_top_limits_the_keeper_rows(self) -> None:
        for name in ("a", "b", "c"):
            write_rows(self.base, name, DAY, [row(TWO_TURNS)])
        tally, skipped = measure(self.base)
        self.assertEqual(len(cast(list[object], aged_tool.report(tally, skipped, THRESHOLDS, MARKER, HEADLINE, 2)["by_keeper"])), 2)

    def test_an_empty_store_reports_zeros(self) -> None:
        result = report(self.base)
        self.assertEqual(result["prompt_bytes"], 0)
        current = obj(obj(result["rules"])["before_current_turn"])
        self.assertEqual(current["saved_share_by_threshold"], {"500": 0.0, "1000": 0.0})
        self.assertEqual(current["per_request_saved_share_at_headline"], {})


class CommandLineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.base = pathlib.Path(self.directory.name)
        write_rows(self.base, "k", DAY, [row(TWO_TURNS)])

    def run_main(self, *args: str) -> int:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return aged_tool.main(["--base-path", str(self.base), "--from-date", DAY, "--to-date", DAY, *args])

    def test_json_out_writes_the_report(self) -> None:
        target = self.base / "out.json"
        self.assertEqual(self.run_main("--json-out", str(target)), 0)
        self.assertTrue(target.read_text(encoding="utf-8").endswith("}\n"))
        written = json.loads(target.read_text(encoding="utf-8"))
        self.assertEqual(written["params"], {"marker_bytes": 596, "thresholds": [1024, 2048, 4096, 16384], "headline_threshold": 2048})
        self.assertEqual(written["requests"]["counted"], 1)

    def test_options_reach_the_measurement(self) -> None:
        target = self.base / "out.json"
        self.run_main("--marker-bytes", "100", "--threshold", "500", "--headline-threshold", "500", "--json-out", str(target))
        written = json.loads(target.read_text(encoding="utf-8"))
        self.assertEqual(written["params"], {"marker_bytes": 100, "thresholds": [500], "headline_threshold": 500})
        self.assertEqual(written["rules"]["before_current_turn"]["saved_bytes_by_threshold"], {"500": 4900})

    def test_exclude_keeper_option(self) -> None:
        target = self.base / "out.json"
        self.run_main("--exclude-keeper", "k", "--json-out", str(target))
        self.assertEqual(json.loads(target.read_text(encoding="utf-8"))["requests"]["counted"], 0)

    def test_the_report_prints_when_no_file_is_named(self) -> None:
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            aged_tool.main(["--base-path", str(self.base), "--from-date", DAY, "--to-date", DAY])
        self.assertEqual(json.loads(buffer.getvalue())["requests"]["counted"], 1)

    def test_a_bad_day_is_a_usage_error(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.run_main("--from-date", "yesterday")
        self.assertEqual(raised.exception.code, 2)

    def test_a_headline_outside_the_thresholds_is_a_usage_error(self) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.run_main("--threshold", "500", "--headline-threshold", "999")
        self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()

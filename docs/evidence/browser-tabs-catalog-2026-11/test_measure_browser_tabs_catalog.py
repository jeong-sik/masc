"""Checks measure_browser_tabs_catalog.py on small synthetic results, ledgers and blobs.

Run: python3 -m unittest discover -s docs/evidence/browser-tabs-catalog-2026-11
"""

from __future__ import annotations

import datetime
import hashlib
import json
import pathlib
import sys
import tempfile
import unittest
from typing import cast

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import measure_browser_tabs_catalog as catalog  # noqa: E402

UTC = datetime.timezone.utc
Json = dict[str, object]
LONG = "c" * 400


def at(day: int, hour: int = 0) -> float:
    return datetime.datetime(2026, 11, day, hour, tzinfo=UTC).timestamp()


def available(operation: str) -> Json:
    return {"operation": operation, "status": "available", "tool": "masc_browser_tabs"}


def conditional(operation: str, action: str) -> Json:
    return {"operation": operation, "status": "conditional", "tool": "masc_browser_interact", "action": action, "constraints": [LONG, operation]}


def unsupported(operation: str) -> Json:
    return {"operation": operation, "status": "unsupported", "reason": "No public browser tool implements this operation."}


def stored(required: list[str]) -> Json:
    """A result as the code before the change wrote it: the catalog and the echo come first."""
    return {
        "browserCapabilities": {
            "scope": catalog.SCOPE_BEFORE,
            "operations": [available("list_tabs"), conditional("hover", "hover"), conditional("type_text", "type_text"), unsupported("close_window")],
        },
        "requiredActions": cast("object", required),
        "source": "live",
        "browserSelection": {"lane": "live"},
        "clientId": "c1",
        "tabs": [{"id": 1, "title": "t"}],
    }


def rows_of(result: Json) -> list[Json]:
    return catalog.operations_of(result) or []


class ReprojectTest(unittest.TestCase):
    def test_a_conditional_row_keeps_its_constraints_only_when_named(self) -> None:
        row = conditional("hover", "hover")
        self.assertEqual(catalog.reproject_row(row, True), row)
        self.assertEqual(catalog.reproject_row(row, False), {"operation": "hover", "status": "conditional", "tool": "masc_browser_interact", "action": "hover"})

    def test_an_available_and_an_unsupported_row_are_the_same_named_or_not(self) -> None:
        for row in (available("list_tabs"), unsupported("close_window")):
            self.assertEqual(catalog.reproject_row(row, True), row)
            self.assertEqual(catalog.reproject_row(row, False), row)

    def test_the_selection_and_tabs_come_first_then_the_catalog_and_the_echo(self) -> None:
        after = catalog.reproject(stored([]))
        self.assertEqual(list(after), ["source", "browserSelection", "clientId", "tabs", "browserCapabilities", "requiredActions"])
        self.assertEqual(cast("Json", after["browserCapabilities"])["scope"], catalog.SCOPE_AFTER)

    def test_only_the_named_conditional_operations_list_constraints(self) -> None:
        self.assertEqual([r["operation"] for r in rows_of(catalog.reproject(stored([]))) if "constraints" in r], [])
        after = catalog.reproject(stored(["type_text", "list_tabs", "close_window"]))
        self.assertEqual([r["operation"] for r in rows_of(after) if "constraints" in r], ["type_text"])
        self.assertEqual([r["operation"] for r in rows_of(after)], ["list_tabs", "hover", "type_text", "close_window"])

    def test_a_result_without_a_catalog_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            catalog.reproject({"tabs": []})

    def test_the_checks_hold_for_a_reprojection_and_name_what_a_bad_one_breaks(self) -> None:
        before = stored(["hover"])
        good = catalog.reproject(before)
        self.assertEqual([name for name, held in catalog.checks_hold(before, good).items() if not held], [])
        everything = cast("Json", json.loads(json.dumps(good)))
        cast("Json", everything["browserCapabilities"])["operations"] = rows_of(before)
        self.assertIn("constraints_exactly_for_named_conditional_rows", [n for n, held in catalog.checks_hold(before, everything).items() if not held])
        reordered = dict(reversed(list(good.items())))
        self.assertIn("catalog_and_echo_last", [n for n, held in catalog.checks_hold(before, reordered).items() if not held])
        shorter = cast("Json", json.loads(json.dumps(good)))
        cast("list[object]", cast("Json", shorter["browserCapabilities"])["operations"]).pop()
        self.assertIn("every_row_kept_in_order", [n for n, held in catalog.checks_hold(before, shorter).items() if not held])

    def test_json_bytes_is_compact_utf8(self) -> None:
        self.assertEqual(catalog.json_bytes({"a": "가"}), len('{"a":"가"}'.encode("utf-8")))

    def test_the_scope_text_is_the_text_the_ocaml_file_writes(self) -> None:
        source = (pathlib.Path(__file__).resolve().parents[3] / "lib" / "browser_capabilities.ml").read_text(encoding="utf-8")
        self.assertIn(f'`String "{catalog.SCOPE_AFTER}"', source)


class Fixture:
    """A temporary base path with one ledger file and the blobs its rows point at."""

    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        self.rows: list[str] = []

    def blob(self, text: str) -> Json:
        sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
        folder = self.root / ".masc" / "tool_blobs" / sha[:2]
        folder.mkdir(parents=True, exist_ok=True)
        (folder / sha).write_text(text, encoding="utf-8")
        return {"_blob": {"sha256": sha, "bytes": len(text.encode("utf-8"))}}

    def add(self, stamp: float, output: object, size: int, tool_name: str = "BrowserTabs", keeper: str = "k") -> None:
        self.rows.append(json.dumps({"ts": stamp, "record_kind": "tool_call", "tool": tool_name, "keeper": keeper, "output": output, "result_bytes": size}))

    def summary(self, since: float, until: float) -> Json:
        folder = self.root / ".masc" / "tool_calls" / "2026-11"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "07.jsonl").write_text("\n".join(self.rows) + "\n", encoding="utf-8")
        start = datetime.datetime.fromtimestamp(since, UTC)
        end = datetime.datetime.fromtimestamp(until, UTC)
        paths = catalog.ledger_files(self.root, start, end)
        return catalog.summarize(catalog.read_calls(paths, since, until, self.root / ".masc" / "tool_blobs"))


def padded(required: list[str]) -> tuple[str, int]:
    text = json.dumps(stored(required), separators=(",", ":"), ensure_ascii=False)
    return text, len(text.encode("utf-8"))


class SummaryTest(unittest.TestCase):
    def test_a_catalog_call_over_a_ceiling_shrinks_under_it(self) -> None:
        operations = [conditional(f"op{index}", f"op{index}") for index in range(100)]
        result = stored([])
        cast("Json", result["browserCapabilities"])["operations"] = operations
        text = json.dumps(result, separators=(",", ":"), ensure_ascii=False)
        size = len(text.encode("utf-8"))
        with tempfile.TemporaryDirectory() as folder:
            fixture = Fixture(pathlib.Path(folder))
            fixture.add(at(7, 1), fixture.blob(text), size, keeper="a")
            fixture.add(at(7, 2), fixture.blob(text), size, keeper="b")
            summary = fixture.summary(at(7), at(8))
        self.assertEqual(summary["catalog_calls"], 2)
        self.assertEqual(summary["result_bytes_equal_to_reserialized_before"], 2)
        self.assertEqual(summary["checks_failed"], {})
        self.assertEqual(summary["calls_naming_required_actions"], {"0": 2})
        self.assertGreater(size, 32_768)
        self.assertEqual(summary["above_ceiling_before"], {name: 2 if size > ceiling else 0 for name, ceiling in catalog.CEILINGS})
        self.assertEqual(summary["above_ceiling_after"], {"16384": 0, "32768": 0, "65536": 0})
        self.assertLess(cast("int", cast("Json", summary["bytes_after"])["max"]), cast("int", cast("Json", summary["bytes_before"])["max"]))

    def test_a_cut_call_a_missing_blob_and_a_result_without_a_catalog_are_told_apart(self) -> None:
        connections = json.dumps({"clients": [], "inventoryComplete": True})
        with tempfile.TemporaryDirectory() as folder:
            fixture = Fixture(pathlib.Path(folder))
            fixture.add(at(7, 1), {"_blob": {"sha256": "ab" + "0" * 62}}, 33_000)
            fixture.add(at(7, 2), '{"_truncated":true,"browserCapabilities":{', 33_000)
            fixture.add(at(7, 3), connections, len(connections))
            fixture.add(at(7, 4), 7, 10)
            summary = fixture.summary(at(7), at(8))
        self.assertEqual(summary["calls"], 4)
        self.assertEqual(summary["catalog_calls"], 0)
        self.assertEqual(summary["readable_without_catalog"], 1)
        self.assertEqual(summary["unreadable"], {"blob_missing": 1, "cut_excerpt": 1, "no_output": 1})

    def test_a_cut_call_is_bounded_by_the_smallest_reduction_of_a_readable_one(self) -> None:
        def encoded(count: int) -> tuple[str, int]:
            result = stored([])
            cast("Json", result["browserCapabilities"])["operations"] = [conditional(f"op{index}", f"op{index}") for index in range(count)]
            text = json.dumps(result, separators=(",", ":"), ensure_ascii=False)
            return text, len(text.encode("utf-8"))

        big, big_size = encoded(100)
        small, small_size = encoded(40)
        with tempfile.TemporaryDirectory() as folder:
            fixture = Fixture(pathlib.Path(folder))
            fixture.add(at(7, 1), fixture.blob(big), big_size)
            fixture.add(at(7, 2), fixture.blob(small), small_size)
            fixture.add(at(7, 3), '{"_truncated":true,"x":1}', big_size + 100)
            fixture.add(at(7, 4), '{"_truncated":true,"x":1}', 900)
            summary = fixture.summary(at(7), at(8))
        cut = cast("Json", summary["cut_calls_over_16384"])
        reductions = [big_size - catalog.json_bytes(catalog.reproject(cast("Json", json.loads(big)))), small_size - catalog.json_bytes(catalog.reproject(cast("Json", json.loads(small))))]
        self.assertGreater(max(reductions), min(reductions))
        self.assertEqual(cut["smallest_reduction_of_a_readable_call"], min(reductions))
        self.assertEqual(cut["calls"], 1)
        self.assertEqual(cast("Json", cut["bytes_after_at_most"])["max"], big_size + 100 - min(reductions))

    def test_a_result_of_exactly_a_ceiling_is_not_above_it(self) -> None:
        result = stored([])
        result["pad"] = ""
        room = 16_384 - catalog.json_bytes(result)
        result["pad"] = "x" * room
        text = json.dumps(result, separators=(",", ":"), ensure_ascii=False)
        self.assertEqual(len(text.encode("utf-8")), 16_384)
        with tempfile.TemporaryDirectory() as folder:
            fixture = Fixture(pathlib.Path(folder))
            fixture.add(at(7, 1), text, 16_384)
            summary = fixture.summary(at(7), at(8))
        self.assertEqual(summary["above_ceiling_before"], {"16384": 0, "32768": 0, "65536": 0})
        self.assertEqual(summary["above_ceiling_by_ledger_result_bytes_any_catalog_or_not"], {"16384": 0, "32768": 0, "65536": 0})

    def test_only_the_tool_and_the_window_count(self) -> None:
        text, size = padded([])
        with tempfile.TemporaryDirectory() as folder:
            fixture = Fixture(pathlib.Path(folder))
            fixture.add(at(7, 1), text, size)
            fixture.add(at(7, 2), text, size, tool_name="Grep")
            fixture.add(at(6, 23), text, size)
            fixture.add(at(8), text, size)
            summary = fixture.summary(at(7), at(8))
        self.assertEqual(summary["calls"], 1)
        self.assertEqual(summary["catalog_calls"], 1)

    def test_a_call_that_names_operations_is_counted_by_how_many(self) -> None:
        text, size = padded(["hover", "type_text"])
        with tempfile.TemporaryDirectory() as folder:
            fixture = Fixture(pathlib.Path(folder))
            fixture.add(at(7, 1), text, size)
            summary = fixture.summary(at(7), at(8))
        self.assertEqual(summary["calls_naming_required_actions"], {"2": 1})
        self.assertEqual(summary["checks_failed"], {})


if __name__ == "__main__":
    unittest.main()

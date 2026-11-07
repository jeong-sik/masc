"""Checks measure_tools_list_inventory.py on small synthetic surfaces, ledgers and blobs.

Run: python3 -m unittest discover -s docs/evidence/tools-list-inventory-2026-11
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

import measure_tools_list_inventory as inventory  # noqa: E402

UTC = datetime.timezone.utc
Json = dict[str, object]


def at(day: int, hour: int = 0) -> float:
    return datetime.datetime(2026, 11, day, hour, tzinfo=UTC).timestamp()


def tool(public: str, availability: str, **extra: object) -> Json:
    """A stored Tool row with the keys the inventory ignores and the ones it keeps."""
    return {"id": "d." + public, "public_name": public, "internal_name": public, "description": "d" * 400, "availability": availability, **extra}


def skill(name: str, kind: str = "instruction", **extra: object) -> Json:
    reference: Json = {"identity": {"source_id": "s", "package_id": "p", "name": name}, "content_revision": "r"}
    return {"reference": reference, "description": "d" * 300, "catalog_status": "effective", "exposure": "model_visible", "availability": "active", "kind": kind, **extra}


def surface(tools: list[Json], skills: list[Json]) -> Json:
    return {
        "schema": "masc.keeper.capability_surface.v1",
        "skill_snapshot_revision": "rev",
        "surface_digest": "digest",
        "descriptor_surface": tools,
        "skills": skills,
    }


def section(value: object, key: str) -> Json:
    return cast("Json", cast("Json", value)[key])


class InventoryTest(unittest.TestCase):
    def test_rows_are_filed_by_availability_in_first_seen_order(self) -> None:
        stored = surface(
            [tool("b", "not_model_invocable"), tool("a", "active"), tool("c", "not_model_invocable"), tool("d", "active")],
            [],
        )
        tools = section(inventory.inventory_of(stored), "tools")
        self.assertEqual(list(tools), ["not_model_invocable", "active"])
        self.assertEqual(inventory.row_names(tools), ["b", "c", "a", "d"])

    def test_a_transport_alias_names_the_tool_it_projects(self) -> None:
        stored = surface([tool("masc_add_task", "not_model_invocable", transport_alias_of="keeper_task_create"), tool("Read", "active")], [])
        tools = section(inventory.inventory_of(stored), "tools")
        self.assertEqual(tools["not_model_invocable"], [{"name": "masc_add_task", "transport_alias_of": "keeper_task_create"}])
        self.assertEqual(tools["active"], [{"name": "Read"}])

    def test_a_refusal_keeps_its_reason(self) -> None:
        stored = surface([tool("keeper_job_start", "refused_by_sandbox", sandbox_refusal="needs Docker")], [])
        tools = section(inventory.inventory_of(stored), "tools")
        self.assertEqual(tools["refused_by_sandbox"], [{"name": "keeper_job_start", "sandbox_refusal": "needs Docker"}])

    def test_a_skill_row_keeps_name_kind_tool_name_and_withheld_tools(self) -> None:
        stored = surface(
            [],
            [
                skill("plain"),
                skill("plan", "composition", tool_name="keeper_compose_plan"),
                skill("cut", "composition", tool_name="keeper_compose_cut", availability="node_tools_outside_surface", outside_node_tools=["x"]),
            ],
        )
        skills = section(inventory.inventory_of(stored), "skills")
        self.assertEqual(
            skills["active"],
            [{"name": "plain", "kind": "instruction"}, {"name": "plan", "kind": "composition", "tool_name": "keeper_compose_plan"}],
        )
        self.assertEqual(
            skills["node_tools_outside_surface"],
            [{"name": "cut", "kind": "composition", "tool_name": "keeper_compose_cut", "outside_node_tools": ["x"]}],
        )

    def test_a_skill_without_a_reference_is_named_by_directory_or_configured_name(self) -> None:
        invalid: Json = {"reference": None, "directory": "broken-dir", "kind": "invalid", "availability": "invalid_definition"}
        missing: Json = {"reference": None, "name": "gone", "kind": "missing_configured", "availability": "missing_configured_skill"}
        skills = section(inventory.inventory_of(surface([], [invalid, missing])), "skills")
        self.assertEqual(skills["invalid_definition"], [{"name": "broken-dir", "kind": "invalid"}])
        self.assertEqual(skills["missing_configured_skill"], [{"name": "gone", "kind": "missing_configured"}])

    def test_the_whole_inventory_of_a_small_surface(self) -> None:
        stored = surface([tool("Read", "active")], [skill("plain")])
        self.assertEqual(
            json.dumps(inventory.inventory_of(stored), separators=(",", ":")),
            '{"schema":"masc.keeper.capability_inventory.v1","skill_snapshot_revision":"rev","surface_digest":"digest",'
            '"tools":{"active":[{"name":"Read"}]},"skills":{"active":[{"name":"plain","kind":"instruction"}]}}',
        )

    def test_json_bytes_is_compact_utf8(self) -> None:
        self.assertEqual(inventory.json_bytes({"a": "가"}), len('{"a":"가"}'.encode("utf-8")))


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

    def add(self, stamp: float, output: object, size: int, tool_name: str = "keeper_tools_list", keeper: str = "k") -> None:
        self.rows.append(json.dumps({"ts": stamp, "record_kind": "tool_call", "tool": tool_name, "keeper": keeper, "output": output, "result_bytes": size}))

    def summary(self, since: float, until: float) -> Json:
        folder = self.root / ".masc" / "tool_calls" / "2026-11"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "07.jsonl").write_text("\n".join(self.rows) + "\n", encoding="utf-8")
        start = datetime.datetime.fromtimestamp(since, UTC)
        end = datetime.datetime.fromtimestamp(until, UTC)
        paths = inventory.ledger_files(self.root, start, end)
        return inventory.summarize(inventory.read_calls(paths, since, until, self.root / ".masc" / "tool_blobs"))

    def window_bytes(self, since: float, until: float) -> int:
        start = datetime.datetime.fromtimestamp(since, UTC)
        end = datetime.datetime.fromtimestamp(until, UTC)
        return inventory.window_bytes(inventory.ledger_files(self.root, start, end), since, until)


class SummaryTest(unittest.TestCase):
    def test_a_stored_surface_over_every_ceiling_becomes_an_inventory_under_all_of_them(self) -> None:
        tools = [tool(f"t{index}", "active") for index in range(300)]
        text = json.dumps(surface(tools, [skill("plain")])) + "\nfailure_class=none"
        with tempfile.TemporaryDirectory() as folder:
            fixture = Fixture(pathlib.Path(folder))
            fixture.add(at(7, 1), fixture.blob(text), len(text.encode("utf-8")), keeper="a")
            fixture.add(at(7, 2), fixture.blob(text), len(text.encode("utf-8")), keeper="b")
            summary = fixture.summary(at(7), at(8))
        self.assertEqual(summary["calls"], 2)
        self.assertEqual(summary["readable_calls"], 2)
        self.assertEqual(summary["distinct_surfaces"], 1)
        self.assertEqual(summary["above_ceiling_before"], {"16384": 2, "32768": 2, "65536": 2})
        self.assertEqual(summary["above_ceiling_after"], {"16384": 0, "32768": 0, "65536": 0})
        self.assertEqual(summary["every_tool_name_kept_once_per_surface"], True)
        self.assertEqual(summary["every_skill_name_kept_once_per_surface"], True)
        self.assertLess(cast("int", summary["inventory_bytes_after"]), cast("int", summary["result_bytes_before"]) // 20)

    def test_a_missing_blob_and_a_cut_excerpt_are_counted_as_unreadable(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            fixture = Fixture(pathlib.Path(folder))
            fixture.add(at(7, 1), {"_blob": {"sha256": "ab" + "0" * 62}}, 300_000)
            fixture.add(at(7, 2), '{"_truncated":true,"descriptor_surface":[', 300_000)
            summary = fixture.summary(at(7), at(8))
        self.assertEqual(summary["calls"], 2)
        self.assertEqual(summary["readable_calls"], 0)
        self.assertEqual(summary["unreadable"], {"blob_missing": 1, "cut_excerpt": 1})

    def test_only_the_tool_and_the_window_count(self) -> None:
        text = json.dumps(surface([tool("Read", "active")], []))
        with tempfile.TemporaryDirectory() as folder:
            fixture = Fixture(pathlib.Path(folder))
            fixture.add(at(7, 1), text, len(text))
            fixture.add(at(7, 2), text, len(text), tool_name="Grep")
            fixture.add(at(6, 23), text, len(text))
            fixture.add(at(8), text, len(text))
            summary = fixture.summary(at(7), at(8))
            window = fixture.window_bytes(at(7), at(8))
        self.assertEqual(summary["calls"], 1)
        self.assertEqual(window, 2 * len(text))

    def test_two_rows_of_one_name_are_both_kept(self) -> None:
        stored = surface([tool("Read", "active"), tool("Read", "active")], [])
        self.assertEqual(inventory.row_names(section(inventory.inventory_of(stored), "tools")), ["Read", "Read"])


if __name__ == "__main__":
    unittest.main()

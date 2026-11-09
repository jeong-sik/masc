#!/usr/bin/env python3
"""The audit's second registry: `addons/<id>/lane.toml` exports are not "outside".

`config/tools/*.toml` is one registry. An addon declares its tool names under
`[world.tools].export` in `addons/<id>/lane.toml`, and those names are real
tools too. A report that reads only `config/tools` files every addon-only name
under "outside the registry", which is both wrong and invisible: the name can
never appear on the unused list because the unused list is built from the
registry it is missing from (#3446).

These tests pin the three things that must not drift:
  1. the export list is read from the addon contract, not guessed;
  2. a name the addon declares is classified as addon-explained, while a name
     neither registry declares still lands in the true "outside" list;
  3. the `config/tools` population and count do not move when addons are read.
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from datetime import datetime, timezone

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


AUDIT = load("audit_dead_tools", "audit-dead-tools.py")


LANE_TEMPLATE = """\
id = "{addon}"
version = "1.0.0"

[world]

[world.tools]
export = [{exports}]
"""


def write_lane(root: Path, addon: str, names: list[str]) -> None:
    directory = root / addon
    directory.mkdir(parents=True, exist_ok=True)
    exports = ", ".join(json.dumps(name) for name in names)
    (directory / "lane.toml").write_text(
        LANE_TEMPLATE.format(addon=addon, exports=exports), encoding="utf-8"
    )


def write_registry_tool(directory: Path, name: str) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{name}.toml").write_text(
        f'name = "{name}"\ndescription = """test tool"""\n', encoding="utf-8"
    )


class AddonExportListing(unittest.TestCase):
    def test_reads_every_declared_export(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            write_lane(root, "dos-machine", ["masc_dos_load", "masc_dos_save"])
            write_lane(root, "keeper-librarian", ["admit_memory"])
            exports, files, errors = AUDIT.load_addon_exports(root)
        self.assertEqual(errors, [])
        self.assertEqual(files, 2)
        self.assertEqual(
            exports,
            {
                AUDIT.norm("masc_dos_load"): "dos-machine",
                AUDIT.norm("masc_dos_save"): "dos-machine",
                AUDIT.norm("admit_memory"): "keeper-librarian",
            },
        )

    def test_missing_directory_is_not_an_error(self):
        with tempfile.TemporaryDirectory() as raw:
            exports, files, errors = AUDIT.load_addon_exports(Path(raw) / "absent")
        self.assertEqual((exports, files, errors), ({}, 0, []))

    def test_lane_without_export_block_contributes_nothing(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "browser").mkdir()
            (root / "browser" / "lane.toml").write_text('id = "browser"\n', encoding="utf-8")
            exports, files, errors = AUDIT.load_addon_exports(root)
        self.assertEqual(errors, [])
        self.assertEqual(files, 1)
        self.assertEqual(exports, {})

    def test_two_addons_exporting_one_name_is_reported(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            write_lane(root, "first", ["shared_tool"])
            write_lane(root, "second", ["shared_tool"])
            exports, _, errors = AUDIT.load_addon_exports(root)
        self.assertEqual(len(errors), 1)
        self.assertIn("shared_tool", errors[0])
        self.assertEqual(exports[AUDIT.norm("shared_tool")], "first")


class Classification(unittest.TestCase):
    """A ledger name is classified by whichever registry explains it."""

    def build(self, registry_names, addon_exports, observed):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            registry_dir = root / "config" / "tools"
            for name in registry_names:
                write_registry_tool(registry_dir, name)
            addon_dir = root / "addons"
            for addon, names in addon_exports.items():
                write_lane(addon_dir, addon, names)
            ledger_dir = root / "ledger"
            (ledger_dir / "2026-11").mkdir(parents=True)
            now = 1_800_000_000.0
            with (ledger_dir / "2026-11" / "09.jsonl").open("w", encoding="utf-8") as handle:
                for name in observed:
                    handle.write(json.dumps({"ts": now - 60, "tool": name}) + "\n")

            registry = AUDIT.load_registry(registry_dir)
            exports, files, errors = AUDIT.load_addon_exports(addon_dir)
            registry.addon_directory = str(addon_dir)
            registry.addon_files = files
            registry.addons = exports
            registry.addon_errors = errors
            source = AUDIT.load_ledger(ledger_dir, now - 86400, now + 1)
            end = datetime.fromtimestamp(now, tz=timezone.utc)
            start = end.replace(hour=0, minute=0, second=0, microsecond=0)
            report = AUDIT.build_report(
                registry=registry,
                sources=[source],
                coverage=AUDIT.load_coverage(None),
                window_start=start.timestamp(),
                window_end=end.timestamp(),
                window_days=1,
                window_kind="trailing window",
                retired_names=[],
            )
        return registry, report

    def test_addon_export_is_not_outside_the_registry(self):
        registry, report = self.build(
            registry_names=["tool_read_file"],
            addon_exports={"keeper-librarian": ["admit_memory"]},
            observed=["admit_memory"],
        )
        self.assertEqual(report.unregistered_observed, [])
        self.assertEqual(len(report.unregistered_addon), 1)
        name, addon_id, per_source = report.unregistered_addon[0]
        self.assertEqual(name, "admit_memory")
        self.assertEqual(addon_id, "keeper-librarian")
        self.assertEqual(per_source, {"tool_calls": 1})

    def test_a_name_neither_registry_declares_is_still_outside(self):
        registry, report = self.build(
            registry_names=["tool_read_file"],
            addon_exports={"keeper-librarian": ["admit_memory"]},
            observed=["mystery_tool"],
        )
        self.assertEqual(len(report.unregistered_observed), 1)
        self.assertEqual(report.unregistered_observed[0][0], "mystery_tool")
        self.assertEqual(report.unregistered_addon, [])

    def test_config_tools_population_does_not_move(self):
        # The regression that started this: reading a second registry must not
        # add rows to the config/tools population, or the unused list's
        # denominator silently changes.
        without, _ = self.build(
            registry_names=["tool_read_file", "tool_write_file"],
            addon_exports={},
            observed=[],
        )
        with_addons, _ = self.build(
            registry_names=["tool_read_file", "tool_write_file"],
            addon_exports={"keeper-librarian": ["admit_memory", "derive_memory"]},
            observed=[],
        )
        self.assertEqual(without.count, 2)
        self.assertEqual(with_addons.count, 2)
        self.assertEqual(with_addons.addon_count, 2)

    def test_addon_tool_is_absent_from_both_lists_until_observed(self):
        # An addon tool that was never called must not appear on the unused
        # list: profile-dependent addons make "0 calls" a bad deletion ground.
        registry, report = self.build(
            registry_names=["tool_read_file"],
            addon_exports={"keeper-librarian": ["admit_memory"]},
            observed=[],
        )
        unused_names = [row.name for row in report.by_status("unused")]
        self.assertNotIn("admit_memory", unused_names)


class Rendering(unittest.TestCase):
    """An addon error must reach the markdown report, not only the JSON."""

    def report_with_addon_error(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            registry_dir = root / "config" / "tools"
            write_registry_tool(registry_dir, "tool_read_file")
            addon_dir = root / "addons"
            write_lane(addon_dir, "first", ["shared_tool"])
            write_lane(addon_dir, "second", ["shared_tool"])
            now = 1_800_000_000.0
            ledger_dir = root / "ledger"
            (ledger_dir / "2026-11").mkdir(parents=True)
            (ledger_dir / "2026-11" / "09.jsonl").write_text("", encoding="utf-8")

            registry = AUDIT.load_registry(registry_dir)
            exports, files, errors = AUDIT.load_addon_exports(addon_dir)
            registry.addon_directory = str(addon_dir)
            registry.addon_files = files
            registry.addons = exports
            registry.addon_errors = errors
            end = datetime.fromtimestamp(now, tz=timezone.utc)
            source = AUDIT.load_ledger(ledger_dir, now - 86400, now + 1)
            report = AUDIT.build_report(
                registry=registry,
                sources=[source],
                coverage=AUDIT.load_coverage(None),
                window_start=end.timestamp() - 86400,
                window_end=end.timestamp(),
                window_days=1,
                window_kind="trailing window",
                retired_names=[],
            )
        return registry, report

    def test_duplicate_export_error_appears_in_markdown(self):
        registry, report = self.report_with_addon_error()
        self.assertEqual(len(registry.addon_errors), 1)
        rendered = AUDIT.render_markdown(report)
        self.assertIn("등록부 경고", rendered)
        self.assertIn("shared_tool", rendered)

    def test_duplicate_export_error_appears_in_json(self):
        registry, report = self.report_with_addon_error()
        payload = json.loads(AUDIT.render_json(report))
        self.assertEqual(len(payload["registry"]["addon_errors"]), 1)
        self.assertIn("shared_tool", payload["registry"]["addon_errors"][0])


if __name__ == "__main__":
    unittest.main()

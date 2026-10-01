"""Which keyboard PTY scenarios run, decided without opening a terminal.

test_tui_keyboard_input.py picks a family by name, lists descriptions with
--list and runs single scenarios with --scenario. Named family rules pass a binary and at most a family. The default keyboard
alias runs its scenario shards through separate Dune rules.
This suite drives it with a stand-in binary that nothing ever launches: a
scenario that is not selected returns before the terminal, and one that is
selected fails at once on a binary that is not there.
"""

from __future__ import annotations

import ast
import io
import importlib.util
import shutil
import os
import re
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from collections.abc import Callable
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import test_tui_keyboard_input as _keyboard_entry
import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_harness as harness
import tui_keyboard_walk as _keyboard_walk

# scripts/ci/run-edited-tests.sh runs a suite when a pull request changes a
# path the suite names. The choice lives in the harness, and the rule check
# below reads the dune file beside it. It also reads test/stanzas/*.inc, which
# a glob declares in dune but no single path here can name.
SOURCE_MODULES = (
    "test/test_tui_keyboard_input.py",
    "test/test_tui_item_workspace_authority_pty.py",
    "test/test_tui_remote_equipped_portrait.py",
    "test/test_tui_remote_workspace_history_pty.py",
    "test/test_tui_memory_provenance_layout_pty.py",
    "test/test_tui_answering_layout_pty.py",
    "test/test_tui_search_count.py",
    "evidence/39827/capture.py",
    "docs/evidence/2026-09-30-candle-currency-native/scenario.py",
    "scripts/capture-tui-audit.py",
    "test/dune",
    "test/tui_keyboard_approvals.py",
    "test/tui_keyboard_board.py",
    "test/tui_keyboard_browser.py",
    "test/tui_keyboard_chat.py",
    "test/tui_keyboard_clients.py",
    "test/tui_keyboard_context.py",
    "test/tui_keyboard_dashboard.py",
    "test/tui_keyboard_fusion.py",
    "test/tui_keyboard_harness.py",
    "test/tui_keyboard_keepers.py",
    "test/tui_keyboard_machines.py",
    "test/tui_keyboard_memory.py",
    "test/tui_keyboard_observer.py",
    "test/tui_keyboard_planning.py",
    "test/tui_keyboard_repositories.py",
    "test/tui_keyboard_resources.py",
    "test/tui_keyboard_runtime.py",
    "test/tui_keyboard_schedule.py",
    "test/tui_keyboard_startup.py",
    "test/tui_keyboard_terminal.py",
    "test/tui_keyboard_tools.py",
    "test/tui_keyboard_voice.py",
    "test/tui_keyboard_walk.py",
    "test/tui_keyboard_workspace.py",
)

HERE = Path(__file__).resolve().parent
HARNESS = HERE / "test_tui_keyboard_input.py"
DUNE = HERE / "dune"
STANZAS = HERE / "stanzas"
USAGE_ERROR = 2
SHARD_NAMES = ("general", "surfaces", "overview", "rosters", "board_terminal")

# Families whose rule is deliberately off the runtest alias, each with the
# reason test/dune gives beside the rule. A family wired back onto runtest
# has to leave this list, and a new family off runtest has to join it.
OFF_RUNTEST = {
    "memory-journal": "stops on the Linux runner waiting for journal:full (run 34072434219)",
}

# Any rule whose alias belongs to the harness, however it is written.
KEYBOARD_ALIAS = re.compile(
    r"\(rule\s*\(alias runtest-test_tui_keyboard_input(?:-[a-z0-9-]+)?\)"
)
# The runtest edge for one of those aliases.
KEYBOARD_ON_RUNTEST = re.compile(
    r"\(alias\s*\(name runtest\)\s*"
    r"\(deps \(alias runtest-test_tui_keyboard_input(?:-(?P<family>[a-z0-9-]+))?\)\)\)"
)
# The shape each of those rules has: the harness and the binary as deps, then
# the same two and at most one family name as operands.
KEYBOARD_RULE = re.compile(
    r"\(rule\s*\(alias runtest-test_tui_keyboard_input(?:-(?P<alias>[a-z0-9-]+))?\)\s*"
    r"\(deps\s+test_tui_keyboard_input\.py\s+\.\./bin/masc_tui\.exe"
    r"(?P<helpers>(?:\s+tui_keyboard_[a-z_]+\.py)+)\)\s*"
    r"\(action\s*\(run\s+python3\s+%\{dep:test_tui_keyboard_input\.py\}\s+"
    r"%\{dep:\.\./bin/masc_tui\.exe\}(?:\s+(?P<family>[a-z0-9-]+))?\)\)\)"
)


def rule_files_text() -> str:
    """test/dune and every stanza it can include: where a dune rule may live."""
    return "\n".join(
        path.read_text() for path in (DUNE, *sorted(STANZAS.glob("*.inc")))
    )


def unused_interaction(*_args: object) -> None:
    raise AssertionError("no scenario in this suite may reach a terminal")


def listed(output: str) -> list[tuple[str, list[str]]]:
    """--list output as (family, descriptions) in the order it was printed."""
    families: list[tuple[str, list[str]]] = []
    for line in output.splitlines():
        if line.startswith("  "):
            if not families:
                raise AssertionError(f"a description before any family: {line!r}")
            families[-1][1].append(line[2:])
        else:
            families.append((line, []))
    return families


def scenarios(*descriptions: str) -> Callable[[str], None]:
    def run(executable: str) -> None:
        for description in descriptions:
            _keyboard_harness.run_terminal_scenario(
                executable, description=description, interact=unused_interaction
            )

    return run


class ScenarioSelectionTest(unittest.TestCase):
    temporary: tempfile.TemporaryDirectory[str]
    stand_in: str
    missing: str

    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory(prefix="masc-tui-selection-")
        # Two families hash the binary before their first scenario, so the
        # stand-in has to be a readable executable file. It exits at once if a
        # regression ever did launch it.
        cls.stand_in = os.path.join(cls.temporary.name, "masc_tui.exe")
        Path(cls.stand_in).write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        os.chmod(cls.stand_in, 0o755)
        cls.missing = os.path.join(cls.temporary.name, "no-tui-here")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temporary.cleanup()

    def harness(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(HARNESS), self.stand_in, *args],
            capture_output=True,
            text=True,
            check=False,
        )

    def run_main(self, argv: list[str], families: tuple[_keyboard_harness.ScenarioFamily, ...]) -> SystemExit:
        with self.assertRaises(SystemExit) as raised, redirect_stdout(io.StringIO()), \
                redirect_stderr(io.StringIO()):
            _keyboard_harness.main([self.stand_in, *argv], families, families[0])
        return raised.exception

    def test_tracked_capture_helpers_resolve_from_the_entry(self) -> None:
        samples = (
            'docs/evidence/browser-bidi-live-20260913/corrected/capture-original.py',
            'docs/evidence/browser-bidi-live-20260913/corrected/capture.py',
            'docs/evidence/browser-bidi-live-20260913/metadata-assumptions/capture.py',
            'docs/evidence/browser-bidi-live-20260913/post-drag-scene-adapter-failure/capture.py',
            'docs/evidence/browser-context-recovery-20260913/scripts/capture-browser-context-action.py',
            'docs/evidence/browser-continuity-20260913/after-viewport/gesture-capture.py',
            'docs/evidence/browser-current-native-20260913/capture-helper-after-run.py',
            'docs/evidence/browser-delivery-20260913/native-history-fixture.py',
            'docs/evidence/browser-delivery-20260913/scripts/capture-bundled-browser-history.py',
            'docs/evidence/browser-delivery-20260913/scripts/capture-persistent-content-browser.py',
            'docs/evidence/browser-handoff-20260912/raw-follow-c230/probe.py',
            'docs/evidence/browser-history-20260913/capture-original.py',
            'docs/evidence/browser-history-20260913/direct/capture-original.py',
            'docs/evidence/browser-live-content-20260913/native-history-d441/fixture.py',
            'docs/evidence/browser-live-content-20260913/scripts/capture-live-content-browser.py',
            'docs/evidence/browser-live-viewport-20260913/gesture-capture.py',
            'docs/evidence/browser-navigation-composition-20260912/composed/capture-tui.py',
            'docs/evidence/tui-fixture-readable-wait-2026-09-26/reader-wait/scenario.py',
            'docs/evidence/tui-fixture-readable-wait-2026-09-26/screen-window/oracle.py',
            'docs/evidence/tui-fixture-readable-wait-2026-09-26/screen-window/whole.py',
            'docs/evidence/tui-fixture-readable-wait-2026-09-26/screen-window/window.py',
            'docs/evidence/tui-footer-parse-once-2026-09-27/profile-scenario.py',
            'docs/evidence/tui-footer-pinned-key-rules-2026-09-26/profile-scenario.py',
            'docs/evidence/tui-int-bounds-2026-09-27/initial-idle-profile/profile-scenario.py',
            'docs/evidence/tui-int-bounds-2026-09-27/ready-profile/profile-scenario.py',
            'evidence/39827/capture.py',
            'docs/evidence/2026-09-30-candle-currency-native/scenario.py',
            'scripts/capture-tui-audit.py',
            'test/test_tui_agenda_navigation_pty.py',
            'test/test_tui_code_diff_pan_pty.py',
            'test/test_tui_context_inspector.py',
            'test/test_tui_keeper_create_journey_pty.py',
            'test/test_tui_keeper_draft_payload_pty.py',
            'test/test_tui_keeper_logs_wrap_pty.py',
            'test/test_tui_keeper_metadata_wrap_pty.py',
            'test/test_tui_keyboard_scenario_selection.py',
            'test/test_tui_preset_viewport_pty.py',
            'test/test_tui_recorded_diff_pan_pty.py',
            'test/test_tui_runtime_picker_width_pty.py',
            'test/test_tui_schedule_detail_viewport_pty.py',
        )
        for relative in samples:
            source = ast.parse((HERE.parent / relative).read_text())
            aliases = {alias.asname or alias.name for node in ast.walk(source)
                       if isinstance(node, ast.Import) for alias in node.names
                       if alias.name == "test_tui_keyboard_input"}
            names = {node.attr for node in ast.walk(source)
                     if isinstance(node, ast.Attribute)
                     and isinstance(node.value, ast.Name) and node.value.id in aliases}
            self.assertTrue(names, relative)
            for name in names:
                with self.subTest(capture=relative, helper=name):
                    self.assertTrue(hasattr(_keyboard_entry, name), name)

    def test_candle_capture_uses_the_original_tab_helper(self) -> None:
        self.assertIs(_keyboard_entry.tab_until, harness.tab_until)

    def test_capture_manifest_detects_changed_owner_with_unchanged_entry(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "capture_tui_audit", HERE.parent / "scripts/capture-tui-audit.py")
        assert spec is not None and spec.loader is not None
        capture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(capture)
        inputs = capture.fixture_helper_inputs()
        for owner in ("tui_keyboard_harness.py", "tui_keyboard_repositories.py"):
            key = "fixture_helper:" + owner
            self.assertEqual(inputs[key], HERE / owner)
        with tempfile.TemporaryDirectory(prefix="capture-owner-mutation-") as directory:
            copies = {name: Path(directory) / path.name for name, path in inputs.items()}
            for name, path in inputs.items():
                shutil.copyfile(path, copies[name])
            hashes = {name: capture.digest(path) for name, path in copies.items()}
            capture.require_unchanged(copies, hashes)
            owner_key = "fixture_helper:tui_keyboard_harness.py"
            copies[owner_key].write_text(copies[owner_key].read_text() + "\n# mutated fixture\n")
            entry_key = "fixture_helper:test_tui_keyboard_input.py"
            self.assertEqual(capture.digest(copies[entry_key]), hashes[entry_key])
            with self.assertRaisesRegex(RuntimeError, "tui_keyboard_harness"):
                capture.require_unchanged(copies, hashes)
            self.assertNotEqual(capture.digest(copies[owner_key]), hashes[owner_key])

    def test_incoming_workspace_suites_resolve_split_owner_helpers(self) -> None:
        for filename in ("test_tui_memory_provenance_layout_pty.py",
                         "test_tui_answering_layout_pty.py",
                         "test_tui_item_workspace_authority_pty.py",
                         "test_tui_remote_equipped_portrait.py",
                         "test_tui_remote_workspace_history_pty.py"):
            source = ast.parse((HERE / filename).read_text())
            owners = {alias.asname or alias.name: importlib.import_module(alias.name)
                      for node in source.body if isinstance(node, ast.Import)
                      for alias in node.names if alias.name.startswith("tui_keyboard_")}
            self.assertTrue(owners, filename)
            for node in ast.walk(source):
                if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) \
                        and node.value.id in owners:
                    with self.subTest(consumer=filename, helper=node.attr):
                        self.assertTrue(hasattr(owners[node.value.id], node.attr))

    def test_all_entry_consumers_stage_the_full_import_closure(self) -> None:
        required = {path.name for path in HERE.glob("tui_keyboard_*.py")}
        seen = 0
        for match in re.finditer(r"(?ms)^\(rule\b.*?(?=^\(|\Z)", rule_files_text()):
            rule = match.group()
            if "test_tui_keyboard_input.py" not in rule:
                continue
            seen += 1
            staged = set(re.findall(r"\b(tui_keyboard_\w+\.py)\b", rule))
            self.assertFalse(required - staged, f"missing {required - staged}: {rule[:120]}")
        self.assertGreater(seen, 0)

    def test_about_capture_constructs_both_fixtures_before_a_terminal(self) -> None:
        calls = []
        with tempfile.TemporaryDirectory(prefix="tui-capture-contract-") as out:
            argv = ["capture.py", self.stand_in, out, "contract"]
            with patch.object(sys, "argv", argv), redirect_stdout(io.StringIO()), \
                    patch.object(_keyboard_entry, "run_terminal_scenario",
                                 side_effect=lambda *a, **kw: calls.append((a, kw))):
                runpy.run_path(str(HERE.parent / "evidence/39827/capture.py"), run_name="__main__")
        self.assertEqual([kw["terminal_cols"] for _, kw in calls], [80, 140])
        for args, kwargs in calls:
            self.assertEqual(args, (str(Path(self.stand_in).resolve()),))
            self.assertIn("/api/v1/gate/keepers?detailed=true", kwargs["http_fixtures"])

    def test_search_count_constructs_board_details_before_a_terminal(self) -> None:
        import test_tui_search_count
        class ReachedTerminal(Exception):
            pass
        with patch.object(_keyboard_harness, "run_terminal_scenario",
                          side_effect=ReachedTerminal) as terminal:
            with self.assertRaises(ReachedTerminal):
                test_tui_search_count.run(self.stand_in)
        self.assertEqual(terminal.call_count, 1)

    def test_list_names_every_family_once_and_each_description_once_inside_it(self) -> None:
        listing = self.harness("--list")
        self.assertEqual(listing.returncode, 0, listing.stderr)
        printed = listed(listing.stdout)
        self.assertEqual(
            [family for family, _ in printed],
            [family.name for family in _keyboard_entry.SCENARIO_FAMILIES],
        )
        for family, descriptions in printed:
            self.assertTrue(descriptions, f"family {family} lists no scenario")
            self.assertEqual(
                len(descriptions), len(set(descriptions)),
                f"family {family} repeats a description: {descriptions}",
            )
        last_family, last_descriptions = printed[-1]
        one = self.harness(last_family, "--list")
        self.assertEqual(one.returncode, 0, one.stderr)
        self.assertEqual(listed(one.stdout), [(last_family, last_descriptions)])

    def test_a_description_outside_the_family_exits_before_running_and_says_where_it_is(self) -> None:
        printed = dict(listed(self.harness("--list").stdout))
        default = printed[_keyboard_entry.KEYBOARD_FAMILY.name]
        owners: dict[str, list[str]] = {}
        for family, descriptions in printed.items():
            for description in descriptions:
                owners.setdefault(description, []).append(family)
        elsewhere = [
            (description, families[0])
            for description, families in owners.items()
            if len(families) == 1 and description not in default
        ]
        self.assertTrue(elsewhere, "every description is also in the keyboard walk")
        description, owner = elsewhere[0]
        refused = self.harness("--scenario", description)
        self.assertEqual(refused.returncode, USAGE_ERROR, refused.stderr)
        self.assertIn(f"{description!r} (it is in: {owner})", refused.stderr)

        invented = "a description no family has " + self.id()
        refused = self.harness("--scenario", invented)
        self.assertEqual(refused.returncode, USAGE_ERROR, refused.stderr)
        self.assertIn(repr(invented), refused.stderr)
        self.assertNotIn("it is in", refused.stderr)

    def test_usage_errors_exit_before_any_family_runs(self) -> None:
        started: list[str] = []
        family = _keyboard_harness.ScenarioFamily("probe", "probe regression", (started.append,))
        for argv in (
            ["probe", "--list", "--scenario", "anything"],
            ["no-such-family"],
            ["probe", "extra"],
        ):
            with self.subTest(argv=argv):
                self.assertEqual(self.run_main(argv, (family,)).code, USAGE_ERROR)
        self.assertEqual(started, [])

    def test_only_the_selected_description_goes_on_to_the_terminal(self) -> None:
        reached: list[tuple[str, str]] = []

        def run(executable: str) -> None:
            for description in ("first", "second", "third"):
                try:
                    _keyboard_harness.run_terminal_scenario(
                        executable, description=description, interact=unused_interaction
                    )
                except AssertionError as error:
                    reached.append((description, str(error)))

        family = _keyboard_harness.ScenarioFamily("probe", "probe regression", (run,))
        selection = _keyboard_harness.RunNamedScenarios(frozenset({"second"}), [])
        _keyboard_harness.run_family(family, self.missing, selection)
        self.assertEqual(selection.ran, ["second"])
        self.assertEqual([description for description, _ in reached], ["second"])
        self.assertIn(self.missing, reached[0][1])
        self.assertEqual(harness.scenario_selection, _keyboard_harness.RunEveryScenario())

    def test_a_family_that_repeats_a_description_cannot_be_collected(self) -> None:
        family = _keyboard_harness.ScenarioFamily(
            "probe", "probe regression", (scenarios("once", "twice", "once"),)
        )
        with self.assertRaises(AssertionError) as raised:
            _keyboard_harness.collect_scenario_names(family, self.stand_in)
        self.assertIn(repr("once"), str(raised.exception))
        self.assertEqual(harness.scenario_selection, _keyboard_harness.RunEveryScenario())

    def test_a_selected_description_that_does_not_run_fails_the_run(self) -> None:
        calls: list[str] = []

        def run(executable: str) -> None:
            # Collection sees "planned"; the real run describes it otherwise.
            calls.append(executable)
            description = "planned" if len(calls) == 1 else "renamed after collection"
            _keyboard_harness.run_terminal_scenario(
                executable, description=description, interact=unused_interaction
            )

        family = _keyboard_harness.ScenarioFamily("probe", "probe regression", (run,))
        failure = self.run_main(["probe", "--scenario", "planned"], (family,))
        self.assertEqual(len(calls), 2)
        self.assertIsInstance(failure.code, str)
        self.assertIn(repr("planned"), str(failure.code))

    def test_keyboard_shards_cover_each_default_scenario_once(self) -> None:
        default = _keyboard_harness.collect_scenario_names(_keyboard_entry.KEYBOARD_FAMILY, self.stand_in)
        parts: list[str] = []
        for index, name in enumerate(SHARD_NAMES):
            family = _keyboard_harness.ScenarioFamily(
                name,
                name,
                (lambda executable, index=index: _keyboard_walk.run_keyboard_regression(
                    executable, group=index
                ),),
            )
            parts.extend(_keyboard_harness.collect_scenario_names(family, self.stand_in))
            wrapper = ast.parse(
                (HERE / f"test_tui_keyboard_{name}_pty.py").read_text()
            )
            groups = [
                keyword.value.value
                for call in ast.walk(wrapper)
                if isinstance(call, ast.Call)
                and isinstance(call.func, ast.Attribute)
                and call.func.attr == "run_keyboard_regression"
                for keyword in call.keywords
                if keyword.arg == "group" and isinstance(keyword.value, ast.Constant)
            ]
            self.assertEqual(groups, [index], f"{name} wrapper selects another shard")
        self.assertEqual(len(parts), len(set(parts)), "a scenario runs in two shards")
        self.assertCountEqual(parts, default)

    def test_family_rules_declare_every_imported_keyboard_module(self) -> None:
        required: set[str] = set()
        pending = [HARNESS]
        while pending:
            tree = ast.parse(pending.pop().read_text())
            for node in ast.walk(tree):
                names = (
                    [alias.name for alias in node.names]
                    if isinstance(node, ast.Import)
                    else [node.module] if isinstance(node, ast.ImportFrom) else []
                )
                for name in names:
                    if name is None or not name.startswith("tui_keyboard_"):
                        continue
                    filename = name + ".py"
                    if filename not in required:
                        required.add(filename)
                        pending.append(HERE / filename)
        self.assertTrue(required, "the entry imports no keyboard helpers")
        for rule in KEYBOARD_RULE.finditer(rule_files_text()):
            with self.subTest(family=rule["family"]):
                self.assertEqual(set(rule["helpers"].split()), required)

    def test_every_family_has_one_rule_on_runtest_and_every_rule_names_a_family(self) -> None:
        text = rule_files_text()
        rules = [match.groupdict() for match in KEYBOARD_RULE.finditer(text)]
        self.assertTrue(rules, "no rule in test/dune runs test_tui_keyboard_input.py")
        self.assertEqual(
            len(rules), len(KEYBOARD_ALIAS.findall(text)),
            "a rule for the harness is written in a shape this check does not read",
        )
        for rule in rules:
            self.assertEqual(rule["alias"], rule["family"], f"alias and operand differ: {rule}")
        named = sorted(rule["family"] for rule in rules if rule["family"] is not None)
        self.assertEqual(
            named,
            sorted(
                family.name for family in _keyboard_entry.SCENARIO_FAMILIES
                if family is not _keyboard_entry.KEYBOARD_FAMILY
            ),
        )
        self.assertEqual(
            sum(rule["family"] is None for rule in rules), 0,
            "the serial keyboard rule must not remain",
        )
        aggregate = re.search(
            r"\(alias\s*\(name runtest-test_tui_keyboard_input\)"
            r"\s*\(deps[\s\S]*?\n\)\)",
            text,
        )
        self.assertIsNotNone(aggregate, "the default alias does not aggregate shards")
        assert aggregate is not None
        expected = [
            "runtest-test_tui_chat_input_pty",
            *(f"runtest-test_tui_keyboard_{name}_pty" for name in SHARD_NAMES),
        ]
        for alias in expected:
            self.assertEqual(
                aggregate.group().count(f"(alias {alias})"), 1,
                f"{alias} is missing or repeated in the default alias",
            )
        self.assertEqual(
            aggregate.group().count("(alias runtest-test_tui_keyboard_input-http-badge-refresh)"),
            1,
            "the HTTP badge refresh regression is missing from the edited-keyboard alias",
        )
        shard_rules = re.findall(
            r"\(rule\s*\(alias (runtest-test_tui_keyboard_[a-z_]+_pty)\)",
            text,
        )
        self.assertCountEqual(shard_rules, expected[1:])
        on_runtest = [match["family"] for match in KEYBOARD_ON_RUNTEST.finditer(text)]
        self.assertEqual(len(on_runtest), len(set(on_runtest)), "a lane is on runtest twice")
        self.assertIn(None, on_runtest, "the keyboard walk is not on runtest")
        self.assertEqual(
            sorted(set(named) - set(on_runtest)),
            sorted(OFF_RUNTEST),
            "families off the runtest alias differ from the ones OFF_RUNTEST explains",
        )


if __name__ == "__main__":
    unittest.main()

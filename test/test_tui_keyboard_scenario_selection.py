"""Which keyboard PTY scenarios run, decided without opening a terminal.

test_tui_keyboard_input.py picks a family by name, lists descriptions with
--list and runs single scenarios with --scenario. Every dune rule for that
file passes a binary and at most a family, so none of that choice ran in CI.
This suite drives it with a stand-in binary that nothing ever launches: a
scenario that is not selected returns before the terminal, and one that is
selected fails at once on a binary that is not there.
"""

from __future__ import annotations

from collections.abc import Callable
from contextlib import redirect_stderr, redirect_stdout
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

import test_tui_keyboard_input as h

# scripts/ci/run-edited-tests.sh runs a suite when a pull request changes a
# path the suite names. The choice lives in the harness, and the rule check
# below reads the dune file beside it.
SOURCE_MODULES = (
    "test/test_tui_keyboard_input.py",
    "test/dune",
)

HERE = Path(__file__).resolve().parent
HARNESS = HERE / "test_tui_keyboard_input.py"
DUNE = HERE / "dune"
USAGE_ERROR = 2

# Any rule whose alias belongs to the harness, however it is written.
KEYBOARD_ALIAS = re.compile(
    r"\(rule\s*\(alias runtest-test_tui_keyboard_input(?:-[a-z0-9-]+)?\)"
)
# The shape each of those rules has: the harness and the binary as deps, then
# the same two and at most one family name as operands.
KEYBOARD_RULE = re.compile(
    r"\(rule\s*\(alias runtest-test_tui_keyboard_input(?:-(?P<alias>[a-z0-9-]+))?\)\s*"
    r"\(deps\s+test_tui_keyboard_input\.py\s+\.\./bin/masc_tui\.exe\)\s*"
    r"\(action\s*\(run\s+python3\s+%\{dep:test_tui_keyboard_input\.py\}\s+"
    r"%\{dep:\.\./bin/masc_tui\.exe\}(?:\s+(?P<family>[a-z0-9-]+))?\)\)\)"
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
            h.run_terminal_scenario(
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

    def run_main(self, argv: list[str], families: tuple[h.ScenarioFamily, ...]) -> SystemExit:
        with self.assertRaises(SystemExit) as raised, redirect_stdout(io.StringIO()), \
                redirect_stderr(io.StringIO()):
            h.main([self.stand_in, *argv], families, families[0])
        return raised.exception

    def test_list_names_every_family_once_and_each_description_once_inside_it(self) -> None:
        listing = self.harness("--list")
        self.assertEqual(listing.returncode, 0, listing.stderr)
        printed = listed(listing.stdout)
        self.assertEqual(
            [family for family, _ in printed],
            [family.name for family in h.SCENARIO_FAMILIES],
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
        default = printed[h.KEYBOARD_FAMILY.name]
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
        family = h.ScenarioFamily("probe", "probe regression", (started.append,))
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
                    h.run_terminal_scenario(
                        executable, description=description, interact=unused_interaction
                    )
                except AssertionError as error:
                    reached.append((description, str(error)))

        family = h.ScenarioFamily("probe", "probe regression", (run,))
        selection = h.RunNamedScenarios(frozenset({"second"}), [])
        h.run_family(family, self.missing, selection)
        self.assertEqual(selection.ran, ["second"])
        self.assertEqual([description for description, _ in reached], ["second"])
        self.assertIn(self.missing, reached[0][1])
        self.assertEqual(h.scenario_selection, h.RunEveryScenario())

    def test_a_family_that_repeats_a_description_cannot_be_collected(self) -> None:
        family = h.ScenarioFamily(
            "probe", "probe regression", (scenarios("once", "twice", "once"),)
        )
        with self.assertRaises(AssertionError) as raised:
            h.collect_scenario_names(family, self.stand_in)
        self.assertIn(repr("once"), str(raised.exception))
        self.assertEqual(h.scenario_selection, h.RunEveryScenario())

    def test_a_selected_description_that_does_not_run_fails_the_run(self) -> None:
        calls: list[str] = []

        def run(executable: str) -> None:
            # Collection sees "planned"; the real run describes it otherwise.
            calls.append(executable)
            description = "planned" if len(calls) == 1 else "renamed after collection"
            h.run_terminal_scenario(
                executable, description=description, interact=unused_interaction
            )

        family = h.ScenarioFamily("probe", "probe regression", (run,))
        failure = self.run_main(["probe", "--scenario", "planned"], (family,))
        self.assertEqual(len(calls), 2)
        self.assertIsInstance(failure.code, str)
        self.assertIn(repr("planned"), str(failure.code))

    def test_every_family_has_one_rule_and_every_rule_names_a_family(self) -> None:
        text = DUNE.read_text()
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
                family.name for family in h.SCENARIO_FAMILIES
                if family is not h.KEYBOARD_FAMILY
            ),
        )
        self.assertEqual(
            sum(rule["family"] is None for rule in rules), 1,
            "the keyboard walk is the one rule that names no family",
        )


if __name__ == "__main__":
    unittest.main()

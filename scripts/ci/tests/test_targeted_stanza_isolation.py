"""Exercise suite selection through the prebuild reader and targeted shell runner.

The runner scenarios substitute only the build command. No Dune build or
browser runs; the real runner still selects aliases and what to build first.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[2]
MIXED = """
(test
 (name test_browser_activity)
 (deps activity.json)
 (action (setenv ACTIVITY_MODE selected (run %{test}))))
(rule
 (alias runtest-test_stdio_browser_activity)
 (deps ../bin/main_stdio_eio.exe)
 (action (setenv DUNE_SOURCEROOT %{workspace_root}
          (run python3 stdio.py))))
"""


class TargetedStanzaIsolation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="masc-targeted-stanza-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / "scripts/ci").mkdir(parents=True)
        (self.root / "test/stanzas").mkdir(parents=True)
        self.reader = self.root / "scripts/ci/alias_prebuild_deps.py"
        shutil.copyfile(SCRIPTS / "ci/alias_prebuild_deps.py", self.reader)
        self.dune = self.root / "test/dune"
        self.dune.write_text("(include stanzas/test_browser_activity.inc)\n")
        self.inc = self.root / "test/stanzas/test_browser_activity.inc"
        self.inc.write_text(MIXED)

    def read(self, suite, directory="test"):
        return subprocess.run(
            [sys.executable, str(self.reader), directory, suite],
            cwd=self.root, text=True, capture_output=True, timeout=10,
        )

    def assert_targets(self, suite, expected, directory="test"):
        result = self.read(suite, directory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), expected)

    def test_each_name_gets_only_its_own_stanza_targets(self):
        # A per-suite include often declares sibling tests and alias rules
        # too. Their deps belong to their own runs, so a name read from the
        # same file must not collect them, inline or through an include.
        sibling = """
(test (name another_test) (deps other.json)
 (action (setenv ACTIVITY_MODE other (run %{test}))))
"""
        for layout in ("included", "inline"):
            with self.subTest(layout=layout):
                if layout == "inline":
                    self.dune.write_text(MIXED + sibling)
                else:
                    self.inc.write_text(MIXED + sibling)
                self.assert_targets("test_browser_activity", ["test/activity.json"])
                self.assert_targets("test_stdio_browser_activity", ["bin/main_stdio_eio.exe"])
                self.assert_targets("another_test", ["test/other.json"])

    def test_a_tests_group_names_its_deps_and_action_targets_once(self):
        self.inc.write_text("""
(tests (names test_browser_activity unrelated_test)
 (deps launcher.exe)
 (action (run %{test} %{dep:launcher.exe} %{exe:../bin/masc_tui.exe})))
""")
        self.assert_targets("test_browser_activity", ["test/launcher.exe", "bin/masc_tui.exe"])
        self.assert_targets("unrelated_test", ["test/launcher.exe", "bin/masc_tui.exe"])

    def test_a_rule_names_the_executable_its_action_runs(self):
        # Six rules declare no (deps ...) at all and name their executable only
        # as %{exe:PATH} or %{dep:PATH} in the action. Without those paths the
        # alias still compiles inside the budget.
        self.inc.write_text("""
(rule
 (alias runtest-test_browser_activity)
 (action (run %{exe:../packages/agent_core/bench/bench.exe} test "a name")))
(rule
 (alias runtest-test_stdio_browser_activity)
 (action (run python3 %{dep:activity.py} --binary %{dep:../bin/masc_tui.exe})))
""")
        self.assert_targets("test_browser_activity", ["packages/agent_core/bench/bench.exe"])
        self.assert_targets("test_stdio_browser_activity",
                            ["test/activity.py", "bin/masc_tui.exe"])

    def test_only_dune_resolves_expressions_and_unknown_variables(self):
        # A source tree or glob names source files, which Dune copies inside
        # the action; an unknown variable would reach `dune build` as a literal
        # '%{...}'. A root variable names the checkout root.
        self.inc.write_text("""
(test (name test_browser_activity)
 (deps (source_tree tree) (glob_files *.json) %{unknown}
       %{workspace_root}/config/prompts/agent_core.md))
""")
        self.assert_targets("test_browser_activity", ["config/prompts/agent_core.md"])

    def test_a_stanza_with_nothing_to_build_answers_empty(self):
        self.inc.write_text("""
(rule
 (alias runtest-test_browser_activity)
 (action (run python3 -c pass)))
""")
        self.assert_targets("test_browser_activity", [])

    def test_a_name_nothing_declares_is_refused_not_answered_as_no_deps(self):
        # "Nothing carries this name" is not "the stanza needs nothing built":
        # answering both with an empty list and exit 0 let the runner skip the
        # preparation for a misread name without a word.
        result = self.read("test_absent_alias")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(result.stdout, "")
        self.assertIn("runtest-test_absent_alias", result.stderr)

    def executable(self, path, text):
        path.write_text(f"#!{sys.executable}\n" + text)
        path.chmod(0o755)

    def run_ocaml_suite(self, suite_path, *, action, exit_code=0, build_exit_code=0):
        """Run the real runner over one OCaml suite whose stanza lives in the
        suite's own directory. Each fake `opam` call is recorded with whether
        it ran under the fake `timeout`."""
        directory, name = suite_path.rsplit("/", 1)
        source = self.root / (suite_path + ".ml")
        source.parent.mkdir(parents=True, exist_ok=True)
        source.touch()
        action_field = ("(action (chdir nested (setenv DUNE_SOURCEROOT %{workspace_root}"
                        " (run %{test} %{dep:launcher.exe} \"argument with spaces\"))))"
                        if action else "")
        (source.parent / "dune").write_text(f"""
(tests (names {name} unrelated_test)
 (deps launcher.exe)
 {action_field})
""")
        runner = self.root / "scripts/ci-run-targeted-tests.sh"
        shutil.copyfile(SCRIPTS / runner.name, runner)
        commands = self.root / "commands"
        commands.mkdir()
        self.executable(commands / "timeout", """
import os,sys
env = dict(os.environ, TARGETED_FIXTURE_TIMED="1")
os.execvpe(sys.argv[6], sys.argv[6:], env)
""")
        self.executable(commands / "opam", """
import json,os,sys
from pathlib import Path
invocation = {'argv':sys.argv[1:],
              'verbose':os.environ.get('ALCOTEST_VERBOSE'),
              'timed':os.environ.get('TARGETED_FIXTURE_TIMED') == '1'}
with Path('opam-calls.jsonl').open('a') as handle:
    handle.write(json.dumps(invocation) + "\\n")
is_alias = '--force' in sys.argv[1:]
raise SystemExit(int(os.environ['FAKE_DUNE_EXIT' if is_alias else 'FAKE_BUILD_EXIT']))
""")
        env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                   TARGET_SUITES=suite_path, FAKE_DUNE_EXIT=str(exit_code),
                   FAKE_BUILD_EXIT=str(build_exit_code), DUNE_JOBS="2",
                   CI_TEST_LOG_FILE=str(self.root / "runner.log"))
        env.pop("ALCOTEST_VERBOSE", None)
        env.pop("TARGETED_FIXTURE_TIMED", None)
        result = subprocess.run(["bash", str(runner)], cwd=self.root, env=env,
                                text=True, capture_output=True, timeout=15)
        invocations = [json.loads(line) for line in
                       (self.root / "opam-calls.jsonl").read_text().splitlines()]
        build = ["exec", "--", "dune", "build", "--root", ".", "-j", "2"]
        expected = [{"argv": build + [f"{suite_path}.exe"], "verbose": None, "timed": False}]
        if build_exit_code == 0:
            # The action's own dependency is built before the budget starts;
            # then Dune runs the suite through its per-test alias, the only
            # call under the budget.
            expected.append({"argv": build + [f"{directory}/launcher.exe"],
                             "verbose": None, "timed": False})
            expected.append({
                "argv": ["exec", "--", "dune", "build", "--root", ".", "--force",
                         "--no-buffer", "--verbose", "-j", "1",
                         f"@@{directory}/runtest-{name}"],
                "verbose": "1",
                "timed": True,
            })
        self.assertEqual(invocations, expected)
        return result

    def test_a_plain_test_runs_through_its_generated_alias_not_its_executable(self):
        # Running the executable from the shell meant re-reading the stanza's
        # environment and deps outside Dune. Dune's own alias evaluates them.
        self.inc.unlink()
        result = self.run_ocaml_suite("test/test_browser_activity", action=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_custom_action_runs_only_its_nonrecursive_generated_alias(self):
        self.inc.unlink()
        result = self.run_ocaml_suite("test/test_browser_activity", action=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_external_suite_uses_its_own_directory_alias(self):
        result = self.run_ocaml_suite("packages/agent_core/test/test_browser_activity",
                                      action=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_suite_failure_is_not_reported_as_success(self):
        self.inc.unlink()
        result = self.run_ocaml_suite("test/test_browser_activity", action=False, exit_code=23)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL exit 23", result.stdout)

    def test_a_compile_failure_prevents_the_timed_alias(self):
        self.inc.unlink()
        result = self.run_ocaml_suite("test/test_browser_activity", action=False,
                                      build_exit_code=23)
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)

    def run_python_alias_runner(self, alias_name="test_stdio_browser_activity",
                               with_deps=True, prepare_exit_code=0, reader=None):
        """Run the real runner over one Python alias. Each fake `opam` call is
        recorded with whether it ran under the fake `timeout`, and that
        `timeout` records the budget arguments it was given."""
        deps_field = f"(deps {alias_name}.py ../bin/main_stdio_eio.exe)" if with_deps else ""
        self.inc.write_text(f"""
(rule
 (alias runtest-{alias_name})
 {deps_field}
 (action (run python3 {alias_name}.py)))
""")
        (self.root / f"test/{alias_name}.py").write_text("print('body')\n")
        runner = self.root / "scripts/ci-run-targeted-tests.sh"
        shutil.copyfile(SCRIPTS / runner.name, runner)
        if reader is not None:
            self.reader.write_text(reader)
        commands = self.root / "commands"
        commands.mkdir()
        self.executable(commands / "timeout", """
import json,os,sys
from pathlib import Path
with Path('timeout-calls.jsonl').open('a') as handle:
    handle.write(json.dumps(sys.argv[1:6]) + "\\n")
env = dict(os.environ, TARGETED_FIXTURE_TIMED="1")
os.execvpe(sys.argv[6], sys.argv[6:], env)
""")
        self.executable(commands / "opam", """
import json,os,sys
from pathlib import Path
invocation = {'argv':sys.argv[1:],
              'timed':os.environ.get('TARGETED_FIXTURE_TIMED') == '1'}
with Path('opam-calls.jsonl').open('a') as handle:
    handle.write(json.dumps(invocation) + "\\n")
is_alias = '--force' in sys.argv[1:]
raise SystemExit(0 if is_alias else int(os.environ['FAKE_PREPARE_EXIT']))
""")
        env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                   TARGET_SUITES=alias_name, DUNE_JOBS="2",
                   TARGET_SUITE_TIMEOUT_SEC="600", TARGET_SUITE_KILL_GRACE_SEC="30",
                   FAKE_PREPARE_EXIT=str(prepare_exit_code),
                   CI_TEST_LOG_FILE=str(self.root / "runner.log"))
        env.pop("TARGETED_FIXTURE_TIMED", None)
        result = subprocess.run(["bash", str(runner)], cwd=self.root, env=env,
                                text=True, capture_output=True, timeout=15)
        calls = [json.loads(line) for line in
                 (self.root / "opam-calls.jsonl").read_text().splitlines()]
        budgets = [json.loads(line) for line in
                   (self.root / "timeout-calls.jsonl").read_text().splitlines()]
        return result, calls, budgets

    def assert_only_the_alias_is_timed(self, alias_name, alias_call, budgets):
        self.assertIn("--force", alias_call["argv"])
        self.assertEqual(alias_call["argv"][-1], f"@runtest-{alias_name}")
        self.assertTrue(alias_call["timed"], alias_call)
        self.assertEqual(budgets, [["-s", "TERM", "-k", "30", "600"]])

    def test_python_alias_runner_prepares_deps_before_the_timed_alias(self):
        result, calls, budgets = self.run_python_alias_runner()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 2, calls)
        # Dependencies first, outside the suite budget: a compile that ran
        # under it is what spent 601s of 600s.
        self.assertEqual(calls[0]["argv"][-2:], ["test/test_stdio_browser_activity.py",
                                                 "bin/main_stdio_eio.exe"])
        self.assertFalse(calls[0]["timed"], calls[0])
        # Then the alias itself, the only call under the suite budget.
        self.assert_only_the_alias_is_timed("test_stdio_browser_activity", calls[1], budgets)
        self.assertIn("(prepare alias dependencies)", result.stdout)

    def test_python_alias_whose_rule_declares_no_deps_still_runs(self):
        # No (deps ...) and no %{exe:...}: the preparation step must add no
        # build call at all rather than one with an empty target.
        result, calls, budgets = self.run_python_alias_runner("test_bare_alias", with_deps=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 1, calls)
        self.assert_only_the_alias_is_timed("test_bare_alias", calls[0], budgets)

    def test_python_alias_failed_preparation_fails_the_run_and_the_alias_still_runs(self):
        # The preparation build used to stop the whole dispatch under set -e,
        # so no suite after it got a verdict. Swallowing its exit is the other
        # way to be wrong: the run would read as green over a failed build.
        result, calls, budgets = self.run_python_alias_runner(prepare_exit_code=23)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL - prepare alias dependencies: exit 23", result.stdout)
        self.assertEqual(len(calls), 2, calls)
        self.assertFalse(calls[0]["timed"], calls[0])
        self.assert_only_the_alias_is_timed("test_stdio_browser_activity", calls[1], budgets)
        self.assertIn("@runtest-test_stdio_browser_activity: OK", result.stdout)

    def test_python_alias_reader_stderr_is_logged_and_is_not_a_build_target(self):
        # A reader that exits 0 and also writes to stderr: only its stdout
        # names targets. With 2>&1 the warning line reached `dune build`.
        result, calls, _ = self.run_python_alias_runner(reader=(
            "import sys\n"
            "print('a warning, not a target', file=sys.stderr)\n"
            "print('test/x.py')\n"
        ))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls[0]["argv"],
                         ["exec", "--", "dune", "build", "--root", ".", "-j", "2", "test/x.py"])
        self.assertIn("the deps reader wrote to stderr: a warning, not a target", result.stdout)

    def test_python_alias_reader_failure_is_reported_and_the_alias_still_runs(self):
        # A silent fallback to "no deps" is indistinguishable in the log from
        # the 601s in-budget TIMEOUT this preparation exists to prevent, so the
        # run says it fell back. The alias is still built, under its budget.
        alias_name = "test_reader_failure"
        result, calls, budgets = self.run_python_alias_runner(alias_name, reader=(
            "import sys\n"
            "print('simulated reader refusal', file=sys.stderr)\n"
            "raise SystemExit(1)\n"
        ))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("could not read the alias deps", result.stdout)
        self.assertIn("simulated reader refusal", result.stdout)
        self.assertIn(f"@runtest-{alias_name}: OK", result.stdout)
        self.assertNotIn("(prepare alias dependencies)", result.stdout)
        self.assertEqual(len(calls), 1, calls)
        self.assert_only_the_alias_is_timed(alias_name, calls[0], budgets)

    def test_python_alias_without_a_rule_is_reported_by_the_real_reader(self):
        # test/NAME.py exists, so the runner takes it for an alias suite, but
        # no rule carries runtest-NAME. The real reader refuses; the runner
        # says so and leaves the verdict to the alias build.
        alias_name = "test_orphan_script"
        (self.root / f"test/{alias_name}.py").write_text("print('body')\n")
        runner = self.root / "scripts/ci-run-targeted-tests.sh"
        shutil.copyfile(SCRIPTS / runner.name, runner)
        commands = self.root / "commands"
        commands.mkdir()
        self.executable(commands / "timeout", "import os,sys\nos.execvp(sys.argv[6], sys.argv[6:])\n")
        self.executable(commands / "opam", "raise SystemExit(0)\n")
        env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                   TARGET_SUITES=alias_name, DUNE_JOBS="2",
                   CI_TEST_LOG_FILE=str(self.root / "runner.log"))
        result = subprocess.run(["bash", str(runner)], cwd=self.root, env=env,
                                text=True, capture_output=True, timeout=15)
        self.assertIn("could not read the alias deps", result.stdout)
        self.assertIn(f"no (rule (alias runtest-{alias_name})", result.stdout)
        self.assertNotIn("(prepare alias dependencies)", result.stdout)
        self.assertIn(f"@runtest-{alias_name}: OK", result.stdout)


if __name__ == "__main__":
    unittest.main()

"""Exercise suite selection through the reader CLI and targeted shell runner.

The runner scenario substitutes only the compiler/build command. No Dune build
or browser runs; the real runner still selects dependencies and starts a fixture.
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
        self.reader = self.root / "scripts/ci/stanza_env.py"
        shutil.copyfile(SCRIPTS / "ci/stanza_env.py", self.reader)
        self.dune = self.root / "test/dune"
        self.dune.write_text("(include stanzas/test_browser_activity.inc)\n")
        self.inc = self.root / "test/stanzas/test_browser_activity.inc"
        self.inc.write_text(MIXED)

    def read(self, suite="test_browser_activity", *, deps=False):
        return subprocess.run(
            [sys.executable, str(self.reader), *(["--deps"] if deps else []), suite],
            cwd=self.root, text=True, capture_output=True, timeout=10,
        )

    def assert_selected(self):
        for deps, expected in ((False, ["ACTIVITY_MODE=selected"]),
                               (True, ["test/activity.json"])):
            with self.subTest(deps=deps):
                result = self.read(deps=deps)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), expected)

    def test_per_suite_file_does_not_donate_sibling_alias_environment_or_deps(self):
        self.assert_selected()

    def test_shared_include_and_inline_file_select_the_same_action(self):
        self.inc.unlink()
        shared = self.root / "test/stanzas/shared.inc"
        shared.write_text(MIXED)
        self.dune.write_text("(include stanzas/shared.inc)\n")
        self.assert_selected()
        self.dune.write_text(MIXED)
        self.assert_selected()

    def test_sibling_named_test_does_not_donate_environment_or_dependencies(self):
        self.inc.write_text(MIXED + """
(test (name another_test) (deps other.json)
 (action (setenv ACTIVITY_MODE other (run %{test}))))
""")
        self.assert_selected()

    def test_selected_action_unknown_variable_still_refuses(self):
        self.inc.write_text(MIXED.replace("ACTIVITY_MODE selected", "ACTIVITY_MODE %{unknown}"))
        for deps in (False, True):
            result = self.read(deps=deps)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ACTIVITY_MODE uses a dune variable", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_renamed_suite_file_cannot_supply_a_different_named_test(self):
        self.inc.write_text(MIXED.replace("(name test_browser_activity)", "(name another_test)"))
        result = self.read()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no (test)/(tests) stanza declares", result.stderr)

    def test_rule_only_suite_retains_its_action_and_dependencies(self):
        self.inc.write_text("""
(executable (name test_browser_activity))
(rule (alias runtest) (deps fixture.json)
 (action (setenv ACTIVITY_MODE selected (run test_browser_activity.exe))))
""")
        for deps, expected in ((False, ["ACTIVITY_MODE=selected"]),
                               (True, ["test/fixture.json"])):
            result = self.read(deps=deps)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), expected)

    def write_tree(self, directory, files):
        for relative, text in files.items():
            path = directory / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

    def test_source_tree_dep_becomes_one_file_target_per_file(self):
        # `dune build DIR` accepts a directory and exits 0 while copying
        # nothing, so the runtest action's source tree is absent in a targeted
        # run. A file target is copied, so DIR must arrive as its files.
        tree = self.root / "test/tree"
        self.write_tree(tree, {"b.txt": "b", "sub/a.txt": "a"})
        self.inc.write_text("""
(test (name test_browser_activity) (deps (source_tree tree))
 (action (setenv ACTIVITY_MODE selected (run %{test}))))
""")
        result = self.read(deps=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         ["test/tree/b.txt", "test/tree/sub/a.txt"])

    def test_source_tree_under_a_root_variable_resolves_from_the_checkout_root(self):
        # The stanza is written relative to test/, but the root variable names
        # the checkout root. --deps speaks from the root, so no literal
        # '%{workspace_root}' may reach `dune build`.
        prompts = self.root / "config/prompts"
        self.write_tree(prompts, {"agent_core.md": "a", "nested/grader.md": "g"})
        self.inc.write_text("""
(test (name test_browser_activity) (deps (source_tree %{workspace_root}/config/prompts))
 (action (setenv ACTIVITY_MODE selected (run %{test}))))
""")
        result = self.read(deps=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        targets = result.stdout.splitlines()
        self.assertEqual(targets, ["config/prompts/agent_core.md",
                                   "config/prompts/nested/grader.md"])
        for target in targets:
            self.assertTrue((self.root / target).is_file(), target)
            self.assertNotIn("%{", target)

    def test_empty_source_tree_contributes_no_target_and_no_directory(self):
        (self.root / "test/tree").mkdir(parents=True)
        self.inc.write_text("""
(test (name test_browser_activity) (deps (source_tree tree))
 (action (setenv ACTIVITY_MODE selected (run %{test}))))
""")
        result = self.read(deps=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def executable(self, path, text):
        path.write_text(f"#!{sys.executable}\n" + text)
        path.chmod(0o755)

    def test_real_targeted_runner_builds_only_selected_deps_then_executes_fixture(self):
        # No custom action: this exercises the direct executable path. Dune's
        # directory environment still belongs to that executable's run.
        self.inc.write_text(MIXED.replace(
            "(action (setenv ACTIVITY_MODE selected (run %{test})))", ""))
        self.dune.write_text("(env (_ (env-vars (ACTIVITY_MODE selected))))\n"
                             "(include stanzas/test_browser_activity.inc)\n")
        runner = self.root / "scripts/ci-run-targeted-tests.sh"
        shutil.copyfile(SCRIPTS / runner.name, runner)
        (self.root / "test/test_browser_activity.ml").touch()
        commands = self.root / "commands"
        commands.mkdir()
        self.executable(commands / "timeout", "import os,sys\nos.execvp(sys.argv[6], sys.argv[6:])\n")
        self.executable(commands / "opam", """
import json,os
from pathlib import Path
import sys
Path('build-args.json').write_text(json.dumps(sys.argv[1:]))
assert sys.argv[1:] == ['exec','--','dune','build','--root','.', '-j','2',
                       'test/test_browser_activity.exe','test/activity.json'], sys.argv
path=Path('_build/default/test/test_browser_activity.exe')
path.parent.mkdir(parents=True)
path.write_text('#!' + sys.executable + '\\nimport os,json\\nfrom pathlib import Path\\n'
                + 'Path(os.environ["FIXTURE_RESULT"]).write_text(json.dumps('
                + '{"mode":os.environ["ACTIVITY_MODE"],"cwd":os.getcwd()}))\\n')
path.chmod(0o755)
""")
        result_path = self.root / "executed.json"
        env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                   TARGET_SUITES="test_browser_activity", DUNE_JOBS="2",
                   CI_TEST_LOG_FILE=str(self.root / "runner.log"),
                   FIXTURE_RESULT=str(result_path))
        result = subprocess.run(["bash", str(runner)], cwd=self.root, env=env,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        executed = json.loads(result_path.read_text())
        self.assertEqual(executed, {"mode": "selected", "cwd": str(self.root / "_build/default/test")})
        self.assertNotIn("main_stdio", (self.root / "build-args.json").read_text())

    def test_custom_action_query_preserves_dune_variable_and_argv_ownership(self):
        self.inc.write_text(MIXED.replace("ACTIVITY_MODE selected", "ACTIVITY_MODE %{workspace_root}"))
        result = subprocess.run(
            [sys.executable, str(self.reader), "--action-alias", "test_browser_activity"],
            cwd=self.root, text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "@@test/runtest-test_browser_activity\n")
        self.inc.write_text("(test (name test_browser_activity))\n")
        result = subprocess.run(
            [sys.executable, str(self.reader), "--action-alias", "test_browser_activity"],
            cwd=self.root, text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def run_custom_action(self, suite_path, exit_code=0, build_exit_code=0):
        directory, name = suite_path.rsplit("/", 1)
        source = self.root / (suite_path + ".ml")
        source.parent.mkdir(parents=True, exist_ok=True)
        source.touch()
        (source.parent / "dune").write_text(f"""
(tests (names {name} unrelated_test)
 (deps launcher.exe)
 (action (chdir nested
   (setenv DUNE_SOURCEROOT %{{workspace_root}}
    (run %{{test}} %{{dep:launcher.exe}} "argument with spaces")))))
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
        expected = [{
            "argv": ["exec", "--", "dune", "build", "--root", ".", "-j", "2",
                     f"{suite_path}.exe"],
            "verbose": None,
            "timed": False,
        }]
        if build_exit_code == 0:
            expected.append({
                "argv": ["exec", "--", "dune", "build", "--root", ".", "--force",
                         "--no-buffer", "--verbose", "-j", "1",
                         f"@@{directory}/runtest-{name}"],
                "verbose": "1",
                "timed": True,
            })
        self.assertEqual(invocations, expected)
        return result

    def test_custom_action_runs_only_its_nonrecursive_generated_alias(self):
        # Remove the per-suite include so the named action comes from test/dune.
        self.inc.unlink()
        result = self.run_custom_action("test/test_browser_activity")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_external_suite_uses_its_own_directory_alias(self):
        result = self.run_custom_action("packages/agent_core/test/test_browser_activity")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_custom_action_failure_is_not_reported_as_success(self):
        self.inc.unlink()
        result = self.run_custom_action("test/test_browser_activity", exit_code=23)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL exit 23", result.stdout)

    def test_custom_action_build_failure_prevents_the_timed_action(self):
        self.inc.unlink()
        result = self.run_custom_action("test/test_browser_activity", build_exit_code=23)
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)

    def alias_deps(self, suite="test_stdio_browser_activity"):
        return subprocess.run(
            [sys.executable, str(self.reader), "--dir", "test", "--alias-deps", suite],
            cwd=self.root, text=True, capture_output=True, timeout=10,
        )

    def test_alias_deps_reads_the_rule_that_declares_the_alias(self):
        # A Python suite is a (rule (alias runtest-NAME) (deps ...)), and the
        # runner runs it by building the alias. Building the alias compiles its
        # deps, so a runner that does not name them first spends the suite
        # budget compiling: run 41730441832 used 601s of 600s and printed no
        # "Ran N tests" line. This query is what lets the runner build them
        # outside the budget.
        (self.root / "test/stdio.py").write_text("print('body')\n")
        result = self.alias_deps()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["bin/main_stdio_eio.exe"])

    def test_alias_deps_includes_the_executable_named_only_by_an_action(self):
        # Six rules declare no (deps ...) at all and name their executable only
        # as %{exe:PATH} in the action. Without that path the alias still
        # compiles inside the budget.
        self.inc.write_text("""
(rule
 (alias runtest-test_browser_activity)
 (action (run %{exe:../packages/agent_core/bench/bench.exe} test "a name")))
""")
        result = self.alias_deps("test_browser_activity")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         ["packages/agent_core/bench/bench.exe"])

    def test_alias_deps_of_a_missing_alias_is_refused_not_answered_as_no_deps(self):
        # "No rule carries this alias" is not "the rule needs nothing built":
        # answering both with an empty list and exit 0 let the runner skip the
        # preparation for a misread name without a word. A sibling rule must
        # not donate its deps to a name it does not carry either.
        result = self.alias_deps("test_absent_alias")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(result.stdout, "")
        self.assertIn("runtest-test_absent_alias", result.stderr)

    def test_alias_deps_of_a_rule_without_deps_is_empty_and_succeeds(self):
        self.inc.write_text("""
(rule
 (alias runtest-test_browser_activity)
 (action (run python3 -c pass)))
""")
        result = self.alias_deps("test_browser_activity")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_alias_deps_includes_the_files_an_action_names_as_dep(self):
        # The spelling most Python rules use for the binary they drive. A rule
        # that names it only there, with no (deps ...), compiled it inside the
        # suite budget.
        self.inc.write_text("""
(rule
 (alias runtest-test_browser_activity)
 (action (run python3 %{dep:activity.py} --binary %{dep:../bin/masc_tui.exe})))
""")
        result = self.alias_deps("test_browser_activity")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         ["test/activity.py", "bin/masc_tui.exe"])

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
        # A reader that refuses this query: the alias-deps path exits non-zero.
        alias_name = "test_reader_failure"
        result, calls, budgets = self.run_python_alias_runner(alias_name, reader=(
            "import sys\n"
            "if '--alias-deps' in sys.argv:\n"
            "    print('simulated reader refusal', file=sys.stderr)\n"
            "    raise SystemExit(1)\n"
            "print('test/x.py')\n"
        ))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("could not read the rule's deps", result.stdout)
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
        self.assertIn("could not read the rule's deps", result.stdout)
        self.assertIn(f"no (rule (alias runtest-{alias_name})", result.stdout)
        self.assertNotIn("(prepare alias dependencies)", result.stdout)
        self.assertIn(f"@runtest-{alias_name}: OK", result.stdout)


if __name__ == "__main__":
    unittest.main()

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

    def run_custom_action(self, suite_path, exit_code=0):
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
        self.executable(commands / "timeout", "import os,sys\nos.execvp(sys.argv[6], sys.argv[6:])\n")
        self.executable(commands / "opam", """
import json,os,sys
from pathlib import Path
Path('alias-call.json').write_text(json.dumps({'argv':sys.argv[1:],
                                           'verbose':os.environ.get('ALCOTEST_VERBOSE')}))
raise SystemExit(int(os.environ['FAKE_DUNE_EXIT']))
""")
        env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                   TARGET_SUITES=suite_path, FAKE_DUNE_EXIT=str(exit_code),
                   CI_TEST_LOG_FILE=str(self.root / "runner.log"))
        result = subprocess.run(["bash", str(runner)], cwd=self.root, env=env,
                                text=True, capture_output=True, timeout=15)
        invocation = json.loads((self.root / "alias-call.json").read_text())
        self.assertEqual(invocation, {
            "argv": ["exec", "--", "dune", "build", "--root", ".", "--force",
                     "--no-buffer", "-j", "1", f"@@{directory}/runtest-{name}"],
            "verbose": "1",
        })
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


if __name__ == "__main__":
    unittest.main()

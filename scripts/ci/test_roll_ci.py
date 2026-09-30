#!/usr/bin/env python3
"""ROLL scope and execution evidence, without an OCaml toolchain."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("roll_ci", ROOT / "scripts/ci/roll_ci.py")
roll_ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(roll_ci)


class RollScopeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "test")
        self.write("README.md", "base\n")
        self.base = self.commit("base")
        self.write("test/test_parent.ml", "parent\n")
        self.parent = self.commit("parent")
        self.write("test/test_child.ml", "child\n")
        self.head = self.commit("child")
        self.input = {"schema": "masc.roll.input.v1", "base": self.base,
                      "digest": "sha256:" + "d" * 64,
                      "members": [{"pr": 10, "head": self.parent, "review_base": self.base},
                                  {"pr": 11, "head": self.head, "review_base": self.parent}]}
        self.pulls = {
            10: {"state": "open", "head": {"sha": self.parent}, "base": {"sha": self.base},
                 "body": "Test-suites: test_extra"},
            11: {"state": "open", "head": {"sha": self.head}, "base": {"sha": self.parent},
                 "body": ""},
        }

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True).strip()

    def write(self, path, content):
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
        return p

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def select(self, paths, body):
        selected = [p for p in paths if p.startswith("test/") and p.endswith(".ml")]
        if body:
            selected.append("test/test_extra.ml")
        return {"sources": selected, "direct_sources": selected}

    def prepare(self, select=None):
        return roll_ci.build_plan(self.root, self.input, self.pulls, 99, self.head,
                                  "123", "1", select or self.select)

    def test_full_diff_and_member_requirements(self):
        plan = self.prepare()
        self.assertEqual(plan["required_suites"],
                         ["test/test_child.ml", "test/test_extra.ml", "test/test_parent.ml"])
        self.assertEqual(plan["base"], self.base)
        self.assertEqual(plan["roll_tree"], self.git("rev-parse", "HEAD^{tree}"))
        self.assertEqual(plan["input_digest"], self.input["digest"])

    def test_missing_lower_member_suite_is_red(self):
        plan = self.prepare()
        executed = ["test/test_child.ml", "test/test_extra.ml"]
        receipt = roll_ci.finish_receipt(plan, executed, 0)
        self.assertEqual(receipt["missing_suites"], ["test/test_parent.ml"])
        self.assertEqual(receipt["result"], "FAIL")

    def test_empty_selection_is_refused(self):
        with self.assertRaises(ValueError):
            self.prepare(lambda paths, body: {"sources": [], "direct_sources": []})

    def test_selector_failure_propagates(self):
        def broken(paths, body):
            raise subprocess.CalledProcessError(2, ["selector"])
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare(broken)

    def test_moved_member_is_refused(self):
        self.pulls[10]["head"]["sha"] = self.head
        with self.assertRaises(ValueError):
            self.prepare()

    def test_changed_parent_chain_is_refused(self):
        self.pulls[11]["base"]["sha"] = self.base
        with self.assertRaises(ValueError):
            self.prepare()

    def test_wrong_checkout_head_is_refused(self):
        self.git("checkout", "-q", self.parent)
        with self.assertRaises(ValueError):
            self.prepare()

    def test_nonancestor_review_base_is_refused(self):
        self.git("checkout", "--orphan", "unrelated")
        self.write("other", "other")
        self.input["members"][0]["review_base"] = self.commit("unrelated")
        self.git("checkout", "-q", self.head)
        with self.assertRaises(ValueError):
            self.prepare()

    def test_failed_run_cannot_certify_complete_list(self):
        plan = self.prepare()
        self.assertEqual(roll_ci.finish_receipt(plan, plan["required_suites"], 1)["result"],
                         "FAIL")

    def test_success_and_extra_execution(self):
        plan = self.prepare()
        self.assertEqual(roll_ci.finish_receipt(plan, plan["required_suites"], 0)["result"],
                         "PASS")
        self.assertEqual(roll_ci.finish_receipt(
            plan, plan["required_suites"] + ["test/other.ml"], 0)["result"], "FAIL")


class RunnerReceiptTests(unittest.TestCase):
    def test_real_runner_records_only_successful_executables(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            scripts = root / "scripts/ci"
            scripts.mkdir(parents=True)
            (scripts / "run-edited-tests.sh").write_bytes(
                (ROOT / "scripts/ci/run-edited-tests.sh").read_bytes())
            (scripts / "dune_suite_scope.py").write_text(
                "import sys\nprint('skip disabled' if sys.argv[-1]=='test_skip' else 'run')\n")
            (scripts / "stanza_env.py").write_text("")
            bindir = root / "fake-bin"
            bindir.mkdir()
            dune = bindir / "dune"
            dune.write_text(r"""#!/usr/bin/env python3
import pathlib,sys
for target in sys.argv[2:]:
    p=pathlib.Path('_build/default')/target
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text('#!/bin/sh\nexit ' + ('1' if 'test_fail' in target else '0') + '\n')
    p.chmod(0o755)
""")
            dune.chmod(0o755)
            plan = root / "selection.json"
            plan.write_text(json.dumps({"sources": ["test/test_ok.ml", "test/test_fail.ml",
                                                    "test/test_skip.ml"],
                                        "direct_sources": []}))
            executed = root / "executed.txt"
            result = subprocess.run(
                ["bash", str(scripts / "run-edited-tests.sh"), "--run-selection", str(plan),
                 "--executed-file", str(executed), "--budget-seconds", "30"],
                cwd=root, env={**os.environ, "PATH": str(bindir) + ":" + os.environ["PATH"]},
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertEqual(executed.read_text().splitlines(), ["test/test_ok.ml"])


if __name__ == "__main__":
    unittest.main()

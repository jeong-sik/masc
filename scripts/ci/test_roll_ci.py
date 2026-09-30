#!/usr/bin/env python3
"""ROLL scope and execution evidence, without an OCaml toolchain."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

import roll_ci

ROOT = Path(__file__).resolve().parents[2]


class RollScopeTests(unittest.TestCase):
    def setUp(self) -> None:
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
        self.input: dict[str, Any] = {
            "schema": "masc.roll.input.v1",
            "base": self.base,
            "digest": "sha256:" + "d" * 64,
            "members": [
                {"pr": 10, "head": self.parent, "review_base": self.base},
                {"pr": 11, "head": self.head, "review_base": self.parent},
            ],
        }
        self.pulls: dict[int, dict[str, Any]] = {
            10: {
                "state": "open",
                "head": {"sha": self.parent},
                "base": {"sha": self.base, "ref": "main"},
                "body": "Test-suites: test_extra",
            },
            11: {
                "state": "open",
                "head": {"sha": self.head},
                "base": {"sha": self.parent},
                "body": "",
            },
        }

        self.git("checkout", "-qb", "inspection", self.base)
        self.git("merge", "--no-ff", "-qm", "inspection merge", self.head)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.check_output(["git", *args], cwd=self.root, text=True).strip()

    def write(self, path: str, content: str) -> Path:
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
        return p

    def commit(self, message: str) -> str:
        self.git("add", ".")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def select(self, paths: list[str], body: str) -> dict[str, list[str]]:
        selected = [p for p in paths if p.startswith("test/") and p.endswith(".ml")]
        if body:
            selected.append("test/test_extra.ml")
        return {"sources": selected, "direct_sources": selected}

    def prepare(self, select: roll_ci.Selector | None = None) -> dict[str, Any]:
        return roll_ci.build_plan(
            self.root,
            self.input,
            self.pulls,
            99,
            self.head,
            "123",
            "1",
            select or self.select,
        )

    def test_full_diff_and_member_requirements(self) -> None:
        plan = self.prepare()
        self.assertEqual(
            plan["required_suites"],
            ["test/test_child.ml", "test/test_extra.ml", "test/test_parent.ml"],
        )
        self.assertEqual(plan["base"], self.base)
        self.assertEqual(plan["roll_tree"], self.git("rev-parse", "HEAD^{tree}"))
        self.assertEqual(plan["input_digest"], self.input["digest"])

    def test_divergent_main_preserves_parent_suite(self) -> None:
        self.git("checkout", "-qb", "new-main", self.base)
        self.write("test/test_main.ml", "main\n")
        fixed_base = self.commit("main moved independently")
        self.git("merge", "--no-ff", "-qm", "inspection merge", self.head)
        self.input["base"] = fixed_base
        self.pulls[10]["base"]["sha"] = fixed_base
        plan = self.prepare()
        self.assertEqual(plan["base"], fixed_base)
        self.assertEqual(
            plan["required_suites"],
            ["test/test_child.ml", "test/test_extra.ml", "test/test_parent.ml"],
        )
        self.assertEqual(self.input["members"][0]["review_base"], self.base)

    def test_shortened_member_review_is_refused(self) -> None:
        self.input["members"][1]["review_base"] = self.head
        with self.assertRaisesRegex(ValueError, "full delta"):
            self.prepare()

    def test_missing_lower_member_suite_is_red(self) -> None:
        plan = self.prepare()
        executed = ["test/test_child.ml", "test/test_extra.ml"]
        receipt = roll_ci.finish_receipt(plan, executed, 0)
        self.assertEqual(receipt["missing_suites"], ["test/test_parent.ml"])
        self.assertEqual(receipt["result"], "failure")

    def test_empty_selection_is_refused(self) -> None:
        with self.assertRaises(ValueError):
            empty: roll_ci.Selector = lambda paths, body: {
                "sources": [],
                "direct_sources": [],
            }
            self.prepare(empty)

    def test_selector_failure_propagates(self) -> None:
        def broken(paths: list[str], body: str) -> dict[str, list[str]]:
            raise subprocess.CalledProcessError(2, ["selector"])

        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare(broken)

    def test_moved_member_is_refused(self) -> None:
        self.pulls[10]["head"]["sha"] = self.head
        with self.assertRaises(ValueError):
            self.prepare()

    def test_changed_parent_chain_is_refused(self) -> None:
        self.pulls[11]["base"]["sha"] = self.base
        with self.assertRaises(ValueError):
            self.prepare()

    def test_wrong_checkout_head_is_refused(self) -> None:
        self.git("checkout", "-q", self.parent)
        with self.assertRaises(ValueError):
            self.prepare()

    def test_nonancestor_review_base_is_refused(self) -> None:
        self.git("checkout", "--orphan", "unrelated")
        self.write("other", "other")
        self.input["members"][0]["review_base"] = self.commit("unrelated")
        self.git("checkout", "-q", self.head)
        with self.assertRaises(ValueError):
            self.prepare()

    def test_failed_run_cannot_certify_complete_list(self) -> None:
        plan = self.prepare()
        self.assertEqual(
            roll_ci.finish_receipt(plan, plan["required_suites"], 1)["result"],
            "failure",
        )

    def test_success_and_extra_execution(self) -> None:
        plan = self.prepare()
        self.assertEqual(
            roll_ci.finish_receipt(plan, plan["required_suites"], 0)["result"],
            "success",
        )
        self.assertEqual(
            roll_ci.finish_receipt(
                plan, plan["required_suites"] + ["test/other.ml"], 0
            )["result"],
            "failure",
        )


class SelectorContractTests(unittest.TestCase):
    def test_member_named_suite_uses_production_selector(self) -> None:
        selection = roll_ci.select_sources(ROOT, [], "Test-suites: test_keeper_toml")
        self.assertIn("test/test_keeper_toml.ml", selection["sources"])
        with self.assertRaises(subprocess.CalledProcessError):
            roll_ci.select_sources(ROOT, [], "Test-suites: test_roll_nonexistent")

    def test_shared_parser_binds_ordered_members(self) -> None:
        body = (
            "<!-- masc-roll-input-v1\n"
            + json.dumps(
                {
                    "base": "a" * 40,
                    "members": [{"pr": 1, "head": "b" * 40, "review_base": "a" * 40}],
                }
            )
            + "\n-->"
        )
        value = roll_ci.shared_input(body)
        self.assertEqual(value["members"][0]["pr"], 1)
        self.assertTrue(value["digest"].startswith("sha256:"))
        with self.assertRaises(ValueError):
            roll_ci.shared_input(body + "\n" + body)


class RunnerReceiptTests(unittest.TestCase):
    def test_real_runner_records_only_successful_executables(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            scripts = root / "scripts/ci"
            scripts.mkdir(parents=True)
            (scripts / "run-edited-tests.sh").write_bytes(
                (ROOT / "scripts/ci/run-edited-tests.sh").read_bytes()
            )
            (scripts / "dune_suite_scope.py").write_text(
                "import sys\nprint('skip disabled' if sys.argv[-1]=='test_skip' else 'run')\n"
            )
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
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(
                [
                    "git",
                    "-c",
                    "user.name=test",
                    "-c",
                    "user.email=test@example.invalid",
                    "commit",
                    "-qm",
                    "runner fixture",
                ],
                cwd=root,
                check=True,
            )
            checkout = roll_ci.git(root, "rev-parse", "HEAD")
            tree = roll_ci.git(root, "rev-parse", "HEAD^{tree}")
            plan = root / "selection.json"
            executed = root / "executed.txt"
            cases: list[tuple[list[str], int, list[str], str]] = [
                (
                    ["test/test_ok.ml", "test/test_fail.ml", "test/test_skip.ml"],
                    1,
                    ["test/test_ok.ml"],
                    "failure",
                ),
                (
                    ["test/test_ok.ml", "test/test_skip.ml"],
                    0,
                    ["test/test_ok.ml"],
                    "failure",
                ),
                (["test/test_skip.ml"], 0, [], "failure"),
                (["test/test_ok.ml"], 0, ["test/test_ok.ml"], "success"),
            ]
            for sources, status, successful, expected in cases:
                with self.subTest(sources=sources):
                    plan.write_text(
                        json.dumps({"sources": sources, "direct_sources": []})
                    )
                    result = subprocess.run(
                        [
                            "bash",
                            str(scripts / "run-edited-tests.sh"),
                            "--run-selection",
                            str(plan),
                            "--executed-file",
                            str(executed),
                            "--budget-seconds",
                            "30",
                        ],
                        cwd=root,
                        env={
                            **os.environ,
                            "PATH": str(bindir) + ":" + os.environ["PATH"],
                        },
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(
                        result.returncode, status, result.stdout + result.stderr
                    )
                    actual = executed.read_text().splitlines()
                    self.assertEqual(actual, successful)
                    receipt = roll_ci.finish_receipt(
                        {"required_suites": sources}, actual, result.returncode
                    )
                    self.assertEqual(receipt["result"], expected)
                    plan.write_text(
                        json.dumps(
                            {
                                "checkout_commit": checkout,
                                "roll_tree": tree,
                                "required_suites": sources,
                                "direct_sources": [],
                            }
                        )
                    )
                    output = root / "roll-evidence.json"
                    with (
                        patch.object(roll_ci, "ROOT", root),
                        patch.dict(
                            os.environ,
                            {
                                "PATH": str(bindir) + ":" + os.environ["PATH"],
                            },
                        ),
                    ):
                        result_code = roll_ci.run(plan, output, 30)
                    saved = json.loads(output.read_text())
                    self.assertEqual(result_code, 0 if expected == "success" else 1)
                    self.assertEqual(saved["result"], expected)
                    self.assertEqual(saved["runner_exit"], status)
                    self.assertEqual(saved["executed_suites"], successful)


if __name__ == "__main__":
    unittest.main()

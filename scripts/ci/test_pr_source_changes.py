#!/usr/bin/env python3
# pyright: strict
"""pr_source_changes.py against a local git remote shaped like a two-layer
native stack. Offline; no network, no real pull request.

Run: python3 -I scripts/ci/test_pr_source_changes.py
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import pr_source_changes as changes  # noqa: E402

SCRIPT = HERE / "pr_source_changes.py"
STACK = 900
GIT_ENV = {
    "PATH": os.environ["PATH"],
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_SYSTEM": os.devnull,
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.invalid",
}


def stack_json(position: int, size: int, base_sha: str | None) -> str:
    base = {"ref": "main"} if base_sha is None else {"ref": "main", "sha": base_sha}
    return json.dumps({"number": STACK, "position": position, "size": size, "base": base})


class Plan(unittest.TestCase):
    SHA = "a" * 40

    def test_no_stack_decides_alone(self):
        for raw in ("", "null", " null\n"):
            self.assertIsInstance(changes.plan(raw), changes.Alone, raw)

    def test_lower_layer_leaves_the_check_to_the_top(self):
        self.assertEqual(changes.plan(stack_json(1, 2, self.SHA)), changes.Lower(STACK))
        # A lower layer needs no base.sha: it reads no diff.
        self.assertEqual(changes.plan(stack_json(83, 84, None)), changes.Lower(STACK))

    def test_top_reads_the_whole_stack(self):
        self.assertEqual(changes.plan(stack_json(2, 2, self.SHA)), changes.Top(STACK, self.SHA))
        self.assertEqual(changes.plan(stack_json(1, 1, self.SHA)), changes.Top(STACK, self.SHA))

    def test_an_unknown_shape_decides_alone(self):
        unknown = (
            "{",
            "[]",
            '"stack"',
            json.dumps({"number": STACK, "position": 1}),
            json.dumps({"number": STACK, "position": "1", "size": 2}),
            json.dumps({"number": STACK, "position": True, "size": 2}),
            json.dumps({"number": STACK, "position": 0, "size": 2}),
            json.dumps({"number": STACK, "position": 3, "size": 2}),
            json.dumps({"number": None, "position": 1, "size": 2}),
            stack_json(2, 2, None),
            stack_json(2, 2, "main"),
            json.dumps({"number": STACK, "position": 2, "size": 2, "base": "main"}),
        )
        for raw in unknown:
            self.assertIsInstance(changes.plan(raw), changes.Alone, raw)


class Sources(unittest.TestCase):
    def test_sources(self):
        for path in (
            "lib/a.ml",
            "lib/a.mli",
            "lib/gen/table.inc",
            "dune",
            "dune-project",
            "test/dune",
            "masc.opam",
            ".github/actions/pin-ocaml-deps/action.yml",
            ".github/workflows/pr-type-check.yml",
            "scripts/ci/pr_source_changes.py",
            "scripts/ci/test_pr_source_changes.py",
        ):
            self.assertTrue(changes.is_source(path), path)

    def test_not_sources(self):
        for path in (
            "docs/evidence/run/snapshot.ml",
            "docs/dune",
            "dashboard/src/a.ts",
            "changelog.d/1.md",
            "scripts/ci/apt-refresh.sh",
            ".github/workflows/test.yml",
            "vendor/dune-project",
            "lib/a.ml.orig",
            "lib/dune.inc.txt",
        ):
            self.assertFalse(changes.is_source(path), path)


class Stack(unittest.TestCase):
    """main: B.  layer 1 adds lib/a.ml.  layer 2 (top) adds dashboard/a.ts.
    Each pull request's merge commit has its base branch as first parent."""

    def git(self, cwd: pathlib.Path, *args: str) -> str:
        done = subprocess.run(
            ["git", "-C", str(cwd), *args],
            check=True, env=GIT_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        return done.stdout.strip()

    def commit(self, path: str, parent_message: str) -> str:
        target = self.origin / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(parent_message)
        self.git(self.origin, "add", path)
        self.git(self.origin, "commit", "-q", "-m", parent_message)
        return self.git(self.origin, "rev-parse", "HEAD")

    def merge(self, base: str, head: str) -> str:
        tree = self.git(self.origin, "rev-parse", f"{head}^{{tree}}")
        return self.git(self.origin, "commit-tree", tree, "-p", base, "-p", head, "-m", "merge")

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="pr-source-changes-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.origin = self.tmp / "origin"
        self.origin.mkdir()
        self.git(self.origin, "init", "-q", "-b", "main")
        # GitHub serves any commit by sha; a local remote must be told to.
        self.git(self.origin, "config", "uploadpack.allowAnySHA1InWant", "true")
        self.git(self.origin, "config", "uploadpack.allowFilter", "true")
        self.base = self.commit("README.md", "base")
        self.layer1 = self.commit("lib/a.ml", "layer 1")
        self.layer2 = self.commit("dashboard/a.ts", "layer 2")
        self.merge1 = self.merge(self.base, self.layer1)
        self.merge2 = self.merge(self.layer1, self.layer2)
        # Keep the merge commits reachable, as refs/pull/N/merge does.
        self.git(self.origin, "update-ref", "refs/pull/1/merge", self.merge1)
        self.git(self.origin, "update-ref", "refs/pull/2/merge", self.merge2)

    def work(self, merge: str) -> pathlib.Path:
        """What the workflow has before the script runs: the merge commit and
        its parents, nothing older."""
        work = self.tmp / f"work-{merge[:8]}"
        self.git(self.tmp, "init", "-q", str(work))
        self.git(work, "remote", "add", "origin", self.origin.as_uri())
        self.git(work, "fetch", "-q", "--depth=2", "--filter=blob:none", "origin", merge)
        return work

    def run_script(self, merge: str, stack: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT),
             "--git-dir", str(self.work(merge)), "--remote", "origin", "--merge", merge],
            env={**GIT_ENV, "STACK_JSON": stack},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )

    def answer(self, merge: str, stack: str) -> str:
        done = self.run_script(merge, stack)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout

    def test_without_a_stack_each_pull_request_reads_its_own_layer(self):
        self.assertEqual(self.answer(self.merge1, "null"), "true\n")
        self.assertEqual(self.answer(self.merge2, "null"), "false\n")

    def test_a_lower_layer_with_sources_is_not_checked(self):
        self.assertEqual(self.answer(self.merge1, stack_json(1, 2, self.base)), "false\n")

    def test_a_dashboard_top_is_checked_for_the_ocaml_layer_below(self):
        work = self.work(self.merge2)
        # A blobless fetch leaves a promisor remote, so git would fetch the
        # object to answer this question unless told not to.
        missing = subprocess.run(
            ["git", "-C", str(work), "cat-file", "-e", self.base],
            env={**GIT_ENV, "GIT_NO_LAZY_FETCH": "1"}, stderr=subprocess.DEVNULL,
        )
        self.assertNotEqual(missing.returncode, 0, "the base must not arrive with the merge commit")
        shutil.rmtree(work)
        self.assertEqual(self.answer(self.merge2, stack_json(2, 2, self.base)), "true\n")

    def test_a_top_whose_stack_has_no_sources_is_not_checked(self):
        self.assertEqual(self.answer(self.merge2, stack_json(2, 2, self.layer1)), "false\n")

    def test_an_unknown_stack_shape_reads_the_layer(self):
        self.assertEqual(self.answer(self.merge1, stack_json(1, 0, self.base)), "true\n")

    def test_a_base_that_cannot_be_fetched_fails(self):
        done = self.run_script(self.merge2, stack_json(2, 2, "0" * 39 + "1"))
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual(done.stdout, "")

    def test_a_short_merge_sha_is_refused(self):
        done = subprocess.run(
            [sys.executable, "-I", str(SCRIPT),
             "--git-dir", str(self.tmp), "--remote", "origin", "--merge", "HEAD"],
            env=GIT_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.assertNotEqual(done.returncode, 0)
        self.assertEqual(done.stdout, "")


if __name__ == "__main__":
    unittest.main()

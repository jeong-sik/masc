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
import posixpath
import re
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
            "dune-workspace",
            "test/dune",
            "masc.opam",
            ".github/actions/pin-ocaml-deps/action.yml",
            ".github/workflows/pr-type-check.yml",
            "scripts/ci/pr_source_changes.py",
            "scripts/ci/test_pr_source_changes.py",
            "scripts/ci/pr_changelog_fragments.py",
            "scripts/ci/test_pr_changelog_fragments.py",
            # Inputs of build rules that are not OCaml (#51595).
            "lib/auth/account_page.css",
            "lib/exec/parser/bash_subset.mly",
            "lib/exec/parser/bash_lexer.mll",
            "lib/sse_event/sse_event.atd",
            "lib/apple_keychain/apple_keychain_stubs.c",
            "lib/build_commit/probe-commit.sh",
            "config/tools/masc_board_post.toml",
            "skills/root-cause-first/SKILL.md",
            "addons/browser/ego/lane.toml",
            "scripts/embed-setup.py",
            "masc.opam.locked",
            "sandbox-images/base/Dockerfile",
            "packages/agent_core/models.toml",
            # A directory nobody listed is a source until it is shown not to be.
            "vendor/dune-project",
            "new-directory/input.txt",
        ):
            self.assertTrue(changes.is_source(path), path)

    def test_not_sources(self):
        for path in (
            "docs/evidence/run/snapshot.ml",
            "docs/dune",
            "dashboard/src/a.ts",
            "changelog.d/1.md",
        ):
            self.assertFalse(changes.is_source(path), path)

    def test_a_directory_is_skipped_by_its_whole_name(self):
        for path in ("docs-site/index.md", "dashboard.toml", "changelog.d.md"):
            self.assertTrue(changes.is_source(path), path)


ROOT = HERE.parents[1]
DUNE_FILES = frozenset({"dune", "dune-project", "dune-workspace"})
# What a tracked dune file reads from NOT_BUILD_INPUTS today: (dune file, path
# from the repository root). Each is the `deps` of a `test` stanza or of a
# rule that has an alias and no target. Those are read when the test runs;
# `dune build @check` runs no test, so a change to one needs no type-check.
# A read by a rule that has a target does not belong here: take its directory
# out of NOT_BUILD_INPUTS instead.
READ_ONLY_BY_TEST_RUNS = frozenset({
    ("test/dune", "dashboard/src/api/fixtures/scheduled-automation-lookup-found.json"),
    ("test/dune", "docs/examples/lane-addons/dos-value-difference.toml"),
    ("test/dune", "docs/examples/lane-addons/dos-value-statistics.toml"),
    ("test/dune", "docs/examples/lane-addons/dos-statistics.toml"),
    ("test/dune", "docs/examples/lane-addons/output-statistics.toml"),
    ("test/dune", "docs/examples/lane-addons/fusion-compute/*.toml"),
    ("test/dune", "docs/examples/lane-addons/operator-quiz.toml"),
    ("test/dune", "docs/evidence/2026-09-30-candle-grade-explicit-outcome"),
    ("test/dune", "docs/evidence/2026-09-30-candle-grade-scope-survey"),
})
ROOT_VARIABLES = ("%{workspace_root}/", "%{project_root}/")
PATH_IN_VARIABLE = re.compile(r"%\{[^}:]+:([^}]+)\}")


def dune_words(text: str) -> tuple[str, ...]:
    """The words of a dune file: atoms, and the words inside each string (an
    action's shell command names files too). Comments are left out."""
    words: list[str] = []
    word = ""
    at = 0
    in_string = False
    while at < len(text):
        char = text[at]
        if in_string and char == "\\":
            word += text[at + 1 : at + 2]
            at += 2
            continue
        if not in_string and char == ";":
            end = text.find("\n", at)
            at = len(text) if end < 0 else end
            continue
        if char == '"':
            in_string = not in_string
        if char.isspace() or char in '()"':
            if word:
                words.append(word)
            word = ""
        else:
            word += char
        at += 1
    if word:
        words.append(word)
    return tuple(words)


def dune_reads(dune_file: str, text: str) -> frozenset[str]:
    """Every path the words of a dune file can name, from the repository
    root. A word that is not a path gives a path nothing tracked has."""
    here = posixpath.dirname(dune_file)
    reads: set[str] = set()
    for word in dune_words(text):
        if word.startswith(ROOT_VARIABLES):
            named = [(".", word.split("/", 1)[1])]
        else:
            named = [(here, path) for path in PATH_IN_VARIABLE.findall(word)] or [(here, word)]
        for start, path in named:
            reads.add(posixpath.normpath(posixpath.join(start, path)))
    return frozenset(reads)


def inside(path: str, directories: tuple[str, ...]) -> bool:
    return f"{path}/".startswith(directories)


class DuneReads(unittest.TestCase):
    def test_paths_are_resolved_from_the_dune_file(self):
        text = (
            "(rule (targets a.ml)\n"
            " ; (deps ../../docs/commented-out.txt)\n"
            " (deps ../../config/a.toml (glob_files ../../skills/*.md)\n"
            "  %{workspace_root}/benchmarks/data.json (source_tree ../../docs))\n"
            ' (action (system "python3 %{dep:../../scripts/gen.py} ; cat ../../dashboard/x.css")))\n'
        )
        reads = dune_reads("lib/x/dune", text)
        for path in (
            "config/a.toml",
            "skills/*.md",
            "benchmarks/data.json",
            "docs",
            "scripts/gen.py",
            "dashboard/x.css",
            "lib/x/a.ml",
        ):
            self.assertIn(path, reads)
        self.assertNotIn("docs/commented-out.txt", reads)
        self.assertTrue(inside("docs", ("docs/",)))
        self.assertTrue(inside("dashboard/x.css", ("dashboard/",)))
        self.assertFalse(inside("docs-site/a.md", ("docs/",)))


class NotBuildInputs(unittest.TestCase):
    """NOT_BUILD_INPUTS against the dune files this checkout tracks."""

    tracked: tuple[str, ...] = ()

    @classmethod
    def setUpClass(cls):
        listed = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "-z"],
            check=True, stdout=subprocess.PIPE, text=True,
        ).stdout
        cls.tracked = tuple(path for path in listed.split("\0") if path)

    def dune_files(self) -> tuple[str, ...]:
        found = tuple(p for p in self.tracked if posixpath.basename(p) in DUNE_FILES)
        self.assertIn("dune", found)
        self.assertIn("lib/exec/parser/dune", found)
        return found

    def test_no_dune_file_sits_in_them(self):
        for path in self.dune_files():
            self.assertFalse(inside(path, changes.NOT_BUILD_INPUTS), path)

    def test_dune_files_read_them_only_to_run_tests(self):
        read = {
            (dune_file, path)
            for dune_file in self.dune_files()
            for path in dune_reads(dune_file, (ROOT / dune_file).read_text(encoding="utf-8"))
            if inside(path, changes.NOT_BUILD_INPUTS)
        }
        self.assertEqual(read, READ_ONLY_BY_TEST_RUNS)


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

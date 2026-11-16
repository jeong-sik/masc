#!/usr/bin/env python3
# pyright: strict
"""pr_changelog_fragments.py against a local git remote, with the real
scripts/changelog-fragments.py as the checker. Offline; no real pull request.

Run: python3 -I scripts/ci/test_pr_changelog_fragments.py
"""

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE / "pr_changelog_fragments.py"
CHECKER = HERE.parent / "changelog-fragments.py"
CHECKER_PATH = "scripts/changelog-fragments.py"
GIT_ENV = {
    "PATH": os.environ["PATH"],
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_SYSTEM": os.devnull,
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.invalid",
}
WELL_FORMED = "### Fixed\n\n- A fragment that follows the format (#{number}).\n"
# The first line of changelog.d/50755.md as #50755 merged it.
WRONG_HEADING = "## Fixed\n\n- A heading one level too high (#{number}).\n"
# changelog.d/42243.md as #42243 merged it: the bullet cites no pull request.
NO_CITATION = "### Fixed\n\n- A bullet that cites nothing.\n"
# changelog.d/42263.md as #42263 merged it: prose, no heading and no bullet.
PROSE = "A sentence where a heading and a bullet belong.\n"


class PullRequest(unittest.TestCase):
    """main holds the checker and one fragment. Each case commits a pull
    request on top and reads its merge commit the way the workflow does."""

    def git(self, cwd: pathlib.Path, *args: str) -> str:
        done = subprocess.run(
            ["git", "-C", str(cwd), *args],
            check=True, env=GIT_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        return done.stdout.strip()

    def write(self, path: str, text: str) -> None:
        target = self.origin / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        self.git(self.origin, "add", path)

    def commit(self, message: str) -> str:
        self.git(self.origin, "commit", "-q", "-m", message)
        return self.git(self.origin, "rev-parse", "HEAD")

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="pr-changelog-fragments-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.origin = self.tmp / "origin"
        self.origin.mkdir()
        self.git(self.origin, "init", "-q", "-b", "main")
        # GitHub serves any commit by sha; a local remote must be told to.
        self.git(self.origin, "config", "uploadpack.allowAnySHA1InWant", "true")
        self.git(self.origin, "config", "uploadpack.allowFilter", "true")
        self.write(CHECKER_PATH, CHECKER.read_text(encoding="utf-8"))
        self.write("changelog.d/1.md", WELL_FORMED.format(number=1))
        self.base = self.commit("base")

    def merge_of(self, head: str) -> str:
        """The pull request's merge commit: the base branch is its first parent."""
        tree = self.git(self.origin, "rev-parse", f"{head}^{{tree}}")
        merge = self.git(
            self.origin, "commit-tree", tree, "-p", self.base, "-p", head, "-m", "merge"
        )
        # Keep the merge commit reachable, as refs/pull/N/merge does.
        self.git(self.origin, "update-ref", "refs/pull/1/merge", merge)
        return merge

    def run_script(self, head: str) -> subprocess.CompletedProcess[str]:
        """What the workflow has before the script runs: the merge commit and
        its parents, without file contents."""
        merge = self.merge_of(head)
        work = self.tmp / "work"
        self.git(self.tmp, "init", "-q", str(work))
        self.git(work, "remote", "add", "origin", self.origin.as_uri())
        self.git(work, "fetch", "-q", "--depth=2", "--filter=blob:none", "origin", merge)
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--git-dir", str(work), "--merge", merge],
            env=GIT_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )

    def test_a_well_formed_fragment_passes(self):
        self.write("changelog.d/2.md", WELL_FORMED.format(number=2))
        done = self.run_script(self.commit("pull request"))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("1 changed fragment(s) OK", done.stdout)

    def test_a_malformed_fragment_is_refused(self):
        for name, text in (
            ("wrong heading", WRONG_HEADING),
            ("no citation", NO_CITATION),
            ("prose", PROSE),
        ):
            with self.subTest(name):
                self.git(self.origin, "reset", "-q", "--hard", self.base)
                self.write("changelog.d/2.md", text.format(number=2))
                done = self.run_script(self.commit("pull request"))
                shutil.rmtree(self.tmp / "work")
                self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
                # The annotation names the fragment, so the pull request shows it.
                self.assertIn("::error file=changelog.d/2.md", done.stdout)

    def test_a_fragment_under_a_wrong_name_is_refused(self):
        self.write("changelog.d/notes.md", WELL_FORMED.format(number=2))
        done = self.run_script(self.commit("pull request"))
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)

    def test_an_edit_that_breaks_a_fragment_on_main_is_refused(self):
        self.write("changelog.d/1.md", WRONG_HEADING.format(number=1))
        done = self.run_script(self.commit("pull request"))
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)

    def test_a_pull_request_without_a_fragment_passes(self):
        self.write("lib/a.ml", "let a = 1\n")
        done = self.run_script(self.commit("pull request"))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("changes no changelog fragment", done.stdout)

    def test_a_malformed_fragment_already_on_the_base_is_not_this_pull_requests(self):
        self.write("changelog.d/3.md", WRONG_HEADING.format(number=3))
        self.base = self.commit("main merged a malformed fragment")
        self.write("changelog.d/2.md", WELL_FORMED.format(number=2))
        done = self.run_script(self.commit("pull request"))
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_removing_a_fragment_passes(self):
        self.git(self.origin, "rm", "-q", "changelog.d/1.md")
        done = self.run_script(self.commit("pull request"))
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_a_tree_without_the_checker_fails(self):
        self.git(self.origin, "rm", "-q", CHECKER_PATH)
        self.write("changelog.d/2.md", WELL_FORMED.format(number=2))
        done = self.run_script(self.commit("pull request"))
        self.assertNotEqual(done.returncode, 0)

    def test_a_short_merge_sha_is_refused(self):
        done = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--git-dir", str(self.tmp), "--merge", "HEAD"],
            env=GIT_ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.assertNotEqual(done.returncode, 0)


if __name__ == "__main__":
    unittest.main()

"""The tracked pre-push hook refuses pushed commits that add Dune trace dumps.

Each case builds a throwaway clone with a bare remote. Pushes run with
core.hooksPath pointing at this checkout's .githooks, so the hook under test
is the working-tree copy. Setup commits and setup pushes run with hooks off,
because .githooks/pre-commit refuses commits on main.

Run: python3 scripts/tests/test_githooks_pre_push.py
"""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path

HOOKS_DIR = Path(__file__).resolve().parents[2] / ".githooks"
IDENTITY = ("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid")
NO_HOOKS = "/dev/null"

type Completed = subprocess.CompletedProcess[str]


def git(cwd: Path, *args: str, hooks_path: str) -> Completed:
    return subprocess.run(
        ["git", "-c", f"core.hooksPath={hooks_path}", *IDENTITY, *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )


class PrePushTraceGuard(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.remote = root / "remote.git"
        self.work = root / "work"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(self.remote)], check=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.work)], check=True)
        self.setup_git("remote", "add", "origin", str(self.remote))
        self.commit("README.md", "seed\n")
        self.setup_git("push", "-q", "origin", "main")
        self.setup_git("checkout", "-q", "-b", "feature")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def setup_git(self, *args: str) -> None:
        result = git(self.work, *args, hooks_path=NO_HOOKS)
        self.assertEqual(result.returncode, 0, result.stderr)

    def commit(self, path: str, content: str) -> None:
        target = self.work / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        self.setup_git("add", "-f", path)
        self.setup_git("commit", "-q", "-m", f"add {path}")

    def delete(self, path: str) -> None:
        self.setup_git("rm", "-q", path)
        self.setup_git("commit", "-q", "-m", f"delete {path}")

    def push(self) -> Completed:
        return git(self.work, "push", "-q", "origin", "feature", hooks_path=str(HOOKS_DIR))

    def assert_refused(self, result: Completed) -> None:
        self.assertNotEqual(result.returncode, 0, "push was accepted")
        self.assertIn("REFUSING", result.stdout + result.stderr)

    def assert_accepted(self, result: Completed) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_first_push_of_a_branch_with_a_trace_is_refused(self) -> None:
        self.commit("trace.csexp", "(env ...)\n")
        self.assert_refused(self.push())

    def test_first_push_of_a_branch_with_a_build_dir_is_refused(self) -> None:
        self.commit("_build-x/log", "x\n")
        self.assert_refused(self.push())

    def test_first_push_without_a_dump_is_accepted(self) -> None:
        self.commit("lib/a.ml", "let x = 1\n")
        self.assert_accepted(self.push())

    def test_later_push_with_a_trace_is_refused(self) -> None:
        self.commit("lib/a.ml", "let x = 1\n")
        self.assert_accepted(self.push())
        self.commit("trace.csexp", "(env ...)\n")
        self.assert_refused(self.push())

    def test_dump_added_then_deleted_before_the_push_is_refused(self) -> None:
        self.commit("lib/a.ml", "let x = 1\n")
        self.assert_accepted(self.push())
        self.commit("trace.csexp", "(env ...)\n")
        self.delete("trace.csexp")
        self.assert_refused(self.push())

    def test_push_that_deletes_a_pushed_dump_is_accepted(self) -> None:
        self.commit("trace.csexp", "(env ...)\n")
        self.setup_git("push", "-q", "origin", "feature")
        self.delete("trace.csexp")
        self.assert_accepted(self.push())


if __name__ == "__main__":
    unittest.main()

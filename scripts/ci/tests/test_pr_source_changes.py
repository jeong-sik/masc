"""Tests for scripts/ci/pr_source_changes.py against temporary git repos."""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile
import unittest

CI_DIR = pathlib.Path(__file__).resolve().parents[1]
if str(CI_DIR) not in sys.path:
    sys.path.insert(0, str(CI_DIR))

import pr_source_changes as changes  # noqa: E402

_ENV = {
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "LC_ALL": "C",
    "GIT_AUTHOR_NAME": "Test",
    "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test",
    "GIT_COMMITTER_EMAIL": "test@example.com",
}


def _git(cwd: pathlib.Path, *args: str) -> str:
    done = subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=_ENV,
    )
    return done.stdout.strip()


class PrSourceChangesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="masc-test-source-changes-")
        self.repo = pathlib.Path(self.tmp.name)
        _git(self.repo, "init", "-q", "-b", "main")
        self.base = self._commit({"lib/a.ml": "let a = 1\n", "dashboard/src/a.ts": "1\n"})

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _commit(self, files: dict[str, str]) -> str:
        for name, text in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            _git(self.repo, "add", name)
        _git(self.repo, "commit", "-q", "-m", "change")
        return _git(self.repo, "rev-parse", "HEAD")

    def _scope(self, merge: str, chosen: changes.Plan) -> changes.Scope:
        return changes.scope(str(self.repo), str(self.repo), merge, chosen)

    def test_dashboard_change_is_measured_from_the_first_parent(self) -> None:
        merge = self._commit({"dashboard/src/a.ts": "2\n"})
        found = self._scope(merge, changes.Alone("no stack"))
        self.assertEqual(found.paths, ("dashboard/src/a.ts",))
        self.assertFalse(changes.needs_type_check(found.paths))
        self.assertEqual(changes.dashboard_since(found), self.base)

    def test_source_only_change_needs_no_dashboard_check(self) -> None:
        merge = self._commit({"lib/a.ml": "let a = 2\n"})
        found = self._scope(merge, changes.Alone("no stack"))
        self.assertTrue(changes.needs_type_check(found.paths))
        self.assertIsNone(changes.dashboard_since(found))

    def test_lower_stack_layer_leaves_the_dashboard_to_the_top(self) -> None:
        merge = self._commit({"dashboard/src/a.ts": "2\n"})
        found = self._scope(merge, changes.Lower(7))
        self.assertIsNone(changes.dashboard_since(found))

    def test_stack_top_is_measured_from_the_stack_base(self) -> None:
        self._commit({"dashboard/src/a.ts": "2\n"})
        merge = self._commit({"lib/a.ml": "let a = 3\n"})
        found = self._scope(merge, changes.Top(7, self.base))
        self.assertEqual(set(found.paths), {"dashboard/src/a.ts", "lib/a.ml"})
        self.assertEqual(changes.dashboard_since(found), self.base)


if __name__ == "__main__":
    unittest.main()

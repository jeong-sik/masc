"""Integration tests for scripts/ci/pr_no_merge_commits.py using temporary bare git repos."""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile
import unittest

CI_DIR = pathlib.Path(__file__).resolve().parents[1]
if str(CI_DIR) not in sys.path:
    sys.path.insert(0, str(CI_DIR))

import pr_no_merge_commits as guard  # noqa: E402


def _git(cwd: pathlib.Path, *args: str) -> str:
    env = {
        "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
        "LC_ALL": "C",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@example.com",
    }
    res = subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    return res.stdout.strip()


class PrNoMergeCommitsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="masc-test-no-merge-")
        self.addCleanup(self.tmp.cleanup)
        root = pathlib.Path(self.tmp.name)
        self.origin = root / "origin.git"
        self.work = root / "work"
        _git(root, "init", "--bare", "-b", "main", str(self.origin))
        # Match strict servers that refuse raw SHA fetches outside advertised refs.
        _git(self.origin, "config", "uploadpack.allowFilter", "true")
        _git(self.origin, "config", "uploadpack.allowReachableSHA1InWant", "false")
        _git(self.origin, "config", "uploadpack.allowAnySHA1InWant", "false")
        _git(root, "clone", "-q", str(self.origin), str(self.work))
        self._commit("base.txt", "v1\n", "init main")
        _git(self.work, "push", "-q", "origin", "main")
        self.main_sha = _git(self.work, "rev-parse", "HEAD")

    def _commit(self, relpath: str, content: str, msg: str) -> str:
        p = self.work / relpath
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
        _git(self.work, "add", relpath)
        _git(self.work, "commit", "-q", "-m", msg)
        return _git(self.work, "rev-parse", "HEAD")

    def _make_pr_merge(self, base_ref: str, head_sha: str) -> str:
        """Synthesize a GitHub-like PR merge commit whose ^1=base and ^2=head."""
        _git(self.work, "checkout", "-q", "--detach", base_ref)
        _git(self.work, "merge", "-q", "--no-ff", "--no-commit", head_sha)
        _git(self.work, "commit", "-q", "-m", "synthetic PR merge")
        return _git(self.work, "rev-parse", "HEAD")

    def test_linear_pr_passes(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "feat/linear", "origin/main")
        head_sha = self._commit("a.txt", "one\n", "linear change")
        _git(self.work, "push", "-q", "origin", "feat/linear")
        _git(self.work, "push", "-q", "origin", f"{head_sha}:refs/pull/1/head")
        merge_sha = self._make_pr_merge("origin/main", head_sha)

        rc = guard.check(
            str(self.work), "origin", merge_sha, "feat/linear", "main", "main",
            same_repo=True, fetch_ref="refs/pull/1/head",
        )
        self.assertEqual(rc, 0)

    def test_pr_with_main_merge_commit_fails(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "feat/merged-main", "origin/main")
        self._commit("feat.txt", "feat\n", "feature commit")
        _git(self.work, "checkout", "-q", "main")
        self._commit("main.txt", "main2\n", "advance main")
        _git(self.work, "push", "-q", "origin", "main")
        _git(self.work, "checkout", "-q", "feat/merged-main")
        _git(self.work, "merge", "-q", "--no-ff", "origin/main", "-m", "Merge main into feat")
        head_sha = _git(self.work, "rev-parse", "HEAD")
        _git(self.work, "push", "-q", "origin", "feat/merged-main")
        _git(self.work, "push", "-q", "origin", f"{head_sha}:refs/pull/2/head")
        merge_sha = self._make_pr_merge("origin/main", head_sha)

        rc = guard.check(
            str(self.work), "origin", merge_sha, "feat/merged-main", "main", "main",
            same_repo=True, fetch_ref="refs/pull/2/head",
        )
        self.assertEqual(rc, 1)

    def test_release_branch_exempt_only_for_same_repo(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "release/v1.0.0", "origin/main")
        self._commit("rel.txt", "r1\n", "release commit")
        _git(self.work, "checkout", "-q", "main")
        self._commit("m2.txt", "m2\n", "main commit")
        _git(self.work, "push", "-q", "origin", "main")
        _git(self.work, "checkout", "-q", "release/v1.0.0")
        _git(self.work, "merge", "-q", "--no-ff", "origin/main", "-m", "Merge main into release")
        head_sha = _git(self.work, "rev-parse", "HEAD")
        _git(self.work, "push", "-q", "origin", f"{head_sha}:refs/pull/3/head")
        merge_sha = self._make_pr_merge("origin/main", head_sha)

        self.assertEqual(
            guard.check(
                str(self.work), "origin", merge_sha, "release/v1.0.0", "main", "main",
                same_repo=True, fetch_ref="refs/pull/3/head",
            ),
            0,
        )
        self.assertEqual(
            guard.check(
                str(self.work), "origin", merge_sha, "release/v1.0.0", "main", "main",
                same_repo=False, fetch_ref="refs/pull/3/head",
            ),
            1,
        )

    def test_stacked_layer_linear_passes_and_merge_fails(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "stack/l1", "origin/main")
        self._commit("l1.txt", "l1\n", "layer 1")
        _git(self.work, "push", "-q", "origin", "stack/l1")

        _git(self.work, "checkout", "-q", "-b", "stack/l2", "stack/l1")
        head_ok = self._commit("l2.txt", "l2\n", "layer 2")
        _git(self.work, "push", "-q", "origin", "stack/l2")
        _git(self.work, "push", "-q", "origin", f"{head_ok}:refs/pull/4/head")
        merge_ok = self._make_pr_merge("origin/stack/l1", head_ok)
        self.assertEqual(
            guard.check(
                str(self.work), "origin", merge_ok, "stack/l2", "stack/l1", "main",
                same_repo=True, fetch_ref="refs/pull/4/head",
            ),
            0,
        )

        _git(self.work, "checkout", "-q", "stack/l1")
        self._commit("l1b.txt", "l1b\n", "layer 1 update")
        _git(self.work, "push", "-q", "origin", "stack/l1")
        _git(self.work, "checkout", "-q", "stack/l2")
        _git(self.work, "merge", "-q", "--no-ff", "origin/stack/l1", "-m", "Merge l1 into l2")
        head_bad = _git(self.work, "rev-parse", "HEAD")
        _git(self.work, "push", "-q", "origin", "stack/l2")
        _git(self.work, "push", "-q", "origin", f"{head_bad}:refs/pull/5/head")
        merge_bad = self._make_pr_merge("origin/stack/l1", head_bad)
        self.assertEqual(
            guard.check(
                str(self.work), "origin", merge_bad, "stack/l2", "stack/l1", "main",
                same_repo=True, fetch_ref="refs/pull/5/head",
            ),
            1,
        )

    def test_deleted_stacked_base_falls_back_to_default_branch(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "stack/deleted-parent", "origin/main")
        self._commit("p.txt", "p\n", "parent commit")
        _git(self.work, "push", "-q", "origin", "stack/deleted-parent")

        _git(self.work, "checkout", "-q", "-b", "stack/child", "stack/deleted-parent")
        head_sha = self._commit("c.txt", "c\n", "child commit")
        _git(self.work, "push", "-q", "origin", "stack/child")
        _git(self.work, "push", "-q", "origin", f"{head_sha}:refs/pull/6/head")
        merge_sha = self._make_pr_merge("origin/stack/deleted-parent", head_sha)

        _git(self.work, "push", "-q", "origin", "--delete", "stack/deleted-parent")
        rc = guard.check(
            str(self.work), "origin", merge_sha, "stack/child", "stack/deleted-parent", "main",
            same_repo=True, fetch_ref="refs/pull/6/head",
        )
        self.assertEqual(rc, 0)

    def test_fork_pr_fetched_via_refs_pull_head(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "fork-feature", "origin/main")
        head_ok = self._commit("fork.txt", "from fork\n", "fork linear commit")
        _git(self.work, "push", "-q", "origin", f"{head_ok}:refs/pull/99/head")
        merge_ok = self._make_pr_merge("origin/main", head_ok)

        self.assertEqual(
            guard.check(
                str(self.work), "origin", merge_ok, "fork-feature", "main", "main",
                same_repo=False, fetch_ref="refs/pull/99/head",
            ),
            0,
        )

        _git(self.work, "checkout", "-q", "main")
        self._commit("upstream.txt", "u\n", "upstream commit")
        _git(self.work, "push", "-q", "origin", "main")
        _git(self.work, "checkout", "-q", "fork-feature")
        _git(self.work, "merge", "-q", "--no-ff", "origin/main", "-m", "Merge upstream main")
        head_bad = _git(self.work, "rev-parse", "HEAD")
        _git(self.work, "push", "-q", "origin", f"+{head_bad}:refs/pull/99/head")
        merge_bad = self._make_pr_merge("origin/main", head_bad)

        self.assertEqual(
            guard.check(
                str(self.work), "origin", merge_bad, "fork-feature", "main", "main",
                same_repo=False, fetch_ref="refs/pull/99/head",
            ),
            1,
        )


if __name__ == "__main__":
    unittest.main()

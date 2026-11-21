"""Tests for scripts/ci/pr_committed_secrets.py and check-committed-secrets.py.

Constructs every synthetic credential-shaped payload dynamically at runtime so
this test file itself contains zero literals matching any scanner rule.
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

CI_DIR = pathlib.Path(__file__).resolve().parents[1]
if str(CI_DIR) not in sys.path:
    sys.path.insert(0, str(CI_DIR))

import pr_committed_secrets as guard  # noqa: E402

_SCRUB_GIT_ENV_KEYS = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_KEY_0",
    "GIT_CONFIG_VALUE_0",
    "GIT_NO_LAZY_FETCH",
)


def _clean_git_env() -> dict[str, str]:
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"),
        "LC_ALL": "C",
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@example.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@example.com",
    }


def _git(cwd: pathlib.Path, *args: str) -> str:
    res = subprocess.run(
        ["git", "-C", str(cwd), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=_clean_git_env(),
    )
    return res.stdout.strip()


def _fake_github_token(seed: str = "A") -> str:
    return "ghp_" + (seed * 36)


def _fake_db_url() -> str:
    return "postgres://" + "dbuser:" + "supersecret99" + "@db.example.com:5432/app"


def _fake_pem_key() -> str:
    body = ("MIIE" * 40) + "\n"
    return "-----BEGIN " + "PRIVATE KEY-----\n" + body + "-----END " + "PRIVATE KEY-----\n"


class PrCommittedSecretsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="masc-test-pr-secrets-")
        self.addCleanup(self.tmp.cleanup)
        root = pathlib.Path(self.tmp.name)
        self.origin = root / "origin.git"
        self.work = root / "work"
        self._clone_seq = 0
        _git(root, "init", "--bare", "-b", "main", str(self.origin))
        _git(self.origin, "config", "uploadpack.allowFilter", "true")
        _git(root, "clone", "-q", str(self.origin), str(self.work))
        self._commit(
            guard.ALLOWLIST_PATH,
            "# allowlist header\n",
            "init allowlist",
        )
        self._commit("README.md", "hello\n", "init readme")
        _git(self.work, "push", "-q", "origin", "main")
        self.main_sha = _git(self.work, "rev-parse", "HEAD")

    def _commit(self, relpath: str, content: str, msg: str, *, executable: bool = False) -> str:
        p = self.work / relpath
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
        if executable:
            p.chmod(p.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        _git(self.work, "add", "--", relpath)
        _git(self.work, "commit", "-q", "-m", msg)
        return _git(self.work, "rev-parse", "HEAD")

    def _make_pr_merge(self, head_sha: str, *, base_ref: str = "origin/main") -> str:
        _git(self.work, "checkout", "-q", "--detach", base_ref)
        _git(self.work, "merge", "-q", "--no-ff", "--no-commit", head_sha)
        _git(self.work, "commit", "-q", "-m", "synthetic PR merge")
        merge_sha = _git(self.work, "rev-parse", "HEAD")
        _git(self.work, "push", "-q", "origin", f"+{merge_sha}:refs/pull/test/merge")
        return merge_sha

    def _make_blobless_clone(self) -> pathlib.Path:
        """Mirror pr-type-check.yml's blobless fetch against origin."""
        self._clone_seq += 1
        clone = pathlib.Path(self.tmp.name) / f"blobless-{self._clone_seq}"
        _git(pathlib.Path(self.tmp.name), "init", "-q", str(clone))
        _git(clone, "remote", "add", "origin", str(self.origin))
        _git(
            clone,
            "fetch",
            "-q",
            "--depth=2",
            "--filter=blob:none",
            "origin",
            "refs/pull/test/merge",
        )
        return clone

    def _run_guard(
        self,
        clone: pathlib.Path,
        merge_sha: str,
        *,
        extra_env: dict[str, str] | None = None,
        scanner_file: pathlib.Path | None = None,
    ) -> tuple[int, str]:
        scrubbed = {k: v for k, v in os.environ.items() if k not in _SCRUB_GIT_ENV_KEYS}
        if extra_env:
            scrubbed.update(extra_env)
        buf = io.StringIO()
        with mock.patch.dict(os.environ, scrubbed, clear=True):
            with contextlib.redirect_stdout(buf):
                rc = guard.check(str(clone), merge_sha, scanner_file=scanner_file)
        return rc, buf.getvalue()

    def _run_on_blobless_clone(
        self,
        merge_sha: str,
        *,
        extra_env: dict[str, str] | None = None,
        scanner_file: pathlib.Path | None = None,
    ) -> tuple[int, str]:
        clone = self._make_blobless_clone()
        return self._run_guard(clone, merge_sha, extra_env=extra_env, scanner_file=scanner_file)

    def test_clean_pr_passes(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "feat/clean", "origin/main")
        head = self._commit("docs/note.md", "plain documentation with no secrets\n", "add doc")
        merge_sha = self._make_pr_merge(head)

        rc, out = self._run_on_blobless_clone(merge_sha)
        self.assertEqual(rc, 0)
        self.assertIn("no unpinned credential shapes", out)

    def test_unpinned_secret_in_docs_fails_without_leaking_value(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "feat/leak", "origin/main")
        token = _fake_github_token("X")
        head = self._commit("docs/leak.md", f"line1\ntoken = {token}\n", "add leaked token")
        merge_sha = self._make_pr_merge(head)

        rc, out = self._run_on_blobless_clone(merge_sha, extra_env={"GITHUB_ACTIONS": "true"})
        self.assertEqual(rc, 1)
        self.assertIn("docs/leak.md:2", out)
        self.assertIn("[github-token]", out)
        self.assertIn("::error file=docs/leak.md,line=2::", out)
        self.assertNotIn(token, out)

    def test_pinned_fixture_in_same_pr_passes(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "feat/pinned", "origin/main")
        url = _fake_db_url()
        # db-url-password matches through the '@' terminating userinfo.
        matched = url.split("@", 1)[0] + "@"
        sha = hashlib.sha256(matched.encode("utf-8")).hexdigest()
        self._commit("test/fixture.txt", f"url = {url}\n", "add fixture")
        head = self._commit(
            guard.ALLOWLIST_PATH,
            f"# allowlist header\n{sha}  test/fixture.txt synthetic test fixture\n",
            "pin fixture",
        )
        merge_sha = self._make_pr_merge(head)

        rc, out = self._run_on_blobless_clone(merge_sha)
        self.assertEqual(rc, 0)
        self.assertIn("no unpinned credential shapes", out)

    def test_multiline_pem_and_base_secret_isolation(self) -> None:
        # Pre-existing unpinned secret on main in an untouched file must NOT
        # fail an unrelated PR, while a multi-line PEM in a changed file MUST.
        _git(self.work, "checkout", "-q", "main")
        self._commit("legacy.txt", f"legacy = {_fake_github_token('L')}\n", "legacy on main")
        _git(self.work, "push", "-q", "origin", "main")

        _git(self.work, "checkout", "-q", "-b", "feat/unrelated", "origin/main")
        head_clean = self._commit("other.txt", "safe content\n", "safe edit")
        merge_clean = self._make_pr_merge(head_clean)
        rc_clean, _ = self._run_on_blobless_clone(merge_clean)
        self.assertEqual(rc_clean, 0)

        _git(self.work, "checkout", "-q", "-b", "feat/pem", "origin/main")
        pem = _fake_pem_key()
        head_pem = self._commit("keys/test.pem", pem, "add pem")
        merge_pem = self._make_pr_merge(head_pem)
        rc_pem, out_pem = self._run_on_blobless_clone(merge_pem)
        self.assertEqual(rc_pem, 1)
        self.assertIn("keys/test.pem:1", out_pem)
        self.assertIn("[private-key-pem]", out_pem)

    def test_delete_only_and_symlink_pr_passes(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "feat/del-symlink", "origin/main")
        _git(self.work, "rm", "-q", "README.md")
        link = self.work / "link_to_etc"
        link.symlink_to("/etc/hosts")
        _git(self.work, "add", "link_to_etc")
        _git(self.work, "commit", "-q", "-m", "delete readme and add symlink")
        head = _git(self.work, "rev-parse", "HEAD")
        merge_sha = self._make_pr_merge(head)

        rc, out = self._run_on_blobless_clone(merge_sha)
        self.assertEqual(rc, 0)
        self.assertIn("changes no regular files", out)

    def test_oversized_blob_multi_chunk_drain_preserves_batch_framing(self) -> None:
        # Place a > 64 KiB blob (> _DRAIN_CHUNK) between a clean file before it
        # and a secret-bearing file after it in the same cat-file batch so any
        # framing bug while draining would misparse the following blob.
        _git(self.work, "checkout", "-q", "-b", "feat/big-middle", "origin/main")
        token_big = _fake_github_token("Z")
        token_after = _fake_github_token("Q")
        self._commit("01_before.txt", "clean before\n", "before")
        self._commit("02_big.txt", ("a" * 140_000) + token_big + "\n", "oversized middle")
        head = self._commit("03_after.txt", f"leaked = {token_after}\n", "leaked after")
        merge_sha = self._make_pr_merge(head)

        scanner = guard._load_scanner(CI_DIR / "check-committed-secrets.py")
        with mock.patch.object(guard, "_load_scanner") as loader:
            scanner.MAX_BYTES = 100_000
            loader.return_value = scanner
            rc, out = self._run_on_blobless_clone(merge_sha)
        self.assertEqual(rc, 1)
        self.assertNotIn("02_big.txt", out)
        self.assertIn("03_after.txt:1", out)
        self.assertNotIn(token_big, out)
        self.assertNotIn(token_after, out)

    def test_bulk_prefetch_uses_single_packfile_and_multi_batch_scanning(self) -> None:
        # 12 distinct files scanned with _BATCH_CHUNK=4 must still prefetch in
        # ONE packfile (not 12+1 per-blob lazy promisor fetches) and catch a
        # secret in the final batch.
        _git(self.work, "checkout", "-q", "-b", "feat/many-files", "origin/main")
        token = _fake_github_token("M")
        for i in range(11):
            p = self.work / f"many/file_{i:02d}.txt"
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(f"unique clean content {i}\n", encoding="utf-8")
        (self.work / "many/file_11.txt").write_text(f"secret = {token}\n", encoding="utf-8")
        _git(self.work, "add", "many")
        _git(self.work, "commit", "-q", "-m", "add 12 files")
        head = _git(self.work, "rev-parse", "HEAD")
        merge_sha = self._make_pr_merge(head)

        clone = self._make_blobless_clone()
        pack_dir = clone / ".git" / "objects" / "pack"
        packs_before = len(list(pack_dir.glob("*.pack")))
        with mock.patch.object(guard, "_BATCH_CHUNK", 4):
            rc, out = self._run_guard(clone, merge_sha)
        packs_after = len(list(pack_dir.glob("*.pack")))

        self.assertEqual(rc, 1)
        self.assertIn("many/file_11.txt:1", out)
        self.assertNotIn(token, out)
        # Exactly one promisor packfile added for allowlist + all 12 blobs.
        self.assertEqual(packs_after - packs_before, 1)

    def test_executable_typechange_and_rename_are_scanned(self) -> None:
        # Seed a symlink and a clean file on main first.
        _git(self.work, "checkout", "-q", "main")
        link = self.work / "was_link.txt"
        link.symlink_to("README.md")
        _git(self.work, "add", "was_link.txt")
        self._commit("orig_name.txt", "clean original\n", "seed rename target")
        _git(self.work, "push", "-q", "origin", "main")

        _git(self.work, "checkout", "-q", "-b", "feat/modes", "origin/main")
        tok_exec = _fake_github_token("E")
        tok_type = _fake_github_token("T")
        tok_ren = _fake_github_token("R")
        # 1. Executable script (100755)
        self._commit("bin/run.sh", f"#!/bin/sh\necho {tok_exec}\n", "add exec", executable=True)
        # 2. Typechange symlink (120000) -> regular file (100644)
        (self.work / "was_link.txt").unlink()
        self._commit("was_link.txt", f"now_regular = {tok_type}\n", "typechange to regular")
        # 3. Renamed file with added secret
        _git(self.work, "mv", "orig_name.txt", "renamed_name.txt")
        head = self._commit("renamed_name.txt", f"moved = {tok_ren}\n", "rename with secret")
        merge_sha = self._make_pr_merge(head)

        rc, out = self._run_on_blobless_clone(merge_sha)
        self.assertEqual(rc, 1)
        self.assertIn("bin/run.sh:2", out)
        self.assertIn("was_link.txt:1", out)
        self.assertIn("renamed_name.txt:1", out)
        for tok in (tok_exec, tok_type, tok_ren):
            self.assertNotIn(tok, out)

    def test_special_filenames_and_annotation_escaping(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "feat/special-names", "origin/main")
        tok1 = _fake_github_token("S")
        tok2 = _fake_github_token("U")
        # Leading '-', spaces, ':', ',', '%', newline, and non-ASCII UTF-8
        tricky = "-weird name:a,b%c\n::add-mask::evil.txt"
        utf8_name = "한글 폴더/파일.txt"
        self._commit(tricky, f"k = {tok1}\n", "tricky filename")
        head = self._commit(utf8_name, f"k = {tok2}\n", "utf8 filename")
        merge_sha = self._make_pr_merge(head)

        rc, out = self._run_on_blobless_clone(merge_sha, extra_env={"GITHUB_ACTIONS": "true"})
        self.assertEqual(rc, 1)
        self.assertIn(
            "::error file=-weird name%3Aa%2Cb%25c%0A%3A%3Aadd-mask%3A%3Aevil.txt,line=1::",
            out,
        )
        # Human-readable output must also escape '\n' so no raw workflow command
        # line starts with '::add-mask::'.
        for line in out.splitlines():
            self.assertFalse(line.startswith("::add-mask::"), f"raw command injected: {line!r}")
        self.assertIn("한글 폴더/파일.txt:1", out)
        self.assertNotIn(tok1, out)
        self.assertNotIn(tok2, out)

    def test_native_stack_pr_scans_only_own_layer_diff(self) -> None:
        # Lower layer adds a secret on base branch `stack/l1`; top layer `stack/l2`
        # branches off `stack/l1` and adds only a clean file. Merging `stack/l2`
        # into `stack/l1` checks `<merge>^1..merge`, so only L2's files are scanned.
        _git(self.work, "checkout", "-q", "-b", "stack/l1", "origin/main")
        self._commit("layer1.txt", f"l1 = {_fake_github_token('1')}\n", "layer 1")
        _git(self.work, "push", "-q", "origin", "stack/l1")

        _git(self.work, "checkout", "-q", "-b", "stack/l2", "origin/stack/l1")
        head_l2 = self._commit("layer2.txt", "clean layer 2\n", "layer 2")
        merge_sha = self._make_pr_merge(head_l2, base_ref="origin/stack/l1")

        rc, out = self._run_on_blobless_clone(merge_sha)
        self.assertEqual(rc, 0)
        self.assertIn("no unpinned credential shapes", out)

    def test_missing_allowlist_fails_closed(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "feat/rm-allowlist", "origin/main")
        _git(self.work, "rm", "-q", guard.ALLOWLIST_PATH)
        _git(self.work, "commit", "-q", "-m", "remove allowlist")
        head = _git(self.work, "rev-parse", "HEAD")
        merge_sha = self._make_pr_merge(head)

        with self.assertRaisesRegex(RuntimeError, "required file missing"):
            self._run_on_blobless_clone(merge_sha)

    def test_directory_replacing_allowlist_fails_closed(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "feat/dir-allowlist", "origin/main")
        _git(self.work, "rm", "-q", guard.ALLOWLIST_PATH)
        head = self._commit(f"{guard.ALLOWLIST_PATH}/nested.txt", "not a file\n", "replace with dir")
        merge_sha = self._make_pr_merge(head)

        with self.assertRaisesRegex(RuntimeError, "not a regular blob"):
            self._run_on_blobless_clone(merge_sha)

    def test_symlink_replacing_allowlist_fails_closed(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "feat/sym-allowlist", "origin/main")
        _git(self.work, "rm", "-q", guard.ALLOWLIST_PATH)
        link = self.work / guard.ALLOWLIST_PATH
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to("../../README.md")
        _git(self.work, "add", guard.ALLOWLIST_PATH)
        _git(self.work, "commit", "-q", "-m", "replace allowlist with symlink")
        head = _git(self.work, "rev-parse", "HEAD")
        merge_sha = self._make_pr_merge(head)

        with self.assertRaisesRegex(RuntimeError, "not a regular blob"):
            self._run_on_blobless_clone(merge_sha)

    def test_missing_scanner_fails_closed(self) -> None:
        _git(self.work, "checkout", "-q", "-b", "feat/missing-scanner", "origin/main")
        head = self._commit("docs/ok.md", "ok\n", "ok")
        merge_sha = self._make_pr_merge(head)

        missing = pathlib.Path(self.tmp.name) / "nonexistent-scanner.py"
        with self.assertRaisesRegex(RuntimeError, "scanner module not found"):
            self._run_on_blobless_clone(merge_sha, scanner_file=missing)


if __name__ == "__main__":
    unittest.main()

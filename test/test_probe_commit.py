#!/usr/bin/env python3
"""lib/build_commit/probe-commit.sh emits a source identity across working-tree shapes."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "lib/build_commit/probe-commit.sh"

DECLARATION_RE = re.compile(
    r'^let commit : string option = (?:Some "([0-9a-f]{40}|[0-9a-f]{64})"|None)\n'
    r'let commit_unix_ts : int64 option = (?:Some ([0-9]+)L|None)\n'
    r'let source_identity_declaration : string option = '
    r'(?:Some "MASC_SOURCE_IDENTITY=([0-9a-f]{40}|[0-9a-f]{64})/(clean|modified:(?:[0-9a-f]{40}|[0-9a-f]{64}));"|None)\n$'
)


def isolated_env(home_dir, extra=None):
    """Strip host Git and MASC_BUILD_* state, including user global gitignore."""
    env = {
        k: v for k, v in os.environ.items()
        if not k.startswith("GIT_") and not k.startswith("MASC_BUILD_")
    }
    env.update({
        "HOME": str(home_dir),
        "XDG_CONFIG_HOME": str(home_dir / ".config"),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
    })
    if extra:
        env.update(extra)
    return env


def git(repo, home_dir, *args, check=True):
    return subprocess.run(
        ["git", *args],
        cwd=repo,
        env=isolated_env(home_dir, {
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.com",
        }),
        capture_output=True,
        text=True,
        check=check,
    )


def init_repo(path, home_dir, object_format=None):
    init_args = ["init", "-q"]
    if object_format is not None:
        init_args.append(f"--object-format={object_format}")
    git(path, home_dir, *init_args)
    (path / "tracked.txt").write_text("initial\n")
    git(path, home_dir, "add", "tracked.txt")
    git(path, home_dir, "commit", "-q", "-m", "init")
    head = git(path, home_dir, "rev-parse", "HEAD").stdout.strip()
    ts = git(path, home_dir, "show", "-s", "--format=%ct", head).stdout.strip()
    return head, ts


def run_probe(cwd, home_dir, *args, extra_env=None, timeout=15):
    return subprocess.run(
        ["sh", str(SCRIPT), *args],
        cwd=cwd,
        env=isolated_env(home_dir, extra_env),
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def parse_ml(text):
    match = DECLARATION_RE.fullmatch(text)
    if match is None:
        raise AssertionError(f"unexpected build_commit_generated.ml output:\n{text!r}")
    return match.groups()


def parse_print_env(text):
    values = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if not sep:
            raise AssertionError(f"malformed --print-env line: {line!r}")
        values[key] = value
    return values


class ProbeCommit(unittest.TestCase):
    def setUp(self):
        self._home_tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._home_tmp.name).resolve()

    def tearDown(self):
        self._home_tmp.cleanup()

    def assert_identity(self, cwd, expected_commit, expected_ts, expected_state=None, extra_env=None):
        ml_res = run_probe(cwd, self.home, extra_env=extra_env)
        self.assertEqual(ml_res.returncode, 0, ml_res.stderr)
        commit, ts, decl_commit, state = parse_ml(ml_res.stdout)
        self.assertEqual(commit, expected_commit)
        self.assertEqual(ts, expected_ts)
        self.assertEqual(decl_commit, expected_commit)
        self.assertIsNotNone(state)

        env_res = run_probe(cwd, self.home, "--print-env", extra_env=extra_env)
        self.assertEqual(env_res.returncode, 0, env_res.stderr)
        env_map = parse_print_env(env_res.stdout)
        self.assertEqual(env_map["MASC_BUILD_COMMIT"], expected_commit)
        self.assertEqual(env_map["MASC_BUILD_COMMIT_UNIX_TS"], expected_ts)
        self.assertEqual(env_map["MASC_BUILD_SOURCE_STATE"], state)

        if expected_state is not None:
            self.assertEqual(state, expected_state)
        return state

    def assert_fails_closed(self, cwd, expected_commit, expected_ts, extra_env=None):
        ml_res = run_probe(cwd, self.home, extra_env=extra_env)
        self.assertEqual(ml_res.returncode, 0, ml_res.stderr)
        commit, got_ts, decl_commit, state = parse_ml(ml_res.stdout)
        self.assertEqual(commit, expected_commit)
        self.assertEqual(got_ts, expected_ts)
        self.assertIsNone(decl_commit)
        self.assertIsNone(state)

        env_res = run_probe(cwd, self.home, "--print-env", extra_env=extra_env)
        self.assertEqual(env_res.returncode, 2)

    def test_clean_checkout_subdirectory_and_ignores_stale_env(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary).resolve()
            head, ts = init_repo(repo, self.home)
            stale = {
                "MASC_BUILD_COMMIT": "f" * 40,
                "MASC_BUILD_COMMIT_UNIX_TS": "1",
                "MASC_BUILD_SOURCE_STATE": "modified:" + "e" * 40,
            }
            self.assert_identity(repo, head, ts, expected_state="clean", extra_env=stale)
            sub = repo / "a/b"
            sub.mkdir(parents=True)
            # Empty directories are ignored by git and keep the checkout clean.
            self.assert_identity(sub, head, ts, expected_state="clean", extra_env=stale)

    def test_tracked_edits_and_relative_tmpdir_leave_no_temp_dirs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repo = root / "repo"
            repo.mkdir()
            head, ts = init_repo(repo, self.home)
            sub = repo / "sub/build"
            sub.mkdir(parents=True)
            rel_tmp = sub / "reltmp"
            rel_tmp.mkdir()
            (repo / ".gitignore").write_text("sub/\n")
            git(repo, self.home, "add", ".gitignore")
            git(repo, self.home, "commit", "-q", "-m", "ignore sub")
            head = git(repo, self.home, "rev-parse", "HEAD").stdout.strip()
            ts = git(repo, self.home, "show", "-s", "--format=%ct", head).stdout.strip()

            (repo / "tracked.txt").write_text("first edit\n")
            first = self.assert_identity(sub, head, ts, extra_env={"TMPDIR": "reltmp"})
            self.assertTrue(first.startswith("modified:"), first)
            self.assertEqual(list(rel_tmp.iterdir()), [], "probe leaked temp directories")

            (repo / "tracked.txt").write_text("second edit\n")
            second = self.assert_identity(sub, head, ts, extra_env={"TMPDIR": "reltmp"})
            self.assertTrue(second.startswith("modified:"), second)
            self.assertNotEqual(first, second)
            self.assertEqual(list(rel_tmp.iterdir()), [], "probe leaked temp directories")

    def test_untracked_regular_files_with_special_names_and_no_object_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary).resolve()
            head, ts = init_repo(repo, self.home)
            objects_dir = repo / ".git/objects"
            objects_before = sorted(str(p.relative_to(objects_dir)) for p in objects_dir.rglob("*"))

            weird_names = ["space name.txt", "--leading-dash", "-n", "line\nbreak.txt"]
            for name in weird_names:
                (repo / name).write_text(f"payload:{name}\n")
            first = self.assert_identity(repo, head, ts)
            self.assertTrue(first.startswith("modified:"), first)

            # Probing must stay read-only and never write loose blobs into .git/objects.
            objects_after = sorted(str(p.relative_to(objects_dir)) for p in objects_dir.rglob("*"))
            self.assertEqual(objects_after, objects_before)

            (repo / "--leading-dash").write_text("changed\n")
            second = self.assert_identity(repo, head, ts)
            self.assertNotEqual(first, second)

            (repo / "space name.txt").rename(repo / "renamed name.txt")
            third = self.assert_identity(repo, head, ts)
            self.assertNotEqual(second, third)

    def test_untracked_directory_symlink_broken_symlink_and_newline_targets(self):
        # Regression: pnpm node_modules/.pnpm stores directory symlinks that
        # git ls-files --others lists; git hash-object previously aborted with
        # "fatal: Unable to hash <path>", leaving source_identity_declaration = None.
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary).resolve()
            head, ts = init_repo(repo, self.home)
            target_a = repo / "pkg_a"
            target_b = repo / "pkg_b"
            target_a.mkdir()
            target_b.mkdir()
            (target_a / "index.js").write_text("a\n")
            (target_b / "index.js").write_text("b\n")

            dir_link = repo / "node_modules/.pnpm/pkg"
            dir_link.parent.mkdir(parents=True)
            dir_link.symlink_to("../../pkg_a")
            broken_link = repo / "--broken-link"
            broken_link.symlink_to("/nonexistent/a\nb")

            first = self.assert_identity(repo, head, ts)
            self.assertTrue(first.startswith("modified:"), first)

            # Retargeting the directory symlink must change the digest.
            dir_link.unlink()
            dir_link.symlink_to("../../pkg_b")
            second = self.assert_identity(repo, head, ts)
            self.assertNotEqual(first, second)

            # Trailing newline in a symlink target must not be stripped away.
            broken_link.unlink()
            broken_link.symlink_to("/nonexistent/a\nb\n")
            third = self.assert_identity(repo, head, ts)
            self.assertNotEqual(second, third)

    def test_untracked_file_symlink_hashes_target_and_never_opens_fifo(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repo = root / "repo"
            repo.mkdir()
            head, ts = init_repo(repo, self.home)

            outside_file = root / "outside.txt"
            outside_file.write_text("v1\n")
            entry = repo / "entry"
            entry.symlink_to(outside_file)
            as_symlink = self.assert_identity(repo, head, ts)

            # A symlink's identity is its link target, not the outside file's bytes.
            outside_file.write_text("v2\n")
            self.assertEqual(self.assert_identity(repo, head, ts), as_symlink)

            # Replacing the symlink with a regular file holding the target path
            # text must not collide with the symlink identity.
            entry.unlink()
            entry.write_text(str(outside_file) + "\n")
            as_regular = self.assert_identity(repo, head, ts)
            self.assertNotEqual(as_regular, as_symlink)

            # Neither a symlink to a FIFO nor a direct untracked FIFO may block.
            fifo = root / "pipe"
            os.mkfifo(fifo)
            entry.unlink()
            entry.symlink_to(fifo)
            as_fifo_link = self.assert_identity(repo, head, ts)
            self.assertTrue(as_fifo_link.startswith("modified:"), as_fifo_link)

            os.mkfifo(repo / "direct-fifo")
            self.assertEqual(self.assert_identity(repo, head, ts), as_fifo_link)

    def test_untracked_nested_git_repositories_and_symlink_to_nested_repo(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary).resolve()
            head, ts = init_repo(repo, self.home)

            # 1. Committed nested git repo.
            nested = repo / "nested"
            nested.mkdir()
            init_repo(nested, self.home)
            s1 = self.assert_identity(repo, head, ts)
            self.assertTrue(s1.startswith("modified:"), s1)

            # Tracked edit inside nested repo changes the outer digest.
            (nested / "tracked.txt").write_text("nested edit\n")
            s2 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(s1, s2)

            # Untracked file creation AND subsequent content edit inside nested
            # repo both change the outer digest.
            (nested / "extra.txt").write_text("v1\n")
            s3 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(s2, s3)
            (nested / "extra.txt").write_text("v2\n")
            s4 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(s3, s4)

            # Untracked directory symlink inside nested repo works and retargeting changes digest.
            nested_link = nested / "dir_link"
            nested_link.symlink_to("/nonexistent/one")
            s5 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(s4, s5)
            nested_link.unlink()
            nested_link.symlink_to("/nonexistent/two")
            s6 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(s5, s6)

            # Symlink pointing to the nested git repo is hashed as a symlink.
            (repo / "link_to_nested").symlink_to("nested")
            s7 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(s6, s7)

            # Outer GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR must not contaminate nested probing.
            outer_env = {
                "GIT_DIR": str(repo / ".git"),
                "GIT_WORK_TREE": str(repo),
                "GIT_COMMON_DIR": str(repo / ".git"),
            }
            self.assertEqual(self.assert_identity(repo, head, ts, extra_env=outer_env), s7)

            # 2. Unborn nested git repo: staged and untracked content edits both matter.
            unborn = repo / "unborn"
            unborn.mkdir()
            git(unborn, self.home, "init", "-q")
            s8 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(s7, s8)

            (unborn / "staged.txt").write_text("staged v1\n")
            git(unborn, self.home, "add", "staged.txt")
            s9 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(s8, s9)

            (unborn / "staged.txt").write_text("staged v2\n")
            s10 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(s9, s10)

            (unborn / "draft.txt").write_text("draft v1\n")
            s11 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(s10, s11)
            (unborn / "draft.txt").write_text("draft v2\n")
            s12 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(s11, s12)

            # 3. A sibling file beside a broken .git file is still seen as untracked.
            broken = repo / "broken_gitdir"
            broken.mkdir()
            (broken / ".git").write_text("gitdir: /nonexistent/gitdir\n")
            (broken / "sibling.txt").write_text("a\n")
            s13 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(s12, s13)
            (broken / "sibling.txt").write_text("b\n")
            s14 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(s13, s14)

    def test_uninspectable_nested_git_repo_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary).resolve()
            head, ts = init_repo(repo, self.home)
            nested = repo / "bare_nested"
            nested.mkdir()
            init_repo(nested, self.home)
            # Setting core.bare=true on a nested .git leaves ls-files listing
            # bare_nested/ while rev-parse --show-toplevel refuses it.
            git(nested, self.home, "config", "core.bare", "true")
            self.assert_fails_closed(repo, head, ts)

    def test_unreadable_untracked_file_fails_closed(self):
        if os.geteuid() == 0:
            self.skipTest("root bypasses chmod 000 read refusal")
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary).resolve()
            head, ts = init_repo(repo, self.home)
            secret = repo / "unreadable.txt"
            secret.write_text("secret\n")
            secret.chmod(0o000)
            try:
                self.assert_fails_closed(repo, head, ts)
            finally:
                secret.chmod(0o600)

    def test_outside_git_env_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            outside = Path(temporary).resolve()
            ceiling = {"GIT_CEILING_DIRECTORIES": str(outside.parent)}
            commit = "a" * 40
            digest = "b" * 40

            # Commit without state yields no identity (an unknown state is not clean).
            ml_missing = run_probe(outside, self.home, extra_env={**ceiling, "MASC_BUILD_COMMIT": commit})
            self.assertEqual(ml_missing.returncode, 0)
            got_commit, _, decl_commit, state = parse_ml(ml_missing.stdout)
            self.assertEqual(got_commit, commit)
            self.assertIsNone(decl_commit)
            self.assertIsNone(state)
            self.assertEqual(
                run_probe(outside, self.home, "--print-env", extra_env={**ceiling, "MASC_BUILD_COMMIT": commit}).returncode,
                2,
            )

            # Complete env fallback succeeds.
            env = {
                "MASC_BUILD_COMMIT": commit,
                "MASC_BUILD_COMMIT_UNIX_TS": "1700000000",
                "MASC_BUILD_SOURCE_STATE": f"modified:{digest}",
            }
            ml_ok = run_probe(outside, self.home, extra_env={**ceiling, **env})
            self.assertEqual(ml_ok.returncode, 0)
            self.assertEqual(parse_ml(ml_ok.stdout), (commit, "1700000000", commit, f"modified:{digest}"))
            env_ok = run_probe(outside, self.home, "--print-env", extra_env={**ceiling, **env})
            self.assertEqual(env_ok.returncode, 0)
            self.assertEqual(parse_print_env(env_ok.stdout), env)

    def test_sha256_repository(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary).resolve()
            probe_sha256 = git(repo, self.home, "init", "-q", "--object-format=sha256", check=False)
            if probe_sha256.returncode != 0:
                self.skipTest("git does not support --object-format=sha256")
            (repo / "tracked.txt").write_text("sha256\n")
            git(repo, self.home, "add", "tracked.txt")
            git(repo, self.home, "commit", "-q", "-m", "init")
            head = git(repo, self.home, "rev-parse", "HEAD").stdout.strip()
            ts = git(repo, self.home, "show", "-s", "--format=%ct", head).stdout.strip()
            self.assertEqual(len(head), 64)
            self.assert_identity(repo, head, ts, expected_state="clean")

            (repo / "link").symlink_to("/nonexistent")
            state = self.assert_identity(repo, head, ts)
            self.assertTrue(state.startswith("modified:") and len(state) == len("modified:") + 64, state)

            unborn = repo / "unborn_sha256"
            unborn.mkdir()
            git(unborn, self.home, "init", "-q", "--object-format=sha256")
            (unborn / "file.txt").write_text("hello\n")
            s2 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(state, s2)
            (unborn / "file.txt").write_text("world\n")
            s3 = self.assert_identity(repo, head, ts)
            self.assertNotEqual(s2, s3)


if __name__ == "__main__":
    unittest.main()

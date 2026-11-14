"""Remote_ssh Keeper workspace cleanup keeps every commit and stash.

RFC-remote-keeper-workspace-entries-are-swept-on-their-endpoint section 4.
Run: python3 test/test_keeper_remote_workspace_cleanup.py -v
"""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

PAYLOAD = (
    Path(__file__).resolve().parents[1] / "config/scripts/keeper-remote-workspace-cleanup.py"
)
SPEC = importlib.util.spec_from_file_location("keeper_remote_workspace_cleanup", PAYLOAD)
assert SPEC is not None and SPEC.loader is not None
cleaner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cleaner)

RETENTION_SEC = 48 * 3600
# Every fixture file is younger than the retention unless the sweep looks
# from this far ahead.
LATER = 3 * 24 * 3600


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-c", "user.email=keeper@example.invalid", "-c", "user.name=keeper", *args],
        cwd=cwd,
        text=True,
        capture_output=True,
        check=True,
    ).stdout


class RemoteWorkspaceCleanup(unittest.TestCase):
    def setUp(self) -> None:
        # The fixtures and the payload's git must not read the runner's global
        # hooks, signing or credential settings.
        isolated = patch.dict(
            os.environ,
            {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"},
        )
        isolated.start()
        self.addCleanup(isolated.stop)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        self.root = base / "keeper"
        self.root.mkdir(mode=0o700)
        self.root.chmod(0o700)
        self.proc = base / "proc"
        self.proc.mkdir()
        self.origin = base / "origin.git"
        git(base, "init", "-q", "--bare", "-b", "main", str(self.origin))
        seed = base / "seed"
        git(base, "clone", "-q", str(self.origin), str(seed))
        (seed / "README").write_text("seed\n")
        git(seed, "add", "README")
        git(seed, "commit", "-q", "-m", "seed")
        git(seed, "push", "-q", "origin", "HEAD:main")
        (seed / "README").write_text("pull request\n")
        git(seed, "commit", "-q", "-am", "pull request head")
        git(seed, "push", "-q", "origin", "HEAD:refs/pull/1/head")

    def clone(self, name: str) -> Path:
        path = self.root / name
        git(self.root, "clone", "-q", str(self.origin), str(path))
        return path

    def sweep(self, apply: bool = True, *, later: bool = True) -> dict[str, dict]:
        now = time.time() + (LATER if later else 0)
        report = cleaner.sweep(self.root, RETENTION_SEC, apply, proc=self.proc, now=now)
        self.report = report
        return {entry["name"]: entry for entry in report["entries"]}

    def assert_removed(self, entries: dict[str, dict], name: str) -> None:
        self.assertEqual(entries[name]["result"], "removed", entries[name])
        self.assertFalse((self.root / name).exists())

    def assert_kept(self, entries: dict[str, dict], name: str, reason: str) -> None:
        self.assertEqual(entries[name]["result"], "skipped", entries[name])
        self.assertIn(reason, entries[name]["reason"])
        self.assertTrue((self.root / name).exists() or (self.root / name).is_symlink())

    def test_old_entries_without_lost_commits_are_removed(self) -> None:
        self.clone("clean")
        dirty = self.clone("dirty")
        (dirty / "README").write_text("uncommitted\n")
        (dirty / "notes.md").write_text("review memo\n")
        pull = self.clone("pull")
        git(pull, "fetch", "-q", "origin", "refs/pull/1/head")
        git(pull, "checkout", "-q", "--detach", "FETCH_HEAD")
        (self.root / "plain").mkdir()
        (self.root / "plain" / "diff.txt").write_text("diff\n")
        (self.root / "49051-review.md").write_text("verdict\n")
        entries = self.sweep()
        for name in ("clean", "dirty", "pull", "plain", "49051-review.md"):
            self.assert_removed(entries, name)
        self.assertIn("free_kib_after", self.report)

    def young(self, path: Path) -> None:
        """Make [path] newer than the retention as the sweep sees it."""
        later = time.time() + LATER
        os.utime(path, (later, later))

    def old_tree(self, path: Path) -> Path:
        (path / "src").mkdir(parents=True)
        (path / "src" / "copy.ml").write_text("let x = 1\n")
        return path

    def test_old_folder_inside_a_young_folder_is_removed(self) -> None:
        memory = self.root / "memory"
        self.old_tree(memory / "t05" / "q114")
        self.old_tree(memory / "notes" / "r48110")
        (memory / "notes" / "verdict.md").write_text("fresh note\n")
        self.young(memory / "notes" / "verdict.md")
        (memory / "old-note.md").write_text("old note\n")
        entries = self.sweep()
        self.assert_kept(entries, "memory", "touched within retention")
        self.assert_removed(entries, "memory/t05")
        self.assert_removed(entries, "memory/notes/r48110")
        # A young directory on the way down gets no record; files inside a
        # container stay even when old.
        self.assertNotIn("memory/notes", entries)
        self.assertTrue((memory / "notes" / "verdict.md").is_file())
        self.assertTrue((memory / "old-note.md").is_file())

    def test_a_unit_is_never_entered(self) -> None:
        clone = self.clone("clone")
        self.old_tree(clone / "docs")
        self.young(clone / "README")
        project = self.root / "project"
        self.old_tree(project / "test")
        (project / "dune-project").write_text("(lang dune 3.0)\n")
        self.young(project / "dune-project")
        container = self.root / "memory"
        mirror = container / "mirror.git"
        git(self.root, "init", "-q", "--bare", str(mirror))
        self.old_tree(mirror / "objects" / "old-pack")
        self.young(mirror / "HEAD")
        entries = self.sweep()
        self.assert_kept(entries, "clone", "touched within retention")
        self.assert_kept(entries, "project", "touched within retention")
        self.assertTrue((clone / "docs").is_dir())
        self.assertTrue((project / "test").is_dir())
        self.assertTrue((mirror / "objects" / "old-pack").is_dir())
        self.assertEqual(
            sorted(name for name in entries if "/" in name), [], self.report["entries"]
        )

    def test_old_unit_inside_a_young_folder_goes_whole(self) -> None:
        container = self.root / "work"
        project = self.old_tree(container / "q114")
        (project / "dune-project").write_text("(lang dune 3.0)\n")
        clean = container / "clean"
        git(self.root, "clone", "-q", str(self.origin), str(clean))
        (container / "fresh.md").write_text("note\n")
        self.young(container / "fresh.md")
        entries = self.sweep()
        self.assert_removed(entries, "work/q114")
        self.assert_removed(entries, "work/clean")

    def test_old_folder_inside_keeps_the_same_protections(self) -> None:
        container = self.root / "work"
        local = container / "local"
        git(self.root, "clone", "-q", str(self.origin), str(local))
        (local / "change").write_text("local\n")
        git(local, "add", "change")
        git(local, "commit", "-q", "-m", "local only")
        busy = self.old_tree(container / "busy")
        process = self.proc / "4242"
        (process / "fd").mkdir(parents=True)
        (process / "cwd").symlink_to(busy)
        (process / "exe").symlink_to("/usr/bin/true")
        self.old_tree(container / ".cache")
        (container / "link").symlink_to(self.old_tree(self.root.parent / "outside"))
        (container / "fresh.md").write_text("note\n")
        self.young(container / "fresh.md")
        entries = self.sweep()
        self.assert_kept(entries, "work/local", "only in local")
        self.assert_kept(entries, "work/busy", "live process uses it")
        self.assertNotIn("work/.cache", entries)
        self.assertNotIn("work/link", entries)
        self.assertTrue((container / ".cache").is_dir())
        self.assertTrue((self.root.parent / "outside" / "src").is_dir())

    def test_report_mode_removes_nothing_inside_either(self) -> None:
        container = self.root / "work"
        self.old_tree(container / "copy")
        (container / "fresh.md").write_text("note\n")
        self.young(container / "fresh.md")
        entries = self.sweep(apply=False)
        self.assertEqual(entries["work/copy"]["result"], "would remove")
        self.assertTrue((container / "copy").is_dir())

    def test_report_mode_removes_nothing(self) -> None:
        self.clone("clean")
        entries = self.sweep(apply=False)
        self.assertEqual(entries["clean"]["result"], "would remove")
        self.assertTrue((self.root / "clean").is_dir())

    def test_old_clone_with_internal_linked_worktree_is_removed(self) -> None:
        main = self.clone("with-worktree")
        linked = main / "linked"
        git(main, "worktree", "add", "-q", "--detach", str(linked))
        with (main / ".git/info/exclude").open("a") as exclude:
            exclude.write("\n/linked/\n")
        for repo in (main, linked):
            self.assertEqual(git(repo, "status", "--porcelain"), "")
            self.assertIsNone(cleaner.unpushed_tip(repo))

        # Administrative files still contribute to retention, even though
        # they must not be treated as independent repository candidates.
        administrative = Path(git(linked, "rev-parse", "--absolute-git-dir").strip())
        head = administrative / "HEAD"
        touched = time.time() + LATER
        os.utime(head, (touched, touched))
        self.assert_kept(self.sweep(), "with-worktree", "touched within retention")
        os.utime(head, (0, 0))

        entries = self.sweep()
        self.assert_removed(entries, "with-worktree")
        self.assertFalse(linked.exists())

    def test_old_clone_with_fully_pushed_submodule_is_removed(self) -> None:
        main = self.clone("with-submodule")
        git(main, "-c", "protocol.file.allow=always", "submodule", "add", "-q",
            str(self.origin), "sub")
        git(main, "commit", "-q", "-am", "add submodule")
        git(main, "push", "-q", "origin", "HEAD:main")
        for repo in (main, main / "sub"):
            self.assertEqual(git(repo, "status", "--porcelain"), "")
            self.assertIsNone(cleaner.unpushed_tip(repo))
        self.assert_removed(self.sweep(), "with-submodule")

    def test_deinitialized_submodule_with_local_commit_is_kept(self) -> None:
        main = self.clone("with-deinitialized-submodule")
        git(main, "-c", "protocol.file.allow=always", "submodule", "add", "-q",
            str(self.origin), "sub")
        git(main, "commit", "-q", "-am", "add submodule")
        git(main, "push", "-q", "origin", "HEAD:main")
        sub = main / "sub"
        (sub / "README").write_text("local submodule commit\n")
        git(sub, "commit", "-q", "-am", "local only")
        commit = git(sub, "rev-parse", "HEAD").strip()
        git(main, "submodule", "deinit", "-q", "-f", "sub")
        administrative = main / ".git/modules/sub"
        self.assertIsNone(cleaner.unpushed_tip(main))
        self.assertEqual(cleaner.unpushed_tip(administrative), commit)
        self.assert_kept(self.sweep(), "with-deinitialized-submodule", "Git directory")
        self.assertEqual(git(administrative, "rev-parse", "HEAD").strip(), commit)

    def test_missing_linked_worktree_with_local_commit_is_kept(self) -> None:
        main = self.clone("with-missing-worktree")
        linked = main / "linked"
        git(main, "worktree", "add", "-q", "--detach", str(linked))
        (linked / "README").write_text("local detached worktree commit\n")
        git(linked, "commit", "-q", "-am", "local only")
        commit = git(linked, "rev-parse", "HEAD").strip()
        administrative = Path(git(linked, "rev-parse", "--absolute-git-dir").strip())
        shutil.rmtree(linked)
        self.assertIsNone(cleaner.unpushed_tip(main))
        self.assertEqual(cleaner.unpushed_tip(administrative), commit)
        self.assert_kept(self.sweep(), "with-missing-worktree", "Git directory")
        self.assertEqual(git(administrative, "rev-parse", "HEAD").strip(), commit)

    def test_recently_touched_entry_is_kept(self) -> None:
        self.clone("fresh")
        self.assert_kept(self.sweep(later=False), "fresh", "touched within retention")

    def test_local_commit_is_kept_even_when_nested(self) -> None:
        local = self.clone("local")
        (local / "README").write_text("local only\n")
        git(local, "commit", "-q", "-am", "local only")
        (self.root / "box").mkdir()
        nested = self.root / "box" / "inner"
        git(self.root, "clone", "-q", str(self.origin), str(nested))
        git(nested, "checkout", "-q", "-b", "topic")
        (nested / "README").write_text("nested local\n")
        git(nested, "commit", "-q", "-am", "nested local")
        entries = self.sweep()
        self.assert_kept(entries, "local", "only in local")
        self.assert_kept(entries, "box", "only in box/inner")

    def test_detached_commit_no_remote_advertises_is_kept(self) -> None:
        detached = self.clone("detached")
        git(detached, "checkout", "-q", "--detach")
        (detached / "README").write_text("detached\n")
        git(detached, "commit", "-q", "-am", "detached only")
        self.assert_kept(self.sweep(), "detached", "only in detached")

    def test_bare_repositories_with_local_commits_are_kept(self) -> None:
        (self.root / "box").mkdir()
        for relative in ("local.git", "box/nested.git"):
            bare = self.root / relative
            git(self.root, "clone", "-q", "--bare", str(self.origin), str(bare))
            commit = git(bare, "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "local only").strip()
            git(bare, "update-ref", "refs/heads/main", commit)
            self.assertEqual(cleaner.unpushed_tip(bare), commit)
        entries = self.sweep()
        self.assert_kept(entries, "local.git", "Git directory")
        self.assert_kept(entries, "box", "Git directory")

    def test_separate_git_directory_keeps_its_external_worktree(self) -> None:
        administrative = self.root / "administrative"
        worktree = self.root.parent / "outside-worktree"
        git(self.root, "clone", "-q", "--separate-git-dir", str(administrative),
            str(self.origin), str(worktree))
        entries = self.sweep()
        self.assert_kept(entries, "administrative", "Git directory")
        self.assertEqual(git(worktree, "rev-parse", "HEAD").strip(),
                         git(self.origin, "rev-parse", "HEAD").strip())

    def test_unreadable_origin_keeps_an_unpushed_tip(self) -> None:
        orphan = self.clone("orphan")
        (orphan / "README").write_text("local only\n")
        git(orphan, "commit", "-q", "-am", "local only")
        git(orphan, "remote", "set-url", "origin", str(self.root / "missing.git"))
        self.assert_kept(self.sweep(), "orphan", "ls-remote")

    def test_stash_is_kept(self) -> None:
        stashed = self.clone("stashed")
        (stashed / "README").write_text("stashed\n")
        git(stashed, "stash", "-q")
        self.assert_kept(self.sweep(), "stashed", "stash in stashed")

    def test_dot_entries_and_symlinks_are_kept(self) -> None:
        gh = self.root / ".config" / "gh"
        gh.mkdir(parents=True)
        (gh / "hosts.yml").write_text("token: kept\n")
        outside = self.root.parent / "outside"
        outside.mkdir()
        (outside / "data").write_text("kept\n")
        (self.root / "link").symlink_to(outside)
        entries = self.sweep()
        self.assert_kept(entries, ".config", "dot entry")
        self.assert_kept(entries, "link", "symlink")
        self.assertTrue((outside / "data").is_file())

    def test_main_repository_with_an_outside_worktree_is_kept(self) -> None:
        main = self.clone("a-main")
        git(main, "worktree", "add", "-q", "--detach", str(self.root / "b-linked"))
        entries = self.sweep()
        self.assert_kept(entries, "a-main", "lives outside")
        self.assert_removed(entries, "b-linked")

    def test_live_process_inside_an_entry_keeps_it(self) -> None:
        busy = self.clone("busy")
        process = self.proc / "4242"
        (process / "fd").mkdir(parents=True)
        (process / "cwd").symlink_to(busy)
        (process / "exe").symlink_to("/usr/bin/true")
        self.assert_kept(self.sweep(), "busy", "live process uses it")

    def test_missing_proc_removes_nothing(self) -> None:
        self.clone("clean")
        self.proc.rmdir()
        self.sweep()
        self.assertEqual(self.report["skip"], "/proc unavailable")
        self.assertTrue((self.root / "clean").is_dir())

    def unreadable_process(self, owner: int, session: int, leader: int | None):
        """Patches under which process 4242 of user [owner] refuses its links,
        as the kernel does for a process that turned inspection off or belongs
        to another user. It is in [session]; [leader] is the user of the
        process that leads that session, None when no such process is left."""
        process = self.proc / "4242"
        (process / "fd").mkdir(parents=True, exist_ok=True)
        # The command name is written to read as a session of PID 1.
        (process / "stat").write_text(f"4242 (x) S 1 1 1 (y) S 4000 4242 {session} 0 -1\n")
        owners = {process: owner}
        leader_entry = self.proc / str(session)
        if leader is None:
            shutil.rmtree(leader_entry, ignore_errors=True)
        else:
            leader_entry.mkdir(exist_ok=True)
            owners[leader_entry] = leader
        readlink, stat_of = os.readlink, Path.stat

        def denied(path, *args, **kwargs):
            if Path(path).parent == process:
                raise PermissionError(13, "Permission denied", str(path))
            return readlink(path, *args, **kwargs)

        def owned(path, *args, **kwargs):
            if path in owners:
                return SimpleNamespace(st_uid=owners[path])
            return stat_of(path, *args, **kwargs)

        return (
            patch.object(cleaner.os, "readlink", side_effect=denied),
            patch.object(Path, "stat", owned),
        )

    def test_unreadable_process_is_passed_over_only_when_it_cannot_be_inside(self) -> None:
        me = os.getuid()
        other = me + 1
        root_user = 0
        sshd_session, command_session = 4000, 4242
        # (root mode, process owner, its session, that session's leader, removed?)
        cases = [
            (0o700, other, command_session, other, True),  # another user cannot enter a private root
            (0o755, other, command_session, other, False),  # a shared root lets it in
            (0o700, me, sshd_session, root_user, True),  # the sshd side that dropped to our user
            # A command of ours that turned inspection off (ssh-agent): its
            # session was opened by our own user.
            (0o700, me, command_session, me, False),
            (0o700, me, sshd_session, me, False),  # the same, started by another command of ours
            (0o700, me, sshd_session, None, False),  # the leader exited
            (0o700, me, 0, None, False),  # the leader is in another PID namespace
            (0o755, me, command_session, me, False),  # the root's mode is not why
        ]
        for mode, owner, session, leader, removed in cases:
            with self.subTest(mode=oct(mode), owner=owner, session=session, leader=leader):
                self.clone("clean")
                self.root.chmod(mode)
                links, owners = self.unreadable_process(owner, session, leader)
                with links, owners:
                    entries = self.sweep()
                if removed:
                    self.assert_removed(entries, "clean")
                else:
                    skip = self.report["skip"]
                    self.assertIn("process 4242", skip)
                    # Only a root that let another user in names the fix.
                    shared = owner != me
                    self.assertEqual("mode 0755" in skip, shared)
                    self.assertEqual("chmod go-rwx" in skip, shared)
                    shutil.rmtree(self.root / "clean")

    def test_process_that_exits_while_it_is_read_is_passed_over(self) -> None:
        me = os.getuid()
        self.clone("clean")
        process = self.proc / "4242"
        read_text = Path.read_text

        def reaped(path, *args, **kwargs):
            if path == process / "stat":
                raise ProcessLookupError(3, "No such process", str(path))
            return read_text(path, *args, **kwargs)

        links, owners = self.unreadable_process(me, 4242, me)
        with links, owners, patch.object(Path, "read_text", reaped):
            self.assert_removed(self.sweep(), "clean")

    def test_unreadable_process_whose_session_leader_is_gone_is_passed_over_once_it_exits(
        self,
    ) -> None:
        me = os.getuid()
        self.clone("clean")
        process = self.proc / "4242"
        links, owners = self.unreadable_process(me, 4000, None)
        stat_of = Path.stat
        seen: list[Path] = []

        def gone_on_second_look(path, *args, **kwargs):
            if path == process:
                seen.append(path)
                if len(seen) > 1:
                    raise FileNotFoundError(2, "No such file or directory", str(path))
            return stat_of(path, *args, **kwargs)

        with links, patch.object(Path, "stat", gone_on_second_look):
            self.assert_removed(self.sweep(), "clean")


if __name__ == "__main__":
    unittest.main()

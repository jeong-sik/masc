#!/usr/bin/env python3
"""nofile-status reads the process table; these cases hand it one."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/nofile-status.sh"

# The process table comes from the file FAKE_PS_ROWS names. `ps -p` is the
# script's probe for a working ps, and its lookup of one fd holder.
FAKE_PS = """#!/bin/sh
case "$1" in
  ax) cat "$FAKE_PS_ROWS" ;;
  *) exit 0 ;;
esac
"""

# An lsof that holds nothing and silent limit readers: the fd census and the
# host limits are not what these cases read.
FAKE_LSOF = "#!/bin/sh\necho 'COMMAND PID USER'\n"
SILENT = "#!/bin/sh\n"

SECTIONS = (
    "dune/local-build processes",
    "orphaned dune-local lock waiters",
    "repo-wide scan processes",
    "potential bare dune bypasses",
)


class NofileStatus(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, body in (("ps", FAKE_PS), ("lsof", FAKE_LSOF), ("launchctl", SILENT), ("sysctl", SILENT)):
            tool = self.bin / name
            tool.write_text(body)
            tool.chmod(0o755)
        self.home = "/home/tester"

    # Run the script over [rows], each "pid ppid command". Returns the rows it
    # printed under each section heading.
    def status(self, rows, *args, home=None):
        table = self.root / "ps-rows"
        table.write_text("".join(f"{pid} {ppid} S 00:10 {command}\n" for pid, ppid, command in rows))
        env = {key: value for key, value in os.environ.items() if not key.startswith("MASC_")}
        env["PATH"] = f"{self.bin}{os.pathsep}{env['PATH']}"
        env["HOME"] = self.home if home is None else home
        env["FAKE_PS_ROWS"] = str(table)
        result = subprocess.run(
            ["bash", str(SCRIPT), *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        sections = {name: [] for name in SECTIONS}
        current = None
        # A heading ends with a colon; a process row starts with its pid.
        for line in result.stdout.splitlines():
            if line.endswith(":"):
                current = line[:-1] if line[:-1] in sections else None
            elif current is not None and line[:1].isdigit():
                sections[current].append(line)
        return sections

    def pids(self, rows):
        return [int(row.split()[0]) for row in rows]


class RepoWideScans(NofileStatus):
    SECTION = "repo-wide scan processes"

    def scans(self, rows, **kwargs):
        return self.pids(self.status(rows, **kwargs)[self.SECTION])

    def test_a_find_over_the_callers_home_is_a_scan(self):
        rows = [
            (101, 1, "find /home/tester -name x"),
            (102, 1, "find /home/tester/src -type f"),
            (103, 1, "bfs /home/tester"),
        ]
        self.assertEqual(self.scans(rows), [101, 102, 103])

    def test_the_home_is_the_callers_not_a_fixed_one(self):
        rows = [(101, 1, "find /home/tester -name x"), (102, 1, "find /srv/elsewhere -name x")]
        self.assertEqual(self.scans(rows, home="/srv/elsewhere"), [102])

    def test_a_path_that_only_starts_like_the_home_is_not_under_it(self):
        self.assertEqual(self.scans([(101, 1, "find /home/tester2/src -name x")]), [])

    # A copy of the home under another root is not the home.
    def test_a_path_that_only_ends_like_the_home_is_not_under_it(self):
        rows = [
            (101, 1, "find /mnt/backup/home/tester/photos -type f"),
            (102, 1, "find /Volumes/disk/home/tester -name x"),
        ]
        self.assertEqual(self.scans(rows), [])

    def test_the_home_after_a_quote_an_equals_sign_or_a_colon_is_a_scan(self):
        rows = [
            (101, 1, "sh -c find '/home/tester' -name x"),
            (102, 1, 'sh -c find "/home/tester/src" -name x'),
            (103, 1, "find --root=/home/tester -name x"),
            (104, 1, "find -path /srv/a:/home/tester/b"),
        ]
        self.assertEqual(self.scans(rows), [101, 102, 103, 104])

    def test_a_later_mention_of_the_home_counts_after_an_earlier_false_one(self):
        rows = [(101, 1, "find /mnt/backup/home/tester /home/tester/src -name x")]
        self.assertEqual(self.scans(rows), [101])

    def test_a_find_elsewhere_is_not_a_scan(self):
        rows = [(101, 1, "find /var/log -name x"), (102, 1, "ls -R /home/tester")]
        self.assertEqual(self.scans(rows), [])

    def test_a_masc_path_and_a_tilde_path_are_scans(self):
        rows = [(101, 1, "find /srv/masc/.masc -name x"), (102, 1, "find ~/src -name x"), (103, 1, "find ~")]
        self.assertEqual(self.scans(rows), [101, 102, 103])

    def test_an_unset_home_names_no_path(self):
        rows = [(101, 1, "find /var/log -name x"), (102, 1, "find / -name x")]
        self.assertEqual(self.scans(rows, home=""), [])
        self.assertEqual(self.scans(rows, home="/"), [])

    def test_kill_repo_scans_ends_the_scans_and_nothing_else(self):
        scan = subprocess.Popen(["sleep", "60"])
        other = subprocess.Popen(["sleep", "60"])
        def end(process):
            if process.poll() is None:
                process.kill()
            process.wait()

        self.addCleanup(end, scan)
        self.addCleanup(end, other)
        rows = [(scan.pid, 1, "find /home/tester -name x"), (other.pid, 1, "find /var/log -name x")]
        self.assertEqual(self.scans(rows), [scan.pid])
        self.assertIsNone(scan.poll())
        self.status(rows, "--kill-repo-scans")
        self.assertIsNotNone(scan.wait(timeout=10))
        self.assertIsNone(other.poll())


class DuneLocks(NofileStatus):
    WAITER = "lockf -k /tmp/locks/build.lock /usr/bin/env MASC_DUNE_LOCK_HELD=1 /repo/scripts/dune-local.sh build"

    def test_a_lock_waiter_without_a_parent_is_orphaned(self):
        rows = [(201, 1, self.WAITER), (202, 300, self.WAITER), (203, 1, "lockf -k /tmp/locks/other.lock make")]
        sections = self.status(rows)
        self.assertEqual(self.pids(sections["orphaned dune-local lock waiters"]), [201])

    def test_the_lock_file_name_does_not_decide(self):
        renamed = self.WAITER.replace("/tmp/locks/build.lock", "/elsewhere/any-name")
        sections = self.status([(201, 1, renamed)])
        self.assertEqual(self.pids(sections["orphaned dune-local lock waiters"]), [201])

    def test_dune_outside_a_wrapper_is_a_bypass(self):
        rows = [(300, 1, "zsh"), (301, 300, "dune build --root /repo")]
        self.assertEqual(self.pids(self.status(rows)["potential bare dune bypasses"]), [301])

    def test_dune_under_the_wrapper_is_not_a_bypass(self):
        rows = [
            (310, 1, "/repo/scripts/dune-local.sh build"),
            (311, 310, "dune build --root /repo"),
            (320, 1, "/usr/bin/env MASC_DUNE_LOCK_HELD=1 bash"),
            (321, 320, "dune build --root /repo"),
        ]
        self.assertEqual(self.status(rows)["potential bare dune bypasses"], [])

    def test_dune_under_any_file_lock_is_not_a_bypass(self):
        rows = [
            (330, 1, "lockf /tmp/another-repo.lock dune build --root /other"),
            (331, 330, "dune build --root /other"),
            (340, 1, "flock /tmp/another-repo.lock dune build --root /other"),
            (341, 340, "dune build --root /other"),
        ]
        self.assertEqual(self.status(rows)["potential bare dune bypasses"], [])

    def test_a_lock_path_in_an_argument_is_not_a_lock_holder(self):
        rows = [(350, 1, "vim /tmp/notes-about-flock.txt"), (351, 350, "dune build --root /repo")]
        self.assertEqual(self.pids(self.status(rows)["potential bare dune bypasses"]), [351])


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""ci-checks.sh against a fake `gh` that pages like GitHub: --paginate runs --jq
once per page. A single-commit endpoint of a large commit (the 183-file backport
159809c803cb) has two pages, so a paginated `.sha` printed two lines and the
40-hex check failed without a message. Offline; no network, no real PR."""
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
TIP = "159809c803cb605b2c2b3cc500edf10e9968bcb3"
HEAD = "814bd3eae8541a2965c5e1339b81a001371343a4"

# api [--paginate] <path> --jq <expr>; paths in $FAKE_DIR/pages=N make --paginate
# repeat the jq output once per page, as gh does for a multi-page response.
FAKE_GH = r"""#!/usr/bin/env bash
shift
paginate=0
[ "$1" != --paginate ] || { paginate=1; shift; }
path="$1"; shift
expr="."
[ "$1" != --jq ] || expr="$2"
printf '%s paginate=%s\n' "$path" "$paginate" >> "$FAKE_DIR/calls.log"
case "$path" in
  repos/o/r/commits/main) f="$FAKE_DIR/commit.json"; pages=2;;
  repos/o/r/compare/*) f="$FAKE_DIR/compare.json"; pages=2;;
  repos/o/r/commits/*/status) f="$FAKE_DIR/status.json"; pages=2;;
  *) echo "fake gh: unexpected $path" >&2; exit 9;;
esac
[ "$paginate" = 1 ] || pages=1
for _ in $(seq "$pages"); do jq -r "$expr" "$f"; done
"""


class CiChecksPagination(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="ci-checks-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        gh = self.tmp / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
        (self.tmp / "commit.json").write_text(f'{{"sha": "{TIP}"}}')
        (self.tmp / "compare.json").write_text('{"behind_by": 0}')
        (self.tmp / "status.json").write_text(
            '{"statuses": [{"context": "merge-compile", "state": "success", "target_url": "https://x/1"}]}')

    def run_check(self, *, behind=0):
        (self.tmp / "compare.json").write_text(f'{{"behind_by": {behind}}}')
        script = (
            f'GH={self.tmp}/gh; repo=o/r; target=main; selected_head={HEAD}; selected_pr=7\n'
            f'. {HERE}/ci-checks.sh\ncheck_merge_compile; echo "rc=$?"')
        env = dict(os.environ, FAKE_DIR=str(self.tmp))
        return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)

    def test_multi_page_commit_still_yields_one_tip(self):
        out = self.run_check()
        self.assertIn("rc=0", out.stdout, out.stderr)
        self.assertIn("merge-compile PASS", out.stderr)
        calls = (self.tmp / "calls.log").read_text()
        self.assertIn("repos/o/r/commits/main paginate=0", calls)
        self.assertIn(f"repos/o/r/compare/{TIP}...{HEAD} paginate=0", calls)

    def test_multi_page_status_takes_one_newest_row(self):
        out = self.run_check()
        self.assertIn("https://x/1", out.stderr)

    def test_stale_head_is_reported_not_silent(self):
        out = self.run_check(behind=3)
        self.assertIn("merge-compile would REFUSE", out.stderr)

    def test_bad_tip_names_the_reason(self):
        (self.tmp / "commit.json").write_text('{"sha": "not-a-sha"}')
        out = self.run_check()
        self.assertIn("rc=1", out.stdout)
        self.assertIn("not one 40-hex sha", out.stderr)


if __name__ == "__main__":
    unittest.main()

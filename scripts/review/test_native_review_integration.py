#!/usr/bin/env python3
"""Exercise GitHub review state and separate release CI checks, offline."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
HEAD = "a" * 40
BASE = "b" * 40


class NativeReviewIntegration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="native-review-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.pr = {"number": 7, "state": "open", "draft": False, "merged": False,
                   "user": {"id": 1, "login": "author"}, "stack": None,
                   "base": {"ref": "main", "sha": BASE},
                   "head": {"ref": "fix/example", "sha": HEAD}}
        self.reviews = [{"id": 10, "state": "APPROVED", "body": "", "author_association": "COLLABORATOR",
                         "user": {"id": 2, "login": "reviewer"},
                         "commit_id": HEAD, "submitted_at": "2026-11-02T06:00:00Z"}]
        fake = self.root / "gh"
        fake.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
root = Path(os.environ["NATIVE_TEST_ROOT"])
args = sys.argv[1:]
if not args or args.pop(0) != "api":
    raise SystemExit("only read-only API calls are permitted")
paginate = "--paginate" in args
slurp = "--slurp" in args
args = [arg for arg in args if arg not in ("--paginate", "--slurp")]
path = args.pop(0)
if path == "repos/o/r/pulls/7": file = "pr.json"
elif path == "repos/o/r/pulls/7/reviews": file = "reviews.json"
elif path.startswith("repos/o/r/commits/") and path.endswith("/status"): file = "status.json"
elif path == "repos/o/r/commits/main": file = "base.json"
elif path.startswith("repos/o/r/compare/"): file = "compare.json"
elif path.startswith("repos/o/r/actions/runs/") and "/jobs" in path: file = "jobs.json"
elif path.startswith("repos/o/r/actions/runs?"): file = "runs.json"
else: raise SystemExit("unexpected or mutating endpoint: " + path)
data = json.loads((root / file).read_text())
if slurp:
    data = [data]
if args:
    if len(args) != 2 or args[0] != "--jq": raise SystemExit("unexpected options")
    result = subprocess.run(["jq", "-r", args[1]], input=json.dumps(data), text=True)
    raise SystemExit(result.returncode)
print(json.dumps(data))
''')
        fake.chmod(0o755)
        self.gh = fake
        self.write("status.json", {"statuses": []})
        self.write("base.json", {"sha": BASE})
        self.write("compare.json", {"behind_by": 0})
        self.write("runs.json", {"workflow_runs": []})
        self.write("jobs.json", {"jobs": []})

    def write(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def check(self, *extra):
        self.write("pr.json", self.pr)
        self.write("reviews.json", self.reviews)
        # The helpers only report the facts. Neither publishes an approval nor
        # performs a merge, and neither requires a review-body format.
        script = '''set -euo pipefail
repo=o/r; pr=7; head="$1"; GH="$2"; here="$3"; run=""
python3 "$here/github-reviews.py" --repo "$repo" --pr "$pr" --head "$head" --gh "$GH"
source "$here/ci-checks.sh"
review_identity=""
check_current_ci
printf 'CURRENT REVIEW AND CI CHECKS PASS\\n'
'''
        return subprocess.run(
            ["bash", "-c", script, "review-test", HEAD, str(self.gh), str(HERE), *extra],
            capture_output=True, text=True,
            env=dict(os.environ, GUARD_GH=str(self.gh), NATIVE_TEST_ROOT=str(self.root)))

    def test_current_head_approval_is_reported(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"approval_ids": [10]', result.stdout)
        self.assertIn("CURRENT REVIEW AND CI CHECKS PASS", result.stdout)

    def test_other_account_change_request_remains_blocking(self):
        self.reviews.append({"id": 11, "state": "CHANGES_REQUESTED", "body": "Fix this",
                             "user": {"id": 3, "login": "other"}, "commit_id": HEAD,
                             "submitted_at": "2026-11-02T06:01:00Z"})
        result = self.check()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(json.loads(result.stdout)["change_requests"], [{"id": 11, "login": "other"}])

    def test_release_approval_does_not_replace_exact_head_full_ci(self):
        self.pr["head"]["ref"] = "release/v1.2.3"
        result = self.check()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("release requires", result.stderr)

        self.write("runs.json", {"workflow_runs": [{
            "id": 101, "status": "completed", "conclusion": "success",
            "head_sha": HEAD, "head_branch": "release/v1.2.3",
            "path": ".github/workflows/release-candidate.yml"}]})
        names = ("compile / Release checks passed", "behavior / test suite",
                 "installation / release", "Record candidate verification")
        self.write("jobs.json", {"jobs": [{"id": i, "name": name, "status": "completed",
                                           "conclusion": "success"}
                                          for i, name in enumerate(names, 1)]})
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()

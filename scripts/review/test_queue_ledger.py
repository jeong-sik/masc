#!/usr/bin/env python3
"""Offline queue output preserves independent blockers and their ownership."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
HEAD = "a" * 40


class QueueLedgerCase(unittest.TestCase):
    def test_reports_every_blocker_despite_a_later_unrelated_pass(self):
        with tempfile.TemporaryDirectory(prefix="review-ledger-") as directory:
            root = Path(directory)
            records = []
            for rid, actor, state in ((1, "reviewer-a", "HOLD"),
                                      (2, "reviewer-b", "FAIL"),
                                      (3, "unrelated", "PASS")):
                records.append({
                    "id": rid, "user": {"login": actor},
                    "author_association": "COLLABORATOR",
                    "body": f"verdict: {state} head: {HEAD} by: keeper-{rid}",
                    "created_at": f"2026-10-26T10:0{rid}:00Z",
                    "updated_at": f"2026-10-26T10:0{rid}:00Z",
                })
            (root / "comments.json").write_text(json.dumps(records))
            fake = root / "gh"
            fake.write_text('''#!/usr/bin/env bash
set -eu
if [ "$1" = pr ]; then
  printf '7\tpr-author\tmain\t%s\tfix/example\tfalse\n' "$LEDGER_TEST_HEAD"
elif [ "$1" = api ]; then
  shift; [ "$1" != --paginate ] || shift
  path="$1"; shift
  case "$path" in
    */comments) jq -r "$2" "$LEDGER_TEST_ROOT/comments.json";;
    */reviews) jq -r "$2" <<< '[]';;
    *) echo "unexpected API: $path" >&2; exit 9;;
  esac
else exit 9; fi
''')
            fake.chmod(0o755)
            env = dict(os.environ, LEDGER_GH=str(fake), LEDGER_TEST_HEAD=HEAD,
                       LEDGER_TEST_ROOT=str(root))
            for output_format in ("tsv", "md"):
                with self.subTest(output_format=output_format):
                    result = subprocess.run(
                        ["bash", str(HERE / "queue-ledger.sh"), "--repo", "o/r",
                         "--format", output_format], env=env, text=True,
                        capture_output=True, check=True)
                    self.assertIn("HOLD by reviewer-a at comment:1 since 2026-10-26T10:01:00", result.stdout)
                    self.assertIn("FAIL by reviewer-b at comment:2 since 2026-10-26T10:02:00", result.stdout)
                    self.assertNotIn("PASS by", result.stdout)


if __name__ == "__main__":
    unittest.main()

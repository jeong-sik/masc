#!/usr/bin/env python3
"""stack-scope.py against a fake `gh`: a native stack is merged only through
its top open PR. Offline; no network, no real PR.

Run: python3 -I scripts/review/test_stack_scope.py
"""
import json
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
REPO = "o/r"
STACK = 900

FAKE_GH = r"""#!/usr/bin/env bash
# api <path> --jq . over canned JSON in $FAKE_DIR.
shift
case "$1" in
  repos/*/pulls/*) f="$FAKE_DIR/pr-${1##*/}.json";;
  repos/*/stacks/*) f="$FAKE_DIR/stack.json";;
  *) echo "fake gh: unexpected $1" >&2; exit 9;;
esac
exec jq -r . "$f"
"""


def sha(n):
    return f"{n:040x}"


class StackScope(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="stack-scope-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        gh = self.tmp / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
        self.data = self.tmp / "data"
        self.data.mkdir()

    def stack(self, states):
        """One native stack over main; [states] lists each member bottom first
        as "open", "merged" or "closed" (closed without merging)."""
        numbers = [101 + i for i in range(len(states))]
        for position, (number, state) in enumerate(zip(numbers, states), 1):
            below = "main" if position == 1 else f"layer-{numbers[position - 2]}"
            (self.data / f"pr-{number}.json").write_text(json.dumps({
                "state": "open" if state == "open" else "closed",
                "draft": False, "merged": state == "merged",
                "base": {"ref": below, "sha": sha(number - 1), "repo": {"full_name": REPO}},
                "head": {"ref": f"layer-{number}", "sha": sha(number), "repo": {"full_name": REPO}},
                "user": {"login": "author"},
                "stack": {"id": 7, "number": STACK, "base": {"ref": "main"},
                          "size": len(numbers), "position": position},
            }))
        (self.data / "stack.json").write_text(json.dumps({
            "id": 7, "number": STACK, "base": {"ref": "main"},
            "pull_requests": [
                {"number": number, "state": "open" if state == "open" else "closed",
                 "head": {"sha": sha(number)}}
                for number, state in zip(numbers, states)],
        }))
        return numbers

    def scope(self, selected):
        return subprocess.run(
            [sys.executable, "-I", str(HERE / "stack-scope.py"), REPO, str(selected), sha(selected)],
            capture_output=True, text=True,
            env={"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
                 "GUARD_GH": str(self.tmp / "gh"), "FAKE_DIR": str(self.data)})

    def test_the_top_open_pr_takes_every_layer_below_it(self):
        numbers = self.stack(["merged", "open", "open"])
        result = self.scope(numbers[-1])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([m["number"] for m in json.loads(result.stdout)["scope"]], numbers)

    def test_a_lower_pr_with_open_layers_above_is_refused(self):
        numbers = self.stack(["open", "open", "open"])
        result = self.scope(numbers[0])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn(f"#{numbers[0]} is not the top of native stack #{STACK}", result.stderr)
        self.assertIn(f"through #{numbers[-1]}", result.stderr)

    def test_a_pr_whose_layers_above_are_closed_is_the_top(self):
        numbers = self.stack(["open", "open", "closed"])
        result = self.scope(numbers[1])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([m["number"] for m in json.loads(result.stdout)["scope"]], numbers[:2])


if __name__ == "__main__":
    unittest.main()

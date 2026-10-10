#!/usr/bin/env python3
"""stack-scope.py against a fake `gh`: a native stack is admitted only through
its top open layer. Offline; no network, no real PR."""
import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
REPO = "owner/repo"
STACK = {"id": 7, "number": 900, "base": {"ref": "main"}}

FAKE_GH = r"""#!/usr/bin/env bash
# api <path> --jq . over canned JSON in $FAKE_DIR, one file per path.
path="$2"
f="$FAKE_DIR/$(printf '%s' "$path" | tr '/' '_').json"
[ -f "$f" ] || { echo "fake gh: unexpected $path" >&2; exit 9; }
exec cat "$f"
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
        self.env = dict(os.environ, GUARD_GH=str(gh), FAKE_DIR=str(self.data))

    def write(self, path, value):
        (self.data / (path.replace("/", "_") + ".json")).write_text(json.dumps(value))

    def stack_of(self, states):
        """Layers 1..n with the given states; a closed layer is unmerged."""
        numbers = [100 + position for position in range(1, len(states) + 1)]
        for position, (number, state) in enumerate(zip(numbers, states), 1):
            base = "main" if position == 1 else f"layer-{position - 1}"
            self.write(f"repos/{REPO}/pulls/{number}", {
                "state": state, "draft": False, "merged": False,
                "base": {"ref": base, "sha": sha(number - 1), "repo": {"full_name": REPO}},
                "head": {"ref": f"layer-{position}", "sha": sha(number), "repo": {"full_name": REPO}},
                "user": {"login": "author"},
                "stack": dict(STACK, size=len(states), position=position),
            })
        self.write(f"repos/{REPO}/stacks/{STACK['number']}", dict(STACK, pull_requests=[
            {"number": number, "state": state, "head": {"sha": sha(number)}}
            for number, state in zip(numbers, states)]))
        return numbers

    def run_scope(self, number):
        return subprocess.run(
            ["python3", str(HERE / "stack-scope.py"), REPO, str(number), sha(number)],
            env=self.env, capture_output=True, text=True)

    def test_top_layer_admits_the_whole_stack(self):
        numbers = self.stack_of(["open", "open", "open"])
        result = self.run_scope(numbers[-1])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([item["number"] for item in json.loads(result.stdout)["scope"]], numbers)

    def test_lower_layer_is_refused_and_names_the_open_layers_above(self):
        numbers = self.stack_of(["open", "open", "open"])
        result = self.run_scope(numbers[0])
        self.assertEqual(result.returncode, 2)
        self.assertIn(f"#{numbers[0]} sits below open stack layers #{numbers[1]} #{numbers[2]}",
                      result.stderr)
        self.assertEqual(result.stdout, "")

    def test_closed_unmerged_layer_above_does_not_hold_the_stack(self):
        numbers = self.stack_of(["open", "open", "closed"])
        result = self.run_scope(numbers[1])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([item["number"] for item in json.loads(result.stdout)["scope"]], numbers[:2])

    def test_unknown_state_above_is_refused(self):
        numbers = self.stack_of(["open", "open"])
        self.write(f"repos/{REPO}/stacks/{STACK['number']}", dict(STACK, pull_requests=[
            {"number": numbers[0], "state": "open", "head": {"sha": sha(numbers[0])}},
            {"number": numbers[1], "state": "queued", "head": {"sha": sha(numbers[1])}}]))
        result = self.run_scope(numbers[0])
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown member state", result.stderr)


if __name__ == "__main__":
    unittest.main()

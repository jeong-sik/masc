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
# A pull request names its repository by id and full name. The stack listing
# names the same repository by id, name and url, and never by full name.
HOME = {"id": 1, "full_name": REPO}
LISTED_HOME = {"id": 1, "name": "r", "url": "https://api.github.test/r"}

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
                "base": {"ref": below, "sha": sha(number - 1), "repo": HOME},
                "head": {"ref": f"layer-{number}", "sha": sha(number), "repo": HOME},
                "user": {"login": "author"},
                "stack": {"id": 7, "number": STACK, "base": {"ref": "main"},
                          "size": len(numbers), "position": position},
            }))
        (self.data / "stack.json").write_text(json.dumps({
            "id": 7, "number": STACK, "base": {"ref": "main"},
            "pull_requests": [
                {"number": number, "state": "open" if state == "open" else "closed",
                 "draft": False, "merged_at": "2026-11-09T01:00:00Z" if state == "merged" else None,
                 "user": {"login": "author"},
                 "base": {"ref": "main" if position == 1 else f"layer-{numbers[position - 2]}",
                          "sha": sha(number - 1), "repo": LISTED_HOME},
                 "head": {"ref": f"layer-{number}", "sha": sha(number), "repo": LISTED_HOME}}
                for position, (number, state) in enumerate(zip(numbers, states), 1)],
        }))
        return numbers

    def scope(self, selected):
        return subprocess.run(
            [sys.executable, "-I", str(HERE / "stack-scope.py"), REPO, str(selected), sha(selected)],
            capture_output=True, text=True,
            env={"PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
                 "MASC_REVIEW_GH": str(self.tmp / "gh"), "FAKE_DIR": str(self.data)})

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

    def test_a_layer_above_in_an_unknown_state_is_refused(self):
        numbers = self.stack(["open", "open", "open"])
        listing = json.loads((self.data / "stack.json").read_text())
        listing["pull_requests"][-1]["state"] = "queued"
        (self.data / "stack.json").write_text(json.dumps(listing))
        result = self.scope(numbers[1])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("unknown member state", result.stderr)

    def test_a_pr_whose_layers_above_are_closed_is_the_top(self):
        numbers = self.stack(["open", "open", "closed"])
        result = self.scope(numbers[1])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([m["number"] for m in json.loads(result.stdout)["scope"]], numbers[:2])

    def listing(self, change):
        value = json.loads((self.data / "stack.json").read_text())
        change(value["pull_requests"])
        (self.data / "stack.json").write_text(json.dumps(value))

    def test_a_lower_layer_comes_from_the_listing_alone(self):
        numbers = self.stack(["merged", "open", "open"])
        for lower in numbers[:-1]:
            (self.data / f"pr-{lower}.json").unlink()
        result = self.scope(numbers[-1])
        self.assertEqual(result.returncode, 0, result.stderr)
        scope = json.loads(result.stdout)["scope"]
        self.assertEqual([(m["number"], m["identity"]["merged"], m["identity"]["stack"]["position"],
                           m["identity"]["head"], m["identity"]["author"]) for m in scope[:2]],
                         [(101, True, 1, {"ref": "layer-101", "sha": sha(101), "repo": REPO}, "author"),
                          (102, False, 2, {"ref": "layer-102", "sha": sha(102), "repo": REPO}, "author")])

    def test_the_listing_and_the_selected_pr_must_agree(self):
        for field, value in (("draft", True), ("merged_at", "2026-11-09T01:00:00Z")):
            with self.subTest(field=field):
                numbers = self.stack(["open", "open"])
                self.listing(lambda rows: rows[-1].update({field: value}))
                result = self.scope(numbers[-1])
                self.assertEqual((result.returncode, result.stdout), (2, ""))
        numbers = self.stack(["open", "open"])
        self.listing(lambda rows: rows[-1]["base"].update(sha=sha(9001)))
        result = self.scope(numbers[-1])
        self.assertEqual(result.returncode, 2)
        self.assertIn(f"#{numbers[-1]} changed while reading stack", result.stderr)

    def test_a_closed_unmerged_lower_layer_blocks_the_stack(self):
        numbers = self.stack(["closed", "open"])
        result = self.scope(numbers[-1])
        self.assertEqual(result.returncode, 2)
        self.assertIn(f"#{numbers[0]} is closed without merging", result.stderr)

    def test_an_open_lower_layer_with_a_merge_date_is_refused(self):
        # Read as merged, the layer would be passed over without its reviews.
        numbers = self.stack(["open", "open"])
        self.listing(lambda rows: rows[0].update(merged_at="2026-11-09T01:00:00Z"))
        result = self.scope(numbers[-1])
        self.assertEqual((result.returncode, result.stdout), (2, ""))
        self.assertIn("open member has a merge date", result.stderr)

    def test_a_member_in_another_repository_is_refused(self):
        numbers = self.stack(["open", "open"])
        self.listing(lambda rows: rows[0]["head"]["repo"].update(id=2))
        result = self.scope(numbers[-1])
        self.assertEqual(result.returncode, 2)
        self.assertIn("stack member in another repository", result.stderr)

    def test_a_listed_branch_whose_repository_is_gone_has_no_repository_name(self):
        numbers = self.stack(["merged", "open"])
        self.listing(lambda rows: rows[0]["head"].update(repo=None))
        result = self.scope(numbers[-1])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(result.stdout)["scope"][0]["identity"]["head"]["repo"])


if __name__ == "__main__":
    unittest.main()

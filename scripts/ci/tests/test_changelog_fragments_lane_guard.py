"""A PR that stops accepting a runtime.toml lane id tells the operator."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "changelog_fragments", SCRIPTS / "changelog-fragments.py")
assert spec is not None and spec.loader is not None
fragments = importlib.util.module_from_spec(spec)
sys.modules["changelog_fragments"] = fragments
spec.loader.exec_module(fragments)

LANES = """type t =
  | Librarian
  | Workspace_curator
  | Verifier
[@@deriving enumerate]

let to_id = function
  | Librarian -> "librarian_exact"
  | Workspace_curator -> "workspace_curator_exact"
  | Verifier -> "verifier_exact"
;;
"""
WITHOUT_CURATOR = LANES.replace("  | Workspace_curator\n", "").replace(
    '  | Workspace_curator -> "workspace_curator_exact"\n', "")
RENAMED = LANES.replace("Workspace_curator", "Curator")
NOTE = """### Upgrade notes

- Delete `[runtime.exact_output_lanes.workspace_curator_exact]` from runtime.toml;
  the model is set per Addon installation now (#7).
"""
NOTE_IN_OTHER_SECTION = NOTE.replace("Upgrade notes", "Changed")


class LaneGuard(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.previous = Path.cwd()
        os.chdir(self.root)
        self.git("init", "-q")
        self.write("lib/runtime/standalone_lane.ml", LANES)
        self.commit("base")
        self.base = self.git("rev-parse", "HEAD").strip()

    def tearDown(self) -> None:
        os.chdir(self.previous)
        self.directory.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-c", "user.name=t", "-c", "user.email=t@example.test",
             "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *args],
            text=True, capture_output=True, check=True).stdout

    def write(self, name: str, text: str) -> None:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def guard(self) -> int:
        return fragments.lane_guard(self.base, "HEAD")

    def test_an_unchanged_lane_list_passes(self) -> None:
        self.write("README.md", "x")
        self.commit("unrelated")
        self.assertEqual(self.guard(), 0)

    def test_a_dropped_lane_without_a_note_is_refused(self) -> None:
        self.write("lib/runtime/standalone_lane.ml", WITHOUT_CURATOR)
        self.commit("drop")
        self.assertEqual(self.guard(), 1)

    def test_a_dropped_lane_named_in_upgrade_notes_passes(self) -> None:
        self.write("lib/runtime/standalone_lane.ml", WITHOUT_CURATOR)
        self.write("changelog.d/7.md", NOTE)
        self.commit("drop with note")
        self.assertEqual(self.guard(), 0)

    def test_a_note_in_another_section_does_not_count(self) -> None:
        self.write("lib/runtime/standalone_lane.ml", WITHOUT_CURATOR)
        self.write("changelog.d/7.md", NOTE_IN_OTHER_SECTION)
        self.commit("drop with a Changed bullet")
        self.assertEqual(self.guard(), 1)

    def test_a_note_that_names_another_lane_does_not_count(self) -> None:
        self.write("lib/runtime/standalone_lane.ml", WITHOUT_CURATOR)
        self.write("changelog.d/7.md", NOTE.replace("workspace_curator_exact", "verifier_exact"))
        self.commit("drop with a note about another lane")
        self.assertEqual(self.guard(), 1)

    def test_renaming_a_constructor_keeps_the_id_and_passes(self) -> None:
        self.write("lib/runtime/standalone_lane.ml", RENAMED)
        self.commit("rename")
        self.assertEqual(self.guard(), 0)

    def test_an_id_that_moved_to_the_identity_file_is_still_read(self) -> None:
        moved = LANES.split("let to_id")[0]
        self.write("lib/runtime/standalone_lane.ml", moved)
        self.write("lib/runtime/lane_run_identity.ml", "let to_id" + LANES.split("let to_id")[1])
        self.commit("move ids")
        self.assertEqual(self.guard(), 0)

    def test_a_shape_the_guard_cannot_read_is_an_error_not_a_pass(self) -> None:
        self.write("lib/runtime/standalone_lane.ml", "type t = Librarian | Verifier\n")
        self.commit("reshape")
        with self.assertRaises(fragments.FragmentError):
            self.guard()


if __name__ == "__main__":
    unittest.main()

"""Fixtures for scripts/ci/changelog-section.py, the release-body cutter.

The release job hands its output to GitHub, which keeps the first 125,000
characters of a release body and drops the rest without an error (v0.37.0,
run 35889074765). These cases pin both sides of that limit and keep the
refusals the script already had.
"""
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "changelog-section.py"
GITHUB_RELEASE_BODY_LIMIT = 125_000


def changelog_with_body_of(chars: int) -> str:
    """A CHANGELOG whose [9.9.9] section cuts to exactly [chars] characters."""
    head = "## [9.9.9] - 2026-09-23\n\n### Fixed\n\n- "
    # The cut body is the section stripped plus one trailing newline.
    filler = "x" * (chars - len(head) - 1)
    return f"# Changelog\n\n{head}{filler}\n\n## [9.9.8]\n\n- Older (#1).\n"


def run(*args):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *map(str, args)],
        capture_output=True,
        text=True,
    )


class ChangelogSection(unittest.TestCase):
    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.changelog = self.dir / "CHANGELOG.md"
        self.out = self.dir / "release-body.md"

    def test_a_body_at_the_limit_is_written(self):
        self.changelog.write_text(changelog_with_body_of(GITHUB_RELEASE_BODY_LIMIT))
        result = run("9.9.9", self.changelog, self.out,
                     "--max-chars", GITHUB_RELEASE_BODY_LIMIT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.out.read_text()), GITHUB_RELEASE_BODY_LIMIT)

    def test_one_character_over_the_limit_fails_and_writes_nothing(self):
        self.changelog.write_text(
            changelog_with_body_of(GITHUB_RELEASE_BODY_LIMIT + 1))
        result = run("9.9.9", self.changelog, self.out,
                     "--max-chars", GITHUB_RELEASE_BODY_LIMIT)
        self.assertEqual(result.returncode, 1)
        self.assertIn("125001 characters", result.stderr)
        self.assertIn("1 characters would be cut", result.stderr)
        self.assertFalse(self.out.exists(), "a refused body must not be written")

    def test_the_appended_list_counts_against_the_limit(self):
        # The section alone fits; the generated notes placed after it do not.
        self.changelog.write_text(changelog_with_body_of(1_000))
        notes = self.dir / "generated.md"
        notes.write_text("## What's Changed\n" + "y" * GITHUB_RELEASE_BODY_LIMIT)
        result = run("9.9.9", self.changelog, self.out,
                     "--append", notes, "--max-chars", GITHUB_RELEASE_BODY_LIMIT)
        self.assertEqual(result.returncode, 1)
        self.assertIn("appended", result.stderr)
        self.assertFalse(self.out.exists())

    def test_the_appended_list_follows_the_section_after_a_blank_line(self):
        self.changelog.write_text(changelog_with_body_of(200))
        notes = self.dir / "generated.md"
        notes.write_text("\n## What's Changed\n* a PR by someone\n\n")
        result = run("9.9.9", self.changelog, self.out, "--append", notes)
        self.assertEqual(result.returncode, 0, result.stderr)
        body = self.out.read_text()
        self.assertTrue(body.startswith("## [9.9.9]"))
        self.assertIn("x\n\n## What's Changed\n* a PR by someone\n", body)
        self.assertTrue(body.endswith("someone\n"))

    def test_without_flags_the_body_is_the_section_alone(self):
        self.changelog.write_text(changelog_with_body_of(300))
        result = run("9.9.9", self.changelog, self.out)
        self.assertEqual(result.returncode, 0, result.stderr)
        body = self.out.read_text()
        self.assertEqual(len(body), 300)
        self.assertNotIn("9.9.8", body)

    def test_a_missing_section_fails(self):
        self.changelog.write_text(changelog_with_body_of(300))
        result = run("1.2.3", self.changelog, self.out)
        self.assertEqual(result.returncode, 1)
        self.assertIn("has no ## [1.2.3] section", result.stderr)

    def test_two_sections_fail(self):
        text = changelog_with_body_of(300)
        self.changelog.write_text(text + "\n## [9.9.9]\n\n- Again (#2).\n")
        result = run("9.9.9", self.changelog, self.out)
        self.assertEqual(result.returncode, 1)
        self.assertIn("2 ## [9.9.9] sections", result.stderr)

    def test_a_section_without_entries_fails(self):
        self.changelog.write_text("# Changelog\n\n## [9.9.9]\n\n## [9.9.8]\n\n- Old.\n")
        result = run("9.9.9", self.changelog, self.out)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no '- ' entries", result.stderr)


if __name__ == "__main__":
    unittest.main()

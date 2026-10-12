"""The release page lists what a reader acts on and counts the rest."""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

CI = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("changelog_section", CI / "changelog-section.py")
assert spec is not None and spec.loader is not None
section = importlib.util.module_from_spec(spec)
sys.modules["changelog_section"] = section
spec.loader.exec_module(section)

URL = "https://example.test/blob/v1.2.0/CHANGELOG.md"
CHANGELOG = """# Changelog

## [Unreleased]

## [1.2.0] - 2026-10-07

### Upgrade notes

- Stop the server before installing.

### Added

- A new Board filter. (#10)
  It keeps the reader's place.

### Fixed

- First fix. (#11)
- Second fix. (#12)
  With a second line.

### Internal

- One refactor. (#13)

## [1.1.0] - 2026-10-01

### Fixed

- An older fix. (#1)
"""


class ChangelogSection(unittest.TestCase):
    def run_script(self, changelog: str, *extra: str) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "CHANGELOG.md"
            out = Path(directory) / "body.md"
            source.write_text(changelog, encoding="utf-8")
            code = section.main(["1.2.0", str(source), str(out), *extra])
            return code, out.read_text(encoding="utf-8") if out.exists() else ""

    def test_listed_sections_are_printed_and_the_rest_are_counted(self):
        code, body = self.run_script(CHANGELOG, "--changelog-url", URL)
        self.assertEqual(code, 0)
        self.assertEqual(body, """## [1.2.0] - 2026-10-07

### Upgrade notes

- Stop the server before installing.

### Added

- A new Board filter. (#10)
  It keeps the reader's place.

### Also in this release

- Fixed: 2 entries
- Internal: 1 entry

Every entry is in [CHANGELOG.md](https://example.test/blob/v1.2.0/CHANGELOG.md) under `## [1.2.0] - 2026-10-07`.
""")

    def test_counted_entries_do_not_count_against_the_page_limit(self):
        fixes = "".join(f"- Fix number {i} with a long explanation. (#{i})\n" for i in range(100, 2100))
        grown = CHANGELOG.replace("- First fix. (#11)\n", fixes)
        self.assertGreater(len(grown), 60_000)
        code, body = self.run_script(grown, "--max-chars", "2000")
        self.assertEqual(code, 0)
        self.assertIn("- Fixed: 2001 entries", body)
        self.assertNotIn("Fix number 100 ", body)

    def test_listed_entries_over_the_limit_are_refused(self):
        added = "".join(f"- Added thing {i}. (#{i})\n" for i in range(100, 400))
        grown = CHANGELOG.replace("- A new Board filter. (#10)\n", added)
        code, body = self.run_script(grown, "--max-chars", "2000")
        self.assertEqual((code, body), (1, ""))

    def test_a_heading_dated_another_day_is_refused(self):
        self.assertEqual(self.run_script(CHANGELOG, "--expect-date", "2026-10-08"), (1, ""))
        code, _ = self.run_script(CHANGELOG, "--expect-date", "2026-10-07")
        self.assertEqual(code, 0)

    def test_a_section_without_entries_is_refused(self):
        stub = CHANGELOG.split("### Upgrade notes")[0] + "### Changed\n\n## [1.1.0] - 2026-10-01\n"
        self.assertEqual(self.run_script(stub), (1, ""))

    def test_a_release_of_counted_entries_only_still_has_a_page(self):
        only_fixes = CHANGELOG.replace(
            "### Upgrade notes\n\n- Stop the server before installing.\n\n", ""
        ).replace("### Added\n\n- A new Board filter. (#10)\n  It keeps the reader's place.\n\n", "")
        code, body = self.run_script(only_fixes)
        self.assertEqual(code, 0)
        self.assertEqual(body, """## [1.2.0] - 2026-10-07

### Also in this release

- Fixed: 2 entries
- Internal: 1 entry

Every entry is in CHANGELOG.md under `## [1.2.0] - 2026-10-07`.
""")

    def test_repeated_categories_are_counted_once(self):
        repeated = CHANGELOG.replace("## [1.1.0]", "### Fixed\n\n- Another fix.\n\n## [1.1.0]")
        code, body = self.run_script(repeated)
        self.assertEqual(code, 0)
        self.assertEqual(body.count("- Fixed:"), 1)
        self.assertIn("- Fixed: 3 entries", body)

    def test_complete_record_counts_replace_summary_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            details = Path(directory) / "complete.md"
            details.write_text(CHANGELOG.replace("- First fix. (#11)",
                "- Detailed fix one.\n- Detailed fix two.").replace("### Internal",
                "### Documentation\n\n- New manual.\n\n### Internal"))
            code, body = self.run_script(CHANGELOG, "--counts-changelog", str(details),
                "--counts-changelog-url", URL.replace("CHANGELOG.md", "complete.md"))
            self.assertEqual(code, 0)
            self.assertIn("- Fixed: 3 entries", body)
            self.assertIn("- Documentation: 1 entry", body)
            self.assertIn("[complete changelog](https://example.test/blob/v1.2.0/complete.md)", body)
            self.assertNotIn("Detailed fix", body)
            self.assertIn("Stop the server before installing.", body)

    def test_complete_record_must_match_the_selected_version_and_date(self):
        for details_text in [CHANGELOG.replace("1.2.0", "1.3.0"),
                             CHANGELOG.replace("2026-10-07", "2026-10-06"),
                             CHANGELOG + "\n## [1.2.0] - 2026-10-07\n- Duplicate\n"]:
            with self.subTest(details=details_text), tempfile.TemporaryDirectory() as directory:
                details = Path(directory) / "complete.md"
                details.write_text(details_text)
                self.assertEqual(self.run_script(CHANGELOG,
                    "--counts-changelog", str(details), "--counts-changelog-url", URL), (1, ""))

    def test_complete_record_requires_its_own_published_link(self):
        self.assertEqual(self.run_script(CHANGELOG, "--counts-changelog", "complete.md"), (1, ""))


if __name__ == "__main__":
    unittest.main()

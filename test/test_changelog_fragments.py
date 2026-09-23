"""Fixtures for scripts/changelog-fragments.py: check, assemble, pr-guard."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "changelog-fragments.py"

CHANGELOG = """# Changelog

## [Unreleased]

### Added

- An entry already merged (#100).

### Fixed

- A merged fix that
  wraps (#101).


## [1.0.0] - 2026-01-01

### Fixed

- Released (#50).

## [Unreleased]

### Changed

- History that must stay put.
"""


def run(*args, cwd=None):
    return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=cwd,
                          text=True, capture_output=True)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="masc-changelog-")
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name)
        self.dir = self.root / "changelog.d"
        self.dir.mkdir()
        self.changelog = self.root / "CHANGELOG.md"
        self.changelog.write_text(CHANGELOG)

    def fragment(self, name, text):
        (self.dir / name).write_text(text)

    def check(self):
        return run("check", "--dir", str(self.dir))

    def assemble(self):
        return run("assemble", "--dir", str(self.dir), "--changelog", str(self.changelog))


class Check(Fixture):
    def test_accepts_a_wrapped_bullet_citing_its_pr(self):
        self.fragment("200.md", "### Fixed\n\n- A fix that wraps\n  here (#200).\n")
        (self.dir / "README.md").write_text("# not a fragment\n")
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def refused(self, name, text, needle):
        self.fragment(name, text)
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(needle, result.stderr)

    def test_refuses_a_name_that_is_not_a_pr_number(self):
        self.refused("fix-thing.md", "### Fixed\n\n- x (#1).\n", "<PR number>.md")

    def test_refuses_a_bullet_citing_another_pr(self):
        self.refused("200.md", "### Fixed\n\n- x (#2001).\n", "does not cite #200")

    def test_refuses_a_heading_outside_the_vocabulary(self):
        self.refused("200.md", "### Fixes\n\n- x (#200).\n", "expected '### <Section>'")

    def test_refuses_a_bullet_before_any_heading(self):
        self.refused("200.md", "- x (#200).\n", "bullet before any")

    def test_refuses_prose_outside_a_bullet(self):
        self.refused("200.md", "### Fixed\n\nprose (#200)\n", "text outside a bullet")

    def test_refuses_an_empty_fragment(self):
        self.refused("200.md", "### Fixed\n", "no bullets")

    def test_lists_every_bad_fragment(self):
        self.fragment("200.md", "### Fixed\n\n- x (#9).\n")
        self.fragment("201.md", "### Nope\n\n- x (#201).\n")
        result = self.check()
        self.assertIn("200.md", result.stderr)
        self.assertIn("201.md", result.stderr)


class Assemble(Fixture):
    def test_folds_by_section_in_pr_order_and_deletes_fragments(self):
        self.fragment("300.md", "### Fixed\n\n- Later fix (#300).\n\n### Removed\n\n- Gone (#300).\n")
        self.fragment("250.md", "### Fixed\n\n- Earlier fix (#250).\n")
        result = self.assemble()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), [])
        text = self.changelog.read_text()
        unreleased = text.split("## [1.0.0]")[0]
        self.assertEqual(unreleased, """# Changelog

## [Unreleased]

### Added

- An entry already merged (#100).

### Removed

- Gone (#300).

### Fixed

- A merged fix that
  wraps (#101).
- Earlier fix (#250).
- Later fix (#300).

""")
        # Released sections and the historical [Unreleased] are untouched.
        self.assertTrue(text.endswith(CHANGELOG[CHANGELOG.index("## [1.0.0]"):]))

    def test_drops_a_bullet_already_present(self):
        self.fragment("101.md", "### Fixed\n\n- A merged fix that wraps (#101).\n")
        self.assertEqual(self.assemble().returncode, 0)
        self.assertEqual(self.changelog.read_text().count("wraps (#101)"), 1)

    def test_no_fragments_leaves_the_changelog_byte_identical(self):
        self.assertEqual(self.assemble().returncode, 0)
        self.assertEqual(self.changelog.read_text(), CHANGELOG)

    def test_a_bad_fragment_changes_nothing(self):
        self.fragment("300.md", "### Fixed\n\n- ok (#300).\n")
        self.fragment("301.md", "### Fixed\n\n- wrong (#1).\n")
        self.assertNotEqual(self.assemble().returncode, 0)
        self.assertEqual(self.changelog.read_text(), CHANGELOG)
        self.assertEqual(len(list(self.dir.iterdir())), 2)


class PrGuard(Fixture):
    def git(self, *args):
        # A developer's global hooks (a main-branch commit block, say) are not
        # part of this fixture.
        subprocess.run(["git", "-c", "core.hooksPath=/dev/null", *args],
                       cwd=self.root, check=True, capture_output=True)

    def setUp(self):
        super().setUp()
        (self.root / "dune-project").write_text("(lang dune 3.0)\n(version 1.0.0)\n")
        self.git("init", "-q", "-b", "fixture")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.fragment("100.md", "### Added\n\n- Pending (#100).\n")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "base")
        self.git("tag", "base")

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "head")

    def guard(self):
        return run("pr-guard", "--base", "base", "--head", "HEAD", cwd=self.root)

    def test_refuses_a_new_unreleased_bullet(self):
        self.changelog.write_text(CHANGELOG.replace(
            "- An entry already merged (#100).",
            "- An entry already merged (#100).\n- New (#400)."))
        self.commit()
        result = self.guard()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changelog.d/<PR number>.md", result.stderr)

    def test_accepts_a_fragment_and_a_reworded_bullet(self):
        self.fragment("400.md", "### Fixed\n\n- New (#400).\n")
        self.changelog.write_text(CHANGELOG.replace("already merged", "merged before"))
        self.commit()
        self.assertEqual(self.guard().returncode, 0)

    def test_accepts_assembly(self):
        self.assertEqual(self.assemble().returncode, 0)
        self.commit()
        self.assertEqual(self.guard().returncode, 0)

    def test_accepts_a_version_bump(self):
        (self.root / "dune-project").write_text("(lang dune 3.0)\n(version 1.0.1)\n")
        self.changelog.write_text(CHANGELOG.replace(
            "- An entry already merged (#100).",
            "- An entry already merged (#100).\n- Release note (#401)."))
        self.commit()
        self.assertEqual(self.guard().returncode, 0)

    def test_accepts_a_release_that_promoted_unreleased(self):
        self.changelog.write_text(CHANGELOG.replace(
            "## [Unreleased]\n\n### Added", "## [1.0.1] - 2026-02-01\n\n### Added", 1))
        self.commit()
        self.assertEqual(self.guard().returncode, 0)


if __name__ == "__main__":
    unittest.main()

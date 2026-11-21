"""Tests for scripts/changelog-fragments.py, including per-PR ### Exempt fragments."""

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
SCRIPT_PATH = SCRIPTS / "changelog-fragments.py"
CHANGELOG_TEMPLATE = (
    "# Changelog\n\n"
    "## [Unreleased]\n\n"
    "## [0.1.0] - 2026-01-01\n\n"
    "### Fixed\n\n"
    "- First (#1).\n"
)


def _load_module() -> types.ModuleType:
    spec = importlib.util.spec_from_file_location("changelog_fragments", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CF = _load_module()


def _run_cli(*args: str, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT_PATH), *args],
        cwd=cwd,
        text=True,
        capture_output=True,
    )


class ExemptFragmentParseTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory(prefix="masc-changelog-parse-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.frag_dir = self.root / "changelog.d"
        self.frag_dir.mkdir()

    def write_fragment(self, name: str, content: str) -> Path:
        path = self.frag_dir / name
        path.write_text(content, encoding="utf-8")
        return path

    def test_valid_exempt_fragment_single_and_multiline(self) -> None:
        path = self.write_fragment(
            "54014.md",
            "### Exempt\n\n"
            "- Docs only: update README exemption rules\n"
            "  without changing runtime behavior (#54014).\n",
        )
        sections = CF.parse_fragment(path)
        self.assertTrue(CF.is_exempt(sections))
        self.assertEqual(list(sections.keys()), ["Exempt"])
        self.assertEqual(len(sections["Exempt"]), 1)

        res = _run_cli("check-files", "changelog.d/54014.md", cwd=self.root)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("1 changed fragment(s) OK", res.stdout)

    def test_valid_exempt_fragment_multiple_bullets(self) -> None:
        path = self.write_fragment(
            "54023.md",
            "### Exempt\n\n"
            "- Comments only: clarify helper docstrings (#54023).\n"
            "- Tests only: add parser regression test (#54023).\n",
        )
        sections = CF.parse_fragment(path)
        self.assertTrue(CF.is_exempt(sections))
        self.assertEqual(len(sections["Exempt"]), 2)

    def test_exempt_mixed_with_release_section_rejected_both_orders(self) -> None:
        self.write_fragment(
            "54014.md",
            "### Fixed\n\n"
            "- Fix bug (#54014).\n\n"
            "### Exempt\n\n"
            "- Docs only (#54014).\n",
        )
        res = _run_cli("check-files", "changelog.d/54014.md", cwd=self.root)
        self.assertEqual(res.returncode, 1)
        self.assertIn("cannot be combined with release sections", res.stderr)
        self.assertIn("::error file=changelog.d/54014.md,line=5::", res.stdout)

        self.write_fragment(
            "54015.md",
            "### Exempt\n\n"
            "- Docs only (#54015).\n\n"
            "### Documentation\n\n"
            "- Update docs (#54015).\n",
        )
        res2 = _run_cli("check-files", "changelog.d/54015.md", cwd=self.root)
        self.assertEqual(res2.returncode, 1)
        self.assertIn("cannot be combined with release sections", res2.stderr)
        self.assertIn("::error file=changelog.d/54015.md,line=5::", res2.stdout)

    def test_valid_exempt_fragment_reason_on_continuation_line(self) -> None:
        path = self.write_fragment(
            "54024.md",
            "### Exempt\n\n"
            "- (#54024)\n"
            "  Comments only: clarify helper docstring.\n",
        )
        sections = CF.parse_fragment(path)
        self.assertTrue(CF.is_exempt(sections))
        self.assertEqual(len(sections["Exempt"]), 1)

    def test_exempt_without_reason_rejected(self) -> None:
        for body in (
            "### Exempt\n\n- (#54014).\n",
            "### Exempt\n\n- #54014\n",
            "### Exempt\n\n- --- (#54014) ...\n",
            "### Exempt\n\n- (#54014) (#54014)\n",
            "### Exempt\n\n- (#54014)\n  ---\n",
        ):
            with self.subTest(body=body):
                self.write_fragment("54014.md", body)
                res = _run_cli("check-files", "changelog.d/54014.md", cwd=self.root)
                self.assertEqual(res.returncode, 1)
                self.assertIn("exempt bullet must state a reason", res.stderr)
                self.assertIn("::error file=changelog.d/54014.md,line=3::", res.stdout)

    def test_exempt_second_bullet_without_reason_reports_second_line(self) -> None:
        self.write_fragment(
            "54025.md",
            "### Exempt\n\n"
            "- Docs only: tighten README (#54025).\n"
            "- (#54025).\n",
        )
        res = _run_cli("check-files", "changelog.d/54025.md", cwd=self.root)
        self.assertEqual(res.returncode, 1)
        self.assertIn("exempt bullet must state a reason", res.stderr)
        self.assertIn("::error file=changelog.d/54025.md,line=4::", res.stdout)

    def test_exempt_missing_pr_citation_rejected(self) -> None:
        self.write_fragment(
            "54014.md",
            "### Exempt\n\n- Docs only: clarify wording.\n",
        )
        res = _run_cli("check-files", "changelog.d/54014.md", cwd=self.root)
        self.assertEqual(res.returncode, 1)
        self.assertIn("does not cite #54014", res.stderr)

    def test_exempt_empty_section_and_duplicate_rejected(self) -> None:
        self.write_fragment("54014.md", "### Exempt\n")
        res = _run_cli("check", "--dir", str(self.frag_dir), cwd=self.root)
        self.assertEqual(res.returncode, 1)
        self.assertIn("no bullets", res.stderr)

        self.write_fragment(
            "54014.md",
            "### Exempt\n\n- Docs only (#54014).\n\n### Exempt\n\n- Tests only (#54014).\n",
        )
        res2 = _run_cli("check", "--dir", str(self.frag_dir), cwd=self.root)
        self.assertEqual(res2.returncode, 1)
        self.assertIn("section 'Exempt' appears twice", res2.stderr)


class AssembleTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory(prefix="masc-changelog-assemble-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.frag_dir = self.root / "changelog.d"
        self.frag_dir.mkdir()
        (self.frag_dir / "README.md").write_text("readme\n", encoding="utf-8")
        self.changelog = self.root / "CHANGELOG.md"
        self.changelog.write_text(CHANGELOG_TEMPLATE, encoding="utf-8")

    def test_assemble_mixed_folds_only_release_and_removes_all(self) -> None:
        (self.frag_dir / "100.md").write_text(
            "### Fixed\n\n- Resolve race condition (#100).\n", encoding="utf-8"
        )
        (self.frag_dir / "101.md").write_text(
            "### Exempt\n\n- Docs only: tighten README wording (#101).\n",
            encoding="utf-8",
        )

        res = _run_cli(
            "assemble",
            "--dir",
            str(self.frag_dir),
            "--changelog",
            str(self.changelog),
            cwd=self.root,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("folded 1 fragment(s)", res.stdout)
        self.assertIn("1 exempt removed", res.stdout)

        content = self.changelog.read_text(encoding="utf-8")
        self.assertIn("- Resolve race condition (#100).", content)
        self.assertNotIn("Exempt", content)
        self.assertNotIn("#101", content)
        self.assertFalse((self.frag_dir / "100.md").exists())
        self.assertFalse((self.frag_dir / "101.md").exists())
        self.assertTrue((self.frag_dir / "README.md").exists())

    def test_assemble_exempt_only_leaves_changelog_byte_identical(self) -> None:
        (self.frag_dir / "201.md").write_text(
            "### Exempt\n\n- Comments only (#201).\n", encoding="utf-8"
        )
        (self.frag_dir / "202.md").write_text(
            "### Exempt\n\n- Test fixture update (#202).\n", encoding="utf-8"
        )
        before = self.changelog.read_bytes()

        res = _run_cli(
            "assemble",
            "--dir",
            str(self.frag_dir),
            "--changelog",
            str(self.changelog),
            cwd=self.root,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("removed 2 exempt fragment(s)", res.stdout)
        self.assertIn("unchanged", res.stdout)
        self.assertEqual(self.changelog.read_bytes(), before)
        self.assertFalse((self.frag_dir / "201.md").exists())
        self.assertFalse((self.frag_dir / "202.md").exists())
        self.assertTrue((self.frag_dir / "README.md").exists())

    def test_assemble_exempt_only_preserves_existing_unreleased_entries(self) -> None:
        populated = (
            "# Changelog\n\n"
            "## [Unreleased]\n\n"
            "### Fixed\n\n"
            "- Existing entry (#99).\n\n"
            "## [0.1.0] - 2026-01-01\n\n"
            "### Fixed\n\n"
            "- First (#1).\n"
        )
        self.changelog.write_text(populated, encoding="utf-8")
        (self.frag_dir / "203.md").write_text(
            "### Exempt\n\n- Docs only (#203).\n", encoding="utf-8"
        )
        before = self.changelog.read_bytes()

        res = _run_cli(
            "assemble",
            "--dir",
            str(self.frag_dir),
            "--changelog",
            str(self.changelog),
            cwd=self.root,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.changelog.read_bytes(), before)
        self.assertFalse((self.frag_dir / "203.md").exists())

    def test_assemble_exempt_only_fails_closed_on_malformed_changelog(self) -> None:
        self.changelog.write_text("# Changelog\n\n## [0.1.0] - 2026-01-01\n", encoding="utf-8")
        exempt = self.frag_dir / "204.md"
        exempt.write_text("### Exempt\n\n- Docs only (#204).\n", encoding="utf-8")

        res = _run_cli(
            "assemble",
            "--dir",
            str(self.frag_dir),
            "--changelog",
            str(self.changelog),
            cwd=self.root,
        )
        self.assertEqual(res.returncode, 1)
        self.assertIn("## [Unreleased]", res.stderr)
        self.assertTrue(exempt.exists())

    def test_assemble_release_only_keeps_clean_summary(self) -> None:
        (self.frag_dir / "300.md").write_text(
            "### Added\n\n- Add feature (#300).\n", encoding="utf-8"
        )
        res = _run_cli(
            "assemble",
            "--dir",
            str(self.frag_dir),
            "--changelog",
            str(self.changelog),
            cwd=self.root,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("folded 1 fragment(s)", res.stdout)
        self.assertNotIn("exempt", res.stdout)
        self.assertIn("- Add feature (#300).", self.changelog.read_text(encoding="utf-8"))
        self.assertFalse((self.frag_dir / "300.md").exists())


CHANGELOG_WITH_SECTION = (
    "# Changelog\n\n"
    "## [Unreleased]\n\n"
    "## [0.2.0] - 2026-02-02\n\n"
    "### Summary\n\n"
    "- Ships two fixes (#1).\n"
    "\n"
    "### Added\n\n"
    "- Existing feature (#2).\n"
    "\n"
    "### Changed\n\n"
    "- TBD\n"
    "\n"
    "### Deprecated\n\n"
    "- TBD\n"
    "\n"
    "## [0.1.0] - 2026-01-01\n\n"
    "### Fixed\n\n"
    "- First (#3).\n"
)


class FoldedTests(unittest.TestCase):
    """`folded`: a fragment already owning a CHANGELOG entry is history."""

    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory(prefix="masc-changelog-folded-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.frag_dir = self.root / "changelog.d"
        self.frag_dir.mkdir()
        (self.frag_dir / "README.md").write_text("readme\n", encoding="utf-8")
        self.changelog = self.root / "CHANGELOG.md"
        self.changelog.write_text(
            "# Changelog\n\n"
            "## [Unreleased]\n\n"
            "## [0.1.0] - 2026-01-01\n\n"
            "### Fixed\n\n"
            "- Resolved the race (#10).\n"
            "- Hardened the retry path (#12, fixes #11).\n",
            encoding="utf-8",
        )
        for number in (10, 11, 12):
            (self.frag_dir / f"{number}.md").write_text(
                f"### Fixed\n\n- Fix {number} (#{number}).\n", encoding="utf-8"
            )

    def folded(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return _run_cli(
            "folded", "--dir", str(self.frag_dir), "--changelog", str(self.changelog),
            *extra, cwd=self.root,
        )

    def test_owner_citation_counts_passing_mention_does_not(self) -> None:
        res = self.folded()
        self.assertEqual(res.returncode, 0, res.stderr)
        # #10 and #12 own entries; #11 is named inside #12's entry only.
        self.assertIn("changelog.d/10.md", res.stdout)
        self.assertIn("changelog.d/12.md", res.stdout)
        self.assertIn("CHANGELOG.md:9", res.stdout)
        self.assertNotIn("changelog.d/11.md", res.stdout)
        self.assertIn("2 fragment(s) already folded", res.stdout)
        self.assertIn("1 not folded", res.stdout)

    def test_strict_exits_3_while_any_remain_and_zero_after_delete(self) -> None:
        strict = self.folded("--strict")
        self.assertEqual(strict.returncode, 3, strict.stderr)
        deleted = self.folded("--delete")
        self.assertEqual(deleted.returncode, 0, deleted.stderr)
        self.assertIn(f"deleted {self.frag_dir / '10.md'}", deleted.stdout)
        self.assertFalse((self.frag_dir / "10.md").exists())
        self.assertFalse((self.frag_dir / "12.md").exists())
        self.assertTrue((self.frag_dir / "11.md").exists())
        again = self.folded("--strict")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("0 fragment(s) already folded", again.stdout)


class AssembleIntoTests(unittest.TestCase):
    """`assemble --into V`: fold straight into the existing [V] section."""

    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory(prefix="masc-changelog-into-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.frag_dir = self.root / "changelog.d"
        self.frag_dir.mkdir()
        (self.frag_dir / "README.md").write_text("readme\n", encoding="utf-8")
        self.changelog = self.root / "CHANGELOG.md"
        self.changelog.write_text(CHANGELOG_WITH_SECTION, encoding="utf-8")

    def assemble_into(self, version: str, *extra: str) -> subprocess.CompletedProcess[str]:
        return _run_cli(
            "assemble", "--dir", str(self.frag_dir), "--changelog", str(self.changelog),
            "--into", version, *extra, cwd=self.root,
        )

    def section_body(self, heading: str) -> str:
        text = self.changelog.read_text(encoding="utf-8")
        start = text.index(f"## [{heading}]")
        end = text.find("## [", start + 1)
        return text[start:] if end == -1 else text[start:end]

    def test_appends_within_existing_sections_and_keeps_heading_order(self) -> None:
        (self.frag_dir / "5.md").write_text(
            "### Added\n\n- New feature (#5).\n\n### Fixed\n\n- Repair (#5).\n",
            encoding="utf-8",
        )
        res = self.assemble_into("0.2.0")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("folded 1 fragment(s) into ## [0.2.0]", res.stdout)
        body = self.section_body("0.2.0")
        # The hand-written summary stays first; Added appends, Fixed is new.
        self.assertLess(body.index("### Summary"), body.index("### Added"))
        self.assertLess(body.index("### Added"), body.index("### Changed"))
        self.assertLess(body.index("### Deprecated"), body.index("### Fixed"))
        self.assertIn("- Existing feature (#2).", body)
        self.assertLess(body.index("- Existing feature (#2)."), body.index("- New feature (#5)."))
        # The untouched TBD-only sections keep their placeholders.
        self.assertIn("- TBD", body)

    def test_tbd_placeholder_replaced_only_where_real_bullets_arrive(self) -> None:
        (self.frag_dir / "6.md").write_text(
            "### Changed\n\n- Real change (#6).\n", encoding="utf-8"
        )
        res = self.assemble_into("0.2.0")
        self.assertEqual(res.returncode, 0, res.stderr)
        body = self.section_body("0.2.0")
        self.assertIn("### Changed\n\n- Real change (#6).\n", body)
        self.assertNotIn("### Changed\n\n- TBD", body)
        self.assertIn("### Deprecated\n\n- TBD\n", body)

    def test_moves_unreleased_bullets_and_empties_unreleased(self) -> None:
        self.changelog.write_text(
            "# Changelog\n\n"
            "## [Unreleased]\n\n"
            "### Fixed\n\n"
            "- Waiting fix (#7).\n\n"
            "## [0.2.0] - 2026-02-02\n\n"
            "### Added\n\n"
            "- Existing feature (#2).\n",
            encoding="utf-8",
        )
        (self.frag_dir / "8.md").write_text(
            "### Fixed\n\n- Later fix (#8).\n", encoding="utf-8"
        )
        res = self.assemble_into("0.2.0")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("moved 1 [Unreleased] bullet(s)", res.stdout)
        self.assertIn("- Waiting fix (#7).", self.section_body("0.2.0"))
        self.assertIn("- Later fix (#8).", self.section_body("0.2.0"))
        self.assertLess(
            self.section_body("0.2.0").index("- Waiting fix (#7)."),
            self.section_body("0.2.0").index("- Later fix (#8)."),
        )
        text = self.changelog.read_text(encoding="utf-8")
        unreleased = text[text.index("## [Unreleased]"):text.index("## [0.2.0]")]
        self.assertNotIn("- ", unreleased)

    def test_dedupes_a_bullet_the_section_already_carries(self) -> None:
        (self.frag_dir / "2.md").write_text(
            "### Added\n\n- Existing feature (#2).\n", encoding="utf-8"
        )
        res = self.assemble_into("0.2.0")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertEqual(self.section_body("0.2.0").count("- Existing feature (#2)."), 1)

    def test_missing_target_section_fails_closed_and_keeps_fragments(self) -> None:
        fragment = self.frag_dir / "9.md"
        fragment.write_text("### Fixed\n\n- Repair (#9).\n", encoding="utf-8")
        before = self.changelog.read_bytes()
        res = self.assemble_into("9.9.9")
        self.assertEqual(res.returncode, 1)
        self.assertIn("no section '## [9.9.9]'", res.stderr)
        self.assertTrue(fragment.exists())
        self.assertEqual(self.changelog.read_bytes(), before)

    def test_into_unreleased_refused_and_nothing_is_touched(self) -> None:
        # The gap slice assumes the target section comes after [Unreleased];
        # --into Unreleased would silently reorder sections, so it must be
        # refused with fragments and changelog both intact.
        fragment = self.frag_dir / "21.md"
        fragment.write_text("### Fixed\n\n- Repair (#21).\n", encoding="utf-8")
        before = self.changelog.read_bytes()
        res = self.assemble_into("Unreleased")
        self.assertEqual(res.returncode, 1)
        self.assertIn("must come after '## [Unreleased]'", res.stderr)
        self.assertTrue(fragment.exists())
        self.assertEqual(self.changelog.read_bytes(), before)

    def test_assemble_replaces_changelog_atomically_and_leaves_no_temp(self) -> None:
        (self.frag_dir / "22.md").write_text(
            "### Added\n\n- Atomic fold (#22).\n", encoding="utf-8"
        )
        res = self.assemble_into("0.2.0")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("- Atomic fold (#22).", self.section_body("0.2.0"))
        # The fold went through a sibling temp file and os.replace: no
        # *.tmp litter may survive a successful run.
        self.assertFalse((self.root / "CHANGELOG.md.tmp").exists())
        self.assertEqual(list(self.root.glob("*.tmp")), [])

    def test_exempt_only_deletes_and_leaves_changelog_unchanged(self) -> None:
        (self.frag_dir / "4.md").write_text(
            "### Exempt\n\n- Docs only (#4).\n", encoding="utf-8"
        )
        before = self.changelog.read_bytes()
        res = self.assemble_into("0.2.0")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("removed 1 exempt fragment(s)", res.stdout)
        self.assertIn("unchanged", res.stdout)
        self.assertEqual(self.changelog.read_bytes(), before)
        self.assertFalse((self.frag_dir / "4.md").exists())


class MissingAndBumpIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory(prefix="masc-changelog-missing-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.env = {
            "PATH": os.environ["PATH"],
            "HOME": str(self.root),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "changelog test",
            "GIT_AUTHOR_EMAIL": "changelog-test@example.invalid",
            "GIT_COMMITTER_NAME": "changelog test",
            "GIT_COMMITTER_EMAIL": "changelog-test@example.invalid",
        }
        self._git("init", "--quiet", "--initial-branch=main")
        (self.root / "scripts").mkdir()
        for name in ("bump-version.sh", "changelog-fragments.py"):
            shutil.copy2(SCRIPTS / name, self.root / "scripts" / name)
        self._write("scripts/changelog-fragments-exempt.txt", "# legacy\n50001  # legacy docs\n")
        self._write("CHANGELOG.md", CHANGELOG_TEMPLATE)
        self._write("changelog.d/README.md", "fragments\n")
        self._write("dune-project", "(lang dune 3.0)\n(version 0.1.0)\n")
        self.base = self._commit("chore(release): bump version to 0.1.0 (#1)")
        self._git("tag", "v0.1.0")

    def _git(self, *args: str) -> str:
        return subprocess.run(
            ["git", *args],
            cwd=self.root,
            env=self.env,
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()

    def _write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def _commit(self, subject: str) -> str:
        self._git("add", "--all")
        self._git("commit", "--quiet", "--allow-empty", "-m", subject)
        return self._git("rev-parse", "HEAD")

    def test_missing_strict_accepts_per_pr_exempt_and_legacy_and_rejects_unexempt(self) -> None:
        # PR #50001: legacy exempt file (no changelog.d/50001.md)
        self._write("docs/legacy.md", "legacy\n")
        self._commit("docs: legacy exemption (#50001)")

        # PR #54014: per-PR ### Exempt fragment
        self._write("docs/per-pr.md", "per-pr\n")
        self._write(
            "changelog.d/54014.md",
            "### Exempt\n\n- Docs only: per-PR exemption (#54014).\n",
        )
        self._commit("docs: per-PR exemption (#54014)")

        res_ok = subprocess.run(
            [
                sys.executable,
                "scripts/changelog-fragments.py",
                "missing",
                "--base",
                self.base,
                "--dir",
                "changelog.d",
                "--strict",
            ],
            cwd=self.root,
            env=self.env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(res_ok.returncode, 0, res_ok.stdout + res_ok.stderr)
        self.assertIn("#50001", res_ok.stdout)
        self.assertIn("(exempt)", res_ok.stdout)
        self.assertNotIn("#54014", res_ok.stdout)

        # PR #54099: neither fragment nor legacy exemption -> exit 3
        self._write("src/untracked.txt", "oops\n")
        self._commit("feat: untracked change (#54099)")
        res_fail = subprocess.run(
            [
                sys.executable,
                "scripts/changelog-fragments.py",
                "missing",
                "--base",
                self.base,
                "--dir",
                "changelog.d",
                "--strict",
            ],
            cwd=self.root,
            env=self.env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(res_fail.returncode, 3, res_fail.stdout + res_fail.stderr)
        self.assertIn("#54099", res_fail.stdout)

    def test_bump_version_end_to_end_mixed_release_and_exempt(self) -> None:
        self._write("src/fix.txt", "fix\n")
        self._write(
            "changelog.d/54010.md",
            "### Fixed\n\n- Fix timeout handling (#54010).\n",
        )
        self._commit("fix: timeout handling (#54010)")

        self._write("docs/guide.md", "guide\n")
        self._write(
            "changelog.d/54014.md",
            "### Exempt\n\n- Docs only: update guide (#54014).\n",
        )
        self._commit("docs: update guide (#54014)")

        res = subprocess.run(
            ["bash", "scripts/bump-version.sh", "0.2.0"],
            cwd=self.root,
            env=self.env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        changelog = (self.root / "CHANGELOG.md").read_text(encoding="utf-8")
        self.assertIn("- Fix timeout handling (#54010).", changelog)
        self.assertNotIn("Exempt", changelog)
        self.assertNotIn("#54014", changelog)
        self.assertFalse((self.root / "changelog.d" / "54010.md").exists())
        self.assertFalse((self.root / "changelog.d" / "54014.md").exists())

    def test_bump_version_end_to_end_exempt_only_and_malformed_exempt(self) -> None:
        self._write("docs/only.md", "only\n")
        self._write(
            "changelog.d/54020.md",
            "### Exempt\n\n- (#54020).\n",
        )
        self._commit("docs: bad exempt (#54020)")

        bad = subprocess.run(
            ["bash", "scripts/bump-version.sh", "0.2.0"],
            cwd=self.root,
            env=self.env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(bad.returncode, 1)
        self.assertIn("exempt bullet must state a reason", bad.stderr)
        self.assertEqual(self._git("status", "--porcelain"), "")

        self._write(
            "changelog.d/54020.md",
            "### Exempt\n\n- Docs only: add doc note (#54020).\n",
        )
        self._commit("docs: fix exempt reason (#54020)")

        good = subprocess.run(
            ["bash", "scripts/bump-version.sh", "0.2.0"],
            cwd=self.root,
            env=self.env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(good.returncode, 0, good.stdout + good.stderr)
        self.assertFalse((self.root / "changelog.d" / "54020.md").exists())
        changelog = (self.root / "CHANGELOG.md").read_text(encoding="utf-8")
        self.assertNotIn("Exempt", changelog)
        self.assertNotIn("#54020", changelog)


    def test_bump_folds_straight_into_the_version_section(self) -> None:
        self._write("src/fix.txt", "fix\n")
        self._write(
            "changelog.d/54011.md",
            "### Fixed\n\n- Repair the fold base scan (#54011).\n",
        )
        self._commit("fix: fold base scan (#54011)")

        res = subprocess.run(
            ["bash", "scripts/bump-version.sh", "0.2.0"],
            cwd=self.root, env=self.env, text=True, capture_output=True,
        )
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        changelog = (self.root / "CHANGELOG.md").read_text(encoding="utf-8")
        self.assertIn("## [0.2.0]", changelog)
        self.assertIn("- Repair the fold base scan (#54011).", changelog)
        # The entry sits in the release section, not in [Unreleased].
        section = changelog[changelog.index("## [0.2.0]"):changelog.index("## [0.1.0]")]
        self.assertIn("- Repair the fold base scan (#54011).", section)
        unreleased = changelog[: changelog.index("## [0.2.0]")]
        self.assertNotIn("- ", unreleased)
        self.assertNotIn("- TBD", changelog)
        self.assertFalse((self.root / "changelog.d" / "54011.md").exists())

    def test_bump_refuses_while_a_fragment_is_already_folded(self) -> None:
        # A release folded elsewhere left the fragment behind while its entry
        # is already in CHANGELOG.md: folding again would duplicate it.
        self._write(
            "CHANGELOG.md",
            "# Changelog\n\n## [Unreleased]\n\n## [0.1.0] - 2026-01-01\n\n"
            "### Fixed\n\n- Already shipped (#54030).\n",
        )
        self._write(
            "changelog.d/54030.md",
            "### Fixed\n\n- Already shipped (#54030).\n",
        )
        self._commit("fix: already shipped elsewhere (#54030)")

        res = subprocess.run(
            ["bash", "scripts/bump-version.sh", "0.2.0"],
            cwd=self.root, env=self.env, text=True, capture_output=True,
        )
        self.assertEqual(res.returncode, 1, res.stdout)
        self.assertIn("already folded into CHANGELOG.md", res.stderr)
        self.assertIn("changelog.d/54030.md", res.stderr)
        self.assertEqual(self._git("status", "--porcelain"), "")
        self.assertTrue((self.root / "changelog.d" / "54030.md").exists())


if __name__ == "__main__":
    unittest.main()

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


if __name__ == "__main__":
    unittest.main()

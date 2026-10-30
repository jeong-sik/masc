"""check-files diagnostics render as workflow error annotations."""
import importlib.util
import os
import pathlib
import sys
import tempfile
import unittest

CI = pathlib.Path(__file__).resolve().parents[2]  # scripts/
spec = importlib.util.spec_from_file_location(
    "changelog_fragments", CI / "changelog-fragments.py"
)
assert spec is not None and spec.loader is not None
fragments = importlib.util.module_from_spec(spec)
sys.modules["changelog_fragments"] = fragments
spec.loader.exec_module(fragments)


class WorkflowError(unittest.TestCase):
    def test_location_with_line(self):
        self.assertEqual(
            fragments.workflow_error(
                "changelog.d/45552.md:3: bullet does not cite #45552: - text"
            ),
            "::error file=changelog.d/45552.md,line=3::bullet does not cite #45552: - text",
        )

    def test_location_without_line(self):
        self.assertEqual(
            fragments.workflow_error("changelog.d/45552.md: not in the tree"),
            "::error file=changelog.d/45552.md::not in the tree",
        )

    def test_other_message_is_fileless(self):
        self.assertEqual(
            fragments.workflow_error("weird: not a fragment path"),
            "::error::weird: not a fragment path",
        )

    def test_literal_percent_sequences_survive_round_trip(self):
        self.assertEqual(
            fragments.workflow_error("changelog.d/x.md:3: bullet cites %0A literal"),
            "::error file=changelog.d/x.md,line=3::bullet cites %250A literal",
        )

    def test_comma_and_colon_in_property_escaped(self):
        self.assertEqual(
            fragments.workflow_error("changelog.d/a,b.md:2: detail"),
            "::error file=changelog.d/a%2Cb.md,line=2::detail",
        )


class CheckFilesAnnotation(unittest.TestCase):
    def run_in_fragment_tree(self, name: str, text: str) -> str:
        """Run check_files on one fragment inside a temporary tree."""
        captured: list[str] = []
        real_print = print

        def capture(text: str) -> None:
            captured.append(text)

        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "changelog.d").mkdir()
            (root / "changelog.d" / name).write_text(text, encoding="utf-8")
            cwd = pathlib.Path.cwd()
            os.chdir(root)
            fragments.print = capture  # type: ignore[assignment]
            try:
                with self.assertRaises(fragments.FragmentError):
                    fragments.check_files([f"changelog.d/{name}"])
            finally:
                fragments.print = real_print  # type: ignore[assignment]
                os.chdir(cwd)
        self.assertTrue(captured, "no workflow annotation was printed")
        return "\n".join(captured)

    def test_bullet_missing_cite_reports_line(self):
        printed = self.run_in_fragment_tree(
            "45552.md", "### Internal\n\n- A bullet with no citation.\n"
        )
        self.assertIn("::error file=changelog.d/45552.md,line=3::", printed)

    def test_bad_section_reports_line(self):
        printed = self.run_in_fragment_tree(
            "45552.md", "### Safety\n\n- Wrong section. (#45552)\n"
        )
        self.assertIn("::error file=changelog.d/45552.md,line=1::", printed)
        self.assertIn("expected '### <Section>'", printed)

    def test_good_fragment_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / "changelog.d").mkdir()
            (root / "changelog.d" / "45552.md").write_text(
                "### Internal\n\n- A cited change. (#45552)\n", encoding="utf-8"
            )
            cwd = pathlib.Path.cwd()
            os.chdir(root)
            try:
                self.assertEqual(
                    fragments.check_files(["changelog.d/45552.md"]), 0
                )
            finally:
                os.chdir(cwd)


if __name__ == "__main__":
    unittest.main()

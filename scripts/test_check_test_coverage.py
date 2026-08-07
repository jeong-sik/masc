#!/usr/bin/env python3
import contextlib
import io
import os
import sys
import unittest
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, os.path.dirname(__file__))

import check_test_coverage as coverage


class CheckTestCoverageTest(unittest.TestCase):
    def test_opt_out_commit_uses_pr_side_commit_range(self):
        calls = []

        def fake_run(args, **kwargs):
            calls.append(args)
            return SimpleNamespace(stdout="", stderr="")

        with mock.patch.dict(os.environ, {"GITHUB_BASE_REF": "main"}, clear=False):
            with mock.patch("subprocess.run", side_effect=fake_run):
                self.assertFalse(coverage.is_opt_out_commit())

        self.assertEqual(
            calls[0],
            ["git", "log", "origin/main..HEAD", "--format=%s%n%b"],
        )

    def test_changed_covered_files_include_dashboard_and_config(self):
        with mock.patch(
            "check_test_coverage.run_diff_or_fail",
            return_value="lib/a.ml\ndashboard/app.ts\nconfig/runtime.toml\n",
        ) as run_diff:
            with mock.patch.dict(os.environ, {"GITHUB_BASE_REF": "main"}, clear=False):
                with mock.patch(
                    "check_test_coverage.is_dependency_metadata_only",
                    return_value=False,
                ):
                    self.assertEqual(
                        coverage.get_changed_covered_files(),
                        ["lib/a.ml", "dashboard/app.ts", "config/runtime.toml"],
                    )

        self.assertEqual(
            run_diff.call_args.args[0],
            [
                "git",
                "diff",
                "--name-only",
                "origin/main...HEAD",
                "--",
                "lib/",
                "dashboard/",
                "config/",
            ],
        )

    def test_is_covered_code_file_predicate(self):
        # CSS/HTML/MD/images are non-code assets — excluded from covered paths.
        # Config/data formats stay covered (out of scope here, see #23083).
        self.assertFalse(
            coverage.is_covered_code_file("dashboard/src/styles/app-shell-v2.css")
        )
        self.assertFalse(coverage.is_covered_code_file("lib/README.md"))
        self.assertFalse(coverage.is_covered_code_file("lib/notes.txt"))
        self.assertFalse(coverage.is_covered_code_file("dashboard/public/icon.png"))
        self.assertFalse(coverage.is_covered_code_file("dashboard/index.html"))
        self.assertFalse(coverage.is_covered_code_file("dashboard/public/font.woff2"))
        self.assertTrue(coverage.is_covered_code_file("lib/app.ml"))
        self.assertTrue(coverage.is_covered_code_file("dashboard/app.ts"))
        self.assertTrue(coverage.is_covered_code_file("config/runtime.toml"))
        self.assertTrue(coverage.is_covered_code_file("dashboard/package-lock.json"))
        # Build configuration has no suffix, so the suffix policy cannot
        # express it; no unit test can exercise a dune stanza.
        self.assertFalse(coverage.is_covered_code_file("lib/board/dune"))
        self.assertFalse(coverage.is_covered_code_file("dune-project"))
        # A file merely named like one stays covered.
        self.assertTrue(coverage.is_covered_code_file("lib/dune_helpers.ml"))

    def test_non_code_suffixes_come_from_repo_policy_file(self):
        self.assertEqual(
            coverage.load_non_code_suffixes(),
            coverage.NON_CODE_SUFFIXES,
        )
        self.assertIn(".css", coverage.NON_CODE_SUFFIXES)
        self.assertIn(".woff2", coverage.NON_CODE_SUFFIXES)

    def test_non_code_assets_excluded_from_covered_files(self):
        # Regression for #23082: a CSS-only dashboard PR must not be flagged as
        # "covered code with no test". Non-code assets are filtered out before
        # the added-line count, so only real code files remain.
        with mock.patch(
            "check_test_coverage.run_diff_or_fail",
            return_value=(
                "dashboard/src/styles/app-shell-v2.css\n"
                "dashboard/index.html\n"
                "lib/README.md\n"
                "dashboard/public/logo.svg\n"
                "lib/app.ml\n"
            ),
        ):
            with mock.patch.dict(os.environ, {"GITHUB_BASE_REF": "main"}, clear=False):
                with mock.patch(
                    "check_test_coverage.is_dependency_metadata_only",
                    return_value=False,
                ):
                    self.assertEqual(
                        coverage.get_changed_covered_files(),
                        ["lib/app.ml"],
                    )

    def test_exact_dependency_lockfiles_are_metadata_not_source(self):
        for path in (
            "dashboard/pnpm-lock.yaml",
            "web/package-lock.json",
            "ui/yarn.lock",
        ):
            self.assertTrue(coverage.is_dependency_metadata_only(path))
        self.assertFalse(coverage.is_dependency_metadata_only("config/runtime.yaml"))
        self.assertFalse(
            coverage.is_dependency_metadata_only("dashboard/package-data.json")
        )

    def test_package_manifest_dependency_only_change_is_metadata(self):
        base = {
            "name": "dashboard",
            "scripts": {"test": "vitest"},
            "devDependencies": {"postcss": "8.5.18"},
        }
        head = {
            "name": "dashboard",
            "scripts": {"test": "vitest"},
            "devDependencies": {"postcss": "8.5.23"},
        }
        with mock.patch(
            "check_test_coverage.read_json_at_revision", side_effect=[base, head]
        ):
            self.assertTrue(
                coverage.is_dependency_metadata_only("dashboard/package.json")
            )

    def test_package_manifest_script_change_remains_covered(self):
        base = {
            "name": "dashboard",
            "scripts": {"test": "vitest"},
            "devDependencies": {"postcss": "8.5.18"},
        }
        head = {
            "name": "dashboard",
            "scripts": {"test": "vitest --watch"},
            "devDependencies": {"postcss": "8.5.23"},
        }
        with mock.patch(
            "check_test_coverage.read_json_at_revision", side_effect=[base, head]
        ):
            self.assertFalse(
                coverage.is_dependency_metadata_only("dashboard/package.json")
            )

    def test_test_file_predicate_does_not_match_production_checks(self):
        self.assertFalse(coverage.is_test_file("lib/exec/capability_check_typed.ml"))
        self.assertFalse(
            coverage.is_test_file("lib/keeper/keeper_registry_event_validators.ml")
        )
        self.assertTrue(coverage.is_test_file("test/test_keeper_sandbox.ml"))
        self.assertTrue(coverage.is_test_file("lib/exec/test/test_exec_dispatch.ml"))
        self.assertTrue(coverage.is_test_file("scripts/test_check_test_coverage.py"))
        self.assertTrue(coverage.is_test_file("dashboard/App.spec.tsx"))

    def test_changed_test_files_filters_production_check_and_validator_modules(self):
        changed = "\n".join(
            [
                "lib/exec/capability_check_typed.ml",
                "lib/keeper/keeper_registry_event_validators.ml",
                "test/test_keeper_sandbox.ml",
                "scripts/test_check_test_coverage.py",
                "",
            ]
        )
        with mock.patch("check_test_coverage.run_diff_or_fail", return_value=changed):
            self.assertEqual(
                coverage.get_changed_test_files(),
                ["test/test_keeper_sandbox.ml", "scripts/test_check_test_coverage.py"],
            )

    def test_dashboard_changes_without_tests_trigger_coverage_violation(self):
        with mock.patch.dict(os.environ, {"PR_BODY": ""}, clear=False):
            with mock.patch(
                "check_test_coverage.is_opt_out_commit", return_value=False
            ):
                with mock.patch(
                    "check_test_coverage.get_changed_covered_files",
                    return_value=["dashboard/app.ts"],
                ):
                    with mock.patch(
                        "check_test_coverage.get_changed_test_files", return_value=[]
                    ):
                        with mock.patch(
                            "check_test_coverage.get_added_lines_count", return_value=11
                        ):
                            with self.assertRaises(SystemExit) as raised:
                                with contextlib.redirect_stdout(io.StringIO()):
                                    coverage.check_coverage()

        self.assertEqual(raised.exception.code, 1)

    def test_many_code_file_deletions_without_tests_do_not_trigger_rule_2(self):
        code_files = ["lib/a.ml", "lib/b.ml", "lib/c.ml", "lib/d.ml"]
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"PR_BODY": ""}, clear=False):
            with mock.patch(
                "check_test_coverage.is_opt_out_commit", return_value=False
            ):
                with mock.patch(
                    "check_test_coverage.get_changed_covered_files",
                    return_value=code_files,
                ):
                    with mock.patch(
                        "check_test_coverage.get_changed_test_files", return_value=[]
                    ):
                        with mock.patch(
                            "check_test_coverage.get_added_lines_count", return_value=0
                        ):
                            with self.assertRaises(SystemExit) as raised:
                                with contextlib.redirect_stdout(out):
                                    coverage.check_coverage()

        self.assertEqual(raised.exception.code, 0)
        self.assertIn("Test coverage check passed.", out.getvalue())

    def test_many_code_files_with_additions_without_tests_trigger_rule_2(self):
        code_files = ["lib/a.ml", "lib/b.ml", "lib/c.ml", "lib/d.ml"]
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"PR_BODY": ""}, clear=False):
            with mock.patch(
                "check_test_coverage.is_opt_out_commit", return_value=False
            ):
                with mock.patch(
                    "check_test_coverage.get_changed_covered_files",
                    return_value=code_files,
                ):
                    with mock.patch(
                        "check_test_coverage.get_changed_test_files", return_value=[]
                    ):
                        with mock.patch(
                            "check_test_coverage.get_added_lines_count", return_value=1
                        ):
                            with self.assertRaises(SystemExit) as raised:
                                with contextlib.redirect_stdout(out):
                                    coverage.check_coverage()

        self.assertEqual(raised.exception.code, 1)
        self.assertIn("Changed 4 files", out.getvalue())


class CommentLineNumbersTest(unittest.TestCase):
    """A docstring is not code the gate can ask for a test of.

    Every `+` line used to count, so a documentation-only change to an .mli
    could not satisfy this rule at all — the only way past was the manual
    `# ci:skip-test-coverage` marker, used once in the last 200 commits.

    These are the cases a line-oriented regex gets wrong: most of a docstring
    is continuation lines carrying no marker, and OCaml block comments nest.
    """

    def assert_comment_lines(self, suffix, text, expected, label):
        self.assertEqual(
            coverage.comment_line_numbers(text, suffix), expected, msg=label
        )

    def test_block_continuation_lines_are_comment(self):
        self.assert_comment_lines(
            ".mli",
            "(** doc\n    more doc\n    still doc *)\nval f : int",
            {1, 2, 3},
            "continuation lines carry no marker of their own",
        )

    def test_trailing_comment_does_not_make_the_line_comment(self):
        self.assert_comment_lines(
            ".ml",
            "let x = 1 (* note *)\n(* pure *)\nlet y = 2",
            {2},
            "code with a trailing comment is still code",
        )

    def test_ocaml_block_comments_nest(self):
        self.assert_comment_lines(
            ".ml",
            "(* outer (* inner *) still outer *)\nlet z = 3",
            {1},
            "the inner close must not end the outer comment",
        )

    def test_code_shaped_text_inside_a_comment_is_comment(self):
        self.assert_comment_lines(
            ".ml",
            "(* a\nlet fake = 1\n*)\nlet real = 2",
            {1, 2, 3},
            "a commented-out binding is not an added code line",
        )

    def test_typescript_line_and_block_comments(self):
        self.assert_comment_lines(
            ".ts",
            "// line\nconst a = 1\n/* b\n c */\nconst d = 2",
            {1, 3, 4},
            "both comment forms",
        )

    def test_typescript_trailing_line_comment_is_code(self):
        self.assert_comment_lines(
            ".ts", "const a = 1 // trailing", set(), "trailing // is not comment-only"
        )

    def test_suffix_without_comment_syntax_counts_every_line(self):
        self.assert_comment_lines(
            ".json", '{"a": 1}', set(), "unknown suffix stays conservative"
        )


if __name__ == "__main__":
    unittest.main()

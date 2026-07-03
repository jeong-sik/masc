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
        self.assertFalse(coverage.is_covered_code_file("dashboard/src/styles/app-shell-v2.css"))
        self.assertFalse(coverage.is_covered_code_file("lib/README.md"))
        self.assertFalse(coverage.is_covered_code_file("dashboard/public/icon.png"))
        self.assertFalse(coverage.is_covered_code_file("dashboard/index.html"))
        self.assertTrue(coverage.is_covered_code_file("lib/app.ml"))
        self.assertTrue(coverage.is_covered_code_file("dashboard/app.ts"))
        self.assertTrue(coverage.is_covered_code_file("config/runtime.toml"))

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
                self.assertEqual(
                    coverage.get_changed_covered_files(),
                    ["lib/app.ml"],
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
            with mock.patch("check_test_coverage.is_opt_out_commit", return_value=False):
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
            with mock.patch("check_test_coverage.is_opt_out_commit", return_value=False):
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
            with mock.patch("check_test_coverage.is_opt_out_commit", return_value=False):
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


if __name__ == "__main__":
    unittest.main()

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


if __name__ == "__main__":
    unittest.main()

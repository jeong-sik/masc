"""Publication must not turn a partial behavior run into release approval."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

CI = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CI))
load_profile = importlib.import_module("release_behavior").load_profile

spec = importlib.util.spec_from_file_location(
    "publication", CI / "prepare-release-publication.py")
assert spec is not None and spec.loader is not None
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


class ReleaseBehavior(unittest.TestCase):
    def setUp(self):
        self.candidate_run = {"head_sha": "a" * 40, "run_attempt": 2, "id": 123}
        self.receipt = {
            "schema_version": 2, "commit": self.candidate_run["head_sha"],
            "run_attempt": 2,
            "run_url": "https://github.com/jeong-sik/masc/actions/runs/123",
            "checks_passed": True, "published": False,
            "results": dict(compile="success", behavior="success", installation="success"),
            "behavior_scope": load_profile(),
        }

    def validate(self, receipt):
        publication.validate_receipt(receipt, self.candidate_run, "jeong-sik/masc")

    def test_current_complete_profile_is_admitted(self):
        self.validate(self.receipt)

    def test_green_job_cannot_hide_missing_or_changed_suites(self):
        profile = load_profile()
        for field, replacement in (
            ("suites", []), ("suites", profile["suites"][:-1]),
            ("suites", [*profile["suites"], "test_unreviewed"]),
            ("manifest_sha256", "0" * 64), ("profile", "full"),
        ):
            with self.subTest(field=field, replacement=replacement):
                receipt = copy.deepcopy(self.receipt)
                receipt["behavior_scope"][field] = replacement
                with self.assertRaisesRegex(ValueError, "behavior selection"):
                    self.validate(receipt)

    def test_old_or_missing_scope_is_not_reinterpreted(self):
        for scope in (None, "full Test workflow with the checked-in known-failure policy"):
            receipt = copy.deepcopy(self.receipt)
            receipt["behavior_scope"] = scope
            with self.assertRaises(ValueError):
                self.validate(receipt)
        receipt = dict(self.receipt, schema_version=1)
        with self.assertRaises(ValueError):
            self.validate(receipt)

    def test_profile_does_not_bypass_candidate_or_job_identity(self):
        for field, replacement in (
            ("commit", "b" * 40), ("run_attempt", 1),
            ("checks_passed", False),
            ("results", dict(compile="success", behavior="failure", installation="success")),
        ):
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    self.validate(dict(self.receipt, **{field: replacement}))

    def test_empty_or_duplicate_selection_never_means_full_suite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profile.json"
            for suites in ([], ["test_one", "test_one"], [""], ["test_one,test_two"]):
                path.write_text(json.dumps({"profile": "release-essential-v1", "suites": suites}))
                with self.assertRaises(ValueError):
                    load_profile(path)


if __name__ == "__main__":
    unittest.main()

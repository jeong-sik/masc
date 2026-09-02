import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import MappingProxyType


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = REPO_ROOT / "scripts" / "harness" / "workload" / "campaign_scoreboard.py"
CATALOG_PATH = (
    REPO_ROOT / "scripts" / "fixtures" / "keeper-multi-collaboration" / "missions.json"
)


def load_module():
    spec = importlib.util.spec_from_file_location("campaign_scoreboard", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


sb = load_module()

SHA = "a" * 40


def catalog_doc():
    return {
        "schema": sb.CATALOG_SCHEMA,
        "missions": [
            {"id": "M01", "phase": "bootstrap", "assertions": ["fleet_live"]},
            {"id": "M12", "phase": "verification", "assertions": ["v_first", "v_second"]},
            {"id": "M14", "phase": "verification", "assertions": ["v_third"]},
            {"id": "M20", "phase": "delivery_proof", "assertions": ["delivered"]},
            {"id": "M26", "phase": "claim_reproduction", "assertions": ["reproduced"]},
        ],
    }


def bundle_doc(run_id, failed=None, sha=SHA):
    failed = failed or {}
    missions = []
    for mission in catalog_doc()["missions"]:
        rows = [
            {"name": name, "passed": name not in failed.get(mission["id"], ())}
            for name in mission["assertions"]
        ]
        missions.append(
            {
                "id": mission["id"],
                "status": "passed" if all(r["passed"] for r in rows) else "failed",
                "assertions": rows,
            }
        )
    return {
        "schema": sb.BUNDLE_SCHEMA,
        "run_id": run_id,
        "source_sha": sha,
        "generated_at": f"2026-09-02T00:0{run_id[-1]}:00+00:00",
        "missions": missions,
    }


def residuals_doc(entries=(), sha=SHA):
    return {"schema": sb.RESIDUALS_SCHEMA, "source_sha": sha, "entries": list(entries)}


def entry(mission_id, assertion, cause="harness", issue="jeong-sik/masc#1"):
    return {
        "mission_id": mission_id,
        "assertion": assertion,
        "cause": cause,
        "issue": issue,
        "summary": "why it failed",
    }


def parse_all(bundles, residuals, previous=None, states=None):
    return sb.build_scoreboard(
        catalog=sb.parse_catalog(catalog_doc()),
        bundles=tuple(sb.parse_bundle(b, b["run_id"]) for b in bundles),
        residuals=sb.parse_residuals(residuals, "residuals"),
        previous_residuals=(
            sb.parse_residuals(previous, "previous") if previous is not None else None
        ),
        issue_states=MappingProxyType(states or {}),
        generated_at="2026-09-02T00:00:00+00:00",
    )


class BandsTest(unittest.TestCase):
    def test_bands_come_from_catalog_phases(self):
        catalog = sb.parse_catalog(catalog_doc())
        verification = [m.id for m in sb.band_missions(catalog, sb.VERIFICATION_BAND_PHASES)]
        pilot = [m.id for m in sb.band_missions(catalog, sb.PILOT_BAND_PHASES)]
        self.assertEqual(verification, ["M12", "M14", "M20"])
        self.assertEqual(pilot, ["M26"])

    def test_real_catalog_verification_band_is_the_planned_five(self):
        catalog = sb.parse_catalog(json.loads(CATALOG_PATH.read_text()))
        verification = [m.id for m in sb.band_missions(catalog, sb.VERIFICATION_BAND_PHASES)]
        pilot = [m.id for m in sb.band_missions(catalog, sb.PILOT_BAND_PHASES)]
        self.assertEqual(verification, ["RW12", "RW14", "RW15", "RW16", "RW20"])
        self.assertEqual(pilot, ["RW26"])


class ScoreTest(unittest.TestCase):
    def test_three_clean_runs_score_every_band_mission_and_count(self):
        board = parse_all([bundle_doc("r1"), bundle_doc("r2"), bundle_doc("r3")], residuals_doc())
        self.assertEqual(board["verification_band"]["k_of_3_passed"], 3)
        self.assertEqual(board["verification_band"]["mission_count"], 3)
        self.assertEqual(board["pilot_band"]["k_of_3_passed"], 1)
        self.assertTrue(board["counted"])
        self.assertEqual(board["counted_reason"], "ok")
        self.assertEqual(board["source_sha"], SHA)
        self.assertEqual(board["run_ids"], ["r1", "r2", "r3"])

    def test_one_failed_run_removes_the_mission_from_k_of_3(self):
        bundles = [bundle_doc("r1"), bundle_doc("r2", failed={"M12": ("v_second",)}), bundle_doc("r3")]
        board = parse_all(bundles, residuals_doc([entry("M12", "v_second")]))
        self.assertEqual(board["verification_band"]["passes_of_k"]["M12"], 2)
        self.assertEqual(board["verification_band"]["k_of_3_passed"], 2)
        self.assertTrue(board["counted"])

    def test_failed_assertion_without_cause_is_not_counted(self):
        bundles = [bundle_doc("r1"), bundle_doc("r2", failed={"M12": ("v_second",)}), bundle_doc("r3")]
        board = parse_all(bundles, residuals_doc())
        self.assertFalse(board["counted"])
        self.assertEqual(board["counted_reason"], "residual_unclassified")
        self.assertEqual(
            board["residuals"]["unclassified"],
            [{"mission_id": "M12", "assertion": "v_second", "run_id": "r2"}],
        )
        # An uncounted round carries no score; the raw number stays visible.
        self.assertIsNone(board["verification_band"]["k_of_3_passed"])
        self.assertEqual(board["verification_band"]["k_of_3_if_counted"], 2)

    def test_open_issue_from_previous_round_blocks_counting(self):
        bundles = [bundle_doc("r1"), bundle_doc("r2"), bundle_doc("r3")]
        previous = residuals_doc([entry("M14", "v_third", issue="jeong-sik/masc#28977")])
        board = parse_all(bundles, residuals_doc(), previous, {"jeong-sik/masc#28977": "OPEN"})
        self.assertFalse(board["counted"])
        self.assertEqual(board["counted_reason"], "previous_issue_open")
        self.assertIsNone(board["verification_band"]["k_of_3_passed"])
        self.assertEqual(board["pilot_band"]["k_of_3_passed"], None)
        self.assertEqual(
            board["previous_round_issues"], [{"issue": "jeong-sik/masc#28977", "state": "OPEN"}]
        )
        closed = parse_all(bundles, residuals_doc(), previous, {"jeong-sik/masc#28977": "CLOSED"})
        self.assertTrue(closed["counted"])

    def test_missing_issue_state_is_refused(self):
        bundles = [bundle_doc("r1"), bundle_doc("r2"), bundle_doc("r3")]
        previous = residuals_doc([entry("M14", "v_third", issue="jeong-sik/masc#28977")])
        with self.assertRaises(sb.ScoreboardError):
            parse_all(bundles, residuals_doc(), previous, {})


class RefusalTest(unittest.TestCase):
    def test_unknown_cause_is_refused(self):
        with self.assertRaises(sb.ScoreboardError):
            sb.parse_residuals(residuals_doc([entry("M12", "v_second", cause="flaky")]), "r")

    def test_mixed_source_sha_is_refused(self):
        bundles = [bundle_doc("r1"), bundle_doc("r2"), bundle_doc("r3", sha="b" * 40)]
        with self.assertRaises(sb.ScoreboardError):
            parse_all(bundles, residuals_doc())

    def test_two_runs_are_not_a_round(self):
        with self.assertRaises(sb.ScoreboardError):
            parse_all([bundle_doc("r1"), bundle_doc("r2")], residuals_doc())

    def test_duplicate_run_id_is_refused(self):
        with self.assertRaises(sb.ScoreboardError):
            parse_all([bundle_doc("r1"), bundle_doc("r1"), bundle_doc("r3")], residuals_doc())

    def test_residuals_for_another_sha_are_refused(self):
        bundles = [bundle_doc("r1"), bundle_doc("r2"), bundle_doc("r3")]
        with self.assertRaises(sb.ScoreboardError):
            parse_all(bundles, residuals_doc(sha="b" * 40))

    def test_status_label_that_disagrees_with_assertions_is_refused(self):
        doc = bundle_doc("r1")
        doc["missions"][1]["assertions"][1]["passed"] = False  # M12 v_second failed, label says passed
        with self.assertRaises(sb.ScoreboardError):
            sb.parse_bundle(doc, "r1")
        doc = bundle_doc("r1")
        doc["missions"][1]["status"] = "failed"  # label says failed, every assertion passed
        with self.assertRaises(sb.ScoreboardError):
            sb.parse_bundle(doc, "r1")

    def test_bundle_missing_a_catalog_assertion_is_refused(self):
        doc = bundle_doc("r2")
        doc["missions"][1]["assertions"] = doc["missions"][1]["assertions"][:1]  # drop v_second
        bundles = [bundle_doc("r1"), doc, bundle_doc("r3")]
        with self.assertRaises(sb.ScoreboardError):
            parse_all(bundles, residuals_doc())

    def test_issue_reference_must_be_owner_repo_number(self):
        for bad in ("#", "#12", "o/r #12", "o/r#12\n", "o/r#0", "or#12"):
            with self.assertRaises(sb.ScoreboardError, msg=bad):
                sb.parse_residuals(residuals_doc([entry("M12", "v_second", issue=bad)]), "r")
        ok = sb.parse_residuals(residuals_doc([entry("M12", "v_second", issue="jeong-sik/masc#28977")]), "r")
        self.assertEqual(ok.issues(), ("jeong-sik/masc#28977",))

    def test_non_string_issue_state_is_refused(self):
        doc = {"schema": sb.ISSUE_STATES_SCHEMA, "issues": {"o/r#1": ["OPEN"]}}
        with self.assertRaises(sb.ScoreboardError):
            sb.parse_issue_states(doc, "states")

    def test_empty_catalog_is_refused(self):
        with self.assertRaises(sb.ScoreboardError):
            sb.parse_catalog({"schema": sb.CATALOG_SCHEMA, "missions": []})

    def test_residual_outside_catalog_is_refused(self):
        bundles = [bundle_doc("r1"), bundle_doc("r2"), bundle_doc("r3")]
        with self.assertRaises(sb.ScoreboardError):
            parse_all(bundles, residuals_doc([entry("M99", "nothing")]))

    def test_wrong_bundle_schema_is_refused(self):
        doc = bundle_doc("r1")
        doc["schema"] = "something.else"
        with self.assertRaises(sb.ScoreboardError):
            sb.parse_bundle(doc, "r1")


class CliTest(unittest.TestCase):
    def test_cli_writes_scoreboard_and_reports_band(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "catalog.json").write_text(json.dumps(catalog_doc()))
            for run_id in ("r1", "r2", "r3"):
                (root / f"{run_id}.json").write_text(json.dumps(bundle_doc(run_id)))
            (root / "residuals.json").write_text(json.dumps(residuals_doc()))
            out = root / "scoreboard.json"
            code = sb.main(
                [
                    "--catalog", str(root / "catalog.json"),
                    "--bundle", str(root / "r1.json"),
                    "--bundle", str(root / "r2.json"),
                    "--bundle", str(root / "r3.json"),
                    "--residuals", str(root / "residuals.json"),
                    "--out", str(out),
                ]
            )
            self.assertEqual(code, 0)
            board = json.loads(out.read_text())
            self.assertEqual(board["schema"], sb.SCOREBOARD_SCHEMA)
            self.assertEqual(board["verification_band"]["k_of_3_passed"], 3)

    def test_cli_exit_code_two_on_bad_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "catalog.json").write_text(json.dumps(catalog_doc()))
            (root / "r1.json").write_text(json.dumps(bundle_doc("r1")))
            (root / "residuals.json").write_text(json.dumps(residuals_doc()))
            code = sb.main(
                [
                    "--catalog", str(root / "catalog.json"),
                    "--bundle", str(root / "r1.json"),
                    "--residuals", str(root / "residuals.json"),
                    "--out", str(root / "scoreboard.json"),
                ]
            )
            self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()

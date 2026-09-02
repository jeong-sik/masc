import contextlib
import importlib.util
import inspect
import io
import json
import re
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = (
    REPO_ROOT
    / "scripts"
    / "harness"
    / "workload"
    / "keeper_multi_collaboration_acceptance.py"
)
CATALOG_PATH = (
    REPO_ROOT
    / "scripts"
    / "fixtures"
    / "keeper-multi-collaboration"
    / "missions.json"
)


def load_acceptance_module():
    spec = importlib.util.spec_from_file_location(
        "keeper_multi_collaboration_acceptance",
        SCRIPT_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


acceptance = load_acceptance_module()


def skill_identity(name, *, source_id="fixture", package_id=None):
    return {
        "source_id": source_id,
        "package_id": package_id or name,
        "name": name,
    }


def skill_reference(name, revision, *, source_id="fixture", package_id=None):
    return {
        "identity": skill_identity(
            name,
            source_id=source_id,
            package_id=package_id,
        ),
        "content_revision": revision,
    }


def published_skill(name, revision, *, source_id="fixture", package_id=None):
    return skill_reference(
        name,
        revision,
        source_id=source_id,
        package_id=package_id,
    )


class KeeperMultiCollaborationAcceptanceTest(unittest.TestCase):
    def test_runtime_by_role_requires_exact_five_role_object(self):
        mapping = {
            "coordinator": "runtime-a",
            "builder-a": "runtime-b",
            "builder-b": "runtime-c",
            "reviewer": "runtime-d",
            "researcher": "runtime-e",
        }

        parsed = acceptance.parse_runtime_by_role(json.dumps(mapping))

        self.assertEqual(parsed, mapping)
        with self.assertRaisesRegex(acceptance.AcceptanceError, "exact five roles"):
            acceptance.parse_runtime_by_role(
                json.dumps({"coordinator": "runtime-a"})
            )

    def test_heterogeneous_runtime_mode_refuses_duplicates_and_fallback_mix(self):
        mapping = {
            "coordinator": "runtime-a",
            "builder-a": "runtime-b",
            "builder-b": "runtime-c",
            "reviewer": "runtime-d",
            "researcher": "runtime-e",
        }
        acceptance.validate_runtime_strategy(
            runtime_id=None,
            runtime_by_role=mapping,
            require_heterogeneous=True,
        )
        duplicate = dict(mapping)
        duplicate["researcher"] = "runtime-a"
        with self.assertRaisesRegex(acceptance.AcceptanceError, "five distinct"):
            acceptance.validate_runtime_strategy(
                runtime_id=None,
                runtime_by_role=duplicate,
                require_heterogeneous=True,
            )
        with self.assertRaisesRegex(acceptance.AcceptanceError, "mutually exclusive"):
            acceptance.validate_runtime_strategy(
                runtime_id="fallback",
                runtime_by_role=mapping,
                require_heterogeneous=False,
            )

    def test_runtime_strategy_receipt_is_exact_and_fail_closed(self):
        mapping = {
            "coordinator": "runtime-a",
            "builder-a": "runtime-b",
            "builder-b": "runtime-c",
            "reviewer": "runtime-d",
            "researcher": "runtime-e",
        }
        receipt = acceptance.runtime_strategy_receipt(
            runtime_id=None,
            runtime_by_role=mapping,
            require_heterogeneous=True,
        )
        self.assertEqual(receipt["runtime_strategy"], "heterogeneous_required")
        self.assertEqual(receipt["runtime_by_role"], mapping)
        self.assertEqual(receipt["distinct_runtime_count"], 5)

        with self.assertRaisesRegex(
            acceptance.AcceptanceError, "exact runtime selection"
        ):
            acceptance.runtime_strategy_receipt(
                runtime_id=None,
                runtime_by_role={},
                require_heterogeneous=False,
            )

    def test_sandbox_profiles_pin_the_keeper_up_tool_enum(self):
        toml_text = (REPO_ROOT / "config" / "tools" / "masc_keeper_up.toml").read_text()
        match = re.search(
            r'name = "sandbox_profile"\n(?:.*\n){0,3}?enum = \[([^\]]*)\]', toml_text
        )
        self.assertIsNotNone(match, "masc_keeper_up.toml declares no sandbox_profile enum")
        server_profiles = tuple(re.findall(r'"([^"]+)"', match.group(1)))
        self.assertEqual(acceptance.SANDBOX_PROFILES, server_profiles)

    def test_every_keeper_up_call_uses_the_configured_profile_and_never_local(self):
        module_source = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertNotIn('"sandbox_profile": "local"', module_source)
        self.assertNotIn("ALLOW_LOCAL_PLAYGROUND", module_source)
        keeper_up_calls = module_source.count('"masc_keeper_up"')
        self.assertEqual(keeper_up_calls, 2)
        self.assertEqual(
            module_source.count('"sandbox_profile": self.sandbox_profile'), keeper_up_calls
        )
        for method in (
            acceptance.MissionRun.create_fleet,
            acceptance.MissionRun.restart_and_recall,
        ):
            source = inspect.getsource(method)
            self.assertIn('"sandbox_profile": self.sandbox_profile', source)
            self.assertNotIn('"local"', source)

    def test_run_refuses_to_start_without_a_sandbox_profile(self):
        with unittest.mock.patch.object(sys, "argv", ["acceptance", "--run"]):
            with contextlib.redirect_stderr(io.StringIO()) as stderr:
                code = acceptance.main()
        self.assertEqual(code, 2)
        self.assertIn("--sandbox-profile", stderr.getvalue())

    def test_goal_verifier_phase_failure_is_recorded_not_fatal(self):
        written = {}

        class Writer:
            def write_json(self, name, payload):
                written[name] = payload

        class Stub:
            verifier_goal_id = "goal-x"
            verifier_task_id = "task-9"
            writer = Writer()
            goal_verifier_evidence = {}

            def run_goal_verifier_refute_reenter_prove(self):
                raise acceptance.AcceptanceError("verifier Task has no completion verdict")

        stub = Stub()
        acceptance.MissionRun.run_goal_verifier_guarded(stub)
        self.assertEqual(stub.goal_verifier_evidence["failure"], acceptance.GOAL_VERIFIER_PHASE_FAILED)
        self.assertEqual(stub.goal_verifier_evidence["task_id"], "task-9")
        self.assertIn("no completion verdict", stub.goal_verifier_evidence["detail"])
        self.assertIn("observations/goal-verifier-failure.json", written)

    def test_run_sequence_guards_the_goal_verifier_phase(self):
        run_source = inspect.getsource(acceptance.MissionRun.run)
        self.assertIn("self.run_goal_verifier_guarded()", run_source)
        self.assertNotIn("self.run_goal_verifier_refute_reenter_prove()", run_source)
        self.assertIn("self.run_continuity_chain(post_id)", run_source)

    def test_catalog_has_exact_mission_and_assertion_counts(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)

        self.assertEqual(len(catalog["missions"]), 23)
        self.assertEqual(
            len(
                {
                    assertion
                    for mission in catalog["missions"]
                    for assertion in mission["assertions"]
                }
            ),
            49,
        )
        self.assertEqual(
            catalog["keeper_required_skill_identities"],
            [
                skill_identity(
                    "mission-snapshot",
                    source_id="project-masc",
                ),
                skill_identity(
                    "background-snapshot",
                    source_id="project-masc",
                ),
            ],
        )

    def test_required_exact_reference_resolves_from_snapshot(self):
        required_identity = skill_identity("mission-snapshot")
        required_reference = skill_reference("mission-snapshot", "a" * 64)
        report = acceptance.composition_surface_status(
            skills={
                "state": "ready",
                "snapshot": {"skills": [published_skill("mission-snapshot", "a" * 64)]},
                "surfaces": [
                    {
                        "reference": required_reference,
                        "kind": "composition",
                        "tool_name": "display-name-is-not-acceptance-authority",
                    }
                ],
            },
            required_skill_identities=[required_identity],
            skills_url="http://127.0.0.1:8935/api/v1/skills",
        )

        self.assertEqual(report["status"], "ok")
        self.assertEqual(report["required_skill_references"], [required_reference])
        self.assertEqual(report["missing_skill_references"], [])

    def test_composition_preflight_fails_on_unavailable_surface(self):
        required_identity = skill_identity("broken")
        required_reference = skill_reference("broken", "b" * 64)
        report = acceptance.composition_surface_status(
            skills={
                "state": "ready",
                "snapshot": {"skills": [published_skill("broken", "b" * 64)]},
                "surfaces": [
                    {
                        "reference": required_reference,
                        "kind": "unavailable",
                        "error": "composition rejected",
                    }
                ],
            },
            required_skill_identities=[required_identity],
            skills_url="http://127.0.0.1:8935/api/v1/skills",
        )

        self.assertEqual(report["status"], "surface_unavailable")
        self.assertEqual(report["missing_skill_references"], [required_reference])
        self.assertEqual(
            report["required_unavailable_surfaces"],
            [{"reference": required_reference, "error": "composition rejected"}],
        )

    def test_composition_preflight_rejects_same_name_at_another_revision(self):
        required_identity = skill_identity("mission-snapshot")
        required_reference = skill_reference("mission-snapshot", "a" * 64)
        other_revision = skill_reference("mission-snapshot", "b" * 64)

        report = acceptance.composition_surface_status(
            skills={
                "state": "ready",
                "snapshot": {"skills": [published_skill("mission-snapshot", "a" * 64)]},
                "surfaces": [
                    {
                        "reference": other_revision,
                        "kind": "composition",
                        "tool_name": "keeper_compose_mission-snapshot",
                    }
                ],
            },
            required_skill_identities=[required_identity],
            skills_url="http://127.0.0.1:8935/api/v1/skills",
        )

        self.assertEqual(report["status"], "missing_surfaces")
        self.assertEqual(report["required_skill_references"], [required_reference])
        self.assertEqual(report["missing_skill_references"], [required_reference])
        self.assertEqual(report["installed_skill_references"], [other_revision])

    def test_unrelated_unavailable_is_observed_without_blocking(self):
        required_identity = skill_identity("mission-snapshot")
        required_reference = skill_reference("mission-snapshot", "a" * 64)
        unrelated_reference = skill_reference("unrelated", "c" * 64)

        report = acceptance.composition_surface_status(
            skills={
                "state": "ready",
                "snapshot": {
                    "skills": [
                        published_skill("mission-snapshot", "a" * 64),
                        published_skill("unrelated", "c" * 64),
                    ]
                },
                "surfaces": [
                    {
                        "reference": required_reference,
                        "kind": "composition",
                        "tool_name": "keeper_compose_mission-snapshot",
                    },
                    {
                        "reference": unrelated_reference,
                        "kind": "unavailable",
                        "error": "unrelated composition rejected",
                    },
                ],
            },
            required_skill_identities=[required_identity],
            skills_url="http://127.0.0.1:8935/api/v1/skills",
        )

        self.assertEqual(report["status"], "ok")
        self.assertEqual(report["required_unavailable_surfaces"], [])
        self.assertEqual(
            report["unavailable_surfaces"],
            [
                {
                    "reference": unrelated_reference,
                    "error": "unrelated composition rejected",
                }
            ],
        )

    def test_catalog_has_exact_rw20_rw21_delivery_and_debate_missions(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)

        poc = catalog["missions"][18]
        self.assertEqual(poc["id"], "RW20")
        self.assertEqual(
            poc["assertions"],
            ["poc_execution_proof_observed", "poc_review_cites_execution"],
        )
        debate = catalog["missions"][19]
        self.assertEqual(debate["id"], "RW21")
        self.assertEqual(
            debate["assertions"],
            ["debate_restatement_faithful", "debate_verdict_cites_rebuttal"],
        )
        self.assertIn("tool_execute", catalog["keeper_required_tools"])

    def test_catalog_has_exact_rw22_coverage_mission(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)

        coverage = catalog["missions"][20]
        self.assertEqual(coverage["id"], "RW22")
        self.assertEqual(
            coverage["assertions"],
            [
                "qa_coverage_execution_observed",
                "qa_coverage_passes_verification",
                "qa_coverage_review_matches_spec",
            ],
        )
        # The row exists to reject partial runs, so the tester must be able to
        # execute rather than only claim, and the work has to enter the typed
        # verification flow and actually pass it — submitting is not completing.
        self.assertIn("tool_execute", catalog["keeper_required_tools"])
        self.assertIn("keeper_task_claim", catalog["keeper_required_tools"])
        self.assertIn("keeper_task_done", catalog["keeper_required_tools"])

    def test_catalog_has_exact_rw23_goal_verifier_mission(self):
        catalog = acceptance.load_catalog(CATALOG_PATH)

        goal_verifier = catalog["missions"][21]
        self.assertEqual(goal_verifier["id"], "RW23")
        self.assertEqual(
            goal_verifier["assertions"],
            [
                "goal_verifier_refutation_observed",
                "goal_verifier_reentry_proven",
                "goal_verifier_dashboard_browser_observed",
            ],
        )
        self.assertIn("Goal", goal_verifier["capabilities"])
        self.assertIn("Browser", goal_verifier["capabilities"])
        self.assertIn("masc_goal_transition", catalog["operator_required_tools"])
        self.assertTrue(catalog["approaches_apply_to_each_mission"])
        self.assertEqual(
            [approach["id"] for approach in catalog["execution_approaches"]],
            ["A", "B", "C"],
        )

    def test_goal_verifier_convergence_budget_covers_one_retry_cycle(self):
        # The live worker re-arms retryable deferred reviews on the default
        # 60-second maintenance pulse. A 300-second evaluator request that
        # fails near its boundary still needs a complete second attempt.
        self.assertEqual(
            acceptance.goal_verifier_convergence_timeout(300.0),
            720.0,
        )
        wait_source = inspect.getsource(acceptance.MissionRun.wait_for_goal_state)
        self.assertIn("goal_verifier_convergence_timeout(self.timeout)", wait_source)

    def test_browser_proof_parent_outlives_inner_readiness_and_capture(self):
        self.assertEqual(acceptance.browser_proof_subprocess_timeout(300.0), 600.0)
        self.assertEqual(acceptance.browser_proof_subprocess_timeout(400.0), 800.0)
        capture_source = inspect.getsource(acceptance.MissionRun.capture_browser_proof)
        self.assertIn("browser_proof_subprocess_timeout(self.timeout)", capture_source)
        self.assertNotIn("timeout=120", capture_source)

    def test_runtime_serving_evidence_requires_exact_completed_receipt_per_role(self):
        keepers = {"coordinator": "keeper-c", "reviewer": "keeper-r"}
        expected = {"coordinator": "runtime-c", "reviewer": "runtime-r"}
        with tempfile.TemporaryDirectory() as tmp_name:
            base_path = Path(tmp_name)
            cursors = acceptance.capture_runtime_manifest_line_cursors(
                base_path=base_path, keepers_by_role=keepers
            )
            self.write_runtime_receipts(
                base_path,
                "keeper-c",
                [
                    self.runtime_receipt(
                        "runtime-c", keeper_name="keeper-c", fallback=False
                    )
                ],
            )
            self.write_runtime_receipts(
                base_path,
                "keeper-r",
                [
                    self.runtime_receipt(
                        "runtime-fallback", keeper_name="keeper-r", fallback=True
                    )
                ],
            )

            failed = acceptance.collect_runtime_serving_evidence(
                base_path=base_path,
                keepers_by_role=keepers,
                expected_runtime_by_role=expected,
                manifest_line_cursors_by_keeper=cursors,
            )
            self.assertEqual(failed["status"], "failed")
            self.assertEqual(failed["served_role_count"], 1)
            self.assertEqual(
                failed["roles"]["reviewer"]["fallback_receipt_count"], 1
            )

            self.write_runtime_receipts(
                base_path,
                "keeper-r",
                [
                    self.runtime_receipt(
                        "runtime-fallback", keeper_name="keeper-r", fallback=True
                    ),
                    self.runtime_receipt(
                        "runtime-r", keeper_name="keeper-r", fallback=False
                    ),
                ],
            )
            passed = acceptance.collect_runtime_serving_evidence(
                base_path=base_path,
                keepers_by_role=keepers,
                expected_runtime_by_role=expected,
                manifest_line_cursors_by_keeper=cursors,
            )
            self.assertEqual(passed["status"], "passed")
            self.assertEqual(passed["served_role_count"], 2)
            self.assertEqual(passed["distinct_served_runtime_count"], 2)

    def test_campaign_identity_slug_keeps_seconds_in_identity(self):
        first = acceptance.campaign_identity_slug("rw-20260821-090001", 16)
        second = acceptance.campaign_identity_slug("rw-20260821-090059", 16)

        self.assertNotEqual(first, second)
        self.assertLessEqual(len(first), 16)
        self.assertLessEqual(len(second), 16)

    def test_runtime_serving_evidence_rejects_stale_exact_receipt(self):
        keepers = {"coordinator": "keeper-c"}
        expected = {"coordinator": "runtime-c"}
        with tempfile.TemporaryDirectory() as tmp_name:
            base_path = Path(tmp_name)
            self.write_runtime_receipts(
                base_path,
                "keeper-c",
                [
                    self.runtime_receipt(
                        "runtime-c", keeper_name="keeper-c", fallback=False
                    )
                ],
            )
            cursors = acceptance.capture_runtime_manifest_line_cursors(
                base_path=base_path, keepers_by_role=keepers
            )
            self.append_runtime_receipts(
                base_path,
                "keeper-c",
                [
                    self.runtime_receipt(
                        "runtime-fallback", keeper_name="keeper-c", fallback=True
                    )
                ],
            )

            failed = acceptance.collect_runtime_serving_evidence(
                base_path=base_path,
                keepers_by_role=keepers,
                expected_runtime_by_role=expected,
                manifest_line_cursors_by_keeper=cursors,
            )

            self.assertEqual(failed["status"], "failed")
            role = failed["roles"]["coordinator"]
            self.assertEqual(role["baseline_manifest_line_count"], 1)
            self.assertEqual(role["current_run_receipt_row_count"], 1)
            self.assertEqual(role["exact_success_count"], 0)
            self.assertEqual(role["fallback_receipt_count"], 1)

    def test_runtime_serving_evidence_rejects_malformed_receipt_identity(self):
        keepers = {"coordinator": "keeper-c"}
        expected = {"coordinator": "runtime-c"}
        with tempfile.TemporaryDirectory() as tmp_name:
            base_path = Path(tmp_name)
            cursors = acceptance.capture_runtime_manifest_line_cursors(
                base_path=base_path, keepers_by_role=keepers
            )
            malformed = self.runtime_receipt(
                "runtime-c", keeper_name="wrong-keeper", fallback=False
            )
            malformed["runtime_id"] = "different-top-level-runtime"
            self.write_runtime_receipts(base_path, "keeper-c", [malformed])

            failed = acceptance.collect_runtime_serving_evidence(
                base_path=base_path,
                keepers_by_role=keepers,
                expected_runtime_by_role=expected,
                manifest_line_cursors_by_keeper=cursors,
            )

            self.assertEqual(failed["status"], "failed")
            self.assertEqual(
                failed["roles"]["coordinator"]["exact_success_count"], 0
            )
            self.assertTrue(
                any("keeper_name mismatch" in error for error in failed["parse_errors"])
            )
            self.assertTrue(
                any(
                    "top-level runtime_id does not match decision" in error
                    for error in failed["parse_errors"]
                )
            )

    def test_rw23_task_is_not_exposed_to_autonomous_work_before_refutation(self):
        setup_source = inspect.getsource(acceptance.MissionRun.setup_product_state)
        rw23_source = inspect.getsource(
            acceptance.MissionRun.run_goal_verifier_refute_reenter_prove
        )

        # The success-token Task and verifier Goal both used to be visible
        # during fleet setup. The autonomous fleet completed them before RW23
        # could write the failing artifact. Create the Goal only inside the
        # directed RW23 phase. Goals are now an ownerless shared open set, so
        # no removed assignment/scope compatibility call may return.
        # Since RFC-0387 a created Goal is executing/idle at once; the runner
        # waits for that state (no criterion_state="viable" step remains)
        # before it creates the proof Task.
        self.assertNotIn("goal-verifier-task-create", setup_source)
        self.assertNotIn("goal-verifier-upsert", setup_source)
        self.assertNotIn("goal-verifier-assign", setup_source)
        self.assertNotIn("masc_goal_assign", setup_source)
        self.assertNotIn("active_goal_ids", setup_source)
        self.assertIn("goal-verifier-task-create", rw23_source)
        self.assertIn("goal-verifier-upsert", rw23_source)
        self.assertNotIn("goal-verifier-assign", rw23_source)
        self.assertNotIn("masc_goal_assign", rw23_source)
        self.assertLess(
            rw23_source.index("goal-verifier-upsert"),
            rw23_source.index('completion_state="idle"'),
        )
        self.assertLess(
            rw23_source.index('completion_state="idle"'),
            rw23_source.index("goal-verifier-task-create"),
        )
        self.assertLess(
            rw23_source.index("goal-verifier-task-create"),
            rw23_source.index("goal-verifier-refute-artifact"),
        )

    def test_rw23_uses_durable_verdict_without_parsing_board_text(self):
        rw23_source = inspect.getsource(
            acceptance.MissionRun.run_goal_verifier_refute_reenter_prove
        )

        # masc_tasks is a human-facing Board rendering in the live server. The
        # verifier history event is the typed durable authority for both the
        # rejected and approved transitions.
        self.assertNotIn("wait_for_verifier_task_status", rw23_source)
        self.assertEqual(rw23_source.count("wait_for_verifier_task_verdict"), 2)
        self.assertIn('wait_for_verifier_task_verdict("in_progress")', rw23_source)
        self.assertIn('wait_for_verifier_task_verdict("done")', rw23_source)

    def test_rw23_prompts_pin_canonical_artifact_path_and_original_task(self):
        run = object.__new__(acceptance.MissionRun)
        run.marker = "keeper-collab-contract"
        run.verifier_task_id = "task-009"
        run.verifier_artifact = "artifacts/keeper-collab-contract-goal-proof.txt"
        run.verifier_success_token = "GOAL_PROOF_PASS=keeper-collab-contract"

        refute = run._goal_verifier_refute_prompt(
            "GOAL_PROOF_FAIL=keeper-collab-contract"
        )
        proven = run._goal_verifier_proven_prompt()

        canonical_write = (
            "path='artifacts/keeper-collab-contract-goal-proof.txt'"
        )
        canonical_evidence = (
            "evidence_refs=['artifact:artifacts/"
            "keeper-collab-contract-goal-proof.txt']"
        )
        self.assertIn(canonical_write, refute)
        self.assertIn(canonical_write, proven)
        self.assertIn(canonical_evidence, refute)
        self.assertIn(canonical_evidence, proven)
        self.assertIn("path에 'playground/' 접두사", refute)
        self.assertIn("path에 'playground/' 접두사", proven)
        self.assertNotIn("playground의 artifacts/", refute)
        self.assertNotIn("playground의 artifacts/", proven)
        self.assertIn("task_id='task-009'", refute)
        self.assertIn("task_id='task-009'", proven)
        for forbidden_tool in (
            "keeper_task_release",
            "masc_add_task",
            "keeper_task_claim",
        ):
            self.assertIn(forbidden_tool, proven)
        self.assertIn("대체 Task를 만들거나 claim하지 마세요", proven)

    @staticmethod
    def runtime_receipt(runtime_id, *, keeper_name, fallback):
        return {
            "schema_version": 1,
            "ts": "2026-08-21T09:00:00Z",
            "keeper_name": keeper_name,
            "trace_id": f"trace-{runtime_id}",
            "keeper_turn_id": 1,
            "event": "receipt_appended",
            "runtime_id": runtime_id,
            "status": "ok",
            "decision": {
                "outcome": "ok",
                "runtime_id": runtime_id,
                "runtime_attempt_count": 1,
                "runtime_fallback_applied": fallback,
                "runtime_outcome": "completed",
            },
        }

    @staticmethod
    def write_runtime_receipts(base_path, keeper, rows):
        manifest_root = (
            base_path / ".masc" / "keepers" / keeper / "runtime-manifests"
        )
        manifest_root.mkdir(parents=True, exist_ok=True)
        (manifest_root / "trace.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in rows),
            encoding="utf-8",
        )

    @staticmethod
    def append_runtime_receipts(base_path, keeper, rows):
        manifest_path = (
            base_path
            / ".masc"
            / "keepers"
            / keeper
            / "runtime-manifests"
            / "trace.jsonl"
        )
        with manifest_path.open("a", encoding="utf-8") as handle:
            handle.write("".join(json.dumps(row) + "\n" for row in rows))


if __name__ == "__main__":
    unittest.main()

import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = (
    REPO_ROOT / "scripts" / "harness" / "workload" / "keeper_skill_use_proof.py"
)
sys.path.insert(0, str(SCRIPT_PATH.parent))


def load_module():
    spec = importlib.util.spec_from_file_location("keeper_skill_use_proof", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


proof = load_module()
SHA = "a" * 40
INSTANCE = "018f1d5e-7b3c-7abc-8def-0123456789ab"


def fixture():
    reference = {
        "identity": {
            "source_id": "workspace",
            "package_id": "review-skill",
            "name": "review-skill",
        },
        "content_revision": "b" * 64,
    }
    summary = {
        "instruction_invocations": 1,
        "skill_bodies_served": 1,
        "skill_resources_served": 0,
        "instruction_provider_deliveries": 0,
        "instruction_official_client_handoffs": 1,
        "instruction_actions_observed": 1,
        "composition_invocations": 0,
        "composition_provider_deliveries": 0,
        "composition_official_client_handoffs": 0,
        "composition_actions_observed": 0,
        "invalid_transitions": 0,
    }
    activation = {
        **reference,
        "snapshot_revision": "c" * 64,
        "turn_ref": "trace-one#7",
        "runtime_id": "antigravity.gemini",
        "skill_tool_use_id": "call-skill-1",
        "agent_core_turn": 7,
        "invocation": {
            "kind": "instruction",
            "origin": {"kind": "session_instruction"},
            "served_content": {
                "kind": "skill_body",
                "bytes": 12,
                "sha256": "d" * 64,
            },
        },
        "delivery": {
            "boundary": {
                "kind": "official_client_result_handoff",
                "agent_core_turn": 7,
            },
            "runtime_id": "antigravity.gemini",
            "delivered_at": "2026-08-27T00:00:01Z",
            "content_bytes": 12,
            "content_sha256": "d" * 64,
        },
        "actions": [
            {
                "identity": {
                    "kind": "provider_step",
                    "conversation_id": "conversation-one",
                    "step_index": 4,
                },
                "tool_name": "WebSearch",
                "runtime_id": "antigravity.gemini",
                "agent_core_turn": 7,
                "observed_at": "2026-08-27T00:00:02Z",
            }
        ],
        "activated_at": "2026-08-27T00:00:00Z",
    }
    ledger = {
        "schema": "masc.skill-activations/v5",
        "workspace_key": "e" * 64,
        "session_id": "trace-one",
        "revision": "f" * 64,
        "activations": [activation],
        "transition_rejections": [],
    }
    ledger["revision"] = proof.ledger_revision(ledger)
    dashboard = {
        "effective_keeper_surface": {
            "status": "available",
            "keeper_name": "keeper-one",
        },
        "skill_activations": {
            "status": "available",
            "keeper_name": "keeper-one",
            "ledger": ledger,
            "summary": copy.deepcopy(summary),
            "scoped_summaries": [
                {
                    "scope": {
                        "snapshot_revision": "c" * 64,
                        "turn_ref": "trace-one#7",
                        "invocation_runtime_id": "antigravity.gemini",
                        "reference": reference,
                    },
                    "summary": copy.deepcopy(summary),
                    "provider_delivery_runtime_counts": [],
                    "official_client_handoff_runtime_counts": [
                        {"runtime_id": "antigravity.gemini", "count": 1}
                    ],
                    "action_runtime_counts": [
                        {"runtime_id": "antigravity.gemini", "count": 1}
                    ],
                }
            ],
        },
    }
    health = {
        "health_detail": "full",
        "build": {
            "binary_commit": SHA,
            "binary_commit_source": "embedded",
            "runtime_instance_id": INSTANCE,
            "started_at": "2026-08-27T00:00:00Z",
        },
        "paths": {
            "effective_base_path": "/workspace",
            "effective_masc_root": "/workspace/.masc",
        },
    }
    return health, dashboard, ledger


def refresh_projection(dashboard, ledger):
    ledger["revision"] = proof.ledger_revision(ledger)
    projection = dashboard["skill_activations"]
    projection["summary"] = proof.summarize(
        ledger["activations"], ledger["transition_rejections"]
    )
    projection["scoped_summaries"] = proof.scoped_summaries(
        ledger["activations"], ledger["transition_rejections"]
    )


class KeeperSkillUseProofTest(unittest.TestCase):
    def test_strict_http_reads_send_bearer_without_serializing_it(self):
        token = "strict-proof-token"

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                return b'{"ok":true}'

        def open_request(request, timeout):
            self.assertEqual(timeout, 3.0)
            self.assertEqual(
                request.get_header("Authorization"), f"Bearer {token}"
            )
            return Response()

        with mock.patch.object(
            proof.proof_http, "open_no_redirect", side_effect=open_request
        ):
            value, raw = proof.read_json("https://masc.invalid/strict", 3.0, token)

        self.assertEqual(value, {"ok": True})
        self.assertNotIn(token.encode(), raw)
        options = proof.dashboard_context_options()
        self.assertNotIn("extra_http_headers", options)
        self.assertNotIn(
            "Authorization",
            proof.proof_http.scoped_bearer_headers(
                base_url="https://masc.example",
                request_url="https://foreign.example/image.png",
                headers={"Authorization": f"Bearer {token}"},
                token=token,
            ),
        )

    def test_token_file_is_one_regular_non_symlink_line(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            token_file = root / "token"
            token_file.write_text("exact-token\n", encoding="utf-8")
            self.assertEqual(proof.read_token(token_file), "exact-token")
            token_file.write_text("first\nsecond\n", encoding="utf-8")
            with self.assertRaisesRegex(proof.ProofError, "multiple lines"):
                proof.read_token(token_file)
            target = root / "target"
            target.write_text("secret", encoding="utf-8")
            link = root / "link"
            link.symlink_to(target)
            with self.assertRaisesRegex(proof.ProofError, "symlink"):
                proof.read_token(link)

    def test_dashboard_auth_fetch_rejects_redirect_without_following_it(self):
        class RequestValue:
            url = "https://masc.example/api/v1/dashboard/tools"
            headers = {"Accept": "application/json"}

        class ResponseValue:
            status = 302

        route = mock.Mock()
        route.request = RequestValue()
        route.fetch.return_value = ResponseValue()

        proof.handle_dashboard_route(
            route, base_url="https://masc.example", token="secret"
        )

        route.fetch.assert_called_once_with(
            headers={
                "Accept": "application/json",
                "Authorization": "Bearer secret",
            },
            max_redirects=0,
        )
        route.abort.assert_called_once_with("blockedbyclient")
        route.continue_.assert_not_called()
        route.fulfill.assert_not_called()

    def test_dashboard_auth_fulfills_one_same_origin_response(self):
        class RequestValue:
            url = "https://masc.example/api/v1/dashboard/tools"
            headers = {"Accept": "application/json"}

        class ResponseValue:
            status = 200

        response = ResponseValue()
        route = mock.Mock()
        route.request = RequestValue()
        route.fetch.return_value = response

        proof.handle_dashboard_route(
            route, base_url="https://masc.example", token="secret"
        )

        route.fetch.assert_called_once()
        route.fulfill.assert_called_once_with(response=response)
        route.abort.assert_not_called()
        route.continue_.assert_not_called()

    def test_dashboard_foreign_request_strips_auth_without_fetch(self):
        class RequestValue:
            url = "https://assets.example/image.png"
            headers = {"Authorization": "Bearer inherited", "Accept": "image/png"}

        route = mock.Mock()
        route.request = RequestValue()

        proof.handle_dashboard_route(
            route, base_url="https://masc.example", token="secret"
        )

        route.continue_.assert_called_once_with(headers={"Accept": "image/png"})
        route.fetch.assert_not_called()
        route.fulfill.assert_not_called()

    def test_rejects_base_url_credentials(self):
        with self.assertRaisesRegex(proof.ProofError, "must not contain credentials"):
            proof.canonical_base_url("http://user:secret@127.0.0.1:8935")

    def test_accepts_exact_out_of_band_tui_build_evidence(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            executable = b"exact-built-tui"
            (root / "masc_tui.exe").write_bytes(executable)
            manifest = {
                "schema": "masc.tui-build-evidence/v1",
                "producer": "scripts/harness/workload/build_keeper_skill_tui.py",
                "source": {
                    "head": SHA,
                    "tree": "b" * 40,
                    "tracked_checkout_clean": True,
                },
                "artifact": {
                    "path": "masc_tui.exe",
                    "bytes": len(executable),
                    "sha256": proof.digest_bytes(executable),
                },
            }
            manifest_raw = (json.dumps(manifest, sort_keys=True) + "\n").encode()
            manifest_path = root / "build-evidence.json"
            manifest_path.write_bytes(manifest_raw)

            _, verified_manifest, verified_executable = (
                proof.validate_tui_build_evidence(
                    manifest_path=manifest_path,
                    expected_manifest_sha256=proof.digest_bytes(manifest_raw),
                    expected_source_sha=SHA,
                    expected_source_tree="b" * 40,
                )
            )

            self.assertEqual(verified_manifest, manifest_raw)
            self.assertEqual(verified_executable, executable)

    def test_rejects_tui_build_evidence_not_matching_expected_sha(self):
        with tempfile.TemporaryDirectory() as raw:
            manifest_path = Path(raw) / "build-evidence.json"
            manifest_path.write_bytes(b"{}\n")
            with self.assertRaisesRegex(proof.ProofError, "expected SHA"):
                proof.validate_tui_build_evidence(
                    manifest_path=manifest_path,
                    expected_manifest_sha256="0" * 64,
                    expected_source_sha=SHA,
                    expected_source_tree="b" * 40,
                )

    def validate(self, health, dashboard, ledger):
        return proof.validate_proof(
            health=health,
            dashboard=dashboard,
            durable_ledger=ledger,
            keeper="keeper-one",
            expected_source_sha=SHA,
            skill_tool_use_id="call-skill-1",
        )

    def test_accepts_exact_official_handoff_with_later_provider_step(self):
        health, dashboard, ledger = fixture()

        result = self.validate(health, dashboard, ledger)

        self.assertEqual(result["turn_ref"], "trace-one#7")
        self.assertEqual(
            result["actions"][0]["identity"],
            {
                "kind": "provider_step",
                "conversation_id": "conversation-one",
                "step_index": 4,
            },
        )

    def test_rejects_stale_binary(self):
        health, dashboard, ledger = fixture()
        health["build"]["binary_commit"] = "0" * 64

        with self.assertRaisesRegex(proof.ProofError, "binary commit does not match"):
            self.validate(health, dashboard, ledger)

    def test_rejects_non_full_health_response(self):
        health, dashboard, ledger = fixture()
        health["health_detail"] = "basic"

        with self.assertRaisesRegex(proof.ProofError, "health response is not full"):
            self.validate(health, dashboard, ledger)

    def test_rejects_stale_ledger_schema(self):
        health, dashboard, ledger = fixture()
        ledger["schema"] = "masc.skill-activations/v4"

        with self.assertRaisesRegex(proof.ProofError, "schema is not"):
            self.validate(health, dashboard, ledger)

    def test_rejects_dashboard_and_durable_ledger_mismatch(self):
        health, dashboard, ledger = fixture()
        durable = copy.deepcopy(ledger)
        durable["revision"] = "0" * 64

        with self.assertRaisesRegex(proof.ProofError, "does not equal"):
            self.validate(health, dashboard, durable)

    def test_rejects_name_only_or_implicit_activation_selection(self):
        health, dashboard, ledger = fixture()

        with self.assertRaisesRegex(proof.ProofError, "found 0"):
            proof.validate_proof(
                health=health,
                dashboard=dashboard,
                durable_ledger=ledger,
                keeper="keeper-one",
                expected_source_sha=SHA,
                skill_tool_use_id="review-skill",
            )

    def test_rejects_duplicate_exact_activation_identity(self):
        health, dashboard, ledger = fixture()
        ledger["activations"].append(copy.deepcopy(ledger["activations"][0]))
        refresh_projection(dashboard, ledger)

        with self.assertRaisesRegex(proof.ProofError, "found 2"):
            self.validate(health, dashboard, ledger)

    def test_rejects_resource_as_skill_body_proof(self):
        health, dashboard, ledger = fixture()
        served = ledger["activations"][0]["invocation"]["served_content"]
        served["kind"] = "skill_resource"
        served["relative_path"] = "references/guide.md"
        refresh_projection(dashboard, ledger)

        with self.assertRaisesRegex(proof.ProofError, "did not serve a Skill body"):
            self.validate(health, dashboard, ledger)

    def test_rejects_handoff_without_later_action(self):
        health, dashboard, ledger = fixture()
        ledger["activations"][0]["actions"] = []
        ledger["revision"] = proof.ledger_revision(ledger)
        dashboard["skill_activations"]["summary"]["instruction_actions_observed"] = 0
        dashboard["skill_activations"]["scoped_summaries"][0]["summary"][
            "instruction_actions_observed"
        ] = 0
        dashboard["skill_activations"]["scoped_summaries"][0][
            "action_runtime_counts"
        ] = []

        with self.assertRaisesRegex(proof.ProofError, "no later"):
            self.validate(health, dashboard, ledger)

    def test_rejects_delivery_digest_from_another_body(self):
        health, dashboard, ledger = fixture()
        ledger["activations"][0]["delivery"]["content_sha256"] = "0" * 64
        refresh_projection(dashboard, ledger)

        with self.assertRaisesRegex(proof.ProofError, "digest differs"):
            self.validate(health, dashboard, ledger)

    def test_rejects_transition_rejection_for_exact_invocation(self):
        health, dashboard, ledger = fixture()
        ledger["transition_rejections"] = [
            {"kind": "action_before_delivery", "skill_tool_use_id": "call-skill-1"}
        ]
        ledger["revision"] = proof.ledger_revision(ledger)

        with self.assertRaisesRegex(proof.ProofError, "has rejected transitions"):
            self.validate(health, dashboard, ledger)

    def test_rejects_scoped_summary_from_another_runtime(self):
        health, dashboard, ledger = fixture()
        dashboard["skill_activations"]["scoped_summaries"][0]["scope"][
            "invocation_runtime_id"
        ] = "another-runtime"

        with self.assertRaisesRegex(proof.ProofError, "scoped summaries do not match"):
            self.validate(health, dashboard, ledger)

    def test_rejects_scoped_invalid_transition_count(self):
        health, dashboard, ledger = fixture()
        dashboard["skill_activations"]["scoped_summaries"][0]["summary"][
            "invalid_transitions"
        ] = 1

        with self.assertRaisesRegex(proof.ProofError, "scoped summaries do not match"):
            self.validate(health, dashboard, ledger)

    def test_rejects_session_summary_counter_drift(self):
        health, dashboard, ledger = fixture()
        dashboard["skill_activations"]["summary"]["instruction_actions_observed"] = 2

        with self.assertRaisesRegex(proof.ProofError, "session summary does not match"):
            self.validate(health, dashboard, ledger)

    def test_rejects_duplicate_json_keys(self):
        with self.assertRaisesRegex(
            proof.ProofError, "fixture: JSON object repeats field ledger"
        ):
            proof.decode_json(b'{"ledger":{},"ledger":{}}', "fixture")

    def test_accepts_call_id_action_identity(self):
        health, dashboard, ledger = fixture()
        ledger["activations"][0]["actions"][0]["identity"] = {
            "kind": "call_id",
            "call_id": "call-action-1",
        }
        ledger["revision"] = proof.ledger_revision(ledger)

        result = self.validate(health, dashboard, ledger)

        self.assertEqual(result["actions"][0]["identity"]["kind"], "call_id")


if __name__ == "__main__":
    unittest.main()

import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_DIR = REPO_ROOT / "scripts" / "harness" / "workload"
SCRIPT_PATH = SCRIPT_DIR / "join_natural_keeper_skill_ledger.py"
sys.path.insert(0, str(SCRIPT_DIR))


def load_module():
    spec = importlib.util.spec_from_file_location(
        "join_natural_keeper_skill_ledger", SCRIPT_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


joiner = load_module()
proof = joiner.proof
HEAD = "a" * 40
TREE = "b" * 40
TURN_REF = "trace-one#7"
INSTANCE = "018f1d5e-7b3c-7abc-8def-0123456789ab"
MESSAGE = "Natural proof request.\n"


def source():
    return {"head": HEAD, "tree": TREE, "tracked_changes": []}


def health(started_at="2026-08-27T00:00:00Z"):
    return {
        "health_detail": "full",
        "build": {
            "binary_commit": HEAD,
            "binary_commit_source": "embedded",
            "runtime_instance_id": INSTANCE,
            "started_at": started_at,
        },
        "paths": {
            "effective_base_path": "/workspace",
            "effective_masc_root": "/workspace/.masc",
        },
    }


def receipt():
    operation_input = joiner.natural_producer.direct_message_input(MESSAGE)
    operation_digest = joiner.natural_producer.canonical_json_digest(operation_input)
    value = {
        "schema": "masc.natural-keeper-skill-proof-producer/v1",
        "captured_at": "2026-08-27T00:00:00Z",
        "source": {
            "head": HEAD,
            "tree": TREE,
            "tracked_checkout_clean": True,
        },
        "keeper": "keeper-one",
        "submitted_by": "proof-operator",
        "keeper_admission": "exact_existing",
        "keeper_declarative_runtime_id": "runtime-one",
        "actual_invocation_runtime_id": None,
        "skill_tool_use_id": None,
        "operation": {
            "operation_id": "kmsg-one",
            "acceptance": {
                "operation_id": "kmsg-one",
                "state": "queued",
                "queued_count": 1,
                "existing": False,
            },
            "state": "Succeeded",
            "turn_ref": TURN_REF,
            "status_observations": 1,
            "expected_operation_input_digest": operation_digest,
            "typed_terminal_record": {
                "schema": "masc.keeper_chat_operation.v1",
                "operation_id": "kmsg-one",
                "sequence": "7",
                "created_at": 1.0,
                "execution_digest": operation_digest,
                "source": {
                    "schema": "masc.keeper_chat_operation.source.v1",
                    "submitted_by": "proof-operator",
                    "thread_id": "keeper:keeper-one",
                    "continuation_channel": {
                        "kind": "dashboard",
                        "thread_id": "keeper:keeper-one",
                    },
                    "surface": {"kind": "agent"},
                    "channel": "agent",
                    "channel_user_id": "",
                    "channel_user_name": "",
                    "channel_workspace_id": "",
                    "conversation_id": None,
                    "external_message_id": None,
                    "workspace_id": None,
                    "extra_mentions": [],
                    "user_row_origin": "needs_append",
                },
                "input": None,
                "state": "Succeeded",
                "completed_at": 2.0,
                "outcome_ref": TURN_REF,
            },
        },
        "ledger_lookup": {
            "keeper": "keeper-one",
            "turn_ref": TURN_REF,
            "skill_tool_use_id": None,
        },
        "message": {
            "bytes": len(MESSAGE.encode()),
            "sha256": proof.digest_bytes(MESSAGE.encode()),
        },
        "unresolved_identity": {
            "kind": "operation_surface_does_not_expose_skill_or_runtime_identity",
            "operation_schema": "masc.keeper_chat_operation.v1",
        },
        "producer_calls": {"masc_keeper_msg": 1},
        "server": {
            "binary_commit": HEAD,
            "runtime_instance_id": INSTANCE,
            "started_at": "2026-08-27T00:00:00Z",
            "effective_base_path": "/workspace",
            "effective_masc_root": "/workspace/.masc",
        },
    }
    raw = (json.dumps(value, sort_keys=True) + "\n").encode()
    return value, raw


def activation(skill_id, turn_ref=TURN_REF):
    return {
        "identity": {
            "source_id": "workspace",
            "package_id": f"package-{skill_id}",
            "name": f"skill-{skill_id}",
        },
        "content_revision": "c" * 64,
        "snapshot_revision": "d" * 64,
        "turn_ref": turn_ref,
        "runtime_id": "runtime-one",
        "skill_tool_use_id": skill_id,
        "agent_core_turn": 7,
        "invocation": {
            "kind": "instruction",
            "origin": {"kind": "session_instruction"},
            "served_content": {
                "kind": "skill_body",
                "bytes": 4,
                "sha256": "e" * 64,
            },
        },
        "delivery": {
            "boundary": {
                "kind": "model_response",
                "response_id": f"response-{skill_id}",
            },
            "runtime_id": "runtime-one",
            "delivered_at": "2026-08-27T00:00:01Z",
            "content_bytes": 4,
            "content_sha256": "e" * 64,
        },
        "actions": [
            {
                "identity": {"kind": "call_id", "call_id": f"action-{skill_id}"},
                "tool_name": "keeper_status",
                "runtime_id": "runtime-one",
                "agent_core_turn": 7,
                "observed_at": "2026-08-27T00:00:02Z",
            }
        ],
        "activated_at": "2026-08-27T00:00:00Z",
    }


def ledger(activations, session_id="trace-one"):
    value = {
        "schema": "masc.skill-activations/v5",
        "workspace_key": "f" * 64,
        "session_id": session_id,
        "revision": "0" * 64,
        "activations": activations,
        "transition_rejections": [],
    }
    value["revision"] = proof.ledger_revision(value)
    return value


def dashboard(value):
    return {
        "effective_keeper_surface": {
            "status": "available",
            "keeper_name": "keeper-one",
        },
        "skill_activations": {
            "status": "available",
            "keeper_name": "keeper-one",
            "ledger": value,
            "summary": proof.summarize(
                value["activations"], value["transition_rejections"]
            ),
            "scoped_summaries": proof.scoped_summaries(
                value["activations"], value["transition_rejections"]
            ),
        },
    }


def validate(activations):
    producer, raw = receipt()
    durable = ledger(activations)
    projected = dashboard(durable)
    return joiner.validate_join(
        receipt=producer,
        receipt_raw=raw,
        expected_receipt_sha256=proof.digest_bytes(raw),
        source_before=source(),
        source_after=source(),
        health_before=health(),
        health_after=health(),
        dashboard_before=projected,
        dashboard_after=copy.deepcopy(projected),
        durable_ledger=durable,
        durable_ledger_after=copy.deepcopy(durable),
    )


class NaturalKeeperSkillLedgerJoinTest(unittest.TestCase):
    def test_artifact_manifest_hashes_the_exact_stored_bytes(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            payloads = {
                "health-before.json": b'{"phase":"before"}\n',
                "health-after.json": b'{"phase":"after"}\n',
            }
            artifacts = joiner.write_artifacts(root, payloads)
            for name, payload in payloads.items():
                self.assertEqual((root / name).read_bytes(), payload)
                self.assertEqual(artifacts[name]["bytes"], len(payload))
                self.assertEqual(artifacts[name]["sha256"], proof.digest_bytes(payload))

    def test_zero_exact_turn_matches_is_typed_no_skill_observation(self):
        result = validate([activation("call-other", "trace-one#8")])["result"]

        self.assertEqual(result["match_count"], 0)
        self.assertEqual(result["kind"], "no_skill_observed")
        self.assertEqual(result["matches"], [])

    def test_dashboard_rollover_is_not_reported_as_zero_skill_use(self):
        producer, raw = receipt()
        durable = ledger([activation("call-skill-1")])
        current = ledger(
            [activation("call-current", "trace-new#1")], session_id="trace-new"
        )

        joined = joiner.validate_join(
            receipt=producer,
            receipt_raw=raw,
            expected_receipt_sha256=proof.digest_bytes(raw),
            source_before=source(),
            source_after=source(),
            health_before=health(),
            health_after=health(),
            dashboard_before=dashboard(current),
            dashboard_after=dashboard(copy.deepcopy(current)),
            durable_ledger=durable,
            durable_ledger_after=copy.deepcopy(durable),
        )

        self.assertEqual(joined["result"]["kind"], "historical_projection_unavailable")
        self.assertEqual(joined["result"]["producer_trace_id"], "trace-one")
        self.assertEqual(joined["result"]["dashboard_session_id"], "trace-new")
        self.assertEqual(
            joined["result"]["durable_result"]["kind"], "exact_skill_invocation"
        )

    def test_one_exact_turn_match_selects_exact_identity(self):
        result = validate([activation("call-skill-1")])["result"]

        self.assertEqual(result["match_count"], 1)
        self.assertEqual(result["kind"], "exact_skill_invocation")
        self.assertEqual(result["selected_skill_tool_use_id"], "call-skill-1")
        self.assertEqual(result["matches"][0]["turn_ref"], TURN_REF)
        self.assertEqual(result["matches"][0]["invocation_runtime_id"], "runtime-one")
        self.assertEqual(
            result["matches"][0]["actions"][0]["tool_name"], "keeper_status"
        )

    def test_multiple_exact_turn_matches_require_operator_selection(self):
        result = validate([activation("call-skill-1"), activation("call-skill-2")])[
            "result"
        ]

        self.assertEqual(result["match_count"], 2)
        self.assertEqual(result["kind"], "multiple_skill_activations")
        self.assertEqual(
            result["selection"],
            {
                "kind": "operator_selection_required",
                "candidate_skill_tool_use_ids": ["call-skill-1", "call-skill-2"],
            },
        )
        self.assertEqual(
            [match["skill_tool_use_id"] for match in result["matches"]],
            ["call-skill-1", "call-skill-2"],
        )

    def test_turn_prefix_is_not_an_exact_match(self):
        result = validate(
            [
                activation("call-skill-10", f"{TURN_REF}0"),
                activation("call-skill-1", TURN_REF),
            ]
        )["result"]

        self.assertEqual(result["match_count"], 1)
        self.assertEqual(result["matches"][0]["skill_tool_use_id"], "call-skill-1")

    def test_skill_id_prefixes_remain_distinct_multiple_matches(self):
        result = validate([activation("call-skill-1"), activation("call-skill-10")])[
            "result"
        ]

        self.assertEqual(result["kind"], "multiple_skill_activations")
        self.assertEqual(
            result["selection"]["candidate_skill_tool_use_ids"],
            ["call-skill-1", "call-skill-10"],
        )

    def test_dashboard_durable_ledger_drift_is_rejected(self):
        producer, raw = receipt()
        durable = ledger([activation("call-skill-1")])
        projected_ledger = copy.deepcopy(durable)
        projected_ledger["activations"] = []
        projected_ledger["revision"] = proof.ledger_revision(projected_ledger)

        with self.assertRaisesRegex(joiner.JoinError, "differs from durable"):
            joiner.validate_join(
                receipt=producer,
                receipt_raw=raw,
                expected_receipt_sha256=proof.digest_bytes(raw),
                source_before=source(),
                source_after=source(),
                health_before=health(),
                health_after=health(),
                dashboard_before=dashboard(projected_ledger),
                dashboard_after=dashboard(projected_ledger),
                durable_ledger=durable,
                durable_ledger_after=copy.deepcopy(durable),
            )

    def test_receipt_tamper_is_rejected_by_out_of_band_sha(self):
        producer, raw = receipt()
        tampered = raw.replace(b"keeper-one", b"keeper-evil")
        durable = ledger([])

        with self.assertRaisesRegex(
            joiner.JoinError, "does not match the expected SHA"
        ):
            joiner.validate_join(
                receipt=producer,
                receipt_raw=tampered,
                expected_receipt_sha256=proof.digest_bytes(raw),
                source_before=source(),
                source_after=source(),
                health_before=health(),
                health_after=health(),
                dashboard_before=dashboard(durable),
                dashboard_after=dashboard(durable),
                durable_ledger=durable,
                durable_ledger_after=copy.deepcopy(durable),
            )

    def test_forged_terminal_owner_digest_and_turn_ref_are_rejected(self):
        cases = []
        foreign, _ = receipt()
        foreign["operation"]["typed_terminal_record"]["source"]["submitted_by"] = (
            "foreign-owner"
        )
        cases.append((foreign, "operation identity is invalid"))
        wrong_digest, _ = receipt()
        wrong_digest["operation"]["typed_terminal_record"]["execution_digest"] = (
            "0" * 64
        )
        cases.append((wrong_digest, "execution digest differs"))
        wrong_turn, _ = receipt()
        wrong_turn["operation"]["turn_ref"] = "not-a-turn-ref"
        wrong_turn["operation"]["typed_terminal_record"]["outcome_ref"] = (
            "not-a-turn-ref"
        )
        wrong_turn["ledger_lookup"]["turn_ref"] = "not-a-turn-ref"
        cases.append((wrong_turn, "operation identity is invalid"))
        durable = ledger([])
        for forged, error in cases:
            forged_raw = (json.dumps(forged, sort_keys=True) + "\n").encode()
            with self.subTest(error=error):
                with self.assertRaisesRegex(joiner.JoinError, error):
                    joiner.validate_join(
                        receipt=forged,
                        receipt_raw=forged_raw,
                        expected_receipt_sha256=proof.digest_bytes(forged_raw),
                        source_before=source(),
                        source_after=source(),
                        health_before=health(),
                        health_after=health(),
                        dashboard_before=dashboard(durable),
                        dashboard_after=dashboard(durable),
                        durable_ledger=durable,
                        durable_ledger_after=copy.deepcopy(durable),
                    )

    def test_server_restart_is_rejected(self):
        producer, raw = receipt()
        durable = ledger([])
        projected = dashboard(durable)

        with self.assertRaisesRegex(joiner.JoinError, "server restarted"):
            joiner.validate_join(
                receipt=producer,
                receipt_raw=raw,
                expected_receipt_sha256=proof.digest_bytes(raw),
                source_before=source(),
                source_after=source(),
                health_before=health(),
                health_after=health("2026-08-27T00:01:00Z"),
                dashboard_before=projected,
                dashboard_after=projected,
                durable_ledger=durable,
                durable_ledger_after=copy.deepcopy(durable),
            )

    def test_dashboard_ledger_advance_during_join_is_rejected(self):
        producer, raw = receipt()
        durable = ledger([activation("call-skill-1")])
        before = dashboard(durable)
        advanced = ledger(
            [activation("call-skill-1"), activation("call-skill-2", "trace-two#1")]
        )

        with self.assertRaisesRegex(joiner.JoinError, "differs from durable"):
            joiner.validate_join(
                receipt=producer,
                receipt_raw=raw,
                expected_receipt_sha256=proof.digest_bytes(raw),
                source_before=source(),
                source_after=source(),
                health_before=health(),
                health_after=health(),
                dashboard_before=before,
                dashboard_after=dashboard(advanced),
                durable_ledger=durable,
                durable_ledger_after=copy.deepcopy(durable),
            )

    def test_durable_ledger_advance_during_join_is_rejected(self):
        producer, raw = receipt()
        durable = ledger([activation("call-skill-1")])
        advanced = ledger(
            [activation("call-skill-1"), activation("call-skill-2", "trace-two#1")]
        )
        projected = dashboard(durable)

        with self.assertRaisesRegex(joiner.JoinError, "durable Skill ledger changed"):
            joiner.validate_join(
                receipt=producer,
                receipt_raw=raw,
                expected_receipt_sha256=proof.digest_bytes(raw),
                source_before=source(),
                source_after=source(),
                health_before=health(),
                health_after=health(),
                dashboard_before=projected,
                dashboard_after=projected,
                durable_ledger=durable,
                durable_ledger_after=advanced,
            )

    def test_duplicate_key_receipt_is_rejected_by_shared_strict_decoder(self):
        with self.assertRaisesRegex(proof.ProofError, "repeats field keeper"):
            proof.decode_json(
                b'{"keeper":"keeper-one","keeper":"keeper-two"}', "receipt"
            )


if __name__ == "__main__":
    unittest.main()

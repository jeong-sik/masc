import copy
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = (
    REPO_ROOT
    / "scripts"
    / "harness"
    / "workload"
    / "verify_keeper_skill_proof_bundle.py"
)
sys.path.insert(0, str(SCRIPT_PATH.parent))


def load_module():
    spec = importlib.util.spec_from_file_location(
        "verify_keeper_skill_proof_bundle", SCRIPT_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


verifier = load_module()
HEAD = "a" * 40
TREE = "b" * 40
WORKSPACE = "c" * 64
SNAPSHOT = "d" * 64
CONTENT = "e" * 64
INSTANCE = "018f1d5e-7b3c-7abc-8def-0123456789ab"
SOURCE_FINGERPRINT = "f" * 64
EXECUTABLE_SHA256 = "e" * 64
EXECUTABLE_PROVENANCE_PATH = "/private/provenance.json"
EXECUTABLE_PROVENANCE_SHA256 = "d" * 64
TURN_REF = "trace-one#7"
SKILL_ID = "call-skill-1"
MESSAGE = "Natural proof request.\n"


def write_json(path: Path, value):
    payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    path.write_bytes(payload)
    return payload


def write_json_preserving_order(path: Path, value):
    payload = (json.dumps(value, indent=2) + "\n").encode()
    path.write_bytes(payload)
    return payload


def file_identity(payload: bytes):
    return {"bytes": len(payload), "sha256": verifier.digest(payload)}


def server():
    return {
        "binary_commit": HEAD,
        "source_fingerprint": SOURCE_FINGERPRINT,
        "executable_sha256": EXECUTABLE_SHA256,
        "executable_provenance_path": EXECUTABLE_PROVENANCE_PATH,
        "executable_provenance_sha256": EXECUTABLE_PROVENANCE_SHA256,
        "runtime_instance_id": INSTANCE,
        "started_at": "2026-08-27T00:00:00Z",
        "effective_base_path": "/workspace",
        "effective_masc_root": "/workspace/.masc",
    }


def health():
    return {
        "health_detail": "full",
        "build": {
            "binary_commit": HEAD,
            "binary_commit_source": "embedded",
            "source_fingerprint": SOURCE_FINGERPRINT,
            "executable_sha256": EXECUTABLE_SHA256,
            "executable_provenance_path": EXECUTABLE_PROVENANCE_PATH,
            "executable_provenance_sha256": EXECUTABLE_PROVENANCE_SHA256,
            "runtime_instance_id": INSTANCE,
            "started_at": server()["started_at"],
        },
        "paths": {
            "effective_base_path": "/workspace",
            "effective_masc_root": "/workspace/.masc",
        },
    }


def source():
    return {"head": HEAD, "tree": TREE, "tracked_changes": []}


def activation():
    return {
        "identity": {
            "source_id": "workspace",
            "package_id": "review",
            "name": "review",
        },
        "content_revision": CONTENT,
        "snapshot_revision": SNAPSHOT,
        "turn_ref": TURN_REF,
        "runtime_id": "runtime-one",
        "skill_tool_use_id": SKILL_ID,
        "agent_core_turn": 7,
        "invocation": {
            "kind": "instruction",
            "origin": {"kind": "session_instruction"},
            "served_content": {
                "kind": "skill_body",
                "bytes": 12,
                "sha256": CONTENT,
            },
        },
        "delivery": {
            "boundary": {"kind": "model_response", "response_id": "response-one"},
            "runtime_id": "runtime-one",
            "delivered_at": "2026-08-27T00:00:02Z",
            "content_bytes": 12,
            "content_sha256": CONTENT,
        },
        "actions": [
            {
                "identity": {"kind": "call_id", "call_id": "call-action-1"},
                "tool_name": "keeper_status",
                "runtime_id": "runtime-one",
                "agent_core_turn": 7,
                "observed_at": "2026-08-27T00:00:03Z",
            }
        ],
        "activated_at": "2026-08-27T00:00:01Z",
    }


def ledger():
    value = {
        "schema": "masc.skill-activations/v5",
        "workspace_key": WORKSPACE,
        "session_id": "trace-one",
        "revision": "0" * 64,
        "activations": [activation()],
        "transition_rejections": [],
    }
    value["revision"] = verifier.proof_collector.ledger_revision(value)
    return value


def dashboard(value):
    activations = value["activations"]
    rejections = value["transition_rejections"]
    return {
        "effective_keeper_surface": {
            "status": "available",
            "keeper_name": "keeper-one",
            "runtime_id": "runtime-one",
            "tool_delivery": {"status": "delivered"},
        },
        "skill_activations": {
            "status": "available",
            "keeper_name": "keeper-one",
            "ledger": value,
            "summary": verifier.proof_collector.summarize(activations, rejections),
            "scoped_summaries": verifier.proof_collector.scoped_summaries(
                activations, rejections
            ),
        },
    }


def historical(value):
    activations = value["activations"]
    rejections = value["transition_rejections"]
    return {
        "schema": "masc.dashboard.skill-activations/v1",
        "status": "available",
        "trace_id": "trace-one",
        "ledger": value,
        "summary": verifier.proof_collector.summarize(activations, rejections),
        "scoped_summaries": verifier.proof_collector.scoped_summaries(
            activations, rejections
        ),
    }


def receipt():
    operation_digest = verifier.ledger_join.natural_producer.canonical_json_digest(
        verifier.ledger_join.natural_producer.direct_message_input(MESSAGE)
    )
    return {
        "schema": "masc.natural-keeper-skill-proof-producer/v1",
        "captured_at": "2026-08-27T00:00:00Z",
        "source": {"head": HEAD, "tree": TREE, "tracked_checkout_clean": True},
        "keeper": "keeper-one",
        "submitted_by": "proof-operator",
        "keeper_admission": "exact_existing",
        "keeper_declarative_runtime_id": "runtime-one",
        "actual_invocation_runtime_id": None,
        "operation": {
            "operation_id": "operation-one",
            "acceptance": {
                "operation_id": "operation-one",
                "state": "queued",
                "queued_count": 1,
                "existing": False,
            },
            "state": "Succeeded",
            "turn_ref": TURN_REF,
            "status_observations": 1,
            "typed_terminal_record": {
                "schema": "masc.keeper_chat_operation.v1",
                "operation_id": "operation-one",
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
            "expected_operation_input_digest": operation_digest,
        },
        "message": {
            "bytes": len(MESSAGE.encode()),
            "sha256": verifier.digest(MESSAGE.encode()),
        },
        "skill_tool_use_id": None,
        "ledger_lookup": {
            "keeper": "keeper-one",
            "turn_ref": TURN_REF,
            "skill_tool_use_id": None,
        },
        "unresolved_identity": {
            "kind": "operation_surface_does_not_expose_skill_or_runtime_identity",
            "operation_schema": "masc.keeper_chat_operation.v1",
        },
        "producer_calls": {"masc_keeper_msg": 1},
        "server": server(),
    }


def png_chunk(kind, payload):
    body = kind + payload
    return (
        struct.pack(">I", len(payload))
        + body
        + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    )


def png(width=2, height=3, decoded=None):
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    pixels = (
        b"".join(b"\x00" + (b"\x00\x00\x00" * width) for _ in range(height))
        if decoded is None
        else decoded
    )
    return (
        verifier.PNG_SIGNATURE
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", zlib.compress(pixels))
        + png_chunk(b"IEND", b"")
    )


def make_bundle(root: Path):
    join_root = root / "join"
    proof_root = root / "proof"
    tui_root = root / "tui"
    join_root.mkdir()
    proof_root.mkdir()
    tui_root.mkdir()

    durable = ledger()
    projected = dashboard(durable)
    producer_receipt = receipt()
    receipt_raw = write_json(join_root / "producer-receipt.json", producer_receipt)
    raw_values = {
        "producer-receipt.json": producer_receipt,
        "health-before.json": health(),
        "health-after.json": health(),
        "dashboard-tools-before.json": projected,
        "dashboard-tools-after.json": copy.deepcopy(projected),
        "historical-skill-activations-before.json": historical(durable),
        "historical-skill-activations-after.json": historical(copy.deepcopy(durable)),
        "durable-skill-activations-before.json": durable,
        "durable-skill-activations-after.json": copy.deepcopy(durable),
        "source-before.json": source(),
        "source-after.json": source(),
    }
    join_payloads = {"producer-receipt.json": receipt_raw}
    for name, value in raw_values.items():
        if name != "producer-receipt.json":
            join_payloads[name] = write_json_preserving_order(join_root / name, value)
    recomputed_join = verifier.ledger_join.validate_join(
        receipt=producer_receipt,
        receipt_raw=receipt_raw,
        expected_receipt_sha256=verifier.digest(receipt_raw),
        source_before=raw_values["source-before.json"],
        source_after=raw_values["source-after.json"],
        health_before=raw_values["health-before.json"],
        health_after=raw_values["health-after.json"],
        dashboard_before=raw_values["dashboard-tools-before.json"],
        dashboard_after=raw_values["dashboard-tools-after.json"],
        historical_before=raw_values["historical-skill-activations-before.json"],
        historical_after=raw_values["historical-skill-activations-after.json"],
        durable_ledger=raw_values["durable-skill-activations-before.json"],
        durable_ledger_after=raw_values["durable-skill-activations-after.json"],
        durable_ledger_raw=join_payloads["durable-skill-activations-before.json"],
        durable_ledger_after_raw=join_payloads["durable-skill-activations-after.json"],
    )
    join = {
        "schema": verifier.JOIN_SCHEMA,
        **recomputed_join,
        "inputs": {"producer_receipt_sha256": verifier.digest(receipt_raw)},
        "artifacts": {
            name: file_identity(payload) for name, payload in join_payloads.items()
        },
    }
    join_raw = write_json(join_root / "join.json", join)

    executable = b"exact-tui-executable"
    (proof_root / "masc_tui.exe").write_bytes(executable)
    build = {
        "schema": verifier.BUILD_SCHEMA,
        "source": {"head": HEAD, "tree": TREE, "tracked_checkout_clean": True},
        "build": {"producer": "scripts/dune-local.sh"},
        "artifact": {
            "path": "masc_tui.exe",
            "bytes": len(executable),
            "sha256": verifier.digest(executable),
        },
    }
    build_raw = write_json(proof_root / "tui-build-evidence.json", build)
    proof_raw_values = {
        "health.json": health(),
        "dashboard-tools.json": copy.deepcopy(projected),
        "skill-activations.json": copy.deepcopy(durable),
    }
    proof_payloads = {
        name: write_json_preserving_order(proof_root / name, value)
        for name, value in proof_raw_values.items()
    }
    proof_payloads["tui-build-evidence.json"] = build_raw
    proof_payloads["masc_tui.exe"] = executable
    dashboard_png = png(1440, 1000)
    (proof_root / "dashboard-skill-use.png").write_bytes(dashboard_png)
    proof_identity = verifier.proof_collector.validate_proof(
        health=proof_raw_values["health.json"],
        dashboard=proof_raw_values["dashboard-tools.json"],
        durable_ledger=proof_raw_values["skill-activations.json"],
        keeper="keeper-one",
        expected_source_sha=HEAD,
        skill_tool_use_id=SKILL_ID,
    )
    proof = {
        "schema": verifier.PROOF_SCHEMA,
        "source": {
            "expected_sha": HEAD,
            "collector_head": HEAD,
            "collector_tree": TREE,
            "tracked_checkout_clean": True,
            "binary_commit": HEAD,
            "binary_commit_source": "embedded",
            "source_fingerprint": SOURCE_FINGERPRINT,
            "executable_sha256": EXECUTABLE_SHA256,
            "executable_provenance_path": EXECUTABLE_PROVENANCE_PATH,
            "executable_provenance_sha256": EXECUTABLE_PROVENANCE_SHA256,
            "server_started_at": server()["started_at"],
            "server_runtime_instance_id": INSTANCE,
            "tui_build": {
                "manifest_sha256": verifier.digest(build_raw),
                "executable_sha256": verifier.digest(executable),
                "executable_bytes": len(executable),
                "producer": "scripts/dune-local.sh",
            },
        },
        "runtime": {
            "base_url": "http://127.0.0.1:8935",
            "effective_base_path": "/workspace",
            "effective_masc_root": "/workspace/.masc",
        },
        "proof": proof_identity,
        "durability": {
            "ledger_sha256": verifier.digest(proof_payloads["skill-activations.json"]),
            "ledger_bytes": len(proof_payloads["skill-activations.json"]),
            "dashboard_projection_equals_ledger": True,
        },
        "dashboard": {
            "path": "dashboard-skill-use.png",
            "keeper": "keeper-one",
            "ledger_revision": durable["revision"],
            "exact_row": SKILL_ID,
            **file_identity(dashboard_png),
        },
        "artifacts": {
            name: file_identity(payload) for name, payload in proof_payloads.items()
        },
    }
    proof_raw = write_json(proof_root / "evidence.json", proof)
    producer_artifacts = {
        **proof["artifacts"],
        "dashboard-skill-use.png": file_identity(dashboard_png),
    }

    tui_png = png(1200, 800)
    (tui_root / "tui-skill-use.png").write_bytes(tui_png)
    exact_activation = recomputed_join["result"]["matches"][0]
    receipt_block = "\n".join(
        [
            verifier.exact_reference_line(exact_activation),
            f"invoked turn=7 id={SKILL_ID} runtime=runtime-one at=2026-08-27T00:00:01Z",
            "action turn=7 runtime=runtime-one tool=keeper_status call=call-action-1 at=2026-08-27T00:00:03Z",
        ]
    )
    visible_text = "\n".join(
        [
            "MASC Tools 14:10:47 [connected]",
            receipt_block,
        ]
    )
    tui = {
        "schema": verifier.TUI_SCHEMA,
        "source": {
            "expected_sha": HEAD,
            "capture_head": HEAD,
            "capture_tree": TREE,
            "tracked_checkout_clean": True,
            "executable_path": "/ignored/masc_tui.exe",
            "executable_bytes": len(executable),
            "executable_sha256": verifier.digest(executable),
            "build_evidence_sha256": verifier.digest(build_raw),
            "build_evidence_schema": verifier.BUILD_SCHEMA,
        },
        "proof": {
            "manifest": "/ignored/evidence.json",
            "manifest_sha256": verifier.digest(proof_raw),
            "keeper": "keeper-one",
            "session_id": "trace-one",
            "ledger_revision": durable["revision"],
            "skill_tool_use_id": SKILL_ID,
            "action_markers": ["call=call-action-1"],
            "captured_action_marker": "call=call-action-1",
        },
        "server": {**server(), "binary_commit_source": "embedded"},
        "selection": {
            "visited_keepers": ["keeper-one"],
            "visited_tools_panes": ["surface", "async", "activations"],
        },
        "producer_artifacts": producer_artifacts,
        "terminal": {"cols": 180, "rows": 42},
        "observations": {
            "skill_header": "Skill Use — keeper-one (1 receipts)",
            "session_line": f"session=trace-one  ledger={durable['revision']}",
            "receipt_block": receipt_block,
        },
        "visible_text": visible_text,
        "screenshot": {"path": "tui-skill-use.png", **file_identity(tui_png)},
    }
    tui["visible_text_sha256"] = verifier.digest(tui["visible_text"].encode())
    tui_raw = write_json(tui_root / "tui-evidence.json", tui)
    return {
        "join_root": join_root,
        "proof_root": proof_root,
        "tui_root": tui_root,
        "join": join,
        "join_raw": join_raw,
        "proof": proof,
        "proof_raw": proof_raw,
        "tui": tui,
        "tui_raw": tui_raw,
    }


def verify(bundle):
    return verifier.verify_bundle(
        join=bundle["join"],
        join_root=bundle["join_root"],
        proof=bundle["proof"],
        proof_raw=bundle["proof_raw"],
        proof_root=bundle["proof_root"],
        tui=bundle["tui"],
        tui_root=bundle["tui_root"],
    )


class VerifyKeeperSkillProofBundleTest(unittest.TestCase):
    def test_cli_writes_fail_closed_verification_manifest(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            bundle = make_bundle(root)
            output = root / "verified"
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_PATH),
                    "--join",
                    str(bundle["join_root"] / "join.json"),
                    "--expected-join-sha256",
                    verifier.digest(bundle["join_raw"]),
                    "--proof",
                    str(bundle["proof_root"] / "evidence.json"),
                    "--expected-proof-sha256",
                    verifier.digest(bundle["proof_raw"]),
                    "--tui",
                    str(bundle["tui_root"] / "tui-evidence.json"),
                    "--expected-tui-sha256",
                    verifier.digest(bundle["tui_raw"]),
                    "--out",
                    str(output),
                ],
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertFalse((output / "INCOMPLETE").exists())
            manifest = json.loads((output / "verification.json").read_text())
            self.assertEqual(manifest["schema"], verifier.SCHEMA)
            self.assertEqual(manifest["status"], "passed")
            self.assertEqual(manifest["artifacts"]["verified_count"], 18)

    def test_complete_bundle_emits_quantitative_matrix(self):
        with tempfile.TemporaryDirectory() as raw:
            result = verify(make_bundle(Path(raw)))

        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["artifacts"]["verified_count"], 18)
        self.assertEqual(result["matrix"]["natural_keeper_messages"], 1)
        self.assertEqual(result["matrix"]["exact_turn_skill_activations"], 1)
        self.assertEqual(result["matrix"]["later_model_selected_actions"], 1)
        self.assertEqual(result["matrix"]["incomplete_markers"], 0)

    def test_each_exact_identity_field_tamper_is_rejected(self):
        cases = [
            (("workspace_key",), "0" * 64),
            (("session_id",), "trace-other"),
            (("snapshot_revision",), "0" * 64),
            (("turn_ref",), "trace-one#8"),
            (("invocation_runtime_id",), "runtime-other"),
            (("reference", "name"), "other-skill"),
            (("skill_tool_use_id",), "call-skill-10"),
        ]
        for path, value in cases:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as raw:
                bundle = make_bundle(Path(raw))
                target = bundle["proof"]["proof"]
                for component in path[:-1]:
                    target = target[component]
                target[path[-1]] = value
                with self.assertRaisesRegex(
                    verifier.VerificationError,
                    "proof manifest identity differs from raw authority",
                ):
                    verify(bundle)

    def test_artifact_byte_tamper_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            (bundle["join_root"] / "health-before.json").write_bytes(b"tampered")
            with self.assertRaisesRegex(
                verifier.VerificationError, "byte count differs"
            ):
                verify(bundle)

    def test_durable_ledger_raw_byte_drift_reaches_offline_join_verifier(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            name = "durable-skill-activations-after.json"
            path = bundle["join_root"] / name
            value = json.loads(path.read_bytes())
            changed = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
            self.assertNotEqual(path.read_bytes(), changed)
            path.write_bytes(changed)
            bundle["join"]["artifacts"][name] = file_identity(changed)

            with self.assertRaisesRegex(
                verifier.VerificationError,
                "join raw authority is invalid: durable Skill ledger bytes changed",
            ):
                verify(bundle)

    def test_current_join_observation_tamper_is_rejected(self):
        for field in ("current_surface", "current_projection"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as raw:
                bundle = make_bundle(Path(raw))
                bundle["join"][field]["before"]["status"] = "tampered"

                with self.assertRaisesRegex(
                    verifier.VerificationError,
                    f"join manifest {field} differs from raw authority",
                ):
                    verify(bundle)

    def test_artifact_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            target = bundle["proof_root"] / "real-health.json"
            target.write_bytes(b'{"health_detail":"full"}\n')
            path = bundle["proof_root"] / "health.json"
            path.unlink()
            path.symlink_to(target)
            with self.assertRaisesRegex(verifier.VerificationError, "symlink"):
                verify(bundle)

    def test_non_exact_join_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            bundle["join"]["result"]["kind"] = "no_skill_observed"
            with self.assertRaisesRegex(
                verifier.VerificationError,
                "join manifest result differs from raw authority",
            ):
                verify(bundle)

    def test_extra_declared_artifact_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            bundle["join"]["artifacts"]["unexpected.json"] = {
                "bytes": 0,
                "sha256": verifier.digest(b""),
            }
            with self.assertRaisesRegex(verifier.VerificationError, "artifact set"):
                verify(bundle)

    def test_server_process_identity_tamper_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            bundle["proof"]["source"]["server_runtime_instance_id"] = (
                "018f1d5e-7b3c-7abc-8def-0123456789ac"
            )
            with self.assertRaisesRegex(verifier.VerificationError, "server differs"):
                verify(bundle)

    def test_server_executable_identity_tamper_is_rejected(self):
        for field in (
            "source_fingerprint",
            "executable_sha256",
            "executable_provenance_sha256",
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as raw:
                bundle = make_bundle(Path(raw))
                bundle["proof"]["source"][field] = "0" * 64
                with self.assertRaisesRegex(
                    verifier.VerificationError, "server differs"
                ):
                    verify(bundle)

    def test_delivery_and_action_tamper_are_rejected(self):
        for field, value in (
            ("delivery", None),
            ("actions", []),
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as raw:
                bundle = make_bundle(Path(raw))
                bundle["proof"]["proof"][field] = value
                with self.assertRaisesRegex(
                    verifier.VerificationError,
                    "proof manifest identity differs from raw authority",
                ):
                    verify(bundle)

    def test_identity_field_absent_on_both_sides_is_rejected(self):
        with self.subTest(field="keeper"), tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            receipt_path = bundle["join_root"] / "producer-receipt.json"
            receipt = json.loads(receipt_path.read_text())
            del receipt["keeper"]
            receipt_raw = write_json(receipt_path, receipt)
            bundle["join"]["inputs"]["producer_receipt_sha256"] = verifier.digest(
                receipt_raw
            )
            bundle["join"]["artifacts"]["producer-receipt.json"] = file_identity(
                receipt_raw
            )
            del bundle["join"]["producer"]["keeper"]
            del bundle["proof"]["proof"]["keeper"]
            del bundle["tui"]["proof"]["keeper"]
            with self.assertRaisesRegex(
                verifier.VerificationError,
                "raw authority|join producer.keeper is empty",
            ):
                verify(bundle)

        with self.subTest(field="delivery"), tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            del bundle["join"]["result"]["matches"][0]["delivery"]
            del bundle["proof"]["proof"]["delivery"]
            with self.assertRaisesRegex(
                verifier.VerificationError,
                "raw authority|join match.delivery is not an object",
            ):
                verify(bundle)

        with (
            self.subTest(field="ledger_revision"),
            tempfile.TemporaryDirectory() as raw,
        ):
            bundle = make_bundle(Path(raw))
            del bundle["proof"]["proof"]["ledger_revision"]
            del bundle["tui"]["proof"]["ledger_revision"]
            with self.assertRaisesRegex(
                verifier.VerificationError,
                "raw authority|TUI proof.ledger_revision is empty",
            ):
                verify(bundle)

    def test_dashboard_screenshot_name_collision_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            bundle["proof"]["dashboard"] = {
                "path": "health.json",
                **bundle["proof"]["artifacts"]["health.json"],
            }
            with self.assertRaisesRegex(
                verifier.VerificationError, "not the exact producer artifact"
            ):
                verify(bundle)

    def test_tui_manifest_proof_sha_tamper_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            bundle["tui"]["proof"]["manifest_sha256"] = "0" * 64
            with self.assertRaisesRegex(verifier.VerificationError, "TUI proof SHA"):
                verify(bundle)

    def test_visible_text_hash_tamper_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            bundle["tui"]["visible_text_sha256"] = "0" * 64
            with self.assertRaisesRegex(verifier.VerificationError, "visible text SHA"):
                verify(bundle)

    def test_tui_screenshot_tamper_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            (bundle["tui_root"] / "tui-skill-use.png").write_bytes(b"tampered")
            with self.assertRaisesRegex(
                verifier.VerificationError, "byte count differs"
            ):
                verify(bundle)

    def test_fabricated_raw_join_authority_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            payload = write_json(
                bundle["join_root"] / "health-before.json",
                {"health_detail": "full", "fabricated": True},
            )
            bundle["join"]["artifacts"]["health-before.json"] = file_identity(payload)
            with self.assertRaisesRegex(
                verifier.VerificationError, "join raw authority is invalid"
            ):
                verify(bundle)

    def test_fabricated_raw_proof_authority_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            payload = write_json(
                bundle["proof_root"] / "dashboard-tools.json",
                {"effective_keeper_surface": {"status": "unavailable"}},
            )
            bundle["proof"]["artifacts"]["dashboard-tools.json"] = file_identity(
                payload
            )
            with self.assertRaisesRegex(
                verifier.VerificationError, "proof raw authority is invalid"
            ):
                verify(bundle)

    def test_receipt_terminal_digest_and_owner_are_bound(self):
        mutations = {
            "terminal": lambda value: value["operation"].update({"state": "Failed"}),
            "digest": lambda value: value["operation"]["typed_terminal_record"].update(
                {"execution_digest": "0" * 64}
            ),
            "owner": lambda value: value.update({"submitted_by": "foreign-owner"}),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as raw:
                bundle = make_bundle(Path(raw))
                fabricated = receipt()
                mutate(fabricated)
                payload = write_json(
                    bundle["join_root"] / "producer-receipt.json", fabricated
                )
                bundle["join"]["inputs"]["producer_receipt_sha256"] = verifier.digest(
                    payload
                )
                bundle["join"]["artifacts"]["producer-receipt.json"] = file_identity(
                    payload
                )
                with self.assertRaisesRegex(
                    verifier.VerificationError, "join raw authority is invalid"
                ):
                    verify(bundle)

    def test_dashboard_screenshot_cannot_alias_a_proof_artifact(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            bundle["proof"]["dashboard"] = {
                "path": "health.json",
                **bundle["proof"]["artifacts"]["health.json"],
            }
            with self.assertRaisesRegex(
                verifier.VerificationError, "exact producer artifact"
            ):
                verify(bundle)

    def test_fabricated_png_is_rejected_even_when_its_hash_matches(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            payload = b"dashboard-png"
            (bundle["proof_root"] / "dashboard-skill-use.png").write_bytes(payload)
            identity = file_identity(payload)
            bundle["proof"]["dashboard"].update(identity)
            bundle["tui"]["producer_artifacts"]["dashboard-skill-use.png"] = identity
            with self.assertRaisesRegex(verifier.VerificationError, "is not a PNG"):
                verify(bundle)

    def test_ihdr_only_png_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            payload = png()[:33]
            (bundle["proof_root"] / "dashboard-skill-use.png").write_bytes(payload)
            identity = file_identity(payload)
            bundle["proof"]["dashboard"].update(identity)
            bundle["tui"]["producer_artifacts"]["dashboard-skill-use.png"] = identity
            with self.assertRaisesRegex(verifier.VerificationError, "no terminal IEND"):
                verify(bundle)

    def test_short_idat_scanlines_are_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            payload = png(1440, 1000, decoded=b"x")
            (bundle["proof_root"] / "dashboard-skill-use.png").write_bytes(payload)
            identity = file_identity(payload)
            bundle["proof"]["dashboard"].update(identity)
            bundle["tui"]["producer_artifacts"]["dashboard-skill-use.png"] = identity
            with self.assertRaisesRegex(
                verifier.VerificationError, "scanline length differs"
            ):
                verify(bundle)

    def test_dashboard_exact_row_is_required_and_bound(self):
        for exact_row in (None, "call-other"):
            with (
                self.subTest(exact_row=exact_row),
                tempfile.TemporaryDirectory() as raw,
            ):
                bundle = make_bundle(Path(raw))
                if exact_row is None:
                    bundle["proof"]["dashboard"].pop("exact_row")
                else:
                    bundle["proof"]["dashboard"]["exact_row"] = exact_row
                with self.assertRaisesRegex(
                    verifier.VerificationError, "Dashboard capture identity differs"
                ):
                    verify(bundle)

    def test_dashboard_keeper_and_ledger_revision_are_bound(self):
        cases = (("keeper", "foreign-keeper"), ("ledger_revision", "0" * 64))
        for field, value in cases:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as raw:
                bundle = make_bundle(Path(raw))
                bundle["proof"]["dashboard"][field] = value
                with self.assertRaisesRegex(
                    verifier.VerificationError, "Dashboard capture identity differs"
                ):
                    verify(bundle)

    def test_dashboard_and_tui_screenshots_cannot_be_hardlink_aliases(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            dashboard = bundle["proof_root"] / "dashboard-skill-use.png"
            tui_screenshot = bundle["tui_root"] / "tui-skill-use.png"
            tui_screenshot.unlink()
            os.link(dashboard, tui_screenshot)
            bundle["tui"]["screenshot"].update(file_identity(dashboard.read_bytes()))
            with self.assertRaisesRegex(verifier.VerificationError, "hardlink aliases"):
                verify(bundle)

    def test_png_zero_dimension_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            payload = png(0, 10)
            (bundle["proof_root"] / "dashboard-skill-use.png").write_bytes(payload)
            identity = file_identity(payload)
            bundle["proof"]["dashboard"].update(identity)
            bundle["tui"]["producer_artifacts"]["dashboard-skill-use.png"] = identity
            with self.assertRaisesRegex(
                verifier.VerificationError, "dimensions are invalid"
            ):
                verify(bundle)

    def test_visible_text_requires_the_exact_receipt_observation(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            visible = bundle["tui"]["visible_text"].replace(
                "call=call-action-1", "call=foreign-action"
            )
            bundle["tui"]["visible_text"] = visible
            bundle["tui"]["visible_text_sha256"] = verifier.digest(visible.encode())
            with self.assertRaisesRegex(
                verifier.VerificationError, "screenshot viewport"
            ):
                verify(bundle)

    def test_tui_receipt_is_structurally_bound_to_the_durable_activation(self):
        mutations = (
            ("exact=", "exact=garbage"),
            (f"id={SKILL_ID}", f"id={SKILL_ID}0"),
            ("turn=7", "turn=999"),
            ("tool=keeper_status", "tool=foreign_tool"),
        )
        for old, new in mutations:
            with self.subTest(old=old, new=new), tempfile.TemporaryDirectory() as raw:
                bundle = make_bundle(Path(raw))
                receipt = bundle["tui"]["observations"]["receipt_block"]
                mutated = receipt.replace(old, new, 1)
                bundle["tui"]["observations"]["receipt_block"] = mutated
                bundle["tui"]["visible_text"] = bundle["tui"]["visible_text"].replace(
                    receipt, mutated
                )
                bundle["tui"]["visible_text_sha256"] = verifier.digest(
                    bundle["tui"]["visible_text"].encode()
                )
                with self.assertRaisesRegex(
                    verifier.VerificationError, "exact receipt observation"
                ):
                    verify(bundle)

    def test_tui_ledger_projection_rejects_abbreviation(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            revision = bundle["proof"]["proof"]["ledger_revision"]
            bundle["tui"]["observations"]["session_line"] = (
                f"session=trace-one  ledger={revision[:12]}…"
            )
            with self.assertRaisesRegex(
                verifier.VerificationError, "ledger projection"
            ):
                verify(bundle)

    def test_tui_selection_path_is_required(self):
        cases = (
            ("visited_keepers", []),
            ("visited_tools_panes", ["surface", "async"]),
        )
        for field, value in cases:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as raw:
                bundle = make_bundle(Path(raw))
                bundle["tui"]["selection"][field] = value
                with self.assertRaisesRegex(
                    verifier.VerificationError, "selection path"
                ):
                    verify(bundle)

    def test_tui_skill_header_receipt_count_is_bound(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            bundle["tui"]["observations"]["skill_header"] = (
                "Skill Use — keeper-one (9 receipts)"
            )
            with self.assertRaisesRegex(
                verifier.VerificationError, "exact Skill header"
            ):
                verify(bundle)

    def test_incomplete_marker_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            (bundle["proof_root"] / "INCOMPLETE").write_text("partial\n")
            with self.assertRaisesRegex(verifier.VerificationError, "incomplete"):
                verifier.load_manifest(
                    bundle["proof_root"] / "evidence.json",
                    expected_sha256=verifier.digest(bundle["proof_raw"]),
                    expected_schema=verifier.PROOF_SCHEMA,
                    context="proof manifest",
                )

    def test_broken_incomplete_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            (bundle["proof_root"] / "INCOMPLETE").symlink_to("missing-target")
            with self.assertRaisesRegex(verifier.VerificationError, "incomplete"):
                verifier.load_manifest(
                    bundle["proof_root"] / "evidence.json",
                    expected_sha256=verifier.digest(bundle["proof_raw"]),
                    expected_schema=verifier.PROOF_SCHEMA,
                    context="proof manifest",
                )

    def test_duplicate_field_in_raw_authority_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            payload = (
                b'{"head":"' + HEAD.encode() + b'","head":"' + HEAD.encode() + b'"}'
            )
            (bundle["join_root"] / "source-before.json").write_bytes(payload)
            bundle["join"]["artifacts"]["source-before.json"] = file_identity(payload)
            with self.assertRaisesRegex(verifier.VerificationError, "repeats field"):
                verify(bundle)

    def test_duplicate_manifest_field_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "duplicate.json"
            payload = b'{"schema":"one","schema":"two"}'
            path.write_bytes(payload)
            with self.assertRaisesRegex(verifier.VerificationError, "repeats field"):
                verifier.load_manifest(
                    path,
                    expected_sha256=verifier.digest(payload),
                    expected_schema="two",
                    context="duplicate manifest",
                )

    def test_out_of_band_manifest_sha_tamper_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            with self.assertRaisesRegex(verifier.VerificationError, "SHA differs"):
                verifier.load_manifest(
                    bundle["join_root"] / "join.json",
                    expected_sha256="0" * 64,
                    expected_schema=verifier.JOIN_SCHEMA,
                    context="join manifest",
                )


if __name__ == "__main__":
    unittest.main()

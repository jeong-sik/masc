import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = (
    REPO_ROOT
    / "scripts"
    / "harness"
    / "workload"
    / "verify_keeper_skill_proof_bundle.py"
)


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
LEDGER_REVISION = "f" * 64
INSTANCE = "018f1d5e-7b3c-7abc-8def-0123456789ab"
TURN_REF = "trace-one#7"
SKILL_ID = "call-skill-1"


def write_json(path: Path, value):
    payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
    path.write_bytes(payload)
    return payload


def file_identity(payload: bytes):
    return {"bytes": len(payload), "sha256": verifier.digest(payload)}


def server():
    return {
        "binary_commit": HEAD,
        "runtime_instance_id": INSTANCE,
        "started_at": "2026-08-27T00:00:00Z",
        "effective_base_path": "/workspace",
        "effective_masc_root": "/workspace/.masc",
    }


def make_bundle(root: Path):
    join_root = root / "join"
    proof_root = root / "proof"
    tui_root = root / "tui"
    join_root.mkdir()
    proof_root.mkdir()
    tui_root.mkdir()

    action = {
        "identity": {"kind": "call_id", "call_id": "call-action-1"},
        "tool_name": "keeper_status",
        "runtime_id": "runtime-one",
        "agent_core_turn": 7,
        "observed_at": "2026-08-27T00:00:03Z",
    }
    delivery = {
        "boundary": {"kind": "model_response", "agent_core_turn": 7},
        "runtime_id": "runtime-one",
        "delivered_at": "2026-08-27T00:00:02Z",
        "content_bytes": 12,
        "content_sha256": CONTENT,
    }
    reference_nested = {
        "identity": {
            "source_id": "workspace",
            "package_id": "review",
            "name": "review",
        },
        "content_revision": CONTENT,
    }
    reference_flat = {
        "source_id": "workspace",
        "package_id": "review",
        "name": "review",
        "content_revision": CONTENT,
    }
    receipt = {
        "schema": "masc.natural-keeper-skill-proof-producer/v1",
        "source": {"head": HEAD, "tree": TREE, "tracked_checkout_clean": True},
        "keeper": "keeper-one",
        "producer_calls": {"masc_keeper_msg": 1},
        "operation": {"state": "Succeeded", "turn_ref": TURN_REF},
        "server": server(),
    }
    receipt_raw = write_json(join_root / "producer-receipt.json", receipt)
    join_payloads = {"producer-receipt.json": receipt_raw}
    for name in sorted(verifier.JOIN_ARTIFACTS - {"producer-receipt.json"}):
        payload = (name + "\n").encode()
        (join_root / name).write_bytes(payload)
        join_payloads[name] = payload
    join = {
        "schema": verifier.JOIN_SCHEMA,
        "producer": {
            "source": {"head": HEAD, "tree": TREE},
            "server": server(),
            "keeper": "keeper-one",
            "submitted_by": "proof-operator",
            "operation_id": "operation-one",
            "turn_ref": TURN_REF,
            "trace_id": "trace-one",
        },
        "server": server(),
        "ledger": {
            "schema": "masc.skill-activations/v5",
            "workspace_key": WORKSPACE,
            "session_id": "trace-one",
            "revision": LEDGER_REVISION,
            "dashboard_equals_durable": True,
            "dashboard_projection_kind": "exact_session",
        },
        "result": {
            "kind": "exact_skill_invocation",
            "match_count": 1,
            "selected_skill_tool_use_id": SKILL_ID,
            "matches": [
                {
                    "skill_tool_use_id": SKILL_ID,
                    "turn_ref": TURN_REF,
                    "snapshot_revision": SNAPSHOT,
                    "reference": reference_nested,
                    "invocation_runtime_id": "runtime-one",
                    "invocation": {"kind": "instruction"},
                    "delivery": delivery,
                    "actions": [action],
                }
            ],
        },
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
    proof_payloads = {
        "health.json": b'{"health_detail":"full"}\n',
        "dashboard-tools.json": b'{"skill_activations":{}}\n',
        "skill-activations.json": b'{"schema":"masc.skill-activations/v5"}\n',
        "tui-build-evidence.json": build_raw,
        "masc_tui.exe": executable,
    }
    for name, payload in proof_payloads.items():
        if name not in ("tui-build-evidence.json", "masc_tui.exe"):
            (proof_root / name).write_bytes(payload)
    dashboard_png = b"dashboard-png"
    (proof_root / "dashboard-skill-use.png").write_bytes(dashboard_png)
    proof_identity = {
        "keeper": "keeper-one",
        "skill_tool_use_id": SKILL_ID,
        "workspace_key": WORKSPACE,
        "session_id": "trace-one",
        "ledger_revision": LEDGER_REVISION,
        "reference": reference_flat,
        "snapshot_revision": SNAPSHOT,
        "turn_ref": TURN_REF,
        "invocation_runtime_id": "runtime-one",
        "delivery": delivery,
        "actions": [action],
        "scoped_summary": {
            "summary": {
                "instruction_provider_deliveries": 1,
                "instruction_official_client_handoffs": 0,
                "invalid_transitions": 0,
            }
        },
    }
    proof = {
        "schema": verifier.PROOF_SCHEMA,
        "source": {
            "expected_sha": HEAD,
            "collector_head": HEAD,
            "collector_tree": TREE,
            "tracked_checkout_clean": True,
            "binary_commit": HEAD,
            "binary_commit_source": "embedded",
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

    tui_png = b"tui-png"
    (tui_root / "tui-skill-use.png").write_bytes(tui_png)
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
            "ledger_revision": LEDGER_REVISION,
            "skill_tool_use_id": SKILL_ID,
            "action_markers": ["call=call-action-1"],
            "captured_action_marker": "call=call-action-1",
        },
        "server": {**server(), "binary_commit_source": "embedded"},
        "selection": {"visited_keepers": ["keeper-one"]},
        "producer_artifacts": producer_artifacts,
        "terminal": {"cols": 180, "rows": 42},
        "visible_text": "exact visible Skill proof",
        "visible_text_sha256": verifier.digest(b"exact visible Skill proof"),
        "screenshot": {"path": "tui-skill-use.png", **file_identity(tui_png)},
    }
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
                    verifier.VerificationError, "Skill identities differ"
                ):
                    verify(bundle)

    def test_artifact_byte_tamper_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            (bundle["join_root"] / "health-before.json").write_bytes(b"tampered")
            with self.assertRaisesRegex(verifier.VerificationError, "byte count differs"):
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
            with self.assertRaisesRegex(verifier.VerificationError, "join is not exact"):
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

    def test_delivery_and_action_tamper_are_rejected(self):
        for field, value, error in (
            ("delivery", None, "proof identity.delivery is not an object"),
            ("actions", [], "no later model-selected action"),
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as raw:
                bundle = make_bundle(Path(raw))
                bundle["proof"]["proof"][field] = value
                with self.assertRaisesRegex(verifier.VerificationError, error):
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
                verifier.VerificationError, "join producer.keeper is empty"
            ):
                verify(bundle)

        with self.subTest(field="delivery"), tempfile.TemporaryDirectory() as raw:
            bundle = make_bundle(Path(raw))
            del bundle["join"]["result"]["matches"][0]["delivery"]
            del bundle["proof"]["proof"]["delivery"]
            with self.assertRaisesRegex(
                verifier.VerificationError, "join match.delivery is not an object"
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
                verifier.VerificationError, "TUI proof.ledger_revision is empty"
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
                verifier.VerificationError, "collides with a proof artifact"
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
            with self.assertRaisesRegex(verifier.VerificationError, "byte count differs"):
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

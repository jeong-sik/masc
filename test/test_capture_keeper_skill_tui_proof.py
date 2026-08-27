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
    REPO_ROOT / "scripts" / "harness" / "workload" / "capture_keeper_skill_tui_proof.py"
)


def load_module():
    spec = importlib.util.spec_from_file_location(
        "capture_keeper_skill_tui_proof", SCRIPT_PATH
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


capture = load_module()
HEAD = "a" * 40
TREE = "b" * 40
SKILL_ID = "call-skill-1"
INSTANCE = "018f1d5e-7b3c-7abc-8def-0123456789ab"


def fixture(action_identity=None):
    identity = action_identity or {"kind": "call_id", "call_id": "call-action-1"}
    activation = {
        "skill_tool_use_id": SKILL_ID,
        "actions": [
            {
                "identity": identity,
                "tool_name": "keeper_time_now",
                "runtime_id": "runtime-one",
                "agent_core_turn": 1,
                "observed_at": "2026-08-27T00:00:00Z",
            }
        ],
    }
    dashboard = {
        "effective_keeper_surface": {
            "status": "available",
            "keeper_name": "keeper-one",
        },
        "skill_activations": {
            "status": "available",
            "keeper_name": "keeper-one",
            "ledger": {
                "schema": "masc.skill-activations/v5",
                "session_id": "trace-one",
                "revision": "b" * 64,
                "activations": [activation],
            },
        },
    }
    dashboard_payload = (
        json.dumps(dashboard, indent=2, sort_keys=True) + "\n"
    ).encode()
    evidence = {
        "schema": "masc.keeper-skill-use-proof.v1",
        "source": {
            "expected_sha": HEAD,
            "collector_tree": TREE,
            "tracked_checkout_clean": True,
            "server_started_at": "2026-08-27T00:00:00Z",
            "server_runtime_instance_id": INSTANCE,
            "tui_build": {
                "manifest_sha256": "c" * 64,
                "executable_sha256": "d" * 64,
                "executable_bytes": 42,
            },
        },
        "runtime": {
            "base_url": "http://127.0.0.1:8935",
            "effective_base_path": "/workspace",
            "effective_masc_root": "/workspace/.masc",
        },
        "proof": {
            "keeper": "keeper-one",
            "session_id": "trace-one",
            "ledger_revision": "b" * 64,
            "skill_tool_use_id": SKILL_ID,
            "actions": activation["actions"],
        },
        "artifacts": {
            "dashboard-tools.json": {
                "bytes": len(dashboard_payload),
                "sha256": capture.digest_bytes(dashboard_payload),
            }
        },
    }
    return evidence, dashboard_payload, dashboard


class CaptureKeeperSkillTuiProofTest(unittest.TestCase):
    def test_requires_out_of_band_producer_proof_sha(self):
        payload = b"exact producer proof\n"
        capture.require_expected_digest(
            payload, capture.digest_bytes(payload), "producer proof"
        )
        with self.assertRaisesRegex(capture.CaptureError, "expected SHA"):
            capture.require_expected_digest(payload, "0" * 64, "producer proof")

    def validate(self, evidence, dashboard_payload, dashboard):
        return capture.validate_bundle(
            evidence=evidence,
            dashboard_payload=dashboard_payload,
            dashboard=dashboard,
            source_head=HEAD,
            source_tree=TREE,
            tracked_checkout_clean=True,
        )

    def test_accepts_call_id_action(self):
        evidence, dashboard_payload, dashboard = fixture()

        selected = self.validate(evidence, dashboard_payload, dashboard)

        self.assertEqual(selected["action_markers"], ["call=call-action-1"])

    def test_accepts_provider_step_action(self):
        evidence, dashboard_payload, dashboard = fixture(
            {
                "kind": "provider_step",
                "conversation_id": "conversation-one",
                "step_index": 7,
            }
        )

        selected = self.validate(evidence, dashboard_payload, dashboard)

        self.assertEqual(selected["action_markers"], ["step=conversation-one:7"])

    def test_rejects_source_head_mismatch(self):
        evidence, dashboard_payload, dashboard = fixture()

        with self.assertRaisesRegex(capture.CaptureError, "source HEAD differs"):
            capture.validate_bundle(
                evidence=evidence,
                dashboard_payload=dashboard_payload,
                dashboard=dashboard,
                source_head="0" * 40,
                source_tree=TREE,
                tracked_checkout_clean=True,
            )

    def test_rejects_tui_base_url_credentials(self):
        evidence, dashboard_payload, dashboard = fixture()
        evidence["runtime"]["base_url"] = "http://user:secret@127.0.0.1:8935"

        with self.assertRaisesRegex(
            capture.CaptureError, "must not contain credentials"
        ):
            self.validate(evidence, dashboard_payload, dashboard)

    def test_rejects_dashboard_artifact_hash_mismatch(self):
        evidence, dashboard_payload, dashboard = fixture()
        evidence["artifacts"]["dashboard-tools.json"]["sha256"] = "0" * 64

        with self.assertRaisesRegex(capture.CaptureError, "SHA differs"):
            self.validate(evidence, dashboard_payload, dashboard)

    def test_rejects_ledger_revision_drift(self):
        evidence, dashboard_payload, dashboard = fixture()
        dashboard["skill_activations"]["ledger"]["revision"] = "0" * 64
        dashboard_payload = (
            json.dumps(dashboard, indent=2, sort_keys=True) + "\n"
        ).encode()
        evidence["artifacts"]["dashboard-tools.json"] = {
            "bytes": len(dashboard_payload),
            "sha256": capture.digest_bytes(dashboard_payload),
        }

        with self.assertRaisesRegex(capture.CaptureError, "ledger differs"):
            self.validate(evidence, dashboard_payload, dashboard)

    def test_rejects_manifest_actions_not_in_exact_activation(self):
        evidence, dashboard_payload, dashboard = fixture()
        evidence = copy.deepcopy(evidence)
        evidence["proof"]["actions"][0]["identity"] = {
            "kind": "call_id",
            "call_id": "unrelated-action",
        }

        with self.assertRaisesRegex(capture.CaptureError, "action identities differ"):
            self.validate(evidence, dashboard_payload, dashboard)

    def test_rejects_dirty_tracked_checkout(self):
        evidence, dashboard_payload, dashboard = fixture()

        with self.assertRaisesRegex(capture.CaptureError, "tracked changes"):
            capture.validate_bundle(
                evidence=evidence,
                dashboard_payload=dashboard_payload,
                dashboard=dashboard,
                source_head=HEAD,
                source_tree=TREE,
                tracked_checkout_clean=False,
            )

    def test_parses_exact_keeper_heading(self):
        screen = "│ Effective Keeper Surface — keeper-one (94 tools) │"

        self.assertEqual(capture.selected_keeper_from_screen(screen), "keeper-one")

    def test_loading_placeholder_is_not_a_keeper(self):
        self.assertIsNone(
            capture.selected_keeper_from_screen(
                "│ Effective Keeper Surface — not loaded │"
            )
        )
        self.assertIsNone(
            capture.selected_keeper_from_screen(
                "│ Effective Keeper Surface — no Keeper selected │"
            )
        )

    def test_action_must_be_inside_exact_receipt_block(self):
        same = "\n".join(
            [
                "invoked turn=1 id=call-skill-1 runtime=one",
                "action turn=1 runtime=one tool=x call=call-action-1",
            ]
        )
        another = "\n".join(
            [
                "invoked turn=1 id=call-skill-1 runtime=one",
                "invoked turn=2 id=call-skill-2 runtime=one",
                "action turn=2 runtime=one tool=x call=call-action-1",
            ]
        )

        self.assertTrue(
            capture.receipt_block_contains(same, "call-skill-1", "call=call-action-1")
        )
        self.assertFalse(
            capture.receipt_block_contains(
                another, "call-skill-1", "call=call-action-1"
            )
        )
        prefix_collision = "\n".join(
            [
                "invoked turn=1 id=call-skill-10 runtime=one",
                "action turn=1 runtime=one tool=x call=call-action-1",
            ]
        )
        self.assertFalse(
            capture.receipt_block_contains(
                prefix_collision, "call-skill-1", "call=call-action-1"
            )
        )

    def test_live_server_identity_rejects_restart(self):
        evidence, _, _ = fixture()
        health = {
            "health_detail": "full",
            "build": {
                "binary_commit": HEAD,
                "binary_commit_source": "embedded",
                "runtime_instance_id": INSTANCE,
                "started_at": "2026-08-27T00:00:00Z",
            },
            "paths": {
                "effective_base_path": "/workspace",
                "effective_masc_root": "/workspace/.masc",
            },
        }

        self.assertEqual(
            capture.validate_live_server(evidence, health)["binary_commit"], HEAD
        )
        health["build"]["started_at"] = "2026-08-27T00:01:00Z"
        with self.assertRaisesRegex(capture.CaptureError, "process changed"):
            capture.validate_live_server(evidence, health)
        health["build"]["started_at"] = "2026-08-27T00:00:00Z"
        health["build"]["runtime_instance_id"] = "018f1d5e-7b3c-7abc-8def-0123456789ac"
        with self.assertRaisesRegex(capture.CaptureError, "process identity changed"):
            capture.validate_live_server(evidence, health)

    def test_verifies_every_producer_artifact_and_dashboard_screenshot(self):
        evidence, dashboard_payload, dashboard = fixture()
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            health = {
                "health_detail": "full",
                "build": {
                    "binary_commit": HEAD,
                    "binary_commit_source": "embedded",
                    "runtime_instance_id": INSTANCE,
                    "started_at": "2026-08-27T00:00:00Z",
                },
                "paths": {
                    "effective_base_path": "/workspace",
                    "effective_masc_root": "/workspace/.masc",
                },
            }
            health_payload = (
                json.dumps(health, indent=2, sort_keys=True) + "\n"
            ).encode()
            ledger_payload = (
                json.dumps(
                    dashboard["skill_activations"]["ledger"],
                    indent=2,
                    sort_keys=True,
                )
                + "\n"
            ).encode()
            build_payload = b"{}\n"
            executable_payload = b"trusted-binary"
            payloads = {
                "health.json": health_payload,
                "dashboard-tools.json": dashboard_payload,
                "skill-activations.json": ledger_payload,
                "tui-build-evidence.json": build_payload,
                "masc_tui.exe": executable_payload,
            }
            evidence["artifacts"] = {}
            for name, payload in payloads.items():
                (root / name).write_bytes(payload)
                evidence["artifacts"][name] = {
                    "bytes": len(payload),
                    "sha256": capture.digest_bytes(payload),
                }
            screenshot = b"png"
            (root / "dashboard-skill-use.png").write_bytes(screenshot)
            evidence["dashboard"] = {
                "path": "dashboard-skill-use.png",
                "bytes": len(screenshot),
                "sha256": capture.digest_bytes(screenshot),
            }

            verified = capture.verify_producer_artifacts(evidence, root)

            self.assertEqual(set(verified), {*payloads, "dashboard-skill-use.png"})
            (root / "INCOMPLETE").write_text("partial\n", encoding="utf-8")
            with self.assertRaisesRegex(capture.CaptureError, "bundle is incomplete"):
                capture.verify_producer_artifacts(evidence, root)
            (root / "INCOMPLETE").unlink()
            (root / "skill-activations.json").write_bytes(b"changed")
            with self.assertRaisesRegex(
                capture.CaptureError, "artifact (byte|SHA) mismatch"
            ):
                capture.verify_producer_artifacts(evidence, root)

    def test_rejects_producer_artifact_subset(self):
        evidence, _, _ = fixture()
        evidence["artifacts"] = {
            "dashboard-tools.json": evidence["artifacts"]["dashboard-tools.json"]
        }
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaisesRegex(capture.CaptureError, "required v1 set"):
                capture.verify_producer_artifacts(evidence, Path(raw))

    def test_rejects_producer_health_manifest_drift(self):
        evidence, dashboard_payload, dashboard = fixture()
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            health = {
                "health_detail": "full",
                "build": {
                    "binary_commit": HEAD,
                    "binary_commit_source": "embedded",
                    "runtime_instance_id": INSTANCE,
                    "started_at": "2026-08-27T00:00:00Z",
                },
                "paths": {
                    "effective_base_path": "/workspace",
                    "effective_masc_root": "/workspace/.masc",
                },
            }
            payloads = {
                "health.json": (json.dumps(health) + "\n").encode(),
                "dashboard-tools.json": dashboard_payload,
                "skill-activations.json": (
                    json.dumps(dashboard["skill_activations"]["ledger"]) + "\n"
                ).encode(),
                "tui-build-evidence.json": b"{}\n",
                "masc_tui.exe": b"trusted-binary",
            }
            evidence["source"]["server_started_at"] = "2026-08-27T00:01:00Z"
            evidence["artifacts"] = {}
            for name, payload in payloads.items():
                (root / name).write_bytes(payload)
                evidence["artifacts"][name] = {
                    "bytes": len(payload),
                    "sha256": capture.digest_bytes(payload),
                }
            (root / "dashboard-skill-use.png").write_bytes(b"png")
            evidence["dashboard"] = {
                "path": "dashboard-skill-use.png",
                "bytes": 3,
                "sha256": capture.digest_bytes(b"png"),
            }

            with self.assertRaisesRegex(capture.CaptureError, "process changed"):
                capture.verify_producer_artifacts(evidence, root)

    def test_tui_executable_is_probed_only_after_trusted_hash_match(self):
        evidence, _, _ = fixture()
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            executable = b"trusted-executable"
            build = {
                "schema": "masc.tui-build-evidence/v1",
                "source": {
                    "head": HEAD,
                    "tree": TREE,
                    "tracked_checkout_clean": True,
                },
                "artifact": {
                    "path": "masc_tui.exe",
                    "bytes": len(executable),
                    "sha256": capture.digest_bytes(executable),
                },
            }
            build_raw = (json.dumps(build, sort_keys=True) + "\n").encode()
            (root / "tui-build-evidence.json").write_bytes(build_raw)
            (root / "masc_tui.exe").write_bytes(executable)
            evidence["source"]["tui_build"] = {
                "manifest_sha256": capture.digest_bytes(build_raw),
                "executable_sha256": capture.digest_bytes(executable),
                "executable_bytes": len(executable),
            }
            completed = capture.subprocess.CompletedProcess(
                [str(root / "masc_tui.exe"), "--help"],
                0,
                "masc-tui [OPTIONS]\n",
                "",
            )
            with mock.patch.object(
                capture.subprocess, "run", return_value=completed
            ) as run:
                path, payload, _ = capture.validate_tui_executable(evidence, root, 1.0)
            self.assertEqual(path, (root / "masc_tui.exe").resolve())
            self.assertEqual(payload, executable)
            self.assertNotIn("AWS_SECRET_ACCESS_KEY", run.call_args.kwargs["env"])

            evidence["source"]["tui_build"]["executable_sha256"] = "0" * 64
            with mock.patch.object(capture.subprocess, "run") as rejected_run:
                with self.assertRaisesRegex(
                    capture.CaptureError, "artifact identity differs"
                ):
                    capture.validate_tui_executable(evidence, root, 1.0)
            rejected_run.assert_not_called()


if __name__ == "__main__":
    unittest.main()

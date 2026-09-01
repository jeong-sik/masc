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
sys.path.insert(0, str(SCRIPT_PATH.parent))


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
        "schema": "masc.keeper-skill-use-proof.v2",
        "source": {
            "expected_sha": HEAD,
            "collector_tree": TREE,
            "tracked_checkout_clean": True,
            "server_started_at": "2026-08-27T00:00:00Z",
            "server_runtime_instance_id": INSTANCE,
            "source_fingerprint": "e" * 64,
            "executable_sha256": "f" * 64,
            "executable_provenance_path": "/tmp/server.provenance.json",
            "executable_provenance_sha256": "1" * 64,
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
    def test_backend_pty_size_reads_the_exact_ttyd_child(self):
        process_table = "  100     1 ??\n  101   100 ttys001\n"
        with (
            mock.patch.object(
                capture.subprocess,
                "check_output",
                return_value=process_table,
            ),
            mock.patch.object(capture.os, "open", return_value=7) as open_tty,
            mock.patch.object(
                capture.os,
                "get_terminal_size",
                return_value=capture.os.terminal_size((180, 42)),
            ),
            mock.patch.object(capture.os, "close") as close_tty,
        ):
            observed = capture.backend_pty_size(100)

        self.assertEqual(
            observed,
            {
                "child_pid": 101,
                "device": "/dev/ttys001",
                "cols": 180,
                "rows": 42,
            },
        )
        open_tty.assert_called_once_with(
            Path("/dev/ttys001"), capture.os.O_RDONLY | capture.os.O_NOCTTY
        )
        close_tty.assert_called_once_with(7)

    def test_ttyd_identity_binds_version_and_executable_digest(self):
        with tempfile.TemporaryDirectory() as raw:
            ttyd = Path(raw) / "ttyd"
            ttyd.write_bytes(b"exact ttyd binary")
            completed = mock.Mock(returncode=0, stdout=b"ttyd version 1.7.7\n")
            with mock.patch.object(capture.subprocess, "run", return_value=completed):
                observed = capture.ttyd_executable_identity(ttyd)

        self.assertEqual(observed["path"], str(ttyd.resolve()))
        self.assertEqual(observed["bytes"], len(b"exact ttyd binary"))
        self.assertEqual(observed["sha256"], capture.digest_bytes(b"exact ttyd binary"))
        self.assertEqual(observed["version"], "ttyd version 1.7.7")

    def test_ttyd_session_executes_the_attested_resolved_path(self):
        page = mock.Mock()
        context = mock.Mock()
        context.new_page.return_value = page
        browser = mock.Mock()
        browser.new_context.return_value = context
        process = mock.Mock()
        attested = {
            "path": "/attested/ttyd",
            "bytes": 42,
            "sha256": "a" * 64,
            "version": "ttyd version 1.7.7",
        }
        backend = {
            "child_pid": 321,
            "device": "/dev/ttys001",
            "cols": 180,
            "rows": 42,
        }
        with (
            mock.patch.object(
                capture, "ttyd_executable_identity", return_value=attested
            ),
            mock.patch.object(
                capture.subprocess, "Popen", return_value=process
            ) as popen,
            mock.patch.object(capture, "wait_port"),
            mock.patch.object(capture, "synchronize_ttyd_terminal_size"),
            mock.patch.object(capture, "backend_pty_size", return_value=backend),
            capture.ttyd_session(
                browser=browser,
                ttyd=Path("relative/ttyd"),
                executable=Path("/proof/masc_tui.exe"),
                base_path="/workspace",
                host="127.0.0.1",
                api_port=8935,
                cols=180,
                rows=42,
                timeout=3.0,
                token="token",
            ),
        ):
            pass

        self.assertEqual(popen.call_args.args[0][0], "/attested/ttyd")

    def test_ttyd_size_is_replayed_after_the_pty_connects(self):
        page = mock.Mock()

        capture.synchronize_ttyd_terminal_size(page, cols=180, rows=42, timeout=3.0)

        size = {"cols": 180, "rows": 42}
        self.assertEqual(page.evaluate.call_args_list[0].args[1], size)
        replay_script = page.evaluate.call_args_list[1].args[0]
        self.assertIn("intermediateRows", replay_script)
        self.assertIn("window.term.resize(size.cols, size.rows)", replay_script)
        self.assertEqual(page.evaluate.call_args_list[1].args[1], size)
        self.assertIn(
            ".xterm-screen",
            page.wait_for_function.call_args_list[1].args[0],
        )
        self.assertEqual(
            page.wait_for_function.call_args_list[1].kwargs["arg"],
            "MASC Overview",
        )
        self.assertEqual(
            page.wait_for_function.call_args_list[1].kwargs["timeout"], 3000
        )

    def test_strict_http_and_tui_child_share_explicit_bearer(self):
        token = "strict-tui-token"

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                return b'{"ok":true}'

        def open_request(request, timeout):
            self.assertEqual(timeout, 4.0)
            self.assertEqual(request.get_header("Authorization"), f"Bearer {token}")
            return Response()

        with mock.patch.object(
            capture.proof_http, "open_no_redirect", side_effect=open_request
        ):
            value = capture.read_json_url("https://masc.invalid/strict", 4.0, token)

        self.assertEqual(value, {"ok": True})
        environment = capture.safe_environment("/workspace", "127.0.0.1", token)
        self.assertEqual(environment["MASC_TOKEN"], token)

    def test_token_file_is_one_regular_non_symlink_line(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            token_file = root / "token"
            token_file.write_text("exact-token\n", encoding="utf-8")
            self.assertEqual(capture.read_token(token_file), "exact-token")
            token_file.write_text("first\nsecond\n", encoding="utf-8")
            with self.assertRaisesRegex(capture.CaptureError, "multiple lines"):
                capture.read_token(token_file)
            target = root / "target"
            target.write_text("secret", encoding="utf-8")
            link = root / "link"
            link.symlink_to(target)
            with self.assertRaisesRegex(capture.CaptureError, "symlink"):
                capture.read_token(link)

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

    def test_tools_navigation_walks_to_config_and_hops(self):
        # Tools is off the Tab ring: the walk stops at Config and presses
        # [t], and arrival is the Tools screen text, not a strip token.
        class Page:
            def wait_for_timeout(self, _milliseconds):
                pass

        screens = iter(
            [
                "▸Overview Activity Config\n  MASC Overview",
                "▸Overview Activity Config\n  MASC Overview",
                "Overview ▸Activity Config\n  MASC Activity",
                "Overview ▸Activity Config\n  MASC Activity",
                "Overview Activity ▸Config\n  MASC Config",
            ]
        )
        with (
            mock.patch.object(capture, "screen_text", side_effect=screens),
            mock.patch.object(capture, "press") as press,
            mock.patch.object(capture, "wait_screen") as wait_screen,
        ):
            capture.goto_tools(Page(), 1.0)

        self.assertEqual(
            [call.args[1] for call in press.call_args_list], ["Tab", "Tab", "t"]
        )
        wait_screen.assert_called_once()

    def test_tools_navigation_rejects_a_complete_surface_cycle(self):
        class Page:
            def wait_for_timeout(self, _milliseconds):
                pass

        screens = iter(
            [
                "▸Overview Activity Board",
                "Overview ▸Activity Board",
                "▸Overview Activity Board",
            ]
        )
        with (
            mock.patch.object(capture, "screen_text", side_effect=screens),
            mock.patch.object(capture, "press"),
        ):
            with self.assertRaisesRegex(capture.CaptureError, "surface cycle"):
                capture.goto_tools(Page(), 1.0)

    def test_tools_activations_navigation_follows_the_observed_pane_ring(self):
        class Page:
            def wait_for_timeout(self, _milliseconds):
                pass

        screens = iter(
            [
                "MASC Tools  ▸surface | async | activations | usage | catalog",
                "MASC Tools   surface |▸async | activations | usage | catalog",
                "MASC Tools   surface | async |▸activations | usage | catalog",
            ]
        )
        with (
            mock.patch.object(capture, "screen_text", side_effect=screens),
            mock.patch.object(capture, "press") as press,
        ):
            visited = capture.select_tools_activations(Page(), 1.0)

        self.assertEqual(visited, ["surface", "async", "activations"])
        self.assertEqual([call.args[1] for call in press.call_args_list], ["p", "p"])

    def test_tools_activations_navigation_rejects_a_complete_pane_cycle(self):
        class Page:
            def wait_for_timeout(self, _milliseconds):
                pass

        screens = iter(
            [
                "MASC Tools  ▸surface | async | activations | usage | catalog",
                "MASC Tools   surface |▸async | activations | usage | catalog",
                "MASC Tools  ▸surface | async | activations | usage | catalog",
            ]
        )
        with (
            mock.patch.object(capture, "screen_text", side_effect=screens),
            mock.patch.object(capture, "press"),
        ):
            with self.assertRaisesRegex(capture.CaptureError, "Tools pane cycle"):
                capture.select_tools_activations(Page(), 1.0)

    def test_tools_pane_parser_keeps_an_unfamiliar_observed_pane(self):
        self.assertEqual(
            capture.selected_tools_pane_from_screen(
                "MASC Tools   surface |▸future | activations"
            ),
            "future",
        )

    def test_exact_keeper_selection_does_not_require_offscreen_receipts(self):
        with (
            mock.patch.object(
                capture,
                "screen_text",
                return_value="Effective Keeper Surface — keeper-one (94 tools)",
            ),
            mock.patch.object(capture, "wait_screen") as wait_screen,
        ):
            visited = capture.select_exact_keeper(object(), "keeper-one", 1.0)

        self.assertEqual(visited, ["keeper-one"])
        wait_screen.assert_not_called()

    def test_ledger_projection_requires_the_full_revision(self):
        revision = "abcdef0123456789"

        self.assertTrue(
            capture.ledger_projection_matches(
                f"session=trace-one  ledger={revision}", "trace-one", revision
            )
        )
        self.assertFalse(
            capture.ledger_projection_matches(
                "session=trace-one  ledger=abcdef012345…", "trace-one", revision
            )
        )
        self.assertFalse(
            capture.ledger_projection_matches(
                "session=trace-one  ledger=deadbeef…", "trace-one", revision
            )
        )

    def test_scroll_collects_header_before_an_offscreen_exact_receipt(self):
        class Page:
            def wait_for_timeout(self, _milliseconds):
                pass

        top = "\n".join(
            [
                "MASC Tools 14:10:47 [connected]",
                "Skill Use — keeper-one (8 receipts)",
                "session=trace-one  ledger=abcdef0123456789",
                "invoked=8 actions=8 invalid=0",
            ]
        )
        middle = "MASC Tools 14:10:47 [connected]\nolder receipts"
        activation = {
            "identity": {
                "source_id": "source",
                "package_id": "package",
                "name": "skill",
            },
            "content_revision": "c" * 64,
            "snapshot_revision": "s" * 64,
            "turn_ref": "trace-1787957197137-00000#104",
            "agent_core_turn": 8,
            "skill_tool_use_id": "call-skill-1",
            "runtime_id": "ollama_cloud.minimax-m3",
            "activated_at": "2026-08-29T01:52:26Z",
            "invocation": {
                "kind": "instruction",
                "origin": {"kind": "session_instruction"},
                "served_content": {
                    "kind": "skill_body",
                    "bytes": 3,
                    "sha256": "b" * 64,
                },
            },
            "delivery": {
                "boundary": {"kind": "model_response", "agent_core_turn": 8},
                "runtime_id": "ollama_cloud.minimax-m3",
                "content_bytes": 3,
                "content_sha256": "b" * 64,
                "delivered_at": "2026-08-29T01:52:35Z",
            },
        }
        action = {
            "identity": {"kind": "call_id", "call_id": "call-action-1"},
            "agent_core_turn": 8,
            "runtime_id": "ollama_cloud.minimax-m3",
            "tool_name": "x",
            "observed_at": "2026-08-29T01:52:35Z",
        }
        receipt_sha256 = capture.receipt_projection_revision(
            "abcdef0123456789", "call-skill-1"
        )
        receipt = "\n".join(
            [
                "MASC Tools 14:10:47 [connected]",
                f"receipt_sha256={receipt_sha256}",
            ]
        )
        screens = iter([top, middle, middle, receipt, receipt, receipt])
        with (
            mock.patch.object(capture, "screen_text", side_effect=screens),
            mock.patch.object(capture, "press") as press,
        ):
            captured_frames = []
            visible, observations, visible_frames = capture.scroll_to_skill_receipt(
                Page(),
                keeper="keeper-one",
                session_id="trace-one",
                ledger_revision="abcdef0123456789",
                activation=activation,
                actions=[action],
                capture_frame=captured_frames.append,
                timeout=1.0,
            )

        self.assertEqual(visible, receipt)
        self.assertEqual(
            observations["skill_header"], "Skill Use — keeper-one (8 receipts)"
        )
        self.assertEqual(observations["receipt_sha256"], receipt_sha256)
        self.assertEqual(visible_frames, [receipt])
        self.assertEqual(captured_frames, [0])
        self.assertEqual([call.args[1] for call in press.call_args_list], ["End", "k"])

    def test_scroll_returns_to_header_after_receipt_identity_is_visible_first(self):
        class Page:
            def wait_for_timeout(self, _milliseconds):
                pass

        revision = "a" * 64
        skill_tool_use_id = "call-" + ("한" * 200)
        receipt_sha256 = capture.receipt_projection_revision(
            revision, skill_tool_use_id
        )
        receipt = "\n".join(
            [
                "MASC Tools 14:10:47 [connected]",
                f"receipt_sha256={receipt_sha256}",
            ]
        )
        top = "\n".join(
            [
                "MASC Tools 14:10:48 [connected]",
                "Skill Use — keeper-one (8 receipts)",
                f"session=trace-one  ledger={revision}",
            ]
        )
        screens = iter([receipt, receipt, top, top])
        with (
            mock.patch.object(capture, "screen_text", side_effect=screens),
            mock.patch.object(capture, "press") as press,
        ):
            visible, observations, frames = capture.scroll_to_skill_receipt(
                Page(),
                keeper="keeper-one",
                session_id="trace-one",
                ledger_revision=revision,
                activation={"skill_tool_use_id": skill_tool_use_id},
                actions=[],
                capture_frame=lambda _index: None,
                timeout=1.0,
            )

        self.assertEqual(visible, top)
        self.assertEqual(observations["receipt_sha256"], receipt_sha256)
        self.assertEqual(frames, [receipt])
        self.assertEqual([call.args[1] for call in press.call_args_list], ["Home"])

    def test_receipt_projection_revision_binds_full_unicode_identifier(self):
        revision = "8b9a4dc07173dbf0deca356bf3b9ae53c6da7b155c006087364c48bbfdee70c8"
        self.assertEqual(
            capture.receipt_projection_revision(revision, "call-한한한A"),
            "4f92d081521e839a230f46fbb531c0eae99d3f2f847e062ed174a2720ef3ecff",
        )
        shared = "call-" + ("한" * 200)
        left = capture.receipt_projection_revision(revision, shared + "A")
        right = capture.receipt_projection_revision(revision, shared + "B")
        self.assertRegex(left, r"^[0-9a-f]{64}$")
        self.assertNotEqual(left, right)

    def test_tools_surface_connection_rejects_disconnected(self):
        self.assertTrue(
            capture.tools_surface_is_connected("MASC Tools 14:10:47 [connected]")
        )
        self.assertFalse(
            capture.tools_surface_is_connected("MASC Tools 14:10:48 [disconnected]")
        )

    def test_tools_surface_waits_through_reconnecting(self):
        class Page:
            def wait_for_timeout(self, _milliseconds):
                pass

        screens = iter(
            [
                "MASC Tools 14:10:47 [reconnecting]",
                "MASC Tools 14:10:48 [connected]",
            ]
        )
        with mock.patch.object(capture, "screen_text", side_effect=screens):
            visible = capture.wait_tools_surface_connected(
                Page(), capture.time.monotonic() + 1.0
            )
        self.assertTrue(capture.tools_surface_is_connected(visible))

    def test_live_server_identity_rejects_restart(self):
        evidence, _, _ = fixture()
        health = {
            "health_detail": "full",
            "build": {
                "binary_commit": HEAD,
                "binary_commit_source": "embedded",
                "source_fingerprint": "e" * 64,
                "executable_sha256": "f" * 64,
                "executable_provenance_path": "/tmp/server.provenance.json",
                "executable_provenance_sha256": "1" * 64,
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
        health["build"]["runtime_instance_id"] = INSTANCE
        health["build"]["source_fingerprint"] = "2" * 64
        with self.assertRaisesRegex(capture.CaptureError, "source_fingerprint changed"):
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
                    "source_fingerprint": "e" * 64,
                    "executable_sha256": "f" * 64,
                    "executable_provenance_path": "/tmp/server.provenance.json",
                    "executable_provenance_sha256": "1" * 64,
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
                    "source_fingerprint": "e" * 64,
                    "executable_sha256": "f" * 64,
                    "executable_provenance_path": "/tmp/server.provenance.json",
                    "executable_provenance_sha256": "1" * 64,
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

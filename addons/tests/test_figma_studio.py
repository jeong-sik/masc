"""Studio scenarios through the same host-context entrypoint used by MASC."""

import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PACKAGE = Path(__file__).resolve().parents[1] / "figma-studio"
sys.path.insert(0, str(PACKAGE))
spec = importlib.util.spec_from_file_location("studio_worker", PACKAGE / "server.py")
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
Worker, Refused = module.Worker, module.Refused
BINDING = {
    "installation": "studio-test",
    "keeper": "leader",
    "relay_agent": "studio-relay",
    "sources": [],
}
OWNER = {"kind": "keeper", "name": "leader"}
RELAY = {"kind": "agent", "name": "studio-relay"}
PNG = b"\x89PNG\r\n\x1a\nfixture-bytes"


def bundle(session="plugin-1", root="frame:1"):
    return {
        "schema_version": 1,
        "source": "plugin_live",
        "session_id": session,
        "root_id": root,
        "page_id": "page:1",
        "tree_json": json.dumps(
            {
                "document": {
                    "id": root,
                    "type": "FRAME",
                    "name": "Sign in",
                    "children": [
                        {"id": "text:1", "type": "TEXT", "characters": "Welcome"}
                    ],
                }
            }
        ),
        "preview": {
            "mime_type": "image/png",
            "data_base64": base64.b64encode(PNG).decode(),
        },
        "coverage": {"stable": True, "missing": ["font_files"]},
        "observed_at": 123.0,
    }


class StudioTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.worker = Worker(Path(self.directory.name))
        self.worker.call("lane_observe", {"binding": BINDING, "sources": []})

    def tearDown(self):
        self.worker.store.db.close()
        self.directory.cleanup()

    def call(self, tool, args=None, caller=OWNER):
        return self.worker.call(
            "lane_call", {"tool": tool, "arguments": args or {}, "caller": caller}
        )

    def relay(self, kind, session="plugin-1", **values):
        return self.call(
            "masc_figma_relay",
            {
                "kind": kind,
                "worker_boot_id": self.worker.store.boot_id,
                "session_id": session,
                **values,
            },
            RELAY,
        )["structuredContent"]

    def pair(self, session="plugin-1"):
        self.relay(
            "session",
            session,
            document={
                "name": "File",
                "page_id": "page:1",
                "selection": [],
                "editor_type": "figma",
                "mode": "default",
                "can_edit": True,
            },
        )
        self.call("masc_figma_bind", {"session_id": session})

    def capture(self):
        self.pair()
        self.call(
            "masc_figma_submit",
            {
                "operation_id": "capture-1",
                "session_id": "plugin-1",
                "kind": "capture",
                "root_id": "frame:1",
            },
        )
        self.assertEqual(self.relay("poll")["command"]["id"], "capture-1")
        return self.relay("result", operation_id="capture-1", ok=True, payload=bundle())

    def test_capture_read_image_and_validate_same_snapshot(self):
        operation = self.capture()
        identity = operation["result"]["snapshot_id"]
        snapshot = self.call("masc_figma_snapshot", {"snapshot_id": identity})
        self.assertEqual(base64.b64decode(snapshot["content"][1]["data"]), PNG)
        checks = [{"node_id": "text:1", "path": ["characters"], "equals": "Welcome"}]
        report = self.call(
            "masc_figma_validate", {"snapshot_id": identity, "checks": checks}
        )["structuredContent"]
        self.assertEqual(report["verdict"], "pass")
        self.assertEqual(report["visual_verdict"], "not_evaluated")
        checks[0]["equals"] = "Wrong text"
        failed = self.call(
            "masc_figma_validate", {"snapshot_id": identity, "checks": checks}
        )["structuredContent"]
        self.assertEqual(failed["verdict"], "fail")
        observation = self.worker.call(
            "lane_observe", {"binding": BINDING, "sources": []}
        )["structuredContent"]
        self.assertEqual(len(observation["artifacts"]), 3)
        self.assertTrue(observation["rows"][0]["fields"]["latest_validation"])

    def test_roles_and_explicit_document_binding(self):
        for actor in (
            {"kind": "anonymous"},
            {"kind": "agent", "name": "leader"},
            {"kind": "keeper", "name": "other"},
        ):
            with self.assertRaises(Refused):
                self.call("masc_figma_status", caller=actor)
        with self.assertRaises(Refused):
            self.call("masc_figma_relay", {"kind": "status"})
        self.pair("plugin-2")
        self.assertIsNone(self.relay("poll", "plugin-2")["command"])
        with self.assertRaises(Refused):
            self.call(
                "masc_figma_submit",
                {
                    "operation_id": "x",
                    "session_id": "plugin-1",
                    "kind": "capture",
                    "root_id": "frame:1",
                },
            )

    def test_duplicate_result_and_conflicting_operation_id(self):
        captured = self.capture()
        again = self.relay(
            "result", operation_id="capture-1", ok=True, payload=bundle()
        )
        self.assertEqual(captured, again)
        wrong = bundle()
        wrong["root_id"] = "other"
        with self.assertRaises(Refused):
            self.relay("result", operation_id="capture-1", ok=True, payload=wrong)
        with self.assertRaises(Refused):
            self.call(
                "masc_figma_submit",
                {
                    "operation_id": "capture-1",
                    "session_id": "plugin-1",
                    "kind": "capture",
                    "root_id": "other",
                },
            )

    def test_reply_loss_restart_preserves_unknown_without_redispatch(self):
        self.pair()
        request = {
            "operation_id": "edit-lost",
            "session_id": "plugin-1",
            "kind": "capture",
            "root_id": "frame:1",
        }
        self.call("masc_figma_submit", request)
        self.relay("poll")
        old_boot = self.worker.store.boot_id
        self.worker.store.db.close()
        self.worker = Worker(Path(self.directory.name))
        self.worker.call("lane_observe", {"binding": BINDING, "sources": []})
        self.assertNotEqual(old_boot, self.worker.store.boot_id)
        repeated = self.call("masc_figma_submit", request)["structuredContent"]
        self.assertEqual(repeated["state"], "outcome_unknown")
        self.pair()
        self.assertIsNone(self.relay("poll")["command"])
        with self.assertRaises(Refused):
            self.call(
                "masc_figma_relay",
                {"kind": "poll", "session_id": "plugin-1", "worker_boot_id": old_boot},
                RELAY,
            )

    def test_bad_readback_is_retained_as_unknown(self):
        self.pair()
        self.call(
            "masc_figma_submit",
            {
                "operation_id": "bad",
                "session_id": "plugin-1",
                "kind": "capture",
                "root_id": "frame:1",
            },
        )
        self.relay("poll")
        bad = bundle()
        bad["root_id"] = "frame:elsewhere"
        result = self.relay("result", operation_id="bad", ok=True, payload=bad)
        self.assertEqual(result["state"], "outcome_unknown")
        self.assertIn("identity mismatch", result["result"]["reason"])
        self.assertIsNone(self.worker.store.meta("latest_snapshot"))

    def test_edit_uses_exact_baseline_and_new_worker_cannot_change_owner(self):
        identity = self.capture()["result"]["snapshot_id"]
        self.call(
            "masc_figma_submit",
            {
                "operation_id": "edit",
                "session_id": "plugin-1",
                "kind": "apply",
                "root_id": "frame:1",
                "snapshot_id": identity,
                "ops": [
                    {
                        "op": "rename",
                        "params": {"node_id": "frame:1", "name": "Updated"},
                    }
                ],
            },
        )
        command = self.relay("poll")["command"]
        self.assertEqual(command["expected_tree_json"], bundle()["tree_json"])
        self.assertNotIn("snapshot_id", command)
        with self.assertRaises(Refused):
            self.worker.call(
                "lane_observe",
                {"binding": {**BINDING, "keeper": "different"}, "sources": []},
            )

    def test_stdio_advertises_private_control_and_public_tools_before_binding(self):
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "masc_figma_status", "arguments": {}},
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.run(
                [sys.executable, str(PACKAGE / "server.py"), "--state-dir", directory],
                input="".join(json.dumps(x) + "\n" for x in requests),
                capture_output=True,
                text=True,
                check=True,
            )
        replies = [json.loads(line)["result"] for line in process.stdout.splitlines()]
        self.assertEqual(replies[0]["protocolVersion"], "2025-06-18")
        names = {tool["name"] for tool in replies[1]["tools"]}
        self.assertIn("lane_call", names)
        self.assertIn("masc_figma_snapshot", names)
        self.assertTrue(replies[2]["isError"])
        self.assertEqual(
            replies[2]["_meta"]["io.github.jeong-sik/masc.lane.failure"]["effect"],
            "proven_pre_effect",
        )


if __name__ == "__main__":
    unittest.main()

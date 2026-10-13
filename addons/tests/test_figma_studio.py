"""Studio scenarios through the same host-context entrypoint used by MASC."""

import base64
import importlib.util
import json
import sqlite3
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


MALFORMED_EXPORTS = (
    '{"document":"x"}',
    '{"document":null}',
    '{"document":{"id":"frame:1","children":"x"}}',
    '{"document":{"id":"frame:1","children":[null]}}',
    '{"document":{"id":"frame:1","children":[{"id":false}]}}',
    '{"document":{"id":"frame:1","children":[{"id":"frame:1"}]}}',
    '{"document":{"id":"frame:1","width":NaN}}',
    "{",
)


class StudioTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.worker = Worker(Path(self.directory.name))
        self.worker.call("lane_observe", {"binding": BINDING, "sources": []})

    def tearDown(self):
        self.worker.store.db.close()
        self.directory.cleanup()

    def call(self, tool, args=None, caller=OWNER):
        response = self.worker.call(
            "lane_call", {"tool": tool, "arguments": args or {}, "caller": caller}
        )
        # Decode the same Text content delivered to a Keeper or relay client.
        return {**response, "decoded": json.loads(response["content"][0]["text"])}

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
        )["decoded"]

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

    def submit(self, identity, **values):
        return self.call(
            "masc_figma_submit",
            {
                "operation_id": identity,
                "session_id": "plugin-1",
                "kind": "capture",
                "root_id": "frame:1",
                **values,
            },
        )

    def assert_request_fits(self, tool, args):
        request = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "lane_call",
                "arguments": {"tool": tool, "arguments": args, "caller": OWNER},
            },
        }
        self.assertLessEqual(len(module.encode(request).encode()) + 1, module.MAX_BYTES)

    def observe(self):
        result = self.worker.call("lane_observe", {"binding": BINDING, "sources": []})
        self.assertLessEqual(len(module.response_bytes(1, result)), module.MAX_BYTES)
        return result["structuredContent"]

    def test_exported_result_is_model_visible_without_duplicate_json(self):
        response = self.call("masc_figma_status")
        self.assertNotIn("structuredContent", response)
        self.assertIn("worker_boot_id", json.loads(response["content"][0]["text"]))

    def test_private_stdin_envelope_retains_large_result_and_acknowledges_next_work(
        self,
    ):
        with tempfile.TemporaryDirectory() as directory:
            process = subprocess.Popen(
                [sys.executable, str(PACKAGE / "server.py"), "--state-dir", directory],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
            )
            assert process.stdin and process.stdout
            sequence = 0

            def request(method, params):
                nonlocal sequence
                sequence += 1
                wire = {
                    "jsonrpc": "2.0",
                    "id": sequence,
                    "method": method,
                    "params": params,
                }
                process.stdin.write(module.encode(wire).encode() + b"\n")
                process.stdin.flush()
                line = process.stdout.readline()
                self.assertLessEqual(len(line), module.MAX_BYTES)
                reply = json.loads(line)
                self.assertEqual(reply["id"], sequence)
                result = reply["result"]
                self.assertFalse(result.get("isError"), result)
                if "structuredContent" in result:
                    return result["structuredContent"]
                return json.loads(result["content"][0]["text"])

            def call(tool, arguments, caller=OWNER):
                return request(
                    "tools/call",
                    {
                        "name": "lane_call",
                        "arguments": {
                            "tool": tool,
                            "arguments": arguments,
                            "caller": caller,
                        },
                    },
                )

            try:
                request(
                    "tools/call",
                    {
                        "name": "lane_observe",
                        "arguments": {"binding": BINDING, "sources": []},
                    },
                )
                boot = call("masc_figma_relay", {"kind": "status"}, RELAY)[
                    "worker_boot_id"
                ]
                relay = {"worker_boot_id": boot, "session_id": "plugin-1"}
                call(
                    "masc_figma_relay",
                    {
                        "kind": "session",
                        **relay,
                        "document": {
                            "name": "File",
                            "page_id": "page:1",
                            "selection": [],
                            "editor_type": "figma",
                            "mode": "default",
                            "can_edit": True,
                        },
                    },
                    RELAY,
                )
                call("masc_figma_bind", {"session_id": "plugin-1"})
                call(
                    "masc_figma_submit",
                    {
                        "operation_id": "large-private",
                        "session_id": "plugin-1",
                        "root_id": "frame:1",
                        "kind": "capture",
                    },
                )
                call("masc_figma_relay", {"kind": "poll", **relay}, RELAY)
                payload = bundle()
                payload["completed"] = [
                    {"index": 0, "op": "rename", "node_id": "frame:1", "details": ""},
                    {"index": 1, "op": "rename", "node_id": "text:1"},
                ]
                arguments = {
                    "kind": "result",
                    **relay,
                    "operation_id": "large-private",
                    "ok": True,
                    "payload": payload,
                }
                public = {
                    "jsonrpc": "2.0",
                    "id": sequence + 1,
                    "method": "tools/call",
                    "params": {"name": "masc_figma_relay", "arguments": arguments},
                }
                payload["completed"][0]["details"] = "x" * (
                    module.MAX_BYTES - len(module.encode(public).encode())
                )
                self.assertEqual(len(module.encode(public).encode()), module.MAX_BYTES)
                private = {
                    **public,
                    "params": {
                        "name": "lane_call",
                        "arguments": {
                            "tool": "masc_figma_relay",
                            "arguments": arguments,
                            "caller": RELAY,
                        },
                    },
                }
                self.assertGreater(
                    len(module.encode(private).encode()) + 1, module.MAX_BYTES
                )
                acknowledgement = call("masc_figma_relay", arguments, RELAY)
                self.assertEqual(acknowledgement["state"], "outcome_unknown")
                self.assertEqual(acknowledgement["result"]["completed_count"], 2)
                self.assertEqual(acknowledgement["result"]["completed"], [])
                self.assertEqual(acknowledgement["result"]["completed_omitted"], 2)
                self.assertTrue(acknowledgement["result"]["details_omitted"])
                self.assertEqual(
                    call("masc_figma_relay", arguments, RELAY), acknowledgement
                )
                overview = call(
                    "masc_figma_operation", {"operation_id": "large-private"}
                )
                self.assertEqual(overview["result"]["completed_available"], 2)
                page = call(
                    "masc_figma_operation",
                    {
                        "operation_id": "large-private",
                        "completed_offset": 1,
                        "completed_limit": 1,
                    },
                )
                self.assertEqual(page["result"]["completed"], [payload["completed"][1]])
                self.assertEqual(page["result"]["completed_omitted"], 1)
                with sqlite3.connect(Path(directory) / "studio.sqlite3") as db:
                    row = db.execute(
                        "SELECT state,result FROM operations WHERE id='large-private'"
                    ).fetchone()
                self.assertEqual(row[0], "outcome_unknown")
                self.assertEqual(
                    len(
                        json.loads(row[1])["relay_result"]["payload"]["completed"][0][
                            "details"
                        ]
                    ),
                    len(payload["completed"][0]["details"]),
                )
                call(
                    "masc_figma_submit",
                    {
                        "operation_id": "next-capture",
                        "session_id": "plugin-1",
                        "root_id": "frame:1",
                        "kind": "capture",
                    },
                )
                self.assertEqual(
                    call("masc_figma_relay", {"kind": "poll", **relay}, RELAY)[
                        "command"
                    ]["id"],
                    "next-capture",
                )
                next_result = call(
                    "masc_figma_relay",
                    {
                        "kind": "result",
                        **relay,
                        "operation_id": "next-capture",
                        "ok": True,
                        "payload": bundle(),
                    },
                    RELAY,
                )
                self.assertEqual(next_result["state"], "captured")
                self.assertTrue(next_result["result"]["snapshot_id"])
            finally:
                process.stdin.close()
                process.wait()
                process.stdout.close()
                self.assertEqual(process.returncode, 0)

    def test_completed_range_requires_explicit_valid_offset_and_limit(self):
        self.capture()
        for page in (
            {"completed_offset": 0},
            {"completed_limit": 1},
            {"completed_offset": -1, "completed_limit": 1},
            {"completed_offset": 0, "completed_limit": 0},
            {"completed_offset": True, "completed_limit": 1},
        ):
            with self.subTest(page=page), self.assertRaises(Refused):
                self.call("masc_figma_operation", {"operation_id": "capture-1", **page})

    def test_oversized_poll_baseline_rejects_without_starving_the_next_request(self):
        self.pair()
        self.submit("large-baseline")
        self.relay("poll")
        large = bundle()
        tree = json.loads(large["tree_json"])
        tree["document"]["name"] = "x" * (module.MAX_BYTES // 2)
        large["tree_json"] = module.encode(tree)
        captured = self.relay(
            "result", operation_id="large-baseline", ok=True, payload=large
        )
        self.assertEqual(captured["state"], "captured")
        identity = captured["result"]["snapshot_id"]
        request = {
            "operation_id": "large-edit",
            "session_id": "plugin-1",
            "kind": "apply",
            "root_id": "frame:1",
            "snapshot_id": identity,
            "ops": [
                {
                    "op": "rename",
                    "params": {
                        "node_id": "frame:1",
                        "name": "y" * (module.MAX_BYTES // 2),
                    },
                }
            ],
        }
        self.assert_request_fits("masc_figma_submit", request)
        self.call("masc_figma_submit", request)
        self.submit("next-capture")
        response = self.relay("poll")
        self.assertIsNone(response["command"])
        self.assertEqual(response["rejected_operation"]["operation_id"], "large-edit")
        retained = self.worker.store.operation("large-edit")
        self.assertEqual(retained["state"], "rejected")
        self.assertEqual(retained["result"]["effect"], "proven_pre_effect")
        self.assertIn("UTF-8 envelope", retained["result"]["reason"])
        self.assertEqual(self.relay("poll")["command"]["id"], "next-capture")
        self.assertEqual(
            self.observe()["rows"][0]["fields"]["latest_snapshot"], identity
        )

    def test_oversized_rest_command_rejects_without_starving_the_next_request(self):
        request = {
            "operation_id": "oversized-rest",
            "file_key": '"' * (module.MAX_BYTES // 4),
            "root_id": "frame:1",
        }
        self.assert_request_fits("masc_figma_rest_capture", request)
        self.call("masc_figma_rest_capture", request)
        self.call(
            "masc_figma_rest_capture",
            {"operation_id": "next-rest", "file_key": "file-1", "root_id": "frame:1"},
        )
        args = {"kind": "rest_poll", "worker_boot_id": self.worker.store.boot_id}
        response = self.call("masc_figma_relay", args, RELAY)["decoded"]
        self.assertIsNone(response["command"])
        self.assertEqual(
            response["rejected_operation"]["operation_id"], "oversized-rest"
        )
        retained = self.worker.rest.get("oversized-rest")
        self.assertEqual(retained["state"], "rejected")
        self.assertEqual(retained["result"]["effect"], "proven_pre_effect")
        self.assertIn("UTF-8 envelope", retained["result"]["reason"])
        self.assertEqual(
            self.call("masc_figma_relay", args, RELAY)["decoded"]["command"]["id"],
            "next-rest",
        )

    def test_session_reports_cannot_poison_retained_snapshot_observation(self):
        identity = self.capture()["result"]["snapshot_id"]
        document = {
            "name": "한" * (module.MAX_BYTES // 8),
            "page_id": "page:1",
            "selection": [],
            "editor_type": "figma",
            "mode": "default",
            "can_edit": True,
        }
        self.relay("session", "plugin-2", document=document)
        self.relay("session", "plugin-3", document=document)
        before = self.observe()
        # Each incoming report fits independently. Together they exceed the
        # observation envelope, which also contains the retained artifacts.
        for session, candidate in (
            ("plugin-4", document),
            ("plugin-2", {**document, "name": document["name"] * 2}),
        ):
            args = {
                "kind": "session",
                "worker_boot_id": self.worker.store.boot_id,
                "session_id": session,
                "document": candidate,
            }
            self.assert_request_fits("masc_figma_relay", args)
            with self.assertRaisesRegex(Refused, "UTF-8 envelope"):
                self.call("masc_figma_relay", args, RELAY)
            after = self.observe()
            self.assertEqual(after["rows"][0]["fields"], before["rows"][0]["fields"])
            self.assertEqual(after["artifacts"], before["artifacts"])
            self.assertEqual(after["rows"][0]["fields"]["latest_snapshot"], identity)

    def test_oversized_readback_keeps_previous_snapshot_and_raw_unknown(self):
        previous = self.capture()["result"]["snapshot_id"]
        self.submit("oversized-readback")
        self.relay("poll")
        large = bundle()
        tree = json.loads(large["tree_json"])
        # The request fits by bytes, but publishing the native JSON as a
        # base64 observation artifact exceeds the real manifest envelope.
        tree["document"]["name"] = "한" * (module.MAX_BYTES // 4)
        large["tree_json"] = module.encode(tree)
        args = {
            "kind": "result",
            "worker_boot_id": self.worker.store.boot_id,
            "session_id": "plugin-1",
            "operation_id": "oversized-readback",
            "ok": True,
            "payload": large,
        }
        self.assert_request_fits("masc_figma_relay", args)
        response = self.call("masc_figma_relay", args, RELAY)["decoded"]
        self.assertEqual(response["state"], "outcome_unknown")
        self.assertIn("UTF-8 envelope", response["result"]["reason"])
        self.assertNotIn("snapshot_id", response["result"])
        raw = self.worker.store.operation("oversized-readback")["result"][
            "relay_result"
        ]
        self.assertEqual(raw, {"ok": True, "payload": large})
        self.assertEqual(
            self.observe()["rows"][0]["fields"]["latest_snapshot"], previous
        )
        self.assertEqual(
            self.worker.store.db.execute("SELECT count(*) FROM snapshots").fetchone()[
                0
            ],
            1,
        )
        # Retrying receipt delivery acknowledges the same retained outcome.
        self.assertEqual(
            self.call("masc_figma_relay", args, RELAY)["decoded"], response
        )

    def test_malformed_edit_readback_retains_raw_unknown_without_replay(self):
        previous = self.capture()["result"]["snapshot_id"]
        for index, tree in enumerate(MALFORMED_EXPORTS):
            with self.subTest(tree=tree):
                identity = f"malformed-edit-{index}"
                self.submit(
                    identity,
                    kind="apply",
                    snapshot_id=previous,
                    ops=[
                        {
                            "op": "rename",
                            "params": {"node_id": "frame:1", "name": "Changed"},
                        }
                    ],
                )
                self.assertEqual(self.relay("poll")["command"]["id"], identity)
                payload = {**bundle(), "tree_json": tree}
                response = self.relay(
                    "result", operation_id=identity, ok=True, payload=payload
                )
                self.assertEqual(response["state"], "outcome_unknown")
                retained = self.worker.store.operation(identity)["result"]
                self.assertEqual(
                    retained["relay_result"], {"ok": True, "payload": payload}
                )
                self.assertIn("Unusable readback", retained["reason"])
                self.assertNotIn("snapshot_id", retained)
                self.assertEqual(
                    self.relay(
                        "result", operation_id=identity, ok=True, payload=payload
                    ),
                    response,
                )
                self.assertIsNone(self.relay("poll")["command"])
                self.assertEqual(
                    self.observe()["rows"][0]["fields"]["latest_snapshot"], previous
                )
        self.submit("after-malformed-edit")
        self.assertEqual(self.relay("poll")["command"]["id"], "after-malformed-edit")
        self.assertEqual(
            self.relay(
                "result", operation_id="after-malformed-edit", ok=True, payload=bundle()
            )["state"],
            "captured",
        )

    def test_malformed_rest_readback_retains_raw_unknown_without_replay(self):
        previous = self.capture()["result"]["snapshot_id"]
        boot = {"worker_boot_id": self.worker.store.boot_id}
        for index, tree in enumerate(MALFORMED_EXPORTS):
            with self.subTest(tree=tree):
                identity = f"malformed-rest-{index}"
                self.call(
                    "masc_figma_rest_capture",
                    {
                        "operation_id": identity,
                        "file_key": "file-1",
                        "root_id": "frame:1",
                    },
                )
                self.assertEqual(
                    self.call("masc_figma_relay", {"kind": "rest_poll", **boot}, RELAY)[
                        "decoded"
                    ]["command"]["id"],
                    identity,
                )
                payload = bundle()
                del payload["session_id"], payload["page_id"]
                payload.update(
                    source="rest_version",
                    file_key="file-1",
                    version="v9",
                    tree_json=tree,
                )
                args = {
                    "kind": "rest_result",
                    **boot,
                    "operation_id": identity,
                    "ok": True,
                    "payload": payload,
                }
                response = self.call("masc_figma_relay", args, RELAY)["decoded"]
                self.assertEqual(response["state"], "outcome_unknown")
                retained = self.worker.rest.get(identity)["result"]
                self.assertEqual(
                    retained["relay_result"], {"ok": True, "payload": payload}
                )
                self.assertIn("Unusable REST capture", retained["reason"])
                self.assertNotIn("snapshot_id", retained)
                self.assertEqual(
                    self.call("masc_figma_relay", args, RELAY)["decoded"], response
                )
                self.assertIsNone(
                    self.call("masc_figma_relay", {"kind": "rest_poll", **boot}, RELAY)[
                        "decoded"
                    ]["command"]
                )
                self.assertEqual(
                    self.observe()["rows"][0]["fields"]["latest_snapshot"], previous
                )

    def test_oversized_report_does_not_replace_a_readable_observation(self):
        identity = self.capture()["result"]["snapshot_id"]
        valid = self.call(
            "masc_figma_validate",
            {
                "snapshot_id": identity,
                "checks": [
                    {"node_id": "text:1", "path": ["characters"], "equals": "Welcome"}
                ],
            },
        )["decoded"]["report_id"]
        args = {
            "snapshot_id": identity,
            "checks": [
                {
                    "node_id": "text:1",
                    "path": ["characters"],
                    "equals": "x" * (module.MAX_BYTES * 3 // 4),
                }
            ],
        }
        self.assert_request_fits("masc_figma_validate", args)
        with self.assertRaisesRegex(Refused, "UTF-8 envelope"):
            self.call("masc_figma_validate", args)
        observation = self.observe()
        self.assertEqual(observation["rows"][0]["fields"]["latest_snapshot"], identity)
        self.assertEqual(observation["rows"][0]["fields"]["latest_validation"], valid)
        self.assertEqual(
            self.worker.store.db.execute("SELECT count(*) FROM reports").fetchone()[0],
            1,
        )

    def test_capture_read_image_and_validate_same_snapshot(self):
        operation = self.capture()
        identity = operation["result"]["snapshot_id"]
        snapshot = self.call("masc_figma_snapshot", {"snapshot_id": identity})
        self.assertEqual(base64.b64decode(snapshot["content"][1]["data"]), PNG)
        checks = [{"node_id": "text:1", "path": ["characters"], "equals": "Welcome"}]
        report = self.call(
            "masc_figma_validate", {"snapshot_id": identity, "checks": checks}
        )["decoded"]
        self.assertEqual(report["verdict"], "pass")
        self.assertEqual(report["visual_verdict"], "not_evaluated")
        checks[0]["equals"] = "Wrong text"
        failed = self.call(
            "masc_figma_validate", {"snapshot_id": identity, "checks": checks}
        )["decoded"]
        self.assertEqual(failed["verdict"], "fail")
        observation = self.worker.call(
            "lane_observe", {"binding": BINDING, "sources": []}
        )["structuredContent"]
        self.assertEqual(len(observation["artifacts"]), 3)
        self.assertTrue(observation["rows"][0]["fields"]["latest_validation"])

    def test_relay_can_download_snapshot_without_owner_write_authority(self):
        identity = self.capture()["result"]["snapshot_id"]
        expected = self.call("masc_figma_snapshot", {"snapshot_id": identity})
        self.assertEqual(
            self.call("masc_figma_snapshot", {"snapshot_id": identity}, RELAY),
            expected,
        )
        for caller in (
            {"kind": "agent", "name": "unrelated-admin"},
            {"kind": "agent", "name": "leader"},
        ):
            with self.assertRaises(Refused):
                self.call("masc_figma_snapshot", {"snapshot_id": identity}, caller)
        for tool, args in (
            ("masc_figma_bind", {"session_id": "plugin-1"}),
            ("masc_figma_validate", {"snapshot_id": identity, "checks": []}),
            (
                "masc_figma_submit",
                {
                    "operation_id": "relay-edit",
                    "session_id": "plugin-1",
                    "root_id": "frame:1",
                    "kind": "apply",
                    "snapshot_id": identity,
                    "ops": [],
                },
            ),
            (
                "masc_figma_rest_capture",
                {
                    "operation_id": "relay-rest",
                    "file_key": "file",
                    "root_id": "frame:1",
                },
            ),
        ):
            with self.assertRaises(Refused):
                self.call(tool, args, RELAY)

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

    def test_rest_capture_without_plugin_and_no_cross_source_edit(self):
        request = {
            "operation_id": "rest-1",
            "file_key": "file-1",
            "root_id": "frame:1",
            "version": "v9",
        }
        pending = self.call("masc_figma_rest_capture", request)["decoded"]
        self.assertEqual(pending["state"], "prepared")
        relay = {"worker_boot_id": self.worker.store.boot_id}
        command = self.call("masc_figma_relay", {"kind": "rest_poll", **relay}, RELAY)[
            "decoded"
        ]["command"]
        self.assertEqual(command["version"], "v9")
        payload = bundle()
        del payload["session_id"], payload["page_id"]
        payload.update(source="rest_version", file_key="file-1", version="v9")
        done = self.call(
            "masc_figma_relay",
            {
                "kind": "rest_result",
                "operation_id": "rest-1",
                "ok": True,
                "payload": payload,
                **relay,
            },
            RELAY,
        )["decoded"]
        self.assertEqual(done["state"], "captured")
        identity = done["result"]["snapshot_id"]
        snapshot = self.call("masc_figma_snapshot", {"snapshot_id": identity})[
            "decoded"
        ]
        self.assertEqual(snapshot["source"], "rest_version")
        self.assertNotIn("session_id", snapshot)
        self.pair()
        with self.assertRaises(Refused):
            self.call(
                "masc_figma_submit",
                {
                    "operation_id": "unsafe-association",
                    "session_id": "plugin-1",
                    "kind": "apply",
                    "root_id": "frame:1",
                    "snapshot_id": identity,
                    "ops": [{}],
                },
            )
        repeated = self.call("masc_figma_rest_capture", request)["decoded"]
        self.assertEqual(repeated["state"], "captured")

    def test_rest_wrong_version_does_not_publish_snapshot(self):
        self.call(
            "masc_figma_rest_capture",
            {
                "operation_id": "rest-bad",
                "file_key": "file-1",
                "root_id": "frame:1",
                "version": "v9",
            },
        )
        relay = {"worker_boot_id": self.worker.store.boot_id}
        self.call("masc_figma_relay", {"kind": "rest_poll", **relay}, RELAY)
        payload = bundle()
        del payload["session_id"], payload["page_id"]
        payload.update(source="rest_version", file_key="file-1", version="v10")
        done = self.call(
            "masc_figma_relay",
            {
                "kind": "rest_result",
                "operation_id": "rest-bad",
                "ok": True,
                "payload": payload,
                **relay,
            },
            RELAY,
        )["decoded"]
        self.assertEqual(done["state"], "outcome_unknown")
        self.assertIsNone(self.worker.store.meta("latest_snapshot"))

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
        repeated = self.call("masc_figma_submit", request)["decoded"]
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

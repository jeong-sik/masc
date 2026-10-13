import base64
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "figma-studio/host"))
from adapter import Adapter, FigmaApi, PROTOCOL, ServiceRefused
from mcp_client import ApplicationRefused, TransportError, encode


COMMAND = {"id": "edit", "session_id": "session", "kind": "apply", "root_id": "root",
           "expected_tree_json": "{}", "ops": [{"op": "rename"}]}


class Host:
    url, token = "http://127.0.0.1:1/mcp", "host-token"

    def __init__(self):
        self.commands, self.receipts, self.calls = [COMMAND], [], []
        self.rest_commands = []
        self.lose_ack, self.refuse, self.limit = False, False, 100000

    def call(self, name, args, *, compact=None):
        self.calls.append(args["kind"])
        if args["kind"] == "status":
            return {"worker_boot_id": "host-boot", "max_request_bytes": self.limit}
        if args["kind"] == "poll":
            return {"command": self.commands.pop(0) if self.commands else None}
        if args["kind"] == "rest_poll":
            return {"command": self.rest_commands.pop(0) if self.rest_commands else None}
        if args["kind"] == "session":
            return {}
        if len(encode(args)) > self.limit:
            args = compact(lambda value: len(encode(value)) <= self.limit)
        self.receipts.append(args)
        if self.refuse:
            raise ApplicationRefused("old owner")
        if self.lose_ack:
            self.lose_ack = False
            raise TransportError("ACK lost")
        return {}


class Api:
    url, token = "http://127.0.0.1:2", "service-token"

    def __init__(self):
        self.submits, self.operations = [], {}
        self.bad_protocol, self.lose_submit = False, False

    def info(self):
        if self.bad_protocol:
            raise ServiceRefused("protocol mismatch")
        return {"service_id": "service-boot"}

    def call(self, path, body):
        if path == "/v1/status":
            return {"sessions": [{"session_id": "session", "name": "doc", "page_id": "page", "selection": [],
                                  "editor_type": "figma", "mode": "default", "can_edit": True,
                                  "future_additive_field": {"allowed": True}}]}
        if path == "/v1/operations":
            self.submits.append(body)
            self.operations[body["operation_id"]] = {"service_id": "service-boot", "state": "dispatched"}
            if self.lose_submit:
                self.lose_submit = False
                raise TransportError("POST reply lost")
            return {}
        if path == "/v1/operation":
            return self.operations[body["operation_id"]]
        if path == "/v1/rest-capture":
            return {"snapshot_id": "snapshot", "tree_json": "{}", "preview": None}
        raise AssertionError(path)

    def finish(self):
        self.operations["edit"] = {"service_id": "service-boot", "state": "applied", "result": {"readback_available": True}}

    def readback(self, identity):
        return {"ok": True, "payload": {"completed": [{"index": 7, "node_id": "node:1", "op": "rename"}], "tree_json": "x" * 10000}}


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "state"
        self.host, self.api = Host(), Api()
        self.adapter = Adapter(self.host, self.api, self.path)

    def tearDown(self):
        self.adapter.close()
        self.temp.cleanup()

    def test_protocol_refused_before_host_dequeue(self):
        self.api.bad_protocol = True
        with self.assertRaises(ServiceRefused):
            self.adapter.step()
        self.assertEqual(self.host.calls, [])

    def test_rest_and_plugin_operation_ids_are_independent(self):
        self.host.rest_commands = [{"id": "edit", "file_key": "file", "root_id": "root"}]
        self.adapter.step()
        self.api.finish()
        self.adapter.step()
        rows = self.adapter.db.execute("SELECT kind,state FROM deliveries ORDER BY kind").fetchall()
        self.assertEqual([tuple(row) for row in rows], [("plugin", "acknowledged"), ("rest", "acknowledged")])
        self.assertEqual({r["kind"] for r in self.host.receipts}, {"result", "rest_result"})

    def test_chunked_readback_requires_exact_progress_and_digest(self):
        api = FigmaApi(Api.url, Api.token)
        raw = encode({"ok": True, "payload": {"text": "한글"}})
        digest = hashlib.sha256(raw).hexdigest()

        def chunk(path, body):
            start = body["offset"]
            end = min(start + 5, len(raw))
            return {"encoding": "json-utf8", "offset": start, "next_offset": end if end < len(raw) else None,
                    "total_bytes": len(raw), "sha256": digest, "data_base64": base64.b64encode(raw[start:end]).decode()}

        api.call = chunk
        self.assertEqual(api.readback("op"), {"ok": True, "payload": {"text": "한글"}})
        api.call = lambda path, body: {**chunk(path, body), "sha256": "incorrect"}
        with self.assertRaisesRegex(TransportError, "digest"):
            api.readback("op")
        api.call = lambda path, body: {**chunk(path, body), "next_offset": 1}
        with self.assertRaisesRegex(TransportError, "offset"):
            api.readback("op")

    def test_malformed_or_newer_protocol_is_refused(self):
        api = FigmaApi(Api.url, Api.token)
        for protocol, capabilities in [("figma-studio/2", []), (PROTOCOL, None), (PROTOCOL, [[]])]:
            api.call = lambda *args: {"protocol": protocol, "capabilities": capabilities}
            with self.assertRaises(ServiceRefused):
                api.info()

    def test_lost_submission_reply_reconciles_without_replaying_edit(self):
        self.api.lose_submit = True
        with self.assertRaises(TransportError):
            self.adapter.step()
        self.adapter.close()
        self.adapter = Adapter(self.host, self.api, self.path)
        self.api.finish()
        self.adapter.step()
        self.assertEqual(len(self.api.submits), 1)
        self.assertEqual(len(self.host.receipts), 1)
        self.assertTrue(self.host.receipts[0]["ok"])

    def test_lost_ack_retries_identical_compacted_receipt_after_restart(self):
        self.adapter.step()
        self.api.finish()
        self.host.limit, self.host.lose_ack = 500, True
        with self.assertRaises(TransportError):
            self.adapter.step()
        first = self.host.receipts[0]
        self.assertEqual(first["payload"]["completed"][0]["index"], 7)
        self.adapter.close()
        self.adapter = Adapter(self.host, self.api, self.path)
        self.host.limit = 100000
        self.adapter.step()
        self.assertEqual(self.host.receipts, [first, first])
        self.assertEqual(len(self.api.submits), 1)

    def test_stale_host_refusal_does_not_replay_or_relabel(self):
        self.adapter.step()
        self.api.finish()
        self.host.refuse = True
        self.adapter.step()
        self.host.refuse = False
        self.adapter.step()
        self.assertEqual(len(self.host.receipts), 1)
        self.assertEqual(self.host.receipts[0]["worker_boot_id"], "host-boot")
        self.assertEqual(len(self.api.submits), 1)
        self.assertEqual(self.adapter.db.execute("SELECT state FROM deliveries").fetchone()[0], "obsolete")

    def test_exclusive_writer_and_immutable_destination(self):
        with self.assertRaisesRegex(ValueError, "already has a writer"):
            Adapter(self.host, self.api, self.path)
        self.adapter.close()
        self.api.token = "different-owner"
        with self.assertRaisesRegex(ValueError, "different endpoints or credentials"):
            Adapter(self.host, self.api, self.path)
        self.api.token = Api.token
        self.adapter = Adapter(self.host, self.api, self.path)


if __name__ == "__main__":
    unittest.main()

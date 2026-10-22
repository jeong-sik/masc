import base64
import hashlib
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "figma-studio/host"))
from adapter import Adapter, FigmaApi, PROTOCOL, ServiceRefused
from mcp_client import ApplicationRefused, TransportError, encode


COMMAND = {"id": "edit", "session_id": "session", "kind": "apply", "root_id": "root",
           "expected_tree_json": "{}", "ops": [{"op": "rename"}]}
REST_COMMAND = {"id": "edit", "file_key": "file", "root_id": "root"}


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
        self.bad_protocol = False

    def info(self):
        if self.bad_protocol:
            raise ServiceRefused("protocol mismatch")
        return {"service_id": "service-boot"}

    def call(self, path, body):
        if path == "/v1/status":
            return {"sessions": [{"session_id": "session", "name": "doc", "page_id": "page", "selection": [],
                                  "editor_type": "figma", "mode": "default", "can_edit": True}]}
        if path == "/v1/operation":
            return self.operations.get(body["operation_id"], {"service_id": "service-boot", "state": "prepared"})
        raise AssertionError(path)

    def finish(self):
        self.operations["edit"] = {"service_id": "service-boot", "state": "applied", "result": {"readback_available": True}}

    def readback(self, identity):
        return {"ok": True, "payload": {"completed": [{"index": 7, "node_id": "node:1", "op": "rename"}], "tree_json": "x" * 10000}}


def submit(adapter, command=COMMAND, *, kind="plugin", boot="host-boot", service="service-boot"):
    with adapter.db:
        adapter.db.execute(
            "INSERT INTO deliveries VALUES (?,?,?,?,?,'submitted',NULL)",
            (command["id"], boot, service, kind, json.dumps(command, sort_keys=True)))


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "state"
        self.host, self.api = Host(), Api()
        self.adapter = Adapter(self.host, self.api, self.path)

    def tearDown(self):
        self.adapter.close()
        self.temp.cleanup()

    def test_step_dequeues_no_new_work_without_a_liveness_contract(self):
        # The host offers a plugin and a REST command, and the service
        # reports a live session, but no reviewed liveness contract exists,
        # so step must not dequeue, submit, or announce anything.
        self.host.rest_commands = [REST_COMMAND]
        self.adapter.step()
        self.assertEqual(self.host.calls, ["status"])
        self.assertEqual(self.api.submits, [])
        self.assertEqual(
            self.adapter.db.execute("SELECT COUNT(*) FROM deliveries").fetchone()[0], 0)

    def test_protocol_refused_before_host_dequeue(self):
        self.api.bad_protocol = True
        with self.assertRaises(ServiceRefused):
            self.adapter.step()
        self.assertEqual(self.host.calls, [])

    def test_stalled_error_body_is_a_transport_failure(self):
        release = threading.Event()

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                self.send_response(409)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", "100")
                self.end_headers()
                self.wfile.flush()
                release.wait(5)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            api = FigmaApi(f"http://127.0.0.1:{server.server_port}", "token", timeout=0.1)
            with self.assertRaisesRegex(TransportError, "interrupted"):
                api.call("/v1/info", {})
        finally:
            release.set()
            server.shutdown()
            server.server_close()
            thread.join()

    def test_rest_and_plugin_operation_ids_are_independent(self):
        submit(self.adapter, kind="plugin")
        submit(self.adapter, REST_COMMAND, kind="rest")
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

    def test_service_witness_fields_flow_to_the_receipt(self):
        # A dispatch witness the service adds to its readback payload must
        # reach the Keeper receipt unchanged; the adapter invents none.
        self.api.readback = lambda identity: {
            "ok": True, "payload": {"completed": [], "dispatched_at": "2026-10-22T12:00:00Z"}}
        self.api.finish()
        submit(self.adapter)
        self.adapter.step()
        self.assertEqual(self.host.receipts[0]["payload"]["dispatched_at"], "2026-10-22T12:00:00Z")

    def test_malformed_or_newer_protocol_is_refused(self):
        api = FigmaApi(Api.url, Api.token)
        for protocol, capabilities in [("figma-studio/2", []), (PROTOCOL, None), (PROTOCOL, [[]])]:
            api.call = lambda *args: {"protocol": protocol, "capabilities": capabilities}
            with self.assertRaises(ServiceRefused):
                api.info()

    def test_uncertain_operation_is_reconciled_without_replaying_edit(self):
        # A submitted operation whose POST reply was lost stays submitted
        # while the service still reports prepared/dispatched, and settles
        # from the terminal read alone; no edit is submitted twice.
        submit(self.adapter)
        self.adapter.step()
        self.assertEqual(
            self.adapter.db.execute("SELECT state FROM deliveries").fetchone()[0], "submitted")
        self.api.finish()
        self.adapter.close()
        self.adapter = Adapter(self.host, self.api, self.path)
        self.adapter.step()
        self.assertEqual(self.api.submits, [])
        self.assertEqual(len(self.host.receipts), 1)
        self.assertTrue(self.host.receipts[0]["ok"])

    def test_lost_ack_retries_identical_compacted_receipt_after_restart(self):
        self.api.finish()
        submit(self.adapter)
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
        self.assertEqual(self.api.submits, [])

    def test_stale_host_refusal_does_not_replay_or_relabel(self):
        self.api.finish()
        submit(self.adapter)
        self.host.refuse = True
        self.adapter.step()
        self.host.refuse = False
        self.adapter.step()
        self.assertEqual(len(self.host.receipts), 1)
        self.assertEqual(self.host.receipts[0]["worker_boot_id"], "host-boot")
        self.assertEqual(self.adapter.db.execute("SELECT state FROM deliveries").fetchone()[0], "obsolete")

    def test_exclusive_writer_and_immutable_destination(self):
        with self.assertRaisesRegex(ValueError, "already has a writer"):
            Adapter(self.host, self.api, self.path)
        self.adapter.close()
        self.api.url = "http://127.0.0.1:3"
        with self.assertRaisesRegex(ValueError, "endpoint binding does not match"):
            Adapter(self.host, self.api, self.path)
        self.api.url = Api.url
        self.adapter = Adapter(self.host, self.api, self.path)

    def test_rotating_both_credentials_retains_uncertain_delivery_without_replay(self):
        submit(self.adapter)
        self.adapter.close()
        self.host.token = "rotated-host-token"
        self.api.token = "rotated-service-token"
        self.adapter = Adapter(self.host, self.api, self.path)
        self.api.finish()
        self.adapter.step()
        self.assertEqual(self.api.submits, [])
        self.assertEqual(len(self.host.receipts), 1)
        self.assertEqual(self.host.receipts[0]["operation_id"], COMMAND["id"])
        self.assertEqual(self.host.receipts[0]["worker_boot_id"], "host-boot")
        self.assertEqual(self.adapter.db.execute("SELECT state FROM deliveries").fetchone()[0], "acknowledged")

    def test_rotating_credentials_retries_retained_result_after_lost_ack(self):
        self.api.finish()
        submit(self.adapter)
        self.host.lose_ack = True
        with self.assertRaises(TransportError):
            self.adapter.step()
        first = self.host.receipts[0]
        self.adapter.close()
        self.host.token = "rotated-host-token"
        self.api.token = "rotated-service-token"
        self.adapter = Adapter(self.host, self.api, self.path)
        self.adapter.step()
        self.assertEqual(self.host.receipts, [first, first])
        self.assertEqual(self.api.submits, [])


if __name__ == "__main__":
    unittest.main()

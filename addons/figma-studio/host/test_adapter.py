"""Focused uncertain-operation recovery tests for the Figma Studio host adapter.

Run from this directory: python3 -m unittest test_adapter -v
"""

import json
import tempfile
import unittest
from pathlib import Path

from adapter import Adapter


class FakeClient:
    url = "http://127.0.0.1:18080"
    token = "client-token"

    def __init__(self):
        self.max_bytes = 1 << 20
        self.poll_commands = {}
        self.delivered = []

    def call(self, _method, args, **_kwargs):
        kind = args["kind"]
        if kind == "status":
            return {"worker_boot_id": "boot-1", "max_request_bytes": 1 << 20}
        if kind == "session":
            return {"ok": True}
        if kind == "poll":
            return {"command": self.poll_commands.get(args["session_id"])}
        if kind == "rest_poll":
            return {"command": None}
        if kind in ("result", "rest_result"):
            self.delivered.append(args)
            return {"ok": True}
        raise AssertionError("unexpected relay kind %r" % kind)


class FakeFigma:
    url = "http://127.0.0.1:19090"
    token = "figma-token"

    def __init__(self, sessions=(), operations=None):
        self.sessions = list(sessions)
        self.operations = dict(operations or {})

    def info(self):
        return {"service_id": "svc-1"}

    def call(self, path, body):
        if path == "/v1/status":
            return {"sessions": self.sessions}
        if path == "/v1/operation":
            return self.operations.get(body["operation_id"], {"service_id": "svc-1", "state": "prepared"})
        raise AssertionError("unexpected figma path %r" % path)


def submitted(adapter, kind, identity, session_id="s-1", boot="boot-1", service="svc-1"):
    command = {"id": identity, "session_id": session_id}
    with adapter.db:
        adapter.db.execute(
            "INSERT INTO deliveries VALUES (?,?,?,?,?,'submitted',NULL)",
            (identity, boot, service, kind, json.dumps(command, sort_keys=True)))


def state_of(adapter, kind, identity):
    row = adapter.db.execute(
        "SELECT state, result FROM deliveries WHERE kind=? AND id=?", (kind, identity)).fetchone()
    return row["state"], json.loads(row["result"]) if row["result"] else None


class MissingSessionTest(unittest.TestCase):
    def test_missing_session_is_not_remote_cancellation(self):
        for remote_state in ("prepared", "dispatched"):
            with self.subTest(remote_state=remote_state), tempfile.TemporaryDirectory() as directory:
                client = FakeClient()
                figma = FakeFigma(sessions=[], operations={
                    "op-1": {"service_id": "svc-1", "state": remote_state}})
                adapter = Adapter(client, figma, Path(directory))
                try:
                    submitted(adapter, "plugin", "op-1", session_id="s-gone")
                    adapter.step()
                    self.assertEqual(state_of(adapter, "plugin", "op-1"), ("submitted", None))
                    self.assertEqual(client.delivered, [])
                finally:
                    adapter.close()

    def test_missing_session_can_still_return_a_terminal_operation_result(self):
        with tempfile.TemporaryDirectory() as directory:
            client, figma = FakeClient(), FakeFigma(sessions=[])
            adapter = Adapter(client, figma, Path(directory))
            try:
                submitted(adapter, "plugin", "op-1", session_id="s-gone")
                adapter.step()
                self.assertEqual(state_of(adapter, "plugin", "op-1"), ("submitted", None))
                figma.operations["op-1"] = {
                    "service_id": "svc-1", "state": "applied",
                    "result": {"readback_available": True}}
                result = {"ok": True, "payload": {"completed": [{"node_id": "node-1"}]}}
                figma.readback = lambda identity: result
                adapter.step()
                self.assertEqual(state_of(adapter, "plugin", "op-1"), ("acknowledged", result))
                self.assertEqual(len(client.delivered), 1)
                self.assertEqual(client.delivered[0]["operation_id"], "op-1")
                self.assertTrue(client.delivered[0]["ok"])
            finally:
                adapter.close()


class FailCloseTest(unittest.TestCase):
    def test_step_dequeues_no_new_work_without_a_liveness_contract(self):
        # The host offers a queued poll command, but no reviewed session
        # liveness contract exists, so step must not dequeue or record it.
        with tempfile.TemporaryDirectory() as directory:
            client = FakeClient()
            client.poll_commands["s-1"] = {"id": "op-new", "session_id": "s-1"}
            adapter = Adapter(client, FakeFigma(), Path(directory))
            try:
                adapter.step()
                self.assertEqual(client.delivered, [])
                self.assertEqual(
                    adapter.db.execute("SELECT COUNT(*) FROM deliveries").fetchone()[0], 0)
            finally:
                adapter.close()


if __name__ == "__main__":
    unittest.main()

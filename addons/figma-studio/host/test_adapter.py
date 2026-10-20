"""Focused liveness tests for the Figma Studio host adapter.

Run from this directory: python3 -m unittest test_adapter -v
"""

import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from adapter import Adapter, DOCUMENT_FIELDS


def document(session_id):
    return {"session_id": session_id, **{key: "d-%s" % key for key in DOCUMENT_FIELDS}}


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


class CloseDeadSessionJobsTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="figma-adapter-test-")
        self.adapter = Adapter(FakeClient(), FakeFigma(), Path(self.directory))

    def tearDown(self):
        self.adapter.close()

    def test_closes_only_dead_session_jobs_of_this_boot_and_service(self):
        submitted(self.adapter, "plugin", "dead", session_id="s-dead")
        submitted(self.adapter, "plugin", "live", session_id="s-alive")
        submitted(self.adapter, "plugin", "old-boot", session_id="s-dead", boot="boot-0")
        submitted(self.adapter, "plugin", "old-service", session_id="s-dead", service="svc-0")
        submitted(self.adapter, "rest", "rest-job", session_id="s-dead")
        self.adapter.close_dead_session_jobs("boot-1", "svc-1", {"s-alive"})
        state, result = state_of(self.adapter, "plugin", "dead")
        self.assertEqual("result", state)
        self.assertFalse(result["ok"])
        self.assertIn("no longer live", result["payload"]["error"])
        for kind, identity in [("plugin", "live"), ("plugin", "old-boot"),
                               ("plugin", "old-service"), ("rest", "rest-job")]:
            state, _ = state_of(self.adapter, kind, identity)
            self.assertEqual("submitted", state, identity)

    def test_step_closes_jobs_of_vanished_sessions(self):
        client, figma = FakeClient(), FakeFigma(sessions=[document("s-alive")])
        adapter = Adapter(client, figma, Path(self.directory) / "step")
        try:
            submitted(adapter, "plugin", "op-1", session_id="s-gone")
            adapter.step()
            state, result = state_of(adapter, "plugin", "op-1")
            self.assertEqual("acknowledged", state)
            self.assertFalse(result["ok"])
            self.assertIn("no longer live", result["payload"]["error"])
            self.assertEqual([("op-1", False)],
                             [(args["operation_id"], args["ok"]) for args in client.delivered])
        finally:
            adapter.close()


if __name__ == "__main__":
    unittest.main()

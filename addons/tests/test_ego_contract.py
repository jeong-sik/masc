"""Validate native reply semantics at the isolated worker's MCP boundary."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import unittest

from stdio_fixture import run_stdio

ADDONS = Path(__file__).resolve().parents[1]
SCRIPTS = ADDONS / "ego-browser/skills/ego-native/scripts"
spec = importlib.util.spec_from_file_location("ego_result_contract", SCRIPTS / "contract.py")
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


def result():
    return {"request_id": "request-1", "operation": "observe", "status": "observed",
            "session": {"space_id": 41, "name": "Fixture", "page": "p1", "epoch": "space-1",
                        "owner_identity": "host-1", "native_name": "private-fixture"},
            "completed_steps": 0, "failed_step": None, "url": "https://fixture.test/",
            "title": "Fixture", "snapshot": "Captured native state", "error": None,
            "screenshot": {"path": "/retained/shot.png", "sha256": "a" * 64}}


class EgoReplyContract(unittest.TestCase):
    def invoke(self, fields, *, incarnation="space-1"):
        source = {"source_id": "ego-browser", "incarnation": incarnation, "cursor": "request-1",
                  "complete": fields["status"] in ("observed", "postcondition_met", "closed"),
                  "detail": None, "observations": [{"id": "request-1", "kind": "ego_browser",
                      "observed_at": 1000, "actor": None, "evidence": [], "fields": fields}]}
        request = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
            "name": "lane_observe", "arguments": {"binding": {}, "sources": [source]}}}
        response = run_stdio([sys.executable, str(ADDONS / "ego-browser/server.py")],
            input=json.dumps(request) + "\n", capture_output=True, text=True, check=True)
        self.assertEqual(response.stderr, "")
        return json.loads(response.stdout)["result"]

    def test_exact_native_fields_preserve_worker_owned_provenance(self):
        native = result()
        response = self.invoke(native)
        self.assertFalse(response["isError"])
        fields = response["structuredContent"]["rows"][0]["fields"]
        for key in contract.RESULT_FIELDS:
            self.assertEqual(fields[key], native[key])
        self.assertEqual(fields["source_id"], "ego-browser")
        self.assertEqual(fields["incarnation"], "space-1")
        self.assertEqual(fields["source_event_id"], "request-1")
        self.assertEqual(fields["scope"], "latest_native_ego_observation")
        self.assertIs(fields["task_completion_verified"], False)
        for key, value in (("source_id", "forged"), ("incarnation", "forged"),
                           ("source_event_id", "forged"), ("scope", "forged"),
                           ("task_completion_verified", True)):
            with self.subTest(provenance=key):
                forged = copy.deepcopy(native)
                forged[key] = value
                self.assertTrue(self.invoke(forged)["isError"])

    def test_malformed_reply_values_are_refused_over_stdio(self):
        mutations = [
            ("completed_steps", -1), ("completed_steps", True),
            ("completed_steps", "0"), ("failed_step", 1), ("failed_step", False),
            ("status", "closed"), ("status", "postcondition_met"),
            ("operation", "finish"), ("operation", []),
            ("session", None), ("snapshot", None), ("snapshot", {}),
            ("url", 1), ("title", False), ("request_id", " "),
            ("error", {"code": None, "message": "unexpected"}),
            ("screenshot", "/unverified/shot.png"),
            ("screenshot", {"path": "/shot.png", "sha256": "not-a-digest"}),
        ]
        for key, value in mutations:
            with self.subTest(field=key, value=value):
                malformed = result()
                malformed[key] = value
                self.assertTrue(self.invoke(malformed)["isError"])
        missing = result()
        del missing["operation"]
        self.assertTrue(self.invoke(missing)["isError"])

    def test_strict_session_fields_and_incarnation(self):
        for key, value in (("space_id", True), ("space_id", 0), ("name", ""),
                           ("page", "p2"), ("epoch", ""),
                           ("owner_identity", " "), ("native_name", 7)):
            with self.subTest(field=key, value=value):
                malformed = result()
                malformed["session"][key] = value
                self.assertTrue(self.invoke(malformed)["isError"])
        for key in ("owner_identity", "native_name"):
            malformed = result()
            del malformed["session"][key]
            self.assertTrue(self.invoke(malformed)["isError"])
        malformed = result()
        malformed["session"]["foreign"] = True
        self.assertTrue(self.invoke(malformed)["isError"])
        self.assertTrue(self.invoke(result(), incarnation="different-space")["isError"])

    def test_uncertainty_retains_partial_progress_and_structured_error(self):
        native = result()
        native.update(operation="batch", status="outcome_unknown", completed_steps=2,
                      failed_step=2, error={"code": "Timeout", "message": "Input not confirmed",
                                           "observation": "Fresh snapshot also unavailable"})
        response = self.invoke(native)
        self.assertFalse(response["isError"])
        self.assertFalse(response["structuredContent"]["coverage"][0]["complete"])
        for error in (None, "failed", {"code": 7, "message": "failed"},
                      {"code": None, "message": False},
                      {"code": None, "message": "failed", "observation": None},
                      {"code": None, "message": "failed", "extra": True}):
            with self.subTest(error=error):
                malformed = copy.deepcopy(native)
                malformed["error"] = error
                self.assertTrue(self.invoke(malformed)["isError"])
        native["failed_step"] = 1
        self.assertTrue(self.invoke(native)["isError"])

    def test_recovery_rejection_and_finish_statuses(self):
        for operation in ("open", "observe", "batch", "finish", "recover", "retire"):
            native = result()
            native.update(operation=operation, status="rejected_before_effect", session=None,
                          snapshot=None, error={"code": None, "message": "Native CLI unavailable"})
            self.assertFalse(self.invoke(native)["isError"])
        native = result()
        native.update(operation="recover", status="outcome_unknown", session=None,
                      snapshot=None, error={"code": None, "message": "Native binding unconfirmed"})
        self.assertFalse(self.invoke(native)["isError"])
        native = result()
        native.update(operation="recover")
        self.assertFalse(self.invoke(native)["isError"])
        native.update(operation="finish", status="closed", snapshot=None)
        self.assertFalse(self.invoke(native)["isError"])
        native.update(operation="batch", status="postcondition_met", snapshot="Verified condition",
                      completed_steps=2)
        self.assertFalse(self.invoke(native)["isError"])

    def test_local_retirement_is_distinct_from_browser_finish_or_observation(self):
        native = result()
        native.update(operation="retire", status="retired", url=None, title=None,
                      snapshot=None, screenshot=None)
        for session in (native["session"], None):
            native["session"] = session
            response = self.invoke(native)
            self.assertFalse(response["isError"])
            fields = response["structuredContent"]["rows"][0]["fields"]
            self.assertEqual(fields["status"], "retired")
            self.assertIs(fields["task_completion_verified"], False)
        for key, value in (("operation", "finish"), ("status", "closed"),
                           ("url", "https://fixture.test/"), ("snapshot", "Not a fresh observation")):
            with self.subTest(field=key):
                malformed = copy.deepcopy(native)
                malformed[key] = value
                self.assertTrue(self.invoke(malformed)["isError"])


if __name__ == "__main__":
    unittest.main()

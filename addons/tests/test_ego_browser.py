"""Exercise the optional native CLI and isolated worker at their process edges.

The fake executable implements the private structured reply channel; it is not
evidence of native ego behavior. Real input qualification is recorded separately.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from stdio_fixture import run_stdio

ADDONS = Path(__file__).resolve().parents[1]
HOST = ADDONS / "ego-browser/skills/ego-native/scripts/host.py"
FAKE = r'''#!/usr/bin/env python3
import json,sys
from pathlib import Path
script=sys.stdin.read().splitlines()
def value(index,prefix):
    line=script[index]
    if not line.startswith(prefix) or not line.endswith(';'):raise RuntimeError('bad host envelope')
    return json.loads(line[len(prefix):-1])
request=value(0,'const request=')
session=value(1,'const session=')
output=Path(value(2,'const resultPath='))
shot=Path(value(3,'const screenshotPath='))
intent=value(4,'const intent=')
directory=output.parent.parent
with (directory/'effects.jsonl').open('a') as log:log.write(json.dumps(request['request_id'])+'\n')
behavior=(directory/'behavior').read_text() if (directory/'behavior').exists() else 'reply'
if behavior=='lost':raise SystemExit(7)
session=session or {**intent,'space_id':41,'page':'p1'}
result={'request_id':request['request_id'],'operation':request['operation'],
 'status':'closed' if request['operation']=='finish' else 'observed',
 'session':session,'completed_steps':len(request.get('steps',[])),'failed_step':None,
 'url':'https://fixture.test/','title':'Fixture','snapshot':'Captured fixture state',
 'error':None,'screenshot':None}
if behavior=='wrong_id':result['request_id']='different-request'
if request.get('screenshot'):
 shot.write_bytes(b'fixture image bytes');result['screenshot']=str(shot)
output.write_text(json.dumps(result))
'''


class EgoHost(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / "state"
        self.fake = self.root / "fake-ego"
        self.fake.write_text(FAKE)
        self.fake.chmod(0o700)

    def command(self):
        return [sys.executable, str(HOST), "--state-dir", str(self.state), "--ego-command", str(self.fake)]

    def call(self, request):
        response = subprocess.run(self.command(), input=json.dumps(request), text=True,
                                  capture_output=True, check=False, timeout=10)
        self.assertEqual(response.stderr, "")
        return response.returncode, json.loads(response.stdout)

    def opened(self):
        code, result = self.call({"request_id": "open-1", "operation": "open", "name": "Fixture"})
        self.assertEqual(code, 0)
        return result

    def effects(self):
        path = self.state / "effects.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_open_batch_snapshot_and_finish_keep_the_bound_session(self):
        opened = self.opened()
        request = {"request_id": "batch-1", "operation": "batch",
                   "expected_url": opened["url"], "screenshot": True,
                   "steps": [{"action": "hover", "selector": "#menu"},
                             {"action": "fill", "selector": "#field", "text": "secret-only-in-stdin"},
                             {"action": "click", "selector": "#item"}]}
        code, result = self.call(request)
        self.assertEqual(code, 0)
        self.assertEqual(result["completed_steps"], 3)
        self.assertEqual(result["session"], opened["session"])
        self.assertEqual(len(result["screenshot"]["sha256"]), 64)
        envelope = json.loads((self.state / "snapshot.json").read_text())
        self.assertEqual(envelope["cursor"], "batch-1")
        self.assertEqual(envelope["incarnation"], opened["session"]["epoch"])
        self.assertEqual(envelope["observations"][0]["fields"], result)
        for receipt in (self.state / "receipts").iterdir():
            self.assertNotIn("secret-only-in-stdin", receipt.read_text())
        code, result = self.call({"request_id": "finish-1", "operation": "finish"})
        self.assertEqual((code, result["status"]), (0, "closed"))
        self.assertIsNone(json.loads((self.state / "session.json").read_text()))

    def test_retained_duplicate_never_replays_or_replaces_newer_snapshot(self):
        request = {"request_id": "open-1", "operation": "open", "name": "Fixture"}
        self.opened()
        self.call({"request_id": "read-1", "operation": "observe"})
        before = (self.state / "snapshot.json").read_bytes()
        self.assertEqual(self.call(request)[0], 0)
        self.assertEqual(self.effects(), ["open-1", "read-1"])
        self.assertEqual((self.state / "snapshot.json").read_bytes(), before)
        request["name"] = "Another task"
        self.assertEqual(self.call(request)[0], 2)
        self.assertEqual(self.effects(), ["open-1", "read-1"])

    def test_lost_reply_and_wrong_identity_remain_unknown_without_replay(self):
        self.opened()
        for index, behavior in enumerate(("lost", "wrong_id")):
            (self.state / "behavior").write_text(behavior)
            request = {"request_id": f"read-{index}", "operation": "observe"}
            self.assertEqual(self.call(request)[1]["status"], "outcome_unknown")
            self.assertEqual(self.call(request)[1]["status"], "outcome_unknown")
            self.assertEqual(self.effects().count(request["request_id"]), 1)
        self.assertFalse(json.loads((self.state / "snapshot.json").read_text())["complete"])

    def test_pending_dispatch_survives_process_restart_without_native_call(self):
        self.opened()
        request = {"request_id": "dispatched-before-crash", "operation": "observe"}
        import hashlib
        key = hashlib.sha256(request["request_id"].encode()).hexdigest()
        digest = hashlib.sha256(json.dumps(request, sort_keys=True, ensure_ascii=True).encode()).hexdigest()
        (self.state / "receipts" / (key + ".json")).write_text(json.dumps({"phase": "dispatching", "request_sha256": digest}))
        code, result = self.call(request)
        self.assertEqual((code, result["status"]), (1, "outcome_unknown"))
        self.assertEqual(self.effects(), ["open-1"])

    def test_lost_first_open_can_recover_only_the_retained_owner_intent(self):
        self.state.mkdir()
        (self.state / "behavior").write_text("lost")
        request = {"request_id": "lost-open", "operation": "open", "name": "Fixture"}
        self.assertEqual(self.call(request)[1]["status"], "outcome_unknown")
        intent = json.loads((self.state / "open-intent.json").read_text())
        self.assertIn(intent["owner_identity"], intent["native_name"])
        self.assertEqual(self.call({"request_id": "retry-open", "operation": "open", "name": "Fixture"})[0], 2)
        (self.state / "behavior").write_text("reply")
        code, recovered = self.call({"request_id": "recover-1", "operation": "recover"})
        self.assertEqual(code, 0)
        self.assertEqual(recovered["session"]["epoch"], intent["epoch"])
        self.assertEqual(recovered["session"]["native_name"], intent["native_name"])
        self.assertEqual(self.effects(), ["lost-open", "recover-1"])

    def test_state_directories_with_same_display_name_get_distinct_native_names(self):
        first = self.opened()
        self.state = self.root / "another-state"
        second = self.opened()
        self.assertNotEqual(first["session"]["native_name"], second["session"]["native_name"])

    def test_all_steps_are_validated_before_any_native_effect(self):
        self.opened()
        request = {"request_id": "bad-batch", "operation": "batch", "expected_url": "https://fixture.test/",
                   "steps": [{"action": "click", "selector": "#ok"}, {"action": "evaluate", "code": "steal()"}]}
        self.assertEqual(self.call(request)[0], 2)
        self.assertEqual(self.effects(), ["open-1"])
        self.assertEqual(self.call({"request_id": "other", "operation": "open", "name": "Other"})[0], 2)

    def test_observed_new_tab_url_can_guard_initial_http_navigation(self):
        self.opened()
        request = {"request_id": "first-navigation", "operation": "batch",
                   "expected_url": "chrome://new-tab-page/",
                   "steps": [{"action": "goto", "url": "https://fixture.test/"}]}
        self.assertEqual(self.call(request)[0], 0)
        request["request_id"] = "unsafe-navigation"
        request["steps"][0]["url"] = "file:///private/sensitive"
        self.assertEqual(self.call(request)[0], 2)
        self.assertEqual(self.effects(), ["open-1", "first-navigation"])

    def test_malformed_url_and_unencodable_text_refuse_before_dispatch(self):
        self.opened()
        for index, step in enumerate((
            {"action": "goto", "url": "http://["},
            {"action": "fill", "selector": "#field", "text": "\ud800"},
            {"action": []},
        )):
            request = {"request_id": f"invalid-{index}", "operation": "batch",
                       "expected_url": "https://fixture.test/", "steps": [step]}
            code, result = self.call(request)
            self.assertEqual((code, result["status"]), (2, "rejected_before_effect"))
        self.assertEqual(self.effects(), ["open-1"])

    def test_two_processes_with_one_identity_invoke_native_once(self):
        request = json.dumps({"request_id": "same-open", "operation": "open", "name": "Fixture"})
        processes = [subprocess.Popen(self.command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True) for _ in range(2)]
        for process in processes:
            process.stdin.write(request)
            process.stdin.close()
            process.stdin = None
        results = []
        for process in processes:
            output, error = process.communicate(timeout=10)
            self.assertEqual((process.returncode, error), (0, ""))
            results.append(json.loads(output))
        self.assertEqual(results[0], results[1])
        self.assertEqual(self.effects(), ["same-open"])


class EgoObservation(unittest.TestCase):
    def test_captured_identity_and_uncertainty_cross_worker_mcp(self):
        source = {"source_id": "ego-browser", "incarnation": "space-1", "cursor": "request-1",
                  "complete": False, "detail": "Postcondition not observed", "observations": [{
            "id": "request-1", "kind": "ego_browser", "observed_at": 1000, "actor": None, "evidence": [],
            "fields": {"request_id": "request-1", "status": "outcome_unknown",
                       "operation": "batch", "completed_steps": 1, "failed_step": None,
                       "url": "https://fixture.test/", "title": "Fixture",
                       "error": {"code": None, "message": "Postcondition not observed"}, "screenshot": None,
                       "session": {"epoch": "space-1", "space_id": 41, "name": "Fixture", "page": "p1",
                                   "owner_identity": "fixture-owner", "native_name": "Fixture [owner]"}, "snapshot": "Not completed"}}]}
        def invoke():
            request = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
                "name": "lane_observe", "arguments": {"binding": {}, "sources": [source]}}}
            process = run_stdio([sys.executable, str(ADDONS / "ego-browser/server.py")],
                input=json.dumps(request) + "\n", capture_output=True, text=True, check=True)
            return json.loads(process.stdout)["result"]
        result = invoke()
        self.assertFalse(result["isError"])
        output = result["structuredContent"]
        self.assertFalse(output["coverage"][0]["complete"])
        fields = output["rows"][0]["fields"]
        self.assertEqual(fields["request_id"], "request-1")
        self.assertFalse(fields["task_completion_verified"])
        source["observations"][0]["fields"]["session"]["epoch"] = "another-space"
        self.assertTrue(invoke()["isError"])


if __name__ == "__main__":
    unittest.main()

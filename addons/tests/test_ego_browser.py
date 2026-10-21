"""Exercise the optional native CLI and isolated worker at their process edges.

The fake executable implements the private structured reply channel; it is not
evidence of native ego behavior. Real input qualification is recorded separately.
"""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from stdio_fixture import run_stdio

ADDONS = Path(__file__).resolve().parents[1]
HOST = ADDONS / "ego-browser/skills/ego-native/scripts/host.py"
NODE_SPACE_FIXTURE = r'''
const nativeFS = await import("node:fs");
const nativePath = await import("node:path");
function fixtureDirectory() { return nativePath.dirname(nativePath.dirname(resultPath)); }
function recordNative(kind, value) {
  nativeFS.appendFileSync(nativePath.join(fixtureDirectory(), "native.jsonl"), JSON.stringify({kind, value}) + "\n");
}
async function taskSpace(nameOrId) {
  recordNative("lookup", nameOrId);
  if (typeof nameOrId === "number" && nativeFS.existsSync(nativePath.join(fixtureDirectory(), "missing-space"))) {
    // No documented absence code is assumed by the production runtime.
    throw Object.assign(new Error("Opaque SDK lookup failure"), {code: "fixture-unclassified"});
  }
  const spacesPath = nativePath.join(fixtureDirectory(), "native-spaces.json");
  const spaces = nativeFS.existsSync(spacesPath) ? JSON.parse(nativeFS.readFileSync(spacesPath, "utf8")) : {};
  if (typeof nameOrId === "string" && !Object.hasOwn(spaces, nameOrId)) {
    spaces[nameOrId] = 41 + Object.keys(spaces).length;
    nativeFS.writeFileSync(spacesPath, JSON.stringify(spaces));
  }
  const id = typeof nameOrId === "number" ? nameOrId : spaces[nameOrId];
  return {spaceId: id, page: () => ({
    url: async () => "https://fixture.test/", title: async () => "Fixture",
    snapshot: async () => "Actual fixed runtime snapshot",
    goto: async url => recordNative("goto", url),
  }), finish: async () => recordNative("finish", id)};
}
async function listTaskSpaces() { throw new Error("Bound recovery must not choose a replacement"); }
'''
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

    def use_fixed_runtime_fixture(self):
        self.fake.write_text("#!/usr/bin/env python3\nimport subprocess,sys\n"
            + "raise SystemExit(subprocess.run([" + repr(shutil.which("node"))
            + ", '--input-type=module'], input=" + repr(NODE_SPACE_FIXTURE)
            + " + sys.stdin.read(), text=True).returncode)\n")
        self.fake.chmod(0o700)

    def host_module(self):
        sys.path.insert(0, str(HOST.parent))
        try:
            spec = importlib.util.spec_from_file_location("ego_host_retirement_fixture", HOST)
            host = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(host)
            return host
        finally:
            sys.path.pop(0)

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

    @unittest.skipUnless(shutil.which("node"), "Node.js is required to execute the fixed native program")
    def test_missing_bound_space_requires_explicit_retirement_without_native_cleanup(self):
        # Execute the real runtime.mjs inside a Node SDK transport fixture, rather
        # than having the fake CLI invent the expected normalized result.
        self.use_fixed_runtime_fixture()
        opened = self.opened()
        original = opened["session"]
        (self.state / "missing-space").touch()
        for operation in ("observe", "batch", "finish", "recover", "open"):
            request = {"request_id": "missing-" + operation, "operation": operation}
            if operation == "open":
                request["name"] = "Fixture"
            if operation == "batch":
                request.update(expected_url=opened["url"], steps=[{"action": "goto", "url": "https://fixture.test/next"}])
            code, failed = self.call(request)
            self.assertEqual((code, failed["status"]), (1, "outcome_unknown"))
            self.assertEqual(failed["session"], original)
            self.assertEqual(json.loads((self.state / "session.json").read_text()), original)
        log = self.state / "native.jsonl"
        before = log.read_bytes()
        retirement = {"request_id": "retire-missing", "operation": "retire", "expected_epoch": original["epoch"]}
        # Local retirement must work even when the native executable is absent.
        self.fake.unlink()
        code, retired = self.call(retirement)
        self.assertEqual((code, retired["status"]), (0, "retired"))
        self.assertEqual(retired["session"], original)
        self.assertIsNone(retired["snapshot"])
        self.assertEqual(log.read_bytes(), before)
        self.assertTrue(all(item["kind"] == "lookup" for item in map(json.loads, before.decode().splitlines())))
        self.assertIsNone(json.loads((self.state / "session.json").read_text()))
        self.assertIsNone(json.loads((self.state / "open-intent.json").read_text()))
        self.use_fixed_runtime_fixture()
        code, fresh = self.call({"request_id": "new-open", "operation": "open", "name": "Fixture"})
        self.assertEqual(code, 0)
        for key in ("epoch", "native_name", "space_id"):
            self.assertNotEqual(fresh["session"][key], original[key])
        snapshot = (self.state / "snapshot.json").read_bytes()
        self.assertEqual(self.call(retirement)[1], retired)
        self.assertEqual(self.call({"request_id": "open-1", "operation": "open", "name": "Fixture"})[1]["session"], original)
        self.assertEqual((self.state / "snapshot.json").read_bytes(), snapshot)
        self.assertEqual(json.loads((self.state / "session.json").read_text()), fresh["session"])
        self.assertEqual(self.call({**retirement, "request_id": "stale-retire"})[0], 2)
        self.assertEqual(json.loads((self.state / "session.json").read_text()), fresh["session"])

    def test_retirement_requires_exact_current_epoch_and_rejects_native_action_fields(self):
        original = self.opened()["session"]
        for extra in ({}, {"expected_epoch": "another-epoch"},
                      {"expected_epoch": original["epoch"], "steps": [{"action": "click", "selector": "#input"}]}):
            request = {"request_id": "invalid-retire-" + str(len(extra)), "operation": "retire", **extra}
            self.assertEqual(self.call(request)[0], 2)
            self.assertEqual(json.loads((self.state / "session.json").read_text()), original)
        self.assertEqual(self.effects(), ["open-1"])

    def test_unresolved_open_intent_can_be_retired_without_replaying_the_open(self):
        self.state.mkdir()
        (self.state / "behavior").write_text("lost")
        self.assertEqual(self.call({"request_id": "lost-open", "operation": "open", "name": "Fixture"})[1]["status"], "outcome_unknown")
        intent = json.loads((self.state / "open-intent.json").read_text())
        code, retired = self.call({"request_id": "retire-intent", "operation": "retire", "expected_epoch": intent["epoch"]})
        self.assertEqual((code, retired["status"], retired["session"]), (0, "retired", None))
        self.assertEqual(self.effects(), ["lost-open"])
        (self.state / "behavior").write_text("reply")
        code, fresh = self.call({"request_id": "fresh-open", "operation": "open", "name": "Fixture"})
        self.assertEqual(code, 0)
        self.assertNotEqual(fresh["session"]["native_name"], intent["native_name"])
        self.assertEqual(self.effects(), ["lost-open", "fresh-open"])

    def test_interrupted_retirement_cannot_resurrect_binding_or_reuse_request_identity(self):
        original = self.opened()["session"]
        host = self.host_module()
        retirement = {"request_id": "interrupted-retire", "operation": "retire", "expected_epoch": original["epoch"]}
        atomic_json = host.atomic_json
        def fail_second_clear(path, value):
            if path.name == "open-intent.json" and value is None:
                raise OSError("injected binding clear failure")
            atomic_json(path, value)
        with mock.patch.object(host, "atomic_json", side_effect=fail_second_clear):
            with self.assertRaises(OSError):
                host.run(self.state, str(self.fake), retirement)
        self.assertIsNone(json.loads((self.state / "session.json").read_text()))
        self.assertEqual(json.loads((self.state / "open-intent.json").read_text())["epoch"], original["epoch"])
        code, fresh = self.call({"request_id": "fresh-open", "operation": "open", "name": "Fixture"})
        self.assertEqual(code, 0)
        self.assertNotEqual(fresh["session"]["epoch"], original["epoch"])
        snapshot = (self.state / "snapshot.json").read_bytes()
        self.assertEqual(self.call(retirement)[1]["status"], "outcome_unknown")
        self.assertEqual(self.call({"request_id": retirement["request_id"], "operation": "open", "name": "Fixture"})[0], 2)
        self.assertEqual((self.state / "snapshot.json").read_bytes(), snapshot)
        self.assertEqual(self.effects(), ["open-1", "fresh-open"])

    def test_visible_tombstone_requires_successful_sync_before_any_binding_clear(self):
        original = self.opened()["session"]
        (self.state / "behavior").write_text("lost")
        self.assertEqual(self.call({"request_id": "unknown-read", "operation": "observe"})[1]["status"], "outcome_unknown")
        bindings = {name: (self.state / name).read_bytes() for name in ("session.json", "open-intent.json")}
        original_receipts = {path: path.read_bytes() for path in (self.state / "receipts").iterdir()}
        snapshot = (self.state / "snapshot.json").read_bytes()
        host = self.host_module()
        sync_directory = host.sync_directory
        retirement = {"request_id": "retire-sync-failure", "operation": "retire", "expected_epoch": original["epoch"]}
        sync_trace = []
        def fail_retirement_sync(directory):
            if directory == self.state / "retirements":
                sync_trace.append("directory")
                raise OSError("injected retirement directory sync failure")
            sync_directory(directory)
        with mock.patch.object(host, "sync_directory", side_effect=fail_retirement_sync):
            with self.assertRaises(OSError):
                host.run(self.state, str(self.fake), retirement)
        tombstone = host.retirement_path(self.state, original["epoch"])
        self.assertTrue(tombstone.exists())  # Rename happened; its parent sync failed.
        self.assertEqual({name: (self.state / name).read_bytes() for name in bindings}, bindings)
        pending_receipts = {path: path.read_bytes() for path in (self.state / "receipts").iterdir()}
        tombstone_stat = tombstone.stat()
        fsync = host.os.fsync
        def trace_file_sync(fd):
            observed = host.os.fstat(fd)
            if (observed.st_dev, observed.st_ino) == (tombstone_stat.st_dev, tombstone_stat.st_ino):
                sync_trace.append("file")
            fsync(fd)
        sync_trace.clear()
        recovery_failure = None
        with mock.patch.object(host.os, "fsync", side_effect=trace_file_sync), \
                mock.patch.object(host, "sync_directory", side_effect=fail_retirement_sync):
            try:
                host.run(self.state, str(self.fake), {"request_id": "blocked-recovery", "operation": "observe"})
            except (OSError, host.InvalidRequest) as error:
                recovery_failure = error
        self.assertEqual({name: (self.state / name).read_bytes() for name in bindings}, bindings)
        self.assertIsInstance(recovery_failure, OSError)
        self.assertEqual(sync_trace, ["file", "directory"])
        self.assertEqual({path: path.read_bytes() for path in (self.state / "receipts").iterdir()}, pending_receipts)
        self.assertEqual((self.state / "snapshot.json").read_bytes(), snapshot)
        self.assertEqual(self.effects(), ["open-1", "unknown-read"])
        def fail_file_sync(fd):
            observed = host.os.fstat(fd)
            if (observed.st_dev, observed.st_ino) == (tombstone_stat.st_dev, tombstone_stat.st_ino):
                raise OSError("injected retirement file sync failure")
            fsync(fd)
        with mock.patch.object(host.os, "fsync", side_effect=fail_file_sync):
            with self.assertRaises(OSError):
                host.run(self.state, str(self.fake), {"request_id": "blocked-file-sync", "operation": "observe"})
        self.assertEqual({name: (self.state / name).read_bytes() for name in bindings}, bindings)
        self.assertEqual({path: path.read_bytes() for path in (self.state / "receipts").iterdir()}, pending_receipts)
        (self.state / "behavior").write_text("reply")
        code, fresh = self.call({"request_id": "fresh-open", "operation": "open", "name": "Fixture"})
        self.assertEqual(code, 0)
        self.assertNotEqual(fresh["session"]["epoch"], original["epoch"])
        self.assertNotEqual(fresh["session"]["native_name"], original["native_name"])
        for path, content in original_receipts.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertEqual(self.call(retirement)[1]["status"], "outcome_unknown")
        self.assertEqual(json.loads((self.state / "session.json").read_text()), fresh["session"])
        self.assertEqual(self.effects(), ["open-1", "unknown-read", "fresh-open"])

    def test_retirement_record_must_bind_its_original_owner_epoch_and_exact_saved_binding(self):
        original = self.opened()["session"]
        host = self.host_module()
        bindings = {name: (self.state / name).read_bytes() for name in ("session.json", "open-intent.json")}
        valid = {"epoch": original["epoch"], "request_id": "retire",
                 "session": original, "intent": json.loads(bindings["open-intent.json"])}
        malformed = [{**valid, "session": None, "intent": None, "request_id": None},
                     {**valid, "request_id": None}, {**valid, "epoch": "other-epoch"}]
        for changed in ("owner_identity", "native_name"):
            for both in (False, True):
                record = copy.deepcopy(valid)
                record["session"][changed] = "another-value"
                if both:
                    record["intent"][changed] = "another-value"
                malformed.append(record)
        tombstone = host.retirement_path(self.state, original["epoch"])
        tombstone.parent.mkdir(mode=0o700)
        for record in malformed:
            with self.subTest(record=record):
                for name, encoded in bindings.items():
                    (self.state / name).write_bytes(encoded)
                host.atomic_json(tombstone, record)
                with self.assertRaises(host.InvalidRequest):
                    host.run(self.state, str(self.fake), {"request_id": "refused-recovery", "operation": "observe"})
                self.assertEqual({name: (self.state / name).read_bytes() for name in bindings}, bindings)
        self.assertEqual(self.effects(), ["open-1"])


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

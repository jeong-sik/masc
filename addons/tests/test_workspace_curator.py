"""Actual Curator subprocesses, original Exact conversation and retained results."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

from stdio_fixture import run_stdio

ADDONS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ADDONS))
import exact_worker

SERVER = ADDONS / "workspace-curator" / "server.py"


def request(request_id="original-classification", output="classification"):
    return {"kind": "exact_output", "request_id": request_id, "output": output,
            "system": "Only original evidence.",
            "messages": [{"role": "user", "text": "원래 사실"},
                         {"role": "assistant", "text": "Prior original observation."},
                         {"role": "user", "text": "Continue with the complete batch."}],
            "schema": {"type": "object", "properties": {"original": {"type": "string"}},
                       "required": ["original"], "additionalProperties": False}}


def call(name, arguments):
    return {"method": "tools/call", "params": {"name": name, "arguments": arguments}}


def admitted(arguments, caller=None):
    return call("lane_call", {"tool": "curate", "arguments": arguments,
                              "caller": caller or {"kind": "operator"}})


def submit(original, caller=None):
    return admitted({"kind": "submit", "request": original}, caller)


def read(request_id):
    return admitted({"kind": "read", "request_id": request_id})


def listing():
    return call("lane_host_requests", {})


def deliver(request_id, result):
    return call("lane_host_result", {"request_id": request_id, "result": result})


class CuratorWorker(unittest.TestCase):
    def run_worker(self, state, operations, *, server=SERVER, cwd=None):
        operations = [{"method": "initialize", "params": {}}, *operations]
        lines = [json.dumps({"jsonrpc": "2.0", "id": i, **operation}, ensure_ascii=False)
                 for i, operation in enumerate(operations, 1)]
        completed = run_stdio([sys.executable, str(server), "--state", str(state)],
                              input="\n".join(lines) + "\n", text=True, capture_output=True,
                              check=True, timeout=10, cwd=cwd)
        self.assertEqual(completed.stderr, "")
        replies = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual([reply["id"] for reply in replies], list(range(1, len(operations) + 1)))
        return [reply["result"] for reply in replies[1:]]

    def output(self, result):
        self.assertFalse(result.get("isError", False), result)
        return result["structuredContent"]

    def module(self):
        spec = importlib.util.spec_from_file_location("curator_worker_contract", SERVER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_both_original_conversations_and_terminals_survive_real_restarts(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            classification = request()
            briefing = request("original-briefing", "briefing")
            self.run_worker(state, [submit(classification), submit(briefing)])
            resumed = self.run_worker(state, [listing()])
            self.assertCountEqual(self.output(resumed[0])["requests"], [classification, briefing])
            answer = {"status": "answered", "slot": "original-slot", "output": {"original": "answer"},
                      "usage": {"input_tokens": 12, "output_tokens": 3}}
            unknown = {"status": "outcome_unknown"}
            completed = self.run_worker(state, [deliver(classification["request_id"], answer),
                                                deliver(briefing["request_id"], unknown)])
            self.assertEqual([self.output(value) for value in completed], [{"accepted": True}] * 2)
            reopened = self.run_worker(state, [read(classification["request_id"]),
                                               read(briefing["request_id"]),
                                               submit(classification), submit(briefing), listing()])
            self.assertEqual(self.output(reopened[0])["result"], answer)
            self.assertEqual(self.output(reopened[1])["result"], unknown)
            self.assertEqual(self.output(reopened[2])["result"], answer)
            self.assertEqual(self.output(reopened[3])["result"], unknown)
            self.assertEqual(self.output(reopened[4])["requests"], [])

    def test_id_reuse_cannot_change_roles_system_schema_or_output(self):
        with tempfile.TemporaryDirectory() as directory:
            original = request()
            changes = [{**original, "system": "Changed instructions"},
                       {**original, "messages": [{"role": "user", "text": "Flattened"}]},
                       {**original, "schema": {"type": "object"}},
                       {**original, "output": "briefing"}]
            result = self.run_worker(Path(directory), [submit(original),
                                                       *map(submit, changes), listing()])
            self.assertTrue(all(value["isError"] for value in result[1:-1]))
            self.assertEqual(self.output(result[-1])["requests"], [original])
            terminal = {"status": "input_refused", "kind": "context_overflow"}
            result = self.run_worker(Path(directory), [deliver(original["request_id"], terminal),
                                                       deliver(original["request_id"], {"status": "outcome_unknown"}),
                                                       read(original["request_id"])])
            self.assertTrue(result[1]["isError"])
            self.assertEqual(self.output(result[2])["result"], terminal)

    def test_invalid_or_unadmitted_requests_leave_no_pending_work(self):
        with tempfile.TemporaryDirectory() as directory:
            original = request()
            invalid = [{**original, "unknown": "field"}, {**original, "kind": "ask"},
                       {**original, "messages": [{"role": "tool", "text": "untrusted"}]},
                       {**original, "messages": []}, {**original, "output": "grade"}]
            result = self.run_worker(Path(directory), [submit(original, {"kind": "keeper", "name": "worker"}),
                                                       *map(submit, invalid), listing()])
            self.assertTrue(all(value["isError"] for value in result[:-1]))
            self.assertEqual(self.output(result[-1])["requests"], [])

    def test_corrupt_capture_is_never_absent_or_relisted_as_new_work(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            original = request()
            self.run_worker(state, [submit(original)])
            path, = (state / "workspace-curator").glob("*.json")
            record = json.loads(path.read_text())
            record["request"]["messages"][0]["text"] = "Replaced evidence"
            path.write_text(json.dumps(record))
            results = self.run_worker(state, [read(original["request_id"]), listing(), submit(original)])
            self.assertTrue(all(value["isError"] for value in results))

    def test_uncertain_publication_stops_the_writer_then_reopens_original_terminal(self):
        with tempfile.TemporaryDirectory() as directory:
            module = self.module()
            worker = exact_worker.Worker(Path(directory), 4194304, module.CONTRACT)
            original = request()
            worker.invoke({"kind": "submit", "request": original}, {"kind": "operator"})
            sync = os.fsync

            def fail_directory(fd):
                if stat.S_ISDIR(os.fstat(fd).st_mode):
                    raise OSError("directory settlement unconfirmed")
                return sync(fd)

            with patch.object(os, "fsync", side_effect=fail_directory):
                with self.assertRaises(OSError):
                    worker.host_result({"request_id": original["request_id"],
                                        "result": {"status": "outcome_unknown"}})
            with self.assertRaises(exact_worker.InvalidInput):
                worker.host_requests({})
            with self.assertRaises(exact_worker.InvalidInput):
                worker.invoke({"kind": "read", "request_id": original["request_id"]}, {"kind": "operator"})
            # This is a fresh filesystem observation after an injected fsync
            # error, not a claim about surviving an actual power loss.
            result = self.run_worker(Path(directory), [read(original["request_id"]), listing()])
            self.assertEqual(self.output(result[0])["result"], {"status": "outcome_unknown"})
            self.assertEqual(self.output(result[1])["requests"], [])

    def test_shared_import_works_in_the_packaged_mount_layout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = root / "addon"
            package.mkdir()
            state = root / "state"
            state.mkdir()
            for file in ("server.py", "lane.toml"):
                shutil.copy2(SERVER.parent / file, package / file)
            for file in ("exact_worker.py", "protocol.py"):
                shutil.copy2(ADDONS / file, root / file)
            result = self.run_worker(state, [submit(request()), listing()], server=package / "server.py", cwd=root)
            self.assertEqual(self.output(result[0])["state"], "pending")
            self.assertEqual(self.output(result[1])["requests"], [request()])


if __name__ == "__main__":
    unittest.main()

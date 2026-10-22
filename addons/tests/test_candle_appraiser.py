"""Real MCP subprocess and durable restart boundaries; model answers are scripted."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

from stdio_fixture import run_stdio
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import exact_worker

ADDONS = Path(__file__).resolve().parents[1]
SERVER = ADDONS / "candle-appraiser" / "server.py"


def request(request_id="grade-1", *, stage="grade", task_id=None):
    original = {"request_id": request_id,
            "identity": {"goal_id": "goal-1", "request_id": "payout-1", "verification_run_id": "proof-1"},
            "stage": stage, "input": {"goal": {"title": "원래 목표"}},
            "schema": {"type": "object", "properties": {"grade": {"enum": ["A"]}},
                       "required": ["grade"], "additionalProperties": False},
            "prompt": "Judge only the captured goal."}
    if stage == "relation":
        original["task_id"] = task_id
    return original


def call(name, arguments):
    return {"method": "tools/call", "params": {"name": name, "arguments": arguments}}


def admitted(arguments, caller=None):
    return call("lane_call", {"tool": "candle_appraise", "arguments": arguments,
                              "caller": caller or {"kind": "operator"}})


def submit(original, caller=None):
    return admitted({"kind": "submit", "request": original}, caller)


def read(request_id):
    return admitted({"kind": "read", "request_id": request_id})


def observe():
    # The host sends context only to packages declaring an action tool.
    # Candle is a derive-only package, even though its exported tools use
    # the separate host-admitted caller envelope.
    return call("lane_observe", {"binding": {"sources": []}, "sources": []})


def listing():
    return call("lane_host_requests", {})


def deliver(request_id, result):
    return call("lane_host_result", {"request_id": request_id, "result": result})


class CandleWorker(unittest.TestCase):
    def run_worker(self, state: Path, operations):
        rpc = [{"method": "initialize", "params": {"capabilities": {}}}, *operations]
        lines = [json.dumps({"jsonrpc": "2.0", "id": i, **entry}, ensure_ascii=False)
                 for i, entry in enumerate(rpc, 1)]
        completed = run_stdio([sys.executable, str(SERVER), "--state", str(state)],
                              input="\n".join(lines) + "\n", text=True, capture_output=True,
                              check=True, timeout=10)
        self.assertEqual(completed.stderr, "")
        replies = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual([reply["id"] for reply in replies], list(range(1, len(rpc) + 1)))
        return [reply["result"] for reply in replies[1:]]

    def output(self, result):
        self.assertFalse(result.get("isError", False), result)
        return result["structuredContent"]

    def test_pending_and_original_result_survive_new_worker_incarnations(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            original = request()
            first = self.run_worker(state, [observe(), submit(original), listing()])
            self.assertEqual(self.output(first[0])["rows"][0]["fields"]["pending"], 0)
            self.assertEqual(self.output(first[1])["state"], "pending")
            exact = self.output(first[2])["requests"]
            self.assertEqual(exact, [{"kind": "exact_output", "request_id": "grade-1", "output": "grade",
                                      "schema": original["schema"],
                                      "messages": [{"role": "user", "text": original["prompt"]}]}])
            answer = {"status": "answered", "output": {"grade": "A"}, "slot": "original-slot",
                      "usage": {"input_tokens": 11, "output_tokens": 3}}
            second = self.run_worker(state, [observe(), listing(), deliver("grade-1", answer),
                                             read("grade-1"), listing()])
            self.assertEqual(self.output(second[0])["rows"][0]["fields"]["pending"], 1)
            self.assertEqual(self.output(second[1])["requests"], exact)
            self.assertEqual(self.output(second[2]), {"accepted": True})
            self.assertEqual(self.output(second[3]), {"request_id": "grade-1", "state": "finished", "result": answer})
            self.assertEqual(self.output(second[4]), {"requests": []})
            third = self.run_worker(state, [submit(original), deliver("grade-1", answer), listing()])
            self.assertEqual(self.output(third[0])["result"], answer)
            self.assertEqual(self.output(third[1]), {"accepted": True})
            self.assertEqual(self.output(third[2]), {"requests": []})

    def test_id_reuse_cannot_overwrite_input_or_terminal_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            original = request()
            changed = {**original, "prompt": "Different input"}
            answer = {"status": "answered", "output": {"grade": "A"}, "slot": "slot-1"}
            other = {**answer, "output": {"grade": "B"}}
            result = self.run_worker(state, [submit(original), submit(changed), listing(),
                                             deliver("grade-1", answer), deliver("grade-1", other), read("grade-1")])
            self.assertTrue(result[1]["isError"])
            self.assertEqual(self.output(result[2])["requests"][0]["messages"][0]["text"], original["prompt"])
            self.assertTrue(result[4]["isError"])
            self.assertEqual(self.output(result[5])["result"], answer)

    def test_equal_relation_titles_keep_distinct_task_intents_out_of_model_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            one = request("relation-a", stage="relation", task_id="task-a")
            two = request("relation-b", stage="relation", task_id="task-b")
            result = self.run_worker(Path(directory), [submit(one), submit(two), listing()])
            requests = self.output(result[2])["requests"]
            self.assertEqual({item["request_id"] for item in requests}, {"relation-a", "relation-b"})
            self.assertEqual(requests[0]["messages"], requests[1]["messages"])
            for item in requests:
                self.assertEqual(set(item), {"kind", "request_id", "output", "messages", "schema"})

    def test_output_limit_is_retained_without_another_appraisal(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            terminal = {"status": "output_limit_reached", "detail": "provider output limit"}
            self.run_worker(state, [submit(request()), deliver("grade-1", terminal)])
            result = self.run_worker(state, [submit(request()), listing(), read("grade-1")])
            self.assertEqual(self.output(result[0])["result"], terminal)
            self.assertEqual(self.output(result[1]), {"requests": []})
            self.assertEqual(self.output(result[2])["result"], terminal)

    def test_unknown_outcome_is_terminal_and_never_relisted_after_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            unknown = {"status": "outcome_unknown"}
            self.run_worker(state, [submit(request()), deliver("grade-1", unknown)])
            result = self.run_worker(state, [submit(request()), listing(), read("grade-1")])
            self.assertEqual(self.output(result[0])["result"], unknown)
            self.assertEqual(self.output(result[1]), {"requests": []})
            self.assertEqual(self.output(result[2])["result"], unknown)

    def test_authority_and_invalid_result_do_not_create_or_finish_an_intent(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_worker(Path(directory), [submit(request(), {"kind": "keeper", "name": "worker"}),
                                                       listing(), submit(request()),
                                                       deliver("grade-1", {"status": "made-up"}), listing()])
            self.assertTrue(result[0]["isError"])
            self.assertEqual(self.output(result[1]), {"requests": []})
            self.assertTrue(result[3]["isError"])
            self.assertEqual(len(self.output(result[4])["requests"]), 1)

    def test_corrupt_record_refuses_reads_and_listing_instead_of_redispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            self.run_worker(state, [submit(request())])
            record_path, = (state / "candle-appraiser").glob("*.json")
            record = json.loads(record_path.read_text())
            record["request"]["prompt"] = "tampered"
            record_path.write_text(json.dumps(record))
            result = self.run_worker(state, [read("grade-1"), listing(), submit(request())])
            self.assertTrue(all(item["isError"] for item in result))

    def test_persistence_uncertainty_cannot_publish_a_finished_result(self):
        spec = importlib.util.spec_from_file_location("candle_appraiser_worker", SERVER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            worker = exact_worker.Worker(Path(directory), 4194304, module.CONTRACT)
            worker.invoke({"kind": "submit", "request": request()}, {"kind": "operator"})
            original_fsync = os.fsync
            def failed_directory_sync(fd):
                if stat.S_ISDIR(os.fstat(fd).st_mode):
                    raise OSError("directory persistence unconfirmed")
                return original_fsync(fd)
            with patch.object(os, "fsync", side_effect=failed_directory_sync):
                with self.assertRaises(OSError):
                    worker.host_result({"request_id": "grade-1", "result": {"status": "outcome_unknown"}})
            with self.assertRaises(module.InvalidInput):
                worker.invoke({"kind": "read", "request_id": "grade-1"}, {"kind": "operator"})
            with self.assertRaises(module.InvalidInput):
                worker.host_requests({})

    def test_frame_capacity_defers_new_admission_without_hiding_existing_work(self):
        spec = importlib.util.spec_from_file_location("candle_appraiser_capacity", SERVER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            worker = exact_worker.Worker(Path(directory), 4194304, module.CONTRACT)
            one, two = request("one"), request("two")
            original = worker.invoke({"kind": "submit", "request": one}, {"kind": "operator"})
            envelope = {"jsonrpc": "2.0", "id": 2 ** 53,
                        "result": exact_worker.tool_result({"requests": [worker.host_request(one)]})}
            worker.max_reply_bytes = len((exact_worker.encode_output(envelope) + "\n").encode("utf-8"))
            self.assertEqual(original["state"], "pending")
            waiting = worker.invoke({"kind": "submit", "request": two}, {"kind": "operator"})
            self.assertEqual(waiting["state"], "capacity_wait")
            self.assertIsNone(worker.store.read("two"))
            self.assertEqual([item["request_id"] for item in worker.host_requests({})["requests"]], ["one"])
            worker.host_result({"request_id": "one", "result": {"status": "outcome_unknown"}})
            accepted = worker.invoke({"kind": "submit", "request": two}, {"kind": "operator"})
            self.assertEqual(accepted["state"], "pending")

    def test_missing_store_is_an_error_instead_of_absent_or_an_empty_listing(self):
        spec = importlib.util.spec_from_file_location("candle_appraiser_missing_store", SERVER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            worker = exact_worker.Worker(Path(directory), 4194304, module.CONTRACT)
            worker.store.directory.rmdir()
            with self.assertRaises(FileNotFoundError):
                worker.host_requests({})
            with self.assertRaises(FileNotFoundError):
                worker.invoke({"kind": "read", "request_id": "original"}, {"kind": "operator"})
            with self.assertRaises(FileNotFoundError):
                worker.invoke({"kind": "submit", "request": request()}, {"kind": "operator"})

    def test_replaced_store_cannot_authorize_new_work_for_old_ids(self):
        spec = importlib.util.spec_from_file_location("candle_appraiser_replaced_store", SERVER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            worker = exact_worker.Worker(Path(directory), 4194304, module.CONTRACT)
            worker.invoke({"kind": "submit", "request": request()}, {"kind": "operator"})
            worker.store.directory.rename(Path(directory) / "original-store")
            worker.store.directory.mkdir()
            for operation in (lambda: worker.host_requests({}),
                              lambda: worker.invoke({"kind": "read", "request_id": "grade-1"}, {"kind": "operator"}),
                              lambda: worker.invoke({"kind": "submit", "request": request()}, {"kind": "operator"})):
                with self.assertRaises(module.InvalidInput):
                    operation()

    def test_first_store_creation_syncs_its_installation_parent_before_admission(self):
        spec = importlib.util.spec_from_file_location("candle_appraiser_first_sync", SERVER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory).stat()
            original_fsync = os.fsync
            def fail_parent_sync(fd):
                info = os.fstat(fd)
                if (info.st_dev, info.st_ino) == (parent.st_dev, parent.st_ino):
                    raise OSError("state parent persistence unconfirmed")
                return original_fsync(fd)
            with patch.object(os, "fsync", side_effect=fail_parent_sync):
                with self.assertRaises(OSError):
                    exact_worker.Worker(Path(directory), 4194304, module.CONTRACT)
            self.assertEqual(list((Path(directory) / "candle-appraiser").iterdir()), [])


    def test_excessive_json_nesting_refuses_input_without_killing_the_worker(self):
        with tempfile.TemporaryDirectory() as directory:
            nested = "[" * 1500 + "0" + "]" * 1500
            malformed = ('{"jsonrpc":"2.0","id":1,"method":"tools/call",'
                         '"params":{"name":"lane_call","arguments":' + nested + '}}')
            ping = '{"jsonrpc":"2.0","id":2,"method":"ping"}'
            completed = run_stdio([sys.executable, str(SERVER), "--state", directory],
                                  input=malformed + "\n" + ping + "\n", text=True,
                                  capture_output=True, check=True, timeout=10)
            first, second = map(json.loads, completed.stdout.splitlines())
            # Python 3.12 can refuse this in its JSON parser; Python 3.14's
            # iterative parser reaches the invalid envelope instead. Both
            # must return an error and keep serving the next request.
            if "error" in first:
                self.assertEqual(first["error"]["code"], -32602)
            else:
                self.assertTrue(first["result"]["isError"])
            self.assertEqual(second["result"], {})
            self.assertEqual(list((Path(directory) / "candle-appraiser").iterdir()), [])

    def test_excessive_nesting_in_retained_state_is_an_error_not_a_worker_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            self.run_worker(state, [submit(request())])
            record_path, = (state / "candle-appraiser").glob("*.json")
            record_path.write_text("[" * 1500 + "0" + "]" * 1500)
            results = self.run_worker(state, [read("grade-1"), listing()])
            self.assertTrue(all(item["isError"] for item in results))


if __name__ == "__main__":
    unittest.main()

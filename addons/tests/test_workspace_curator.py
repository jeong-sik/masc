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
import tomllib
import tracemalloc
import unittest
from unittest.mock import patch

from stdio_fixture import run_stdio

ADDONS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ADDONS))
import exact_worker

SERVER = ADDONS / "workspace-curator" / "server.py"
FRAME = tomllib.loads((SERVER.parent / "lane.toml").read_text(encoding="utf-8"))["resources"]["max_reply_bytes"]


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

    def test_output_limit_is_an_original_terminal_across_worker_restart(self):
        for output in ("classification", "briefing"):
            with self.subTest(output=output), tempfile.TemporaryDirectory() as directory:
                state = Path(directory)
                original = request("original-size-refusal", output)
                self.run_worker(state, [submit(original)])
                terminal = {"status": "output_limit_reached", "detail": "provider output limit"}
                malformed = [{**terminal, "extra": True}, {"status": "output_limit_reached"},
                             {**terminal, "detail": 12}]
                replies = self.run_worker(state, [*[deliver(original["request_id"], x) for x in malformed],
                                                  listing(), deliver(original["request_id"], terminal)])
                self.assertTrue(all(x["isError"] for x in replies[:len(malformed)]))
                self.assertEqual(self.output(replies[-2])["requests"], [original])
                self.assertEqual(self.output(replies[-1]), {"accepted": True})
                restored = self.run_worker(state, [read(original["request_id"]), submit(original), listing(),
                                                   deliver(original["request_id"], {"status": "outcome_unknown"})])
                self.assertEqual(self.output(restored[0])["result"], terminal)
                self.assertEqual(self.output(restored[1])["result"], terminal)
                self.assertEqual(self.output(restored[2])["requests"], [])
                self.assertTrue(restored[3]["isError"])

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

    def test_a_request_no_listing_can_carry_is_kept_as_a_typed_refusal(self):
        with tempfile.TemporaryDirectory() as directory:
            contract = self.module().CONTRACT
            small, large = request("original-small"), {**request("original-large"), "system": "x" * 4096}
            envelope = {"jsonrpc": "2.0", "id": 2 ** 53,
                        "result": exact_worker.tool_result({"requests": [contract.host_request(small)]})}
            frame = len((exact_worker.encode_output(envelope) + "\n").encode("utf-8"))
            worker = exact_worker.Worker(Path(directory), frame, contract)
            refused = {"request_id": large["request_id"], "state": "finished",
                       "result": exact_worker.REQUEST_BODY_REFUSED}
            self.assertEqual(worker.invoke({"kind": "submit", "request": large}, {"kind": "operator"}), refused)
            self.assertEqual(worker.host_requests({}), {"requests": []})
            kept = worker.store.path(large["request_id"])
            self.assertEqual(set(json.loads(kept.read_text())), {"version", "request_id", "digest", "result"})
            self.assertLess(kept.stat().st_size, len(large["system"]))
            # Another worker on the same store, as after a lost reply.
            reopened = exact_worker.Worker(Path(directory), frame, contract)
            self.assertEqual(reopened.invoke({"kind": "read", "request_id": large["request_id"]},
                                             {"kind": "operator"}), refused)
            self.assertEqual(reopened.invoke({"kind": "submit", "request": large}, {"kind": "operator"}), refused)
            with self.assertRaises(exact_worker.InvalidInput):
                reopened.invoke({"kind": "submit", "request": {**large, "system": "y" * 4096}}, {"kind": "operator"})
            with self.assertRaises(exact_worker.InvalidInput):
                reopened.host_result({"request_id": large["request_id"], "result": {"status": "outcome_unknown"}})
            self.assertEqual(reopened.host_result({"request_id": large["request_id"],
                                                   "result": exact_worker.REQUEST_BODY_REFUSED}), {"accepted": True})
            fields = reopened.observe({"binding": {}, "sources": []})["rows"][0]["fields"]
            self.assertEqual((fields["pending"], fields["finished"], fields["requests"]),
                             (0, 1, [large["request_id"]]))
            # The refusal holds no capacity: a request that fits is admitted.
            admitted = reopened.invoke({"kind": "submit", "request": small}, {"kind": "operator"})
            self.assertEqual(admitted["state"], "pending")
            self.assertEqual(reopened.host_requests({}), {"requests": [contract.host_request(small)]})

    def test_an_admitted_request_keeps_its_answer_after_the_frame_shrinks(self):
        with tempfile.TemporaryDirectory() as directory:
            contract = self.module().CONTRACT
            original = request()
            exact_worker.Worker(Path(directory), FRAME, contract).invoke(
                {"kind": "submit", "request": original}, {"kind": "operator"})
            # A frame that now holds no listing at all.
            narrowed = exact_worker.Worker(Path(directory), 1, contract)
            pending = {"request_id": original["request_id"], "state": "pending"}
            self.assertEqual(narrowed.invoke({"kind": "submit", "request": original}, {"kind": "operator"}), pending)
            self.assertEqual(narrowed.invoke({"kind": "read", "request_id": original["request_id"]},
                                             {"kind": "operator"}), pending)

    def test_a_changed_or_misplaced_refusal_record_is_never_read_or_listed(self):
        with tempfile.TemporaryDirectory() as directory:
            contract = self.module().CONTRACT
            small, large = request("original-small"), {**request("original-large"), "system": "x" * 4096}
            envelope = {"jsonrpc": "2.0", "id": 2 ** 53,
                        "result": exact_worker.tool_result({"requests": [contract.host_request(small)]})}
            frame = len((exact_worker.encode_output(envelope) + "\n").encode("utf-8"))
            worker = exact_worker.Worker(Path(directory), frame, contract)
            worker.invoke({"kind": "submit", "request": large}, {"kind": "operator"})
            kept = worker.store.path(large["request_id"])
            original = kept.read_text()
            record = json.loads(original)
            changes = {"digest in capitals": {**record, "digest": record["digest"].upper()},
                       "another result": {**record, "result": {"status": "outcome_unknown"}},
                       "an extra field": {**record, "extra": True},
                       "no digest": {key: value for key, value in record.items() if key != "digest"}}
            for name, changed in changes.items():
                with self.subTest(change=name):
                    kept.write_text(json.dumps(changed))
                    reopened = exact_worker.Worker(Path(directory), frame, contract)
                    with self.assertRaises(exact_worker.InvalidInput):
                        reopened.invoke({"kind": "read", "request_id": large["request_id"]}, {"kind": "operator"})
                    with self.assertRaises(exact_worker.InvalidInput):
                        reopened.host_requests({})
                    kept.write_text(original)
            # The same refusal stored under another request's name.
            misplaced = worker.store.path("original-other")
            misplaced.write_text(original)
            with self.assertRaises(exact_worker.InvalidInput):
                exact_worker.Worker(Path(directory), frame, contract).host_requests({})

    def test_a_submit_over_one_frame_gets_the_typed_refusal_through_the_real_worker(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            large = {**request("original-large"), "system": "x" * FRAME}
            replies = self.run_worker(state, [submit(large), read(large["request_id"]), listing()])
            refused = {"request_id": large["request_id"], "state": "finished",
                       "result": exact_worker.REQUEST_BODY_REFUSED}
            self.assertEqual([self.output(reply) for reply in replies[:2]], [refused, refused])
            self.assertEqual(self.output(replies[2])["requests"], [])

    def finished_store(self, count, body):
        """A store with [count] finished requests whose system text is [body]."""
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory)
        worker = exact_worker.Worker(directory, FRAME, self.module().CONTRACT)
        for index in range(count):
            original = {**request(f"original-finished-{index}"), "system": body}
            worker.invoke({"kind": "submit", "request": original}, {"kind": "operator"})
            worker.host_result({"request_id": original["request_id"], "result": {"status": "outcome_unknown"}})
        return directory

    def peak(self, directory, *, before=lambda _worker: None, during):
        worker = exact_worker.Worker(directory, FRAME, self.module().CONTRACT)
        before(worker)
        tracemalloc.start()
        try:
            during(worker)
            return tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()

    def test_finished_bodies_are_held_one_at_a_time_and_read_once(self):
        body = "x" * 1_000_000
        one, six = self.finished_store(1, body), self.finished_store(6, body)
        listing_of = lambda worker: worker.host_requests({})
        # The first inventory reads every record, one body at a time (#45456):
        # five more finished records add far less than one body to its peak.
        self.assertLess(self.peak(six, during=listing_of) - self.peak(one, during=listing_of), len(body) // 2)

        def later(worker):
            worker.invoke({"kind": "submit", "request": request("original-new")}, {"kind": "operator"})
            worker.host_requests({})
            worker.observe({"binding": {}, "sources": []})
        # After it, submits, listings and observations read no finished body.
        self.assertLess(self.peak(six, before=listing_of, during=later), len(body))

    def test_a_pending_record_changed_outside_the_worker_stops_it(self):
        observation = lambda w: w.observe({"binding": {}, "sources": []})["rows"][0]["fields"]
        finished = lambda record: {**record, "result": {"status": "outcome_unknown"}}
        for change, finished_after in (("finished", 1), ("removed", 0)):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                worker = exact_worker.Worker(Path(directory), FRAME, self.module().CONTRACT)
                original = request()
                worker.invoke({"kind": "submit", "request": original}, {"kind": "operator"})
                self.assertEqual(worker.host_requests({}), {"requests": [original]})
                path = worker.store.path(original["request_id"])
                if change == "finished":
                    path.write_text(json.dumps(finished(json.loads(path.read_text()))))
                else:
                    path.unlink()
                with self.assertRaises(exact_worker.InvalidInput) as stopped:
                    worker.host_requests({})
                # Every later call fails the same way, observations included.
                for call in (lambda: worker.host_requests({}), lambda: observation(worker),
                             lambda: worker.invoke({"kind": "submit", "request": request("original-next")},
                                                   {"kind": "operator"})):
                    with self.assertRaises(exact_worker.InvalidInput) as again:
                        call()
                    self.assertEqual(str(again.exception), str(stopped.exception))
                reopened = exact_worker.Worker(Path(directory), FRAME, self.module().CONTRACT)
                self.assertEqual(reopened.host_requests({}), {"requests": []})
                self.assertEqual((observation(reopened)["pending"], observation(reopened)["finished"]),
                                 (0, finished_after))

    def test_a_store_directory_replaced_after_the_first_inventory_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            worker = exact_worker.Worker(Path(directory), FRAME, self.module().CONTRACT)
            worker.invoke({"kind": "submit", "request": request()}, {"kind": "operator"})
            observation = {"binding": {}, "sources": []}
            worker.observe(observation)
            store = worker.store.directory
            store.rename(store.with_name(store.name + "-moved"))
            store.mkdir()
            with self.assertRaises(exact_worker.InvalidInput):
                worker.observe(observation)

    def test_a_record_damaged_before_start_stops_the_worker_without_reading_again(self):
        with tempfile.TemporaryDirectory() as directory:
            original = request()
            exact_worker.Worker(Path(directory), FRAME, self.module().CONTRACT).invoke(
                {"kind": "submit", "request": original}, {"kind": "operator"})
            worker = exact_worker.Worker(Path(directory), FRAME, self.module().CONTRACT)
            path = worker.store.path(original["request_id"])
            path.write_text(path.read_text()[:-2])
            with self.assertRaises(exact_worker.InvalidInput) as stopped:
                worker.host_requests({})
            self.assertIn(path.name, str(stopped.exception))
            with patch.object(exact_worker.Store, "read_path", side_effect=AssertionError("read again")):
                for call in (lambda: worker.host_requests({}), lambda: worker.observe({"binding": {}, "sources": []})):
                    with self.assertRaises(exact_worker.InvalidInput) as again:
                        call()
                    self.assertEqual(str(again.exception), str(stopped.exception))

    def test_a_result_whose_directory_sync_failed_stops_the_worker_and_survives_a_reopen(self):
        with tempfile.TemporaryDirectory() as directory:
            worker = exact_worker.Worker(Path(directory), FRAME, self.module().CONTRACT)
            original = request()
            worker.invoke({"kind": "submit", "request": original}, {"kind": "operator"})
            worker.host_requests({})
            synced = os.fsync

            def fsync(fd):
                if stat.S_ISDIR(os.fstat(fd).st_mode):
                    raise OSError("directory sync failed")
                synced(fd)
            with patch.object(exact_worker.os, "fsync", fsync), self.assertRaises(OSError):
                worker.host_result({"request_id": original["request_id"], "result": {"status": "outcome_unknown"}})
            with self.assertRaisesRegex(exact_worker.InvalidInput, "persistence is unconfirmed"):
                worker.observe({"binding": {}, "sources": []})
            # The rename happened before the directory sync failed.
            reopened = exact_worker.Worker(Path(directory), FRAME, self.module().CONTRACT)
            fields = reopened.observe({"binding": {}, "sources": []})["rows"][0]["fields"]
            self.assertEqual((fields["pending"], fields["finished"]), (0, 1))

    def test_a_reopened_worker_reports_the_same_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            contract = self.module().CONTRACT
            small, large = request("original-small"), {**request("original-large"), "system": "x" * FRAME}
            finished, pending = request("original-finished"), request("original-pending")
            worker = exact_worker.Worker(Path(directory), FRAME, contract)
            for original in (large, finished, pending):
                worker.invoke({"kind": "submit", "request": original}, {"kind": "operator"})
            worker.host_result({"request_id": finished["request_id"], "result": {"status": "outcome_unknown"}})
            worker.invoke({"kind": "submit", "request": small}, {"kind": "operator"})
            observation = lambda w: w.observe({"binding": {}, "sources": []})["rows"][0]["fields"]
            fields = observation(worker)
            self.assertEqual((fields["pending"], fields["finished"]), (2, 2))
            reopened = exact_worker.Worker(Path(directory), FRAME, contract)
            self.assertEqual(observation(reopened), fields)
            self.assertEqual(reopened.host_requests({}), worker.host_requests({}))
            self.assertCountEqual(worker.host_requests({})["requests"],
                                  [contract.host_request(pending), contract.host_request(small)])

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

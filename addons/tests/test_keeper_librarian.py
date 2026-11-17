"""Real Librarian MCP workers retain both original purposes through restarts.

These subprocess fixtures exercise worker persistence and the host-request wire;
they do not execute the host Exact provider or Memory commit.
"""
from __future__ import annotations

import hashlib
import json
import runpy
from pathlib import Path
import sys
import tempfile
import time
import tomllib
import unittest
from unittest.mock import patch

from stdio_fixture import run_stdio

ADDONS = Path(__file__).resolve().parents[1]
SERVER = ADDONS / "keeper-librarian" / "server.py"
FRAME = tomllib.loads((SERVER.parent / "lane.toml").read_text(encoding="utf-8"))["resources"]["max_reply_bytes"]


def request(output, request_id=None):
    return {"kind": "exact_output", "request_id": request_id or "original-" + output,
            "output": output, "system": "Retain original history / 원본.",
            "messages": [{"role": "user", "text": "Original completed-history evidence."},
                         {"role": "assistant", "text": "Original response."},
                         {"role": "user", "text": "Keep the original next boundary."}],
            "schema": {"type": "object", "properties": {"original": {"type": "string"}},
                       "required": ["original"], "additionalProperties": False}}


def tool(output):
    return {"admission": "admit_memory", "durable": "derive_memory"}[output]


def call(name, arguments):
    return {"method": "tools/call", "params": {"name": name, "arguments": arguments}}


def admitted(name, arguments, caller=None):
    return call("lane_call", {"tool": name, "arguments": arguments,
                              "caller": {"kind": "operator"} if caller is None else caller})


def submit(original, name=None, caller=None):
    return admitted(tool(original["output"]) if name is None else name,
                    {"kind": "submit", "request": original}, caller)


def refuse_body(original, request_bytes=None, name=None, caller=None):
    encoded = json.dumps(original, sort_keys=True, ensure_ascii=False,
                         allow_nan=False, separators=(",", ":")).encode("utf-8")
    return admitted(tool(original["output"]) if name is None else name,
                    {"kind": "refuse_body", "request_id": original["request_id"],
                     "request_digest": hashlib.sha256(encoded).hexdigest(),
                     "request_bytes": len(encoded) if request_bytes is None else request_bytes}, caller)


def read(original, name=None):
    return admitted(tool(original["output"]) if name is None else name,
                    {"kind": "read", "request_id": original["request_id"]})


def listing(after=None):
    return call("lane_host_requests", {} if after is None else {"after": after})


def deliver(original, result):
    return call("lane_host_result", {"request_id": original["request_id"], "result": result})


class LibrarianWorker(unittest.TestCase):
    timings = []

    @classmethod
    def tearDownClass(cls):
        if cls.timings:
            print(f"Librarian worker subprocesses: {len(cls.timings)}, "
                  f"total={sum(cls.timings):.3f}s, min={min(cls.timings):.3f}s, max={max(cls.timings):.3f}s")

    def run_worker(self, state, operations):
        operations = [{"method": "initialize", "params": {}}, *operations]
        lines = [json.dumps({"jsonrpc": "2.0", "id": i, **operation}, ensure_ascii=False)
                 for i, operation in enumerate(operations, 1)]
        started = time.perf_counter()
        completed = run_stdio([sys.executable, str(SERVER), "--state", str(state)],
                              input="\n".join(lines) + "\n", timeout=10)
        self.timings.append(time.perf_counter() - started)
        self.assertEqual(completed.stderr, "")
        replies = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual([reply["id"] for reply in replies], list(range(1, len(operations) + 1)))
        return [reply["result"] for reply in replies[1:]]

    def output(self, result):
        self.assertFalse(result.get("isError", False), result)
        return result["structuredContent"]

    def test_both_full_requests_and_terminals_survive_real_restarts(self):
        with tempfile.TemporaryDirectory() as directory:
            originals = [request("admission"), request("durable")]
            replies = self.run_worker(directory, list(map(submit, originals)))
            self.assertTrue(all(self.output(reply)["state"] == "pending" for reply in replies))
            restored = self.run_worker(directory, [listing(), *map(read, originals)])
            self.assertCountEqual(self.output(restored[0])["requests"], originals)
            for path in (Path(directory) / "keeper-librarian").glob("*.json"):
                retained = json.loads(path.read_text())["request"]
                self.assertIn(retained, originals)
            terminals = [{"status": "outcome_unknown"},
                         {"status": "answered", "slot": "original-slot", "output": {"original": "proposal"},
                          "usage": {"input_tokens": 30, "output_tokens": 7}}]
            settled = self.run_worker(directory, [deliver(x, y) for x, y in zip(originals, terminals)])
            self.assertEqual([self.output(x) for x in settled], [{"accepted": True}] * 2)
            for path in (Path(directory) / "keeper-librarian").glob("*.json"):
                retained = json.loads(path.read_text())
                self.assertEqual(set(retained), {"version", "request_id", "digest", "result", "tool"})
                original = next(x for x in originals if x["request_id"] == retained["request_id"])
                self.assertEqual(retained["tool"], tool(original["output"]))
            restored = self.run_worker(directory, [*map(read, originals), *map(submit, originals), listing()])
            self.assertEqual([self.output(x)["result"] for x in restored[:4]], terminals * 2)
            self.assertEqual(self.output(restored[-1])["requests"], [])

    def test_wrong_tool_cannot_submit_or_read_other_purpose_before_or_after_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            originals = [request("admission"), request("durable")]
            other = lambda original: "derive_memory" if original["output"] == "admission" else "admit_memory"
            wrong = self.run_worker(directory, [*[submit(x, other(x)) for x in originals], listing()])
            self.assertTrue(all(x["isError"] for x in wrong[:-1]))
            self.assertEqual(self.output(wrong[-1])["requests"], [])
            self.run_worker(directory, list(map(submit, originals)))
            pending = self.run_worker(directory, [*[read(x, other(x)) for x in originals], listing()])
            self.assertTrue(all(x["isError"] for x in pending[:-1]))
            self.assertCountEqual(self.output(pending[-1])["requests"], originals)
            self.run_worker(directory, [deliver(x, {"status": "outcome_unknown"}) for x in originals])
            terminal = self.run_worker(directory, [*[read(x, other(x)) for x in originals], *map(read, originals)])
            self.assertTrue(all(x["isError"] for x in terminal[:2]))
            self.assertTrue(all(self.output(x)["state"] == "finished" for x in terminal[2:]))

    def test_replacement_ending_survives_worker_restart(self):
        original = request("durable")
        ending = {"status": "not_allowed", "cause": "declaration_replaced"}
        with tempfile.TemporaryDirectory() as directory:
            self.run_worker(directory, [submit(original), deliver(original, ending)])
            restored = self.run_worker(directory, [read(original), listing()])
            self.assertEqual(self.output(restored[0])["result"], ending)
            self.assertEqual(self.output(restored[1])["requests"], [])

    def test_unknown_or_contradictory_replacement_endings_keep_request_pending(self):
        original = request("durable")
        invalid = [
            {"status": "not_allowed", "cause": "unknown"},
            {"status": "not_allowed", "cause": "declaration_replaced", "reason": "ordinary refusal"},
        ]
        with tempfile.TemporaryDirectory() as directory:
            for ending in invalid:
                with self.subTest(ending=ending):
                    replies = self.run_worker(directory, [submit(original), deliver(original, ending), read(original)])
                    self.assertTrue(replies[1]["isError"])
                    self.assertEqual(self.output(replies[2])["state"], "pending")

    def test_body_free_admission_refusal_keeps_its_tool_after_restart(self):
        contract = runpy.run_path(str(SERVER))["CONTRACT"]
        from exact_worker import InvalidInput, REQUEST_BODY_REFUSED, Worker
        with tempfile.TemporaryDirectory() as directory:
            for output in ("admission", "durable"):
                original = {**request(output), "system": "x" * 8192}
                intended = tool(output)
                other = "derive_memory" if output == "admission" else "admit_memory"
                worker = Worker(Path(directory), 4096, contract)
                refused = worker.invoke({"kind": "submit", "request": original},
                                        {"kind": "operator"}, tool_name=intended)
                self.assertEqual(refused["result"], REQUEST_BODY_REFUSED)
                retained = json.loads(worker.store.path(original["request_id"]).read_text())
                self.assertNotIn("request", retained)
                self.assertEqual(retained["tool"], intended)
                reopened = Worker(Path(directory), 4096, contract)
                self.assertEqual(reopened.invoke({"kind": "read", "request_id": original["request_id"]},
                                                 {"kind": "operator"}, tool_name=intended), refused)
                with self.assertRaises(InvalidInput):
                    reopened.invoke({"kind": "read", "request_id": original["request_id"]},
                                    {"kind": "operator"}, tool_name=other)
                self.assertEqual(reopened.host_requests({}), {"requests": []})
                for invalid_tool in ([], {}, None, "", "another-tool"):
                    worker.store.path(original["request_id"]).write_text(
                        json.dumps({**retained, "tool": invalid_tool}))
                    with self.assertRaises(InvalidInput):
                        reopened.invoke({"kind": "read", "request_id": original["request_id"]},
                                        {"kind": "operator"}, tool_name=intended)
                changed = json.dumps({**retained, "tool": other})
                worker.store.path(original["request_id"]).write_text(changed)
                with self.assertRaises(InvalidInput):
                    reopened.invoke({"kind": "submit", "request": original},
                                    {"kind": "operator"}, tool_name=intended)
                self.assertEqual(worker.store.path(original["request_id"]).read_text(), changed)
                worker.store.path(original["request_id"]).write_text(json.dumps(retained))

    def test_measured_body_refusal_survives_restart_without_sending_the_body(self):
        limit = tomllib.loads((SERVER.parent / "lane.toml").read_text())["resources"]["max_reply_bytes"]
        with tempfile.TemporaryDirectory() as directory:
            originals = [{**request(output), "system": "큰" * (limit // len("큰".encode("utf-8")) + 1)}
                         for output in ("admission", "durable")]
            compact = list(map(refuse_body, originals))
            self.assertTrue(all(len(json.dumps(x).encode("utf-8")) < limit for x in compact))
            replies = self.run_worker(directory, [*compact, listing()])
            expected = {"status": "input_refused", "kind": "request_body_refused"}
            for original, reply in zip(originals, replies):
                self.assertEqual(self.output(reply), {"request_id": original["request_id"],
                                                     "state": "finished", "result": expected})
            self.assertEqual(self.output(replies[-1]), {"requests": []})
            records = list((Path(directory) / "keeper-librarian").glob("*.json"))
            self.assertEqual(len(records), 2)
            before = {path.name: path.read_bytes() for path in records}
            for raw in before.values():
                retained = json.loads(raw)
                self.assertEqual(set(retained), {"version", "request_id", "digest", "result", "tool"})
                self.assertEqual(retained["version"], 2)
                self.assertEqual(retained["result"], expected)
            restored = self.run_worker(directory, [*compact, *map(read, originals), listing()])
            self.assertTrue(all(self.output(x)["result"] == expected for x in restored[:-1]))
            self.assertEqual(self.output(restored[-1]), {"requests": []})
            self.assertEqual({path.name: path.read_bytes() for path in records}, before)

    def test_compact_refusal_preserves_existing_pending_and_final_records(self):
        limit = tomllib.loads((SERVER.parent / "lane.toml").read_text())["resources"]["max_reply_bytes"]
        originals = [request("admission"), request("durable")]
        compact = [refuse_body(original, limit + 1) for original in originals]
        with tempfile.TemporaryDirectory() as directory:
            self.run_worker(directory, list(map(submit, originals)))
            records = list((Path(directory) / "keeper-librarian").glob("*.json"))
            for results in (None, [{"status": "outcome_unknown"},
                                   {"status": "answered", "slot": "original-slot",
                                    "output": {"original": "retained answer"}}]):
                if results is not None:
                    self.run_worker(directory, [deliver(x, y) for x, y in zip(originals, results)])
                before = {path.name: path.read_bytes() for path in records}
                wrong_digest = []
                wrong_tool = []
                for original in originals:
                    bad = refuse_body(original, limit + 1)
                    bad["params"]["arguments"]["arguments"]["request_digest"] = "0" * 64
                    wrong_digest.append(bad)
                    wrong_tool.append(refuse_body(original, limit + 1,
                                      name="derive_memory" if original["output"] == "admission" else "admit_memory"))
                replies = self.run_worker(directory, [*wrong_digest, *wrong_tool, *compact, listing()])
                self.assertTrue(all(reply["isError"] for reply in replies[:4]))
                for i, reply in enumerate(replies[4:6]):
                    if results is None:
                        self.assertEqual(self.output(reply)["state"], "pending")
                    else:
                        self.assertEqual(self.output(reply)["result"], results[i])
                self.assertCountEqual(self.output(replies[-1])["requests"],
                                      originals if results is None else [])
                self.assertEqual({path.name: path.read_bytes() for path in records}, before)

    def test_compact_refusal_requires_a_strict_host_measurement_above_the_frame(self):
        limit = tomllib.loads((SERVER.parent / "lane.toml").read_text())["resources"]["max_reply_bytes"]
        original = request("durable")
        operations = []
        for value in (True, False, 0, -1, 1.5, "9999999", None, limit - 1, limit):
            bad = refuse_body(original, limit + 1)
            bad["params"]["arguments"]["arguments"]["request_bytes"] = value
            operations.append(bad)
        for value in (None, [], {}, "", "a" * 63, "A" * 64, "z" * 64):
            bad = refuse_body(original, limit + 1)
            bad["params"]["arguments"]["arguments"]["request_digest"] = value
            operations.append(bad)
        for caller in ({"kind": "anonymous"}, {"kind": "keeper", "name": "keeper"},
                       {"kind": "agent", "name": "agent"}, {"kind": "host_actor", "name": "actor"},
                       {"kind": "operator", "name": "extra"}):
            operations.append(refuse_body(original, limit + 1, caller=caller))
        bad = refuse_body(original, limit + 1)
        bad["params"]["arguments"]["arguments"]["extra"] = True
        operations.append(bad)
        direct = refuse_body(original, limit + 1)["params"]["arguments"]["arguments"]
        operations.append(call("derive_memory", direct))
        with tempfile.TemporaryDirectory() as directory:
            replies = self.run_worker(directory, [*operations, listing(), read(original)])
            self.assertTrue(all(reply["isError"] for reply in replies[:-2]))
            self.assertEqual(self.output(replies[-2]), {"requests": []})
            self.assertEqual(self.output(replies[-1])["state"], "absent")
            self.assertEqual(list((Path(directory) / "keeper-librarian").glob("*.json")), [])

    def test_request_identity_cannot_change_purpose_or_original_input(self):
        with tempfile.TemporaryDirectory() as directory:
            original = request("durable", "same-original-id")
            changed = [request("admission", original["request_id"]),
                       {**original, "system": "Changed system"},
                       {**original, "messages": [{"role": "user", "text": "Flattened"}]},
                       {**original, "schema": {"type": "object"}}]
            self.run_worker(directory, [submit(original)])
            replies = self.run_worker(directory, [*map(submit, changed), listing()])
            self.assertTrue(all(x["isError"] for x in replies[:-1]))
            self.assertEqual(self.output(replies[-1])["requests"], [original])

    def test_invalid_or_unadmitted_requests_create_no_pending_intent(self):
        with tempfile.TemporaryDirectory() as directory:
            original = request("durable")
            invalid = [{**original, "extra": True}, {**original, "output": "unknown"},
                       {**original, "messages": []}, {**original, "schema": []},
                       {**original, "messages": [{"role": "system", "text": "changed role"}]}]
            operations = [admitted("derive_memory", {"kind": "submit", "request": x}) for x in invalid]
            operations += [submit(original, caller={"kind": "keeper", "name": "keeper"}),
                           submit(original, name="unexported_tool"),
                           admitted([], {"kind": "read", "request_id": original["request_id"]}),
                           admitted({}, {"kind": "submit", "request": original}),
                           call("derive_memory", {"kind": "submit", "request": original}), listing()]
            replies = self.run_worker(directory, operations)
            self.assertTrue(all(x["isError"] for x in replies[:-1]))
            self.assertEqual(self.output(replies[-1])["requests"], [])

    def test_corrupted_original_is_not_absent_or_relisted(self):
        for output in ("admission", "durable"):
            with self.subTest(output=output), tempfile.TemporaryDirectory() as directory:
                original = request(output)
                self.run_worker(directory, [submit(original)])
                path, = (Path(directory) / "keeper-librarian").glob("*.json")
                record = json.loads(path.read_text())
                record["request"]["messages"][0]["text"] = "Replaced retained original"
                path.write_text(json.dumps(record))
                replies = self.run_worker(directory, [read(original), listing(), submit(original)])
                self.assertTrue(all(x["isError"] for x in replies))

    def test_a_request_is_admitted_while_another_fills_the_frame_and_both_survive_a_restart(self):
        contract = runpy.run_path(str(SERVER))["CONTRACT"]
        from exact_worker import InvalidInput, Worker
        with tempfile.TemporaryDirectory() as directory:
            first = request("admission", "original-still-waiting")
            second = request("durable", "original-admitted-behind")
            worker = Worker(Path(directory), FRAME, contract)
            name = lambda x: worker.store.path(x["request_id"]).name
            # A frame that holds either request on a page of its own, never both.
            frame = max(self.reply_bytes({"requests": [x], "next": name(x)}) for x in (first, second))
            self.assertGreater(self.reply_bytes({"requests": [first, second]}), frame)
            worker.max_reply_bytes = frame
            self.assertEqual(self.admit(worker, first)["state"], "pending")
            # Admitting the second reads no record but its own.
            with patch.object(worker.store, "read_path", wraps=worker.store.read_path) as read_path:
                self.assertEqual(self.admit(worker, second)["state"], "pending")
            self.assertEqual([read.args[0] for read in read_path.call_args_list], [name(second)])
            head, tail = sorted((first, second), key=name)
            walk = [{"requests": [head], "next": name(head)}, {"requests": [tail]}]
            self.assertEqual(self.pages(worker), walk)
            reopened = Worker(Path(directory), frame, contract)
            for original in (first, second):
                pending = {"request_id": original["request_id"], "state": "pending"}
                self.assertEqual(reopened.invoke({"kind": "read", "request_id": original["request_id"]},
                                                 {"kind": "operator"}, tool_name=tool(original["output"])), pending)
                self.assertEqual(self.admit(reopened, original), pending)
            self.assertEqual(self.pages(reopened), walk)
            with self.assertRaises(InvalidInput):
                self.admit(reopened, {**second, "system": "different frozen input"})
            self.finish(reopened, head)
            self.assertEqual(self.pages(reopened), [{"requests": [tail]}])

    def test_admission_measures_the_page_that_names_the_request_as_next(self):
        contract = runpy.run_path(str(SERVER))["CONTRACT"]
        from exact_worker import REQUEST_BODY_REFUSED, Worker
        with tempfile.TemporaryDirectory() as directory:
            worker = Worker(Path(directory), FRAME, contract)
            name = lambda x: worker.store.path(x["request_id"]).name
            # Ids of one length give each of these requests the same reply length.
            head, tail, *edge = sorted((request("durable", f"original-edge-{index}") for index in range(4)), key=name)
            alone = self.reply_bytes({"requests": [head]})
            followed = self.reply_bytes({"requests": [head], "next": name(head)})
            self.assertLess(alone, followed)
            # A frame that holds the request alone only on a page without next.
            for frame, original in zip((alone, followed - 1), edge):
                worker.max_reply_bytes = frame
                self.assertEqual(self.admit(worker, original),
                                 {"request_id": original["request_id"], "state": "finished",
                                  "result": REQUEST_BODY_REFUSED})
                self.assertNotIn("request", json.loads(worker.store.path(original["request_id"]).read_text()))
            # One byte more holds that page, so the request is listed while another waits behind it.
            worker.max_reply_bytes = followed
            for original in (tail, head):
                self.assertEqual(self.admit(worker, original)["state"], "pending")
            self.assertEqual(self.pages(worker), [{"requests": [head], "next": name(head)}, {"requests": [tail]}])

    def test_requests_beyond_one_frame_are_admitted_and_paged_by_the_real_worker(self):
        # Each body is over half the manifest frame, so no page carries two.
        body = "큰" * (FRAME // 2 // len("큰".encode("utf-8")) + 1)
        originals = [{**request(output), "system": body} for output in ("admission", "durable")]
        name = lambda x: hashlib.sha256(json.dumps(x["request_id"]).encode("utf-8")).hexdigest() + ".json"
        head, tail = sorted(originals, key=name)
        with tempfile.TemporaryDirectory() as directory:
            replies = self.run_worker(directory, list(map(submit, originals)))
            self.assertEqual([self.output(reply)["state"] for reply in replies], ["pending"] * 2)
            walked = self.run_worker(directory, [listing(), listing(name(head)), listing(name(tail))])
            self.assertEqual([self.output(reply) for reply in walked],
                             [{"requests": [head], "next": name(head)}, {"requests": [tail]}, {"requests": []}])

    def admit(self, worker, original):
        return worker.invoke({"kind": "submit", "request": original}, {"kind": "operator"},
                             tool_name=tool(original["output"]))

    def finish(self, worker, original):
        return worker.host_result({"request_id": original["request_id"], "result": {"status": "outcome_unknown"}})

    def reply_bytes(self, page):
        """The length of the reply line that carries [page]."""
        from exact_worker import encode_output, tool_result
        envelope = {"jsonrpc": "2.0", "id": 2 ** 53, "result": tool_result(page)}
        return len((encode_output(envelope) + "\n").encode("utf-8"))

    def pages(self, worker):
        """Every listing page, obtained the way the host does: by following next."""
        pages = [worker.host_requests({})]
        while "next" in pages[-1]:
            after = pages[-1]["next"]
            pages.append(worker.host_requests({"after": after}))
            # A walk ends because every page starts after the one before it.
            if "next" in pages[-1]:
                self.assertGreater(pages[-1]["next"], after)
        return pages

    def test_listing_pages_carry_every_pending_request_exactly_once(self):
        contract = runpy.run_path(str(SERVER))["CONTRACT"]
        from exact_worker import Worker
        with tempfile.TemporaryDirectory() as directory:
            wide = Worker(Path(directory), FRAME, contract)
            originals = [request(output, f"original-paged-{index}")
                         for index, output in enumerate(("admission", "durable") * 3)]
            for original in originals:
                self.assertEqual(self.admit(wide, original)["state"], "pending")
            ordered = sorted(originals, key=lambda x: wide.store.path(x["request_id"]).name)
            names = [wide.store.path(x["request_id"]).name for x in ordered]
            # Everything fits one frame: one page, and it carries no next.
            self.assertEqual(wide.host_requests({}), {"requests": ordered})
            # The same store under a frame that holds two of these records.
            frame = self.reply_bytes({"requests": ordered[:2], "next": names[1]})
            narrow = Worker(Path(directory), frame, contract)
            pages = self.pages(narrow)
            self.assertGreater(len(pages), 2)
            self.assertEqual([x for page in pages for x in page["requests"]], ordered)
            start = 0
            for page in pages:
                end = start + len(page["requests"])
                self.assertLessEqual(self.reply_bytes(page), frame)
                if end == len(ordered):
                    self.assertEqual(page, {"requests": ordered[start:]})
                else:
                    self.assertEqual(page, {"requests": ordered[start:end], "next": names[end - 1]})
                    # The page is full: the record after it would not fit.
                    longer = {"requests": ordered[start:end + 1]}
                    if end + 1 < len(ordered):
                        longer["next"] = names[end]
                    self.assertGreater(self.reply_bytes(longer), frame)
                start = end
            # A page reads the records it carries and the one that no longer fits.
            with patch.object(narrow.store, "read_path", wraps=narrow.store.read_path) as read_path:
                self.assertEqual(narrow.host_requests({}), pages[0])
            self.assertEqual([read.args[0] for read in read_path.call_args_list],
                             names[:len(pages[0]["requests"]) + 1])
            # A restart in the middle of a walk does not change the pages.
            reopened = Worker(Path(directory), frame, contract)
            self.assertEqual(reopened.host_requests({"after": pages[0]["next"]}), pages[1])

    def test_listing_stops_at_a_pending_record_no_page_can_carry(self):
        contract = runpy.run_path(str(SERVER))["CONTRACT"]
        from exact_worker import InvalidInput, Worker
        with tempfile.TemporaryDirectory() as directory:
            wide = Worker(Path(directory), FRAME, contract)
            name = lambda x: wide.store.path(x["request_id"]).name
            ids = sorted((f"original-frame-{index}" for index in range(3)),
                         key=lambda x: wide.store.path(x).name)
            first, last = request("admission", ids[0]), request("admission", ids[2])
            large = {**request("durable", ids[1]), "system": "x" * 8192}
            for original in (last, large, first):
                self.assertEqual(self.admit(wide, original)["state"], "pending")
            # A later frame that holds either small record, but not the large one.
            frame = self.reply_bytes({"requests": [first], "next": name(first)})
            narrow = Worker(Path(directory), frame, contract)
            opening = {"requests": [first], "next": name(first)}
            self.assertEqual(narrow.host_requests({}), opening)
            for _ in range(2):
                with self.assertRaises(InvalidInput) as refused:
                    narrow.host_requests({"after": name(first)})
                self.assertIn(name(large), str(refused.exception))
            # The refusal belongs to that page; the worker keeps answering.
            self.assertEqual(narrow.host_requests({}), opening)
            self.assertEqual(self.admit(narrow, large)["state"], "pending")
            # The same record at the head of the first page.
            self.finish(narrow, first)
            with self.assertRaises(InvalidInput) as refused:
                narrow.host_requests({})
            self.assertIn(name(large), str(refused.exception))
            # Once it ends, the request behind it is listed.
            self.finish(narrow, large)
            self.assertEqual(narrow.host_requests({}), {"requests": [last]})

    def test_a_listing_page_needs_room_for_next_only_while_requests_wait_behind_it(self):
        contract = runpy.run_path(str(SERVER))["CONTRACT"]
        from exact_worker import InvalidInput, Worker
        with tempfile.TemporaryDirectory() as directory:
            wide = Worker(Path(directory), FRAME, contract)
            ids = sorted(("original-edge-0", "original-edge-1"), key=lambda x: wide.store.path(x).name)
            head, tail = request("admission", ids[0]), request("durable", ids[1])
            for original in (head, tail):
                self.admit(wide, original)
            # The head fits this frame alone only when the reply has no next.
            frame = self.reply_bytes({"requests": [head]})
            narrow = Worker(Path(directory), frame, contract)
            with self.assertRaises(InvalidInput) as refused:
                narrow.host_requests({})
            self.assertIn(wide.store.path(head["request_id"]).name, str(refused.exception))
            self.finish(narrow, tail)
            self.assertEqual(narrow.host_requests({}), {"requests": [head]})

    def test_listing_after_is_only_compared_with_record_names(self):
        contract = runpy.run_path(str(SERVER))["CONTRACT"]
        from exact_worker import Worker
        with tempfile.TemporaryDirectory() as directory:
            worker = Worker(Path(directory), FRAME, contract)
            originals = [request("durable", f"original-after-{index}") for index in range(4)]
            for original in originals:
                self.admit(worker, original)
            ordered = sorted(originals, key=lambda x: worker.store.path(x["request_id"]).name)
            names = [worker.store.path(x["request_id"]).name for x in ordered]
            self.finish(worker, ordered[1])
            pending = [ordered[0], ordered[2], ordered[3]]
            with patch.object(worker.store, "read_path", wraps=worker.store.read_path) as read_path:
                for after, expected in (("-", pending),                  # sorts before every name
                                        ("../" + names[2], pending),     # a path is not followed
                                        (names[0], pending[1:]),
                                        (names[0] + "x", pending[1:]),   # between two records
                                        (names[1], pending[1:]),         # a finished record
                                        (names[2], pending[2:]),
                                        (names[3], []),
                                        ("g", [])):                      # sorts after every name
                    with self.subTest(after=after):
                        self.assertEqual(worker.host_requests({"after": after}), {"requests": expected})
                self.assertLessEqual({read.args[0] for read in read_path.call_args_list}, set(names))

    def test_listing_arguments_are_nothing_or_one_non_empty_after(self):
        original = request("durable")
        malformed = [{"after": ""}, {"after": 3}, {"after": None}, {"after": True}, {"after": ["a"]},
                     {"after": "a", "extra": True}, {"extra": True}, {"next": "a"}, [], "a", None]
        with tempfile.TemporaryDirectory() as directory:
            replies = self.run_worker(directory, [submit(original),
                                                  *[call("lane_host_requests", x) for x in malformed],
                                                  listing(), listing("-"), listing("g")])
            self.assertTrue(all(reply["isError"] for reply in replies[1:-3]))
            self.assertEqual([self.output(reply) for reply in replies[-3:]],
                             [{"requests": [original]}, {"requests": [original]}, {"requests": []}])

    def test_a_pending_record_stored_by_an_earlier_revision_is_listed_as_it_is(self):
        compact = lambda value: json.dumps(value, sort_keys=True, ensure_ascii=False,
                                           allow_nan=False, separators=(",", ":"))
        sha256 = lambda value: hashlib.sha256(compact(value).encode("utf-8")).hexdigest()
        original = request("durable", "original-earlier-revision")
        with tempfile.TemporaryDirectory() as directory:
            store = Path(directory) / "keeper-librarian"
            store.mkdir()
            name = sha256(original["request_id"]) + ".json"
            (store / name).write_text(compact({"version": 2, "request": original,
                                               "digest": sha256(original), "result": None}) + "\n",
                                      encoding="utf-8")
            replies = self.run_worker(directory, [listing(), read(original), submit(original), listing(name)])
            self.assertEqual(self.output(replies[0]), {"requests": [original]})
            pending = {"request_id": original["request_id"], "state": "pending"}
            self.assertEqual([self.output(reply) for reply in replies[1:3]], [pending, pending])
            self.assertEqual(self.output(replies[3]), {"requests": []})

    def test_manifest_and_discovery_expose_two_purpose_specific_tools(self):
        manifest = tomllib.loads((SERVER.parent / "lane.toml").read_text())
        self.assertEqual(manifest["world"]["tools"]["export"], ["admit_memory", "derive_memory"])
        self.assertEqual(set(manifest["world"]["exact_outputs"]), {"admission", "durable"})
        for output, declaration in manifest["world"]["exact_outputs"].items():
            self.assertTrue(declaration["request_schema"])
            self.assertEqual(json.loads((SERVER.parent / declaration["schema"]).read_text())["type"], "object")
        with tempfile.TemporaryDirectory() as directory:
            result, = self.run_worker(directory, [{"method": "tools/list", "params": {}}])
            exported = {x["name"]: x for x in result["tools"]}
            self.assertEqual(exported["lane_host_requests"]["inputSchema"],
                             {"type": "object", "additionalProperties": False,
                              "properties": {"after": {"type": "string", "minLength": 1}}})
            for output in ("admission", "durable"):
                schema = exported[tool(output)]["inputSchema"]["oneOf"][0]["properties"]["request"]
                self.assertEqual(schema["properties"]["output"], {"type": "string", "const": output})
                compact = exported[tool(output)]["inputSchema"]["oneOf"][1]
                self.assertEqual(compact["properties"]["kind"]["const"], "refuse_body")
                self.assertEqual(set(compact["required"]),
                                 {"kind", "request_id", "request_digest", "request_bytes"})
                self.assertFalse(compact["additionalProperties"])


if __name__ == "__main__":
    unittest.main()

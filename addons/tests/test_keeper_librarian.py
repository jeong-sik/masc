"""Real Librarian MCP workers retain both original purposes through restarts.

These subprocess fixtures exercise worker persistence and the host-request wire;
they do not execute the host Exact provider or Memory commit.
"""
from __future__ import annotations

import json
import runpy
from pathlib import Path
import sys
import tempfile
import time
import tomllib
import unittest

from stdio_fixture import run_stdio

ADDONS = Path(__file__).resolve().parents[1]
SERVER = ADDONS / "keeper-librarian" / "server.py"


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


def read(original, name=None):
    return admitted(tool(original["output"]) if name is None else name,
                    {"kind": "read", "request_id": original["request_id"]})


def listing():
    return call("lane_host_requests", {})


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
            for output in ("admission", "durable"):
                schema = exported[tool(output)]["inputSchema"]["oneOf"][0]["properties"]["request"]
                self.assertEqual(schema["properties"]["output"], {"type": "string", "const": output})


if __name__ == "__main__":
    unittest.main()

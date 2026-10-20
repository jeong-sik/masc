"""The operator quiz worker over stdio, as the Lane host runs it: MCP tools
in, structured content out, the log on a state directory that outlives the
worker (RFC operator-quiz §4.9, §15 L6)."""
from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from test_operator_quiz_flow import FakeHost, first_quote, answering, post

SERVER = Path(__file__).resolve().parents[1] / "operator-quiz" / "server.py"
LANES = {"quiz/sessions", "quiz/questions", "quiz/topics", "quiz/items", "quiz/measures"}
ROW_FIELDS = {"id", "lane_id", "kind", "title", "observed_at", "subject_id", "clock",
              "actor", "fields", "evidence", "related_ids"}
CONTEXT = {"instance_id": "operator-quiz-1", "incarnation": "operator-quiz-1"}
BINDING = {"sources": [], "language": "ko", "timezone": "Asia/Seoul",
           "records": [{"source_id": "board", "kind": "board", "visibilities": ["public"]}]}
# A test that hangs on a read is killed after this long.
DEADLINE_SECONDS = 20


class Worker:
    def __init__(self, state: Path):
        self.process = subprocess.Popen([sys.executable, str(SERVER), "--state", str(state)],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True)
        self.watchdog = threading.Timer(DEADLINE_SECONDS, self.process.kill)
        self.watchdog.start()
        self.next_id = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "test", "version": "1"}})

    def rpc(self, method: str, params: dict) -> dict:
        self.next_id += 1
        assert self.process.stdin and self.process.stdout
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method,
                                             "params": params}) + "\n")
        self.process.stdin.flush()
        response = json.loads(self.process.stdout.readline())
        assert response["id"] == self.next_id, response
        return response

    def call(self, name: str, arguments: dict) -> dict:
        return self.rpc("tools/call", {"name": name, "arguments": arguments})["result"]

    def ok(self, name: str, arguments: dict) -> dict:
        result = self.call(name, arguments)
        assert result["isError"] is False, result
        return result["structuredContent"]

    def observe(self, binding=BINDING) -> dict:
        return self.ok("lane_observe", {"context": CONTEXT, "binding": binding, "sources": []})

    def act(self, request_id: str, action: dict) -> dict:
        return self.ok("lane_act", {"context": CONTEXT, "request_id": request_id, "action": action})

    def run_host(self, host: FakeHost) -> None:
        """The host cycle: list, deliver one ready result, list again."""
        for _ in range(100):
            ready = [(r, host.produce(r)) for r in self.ok("lane_host_requests", {})["requests"]]
            ready = [(r, result) for r, result in ready if result is not None]
            if not ready:
                return
            request, result = ready[0]
            assert self.ok("lane_host_result", {"request_id": request["request_id"], "result": result}) \
                == {"accepted": True}
        raise AssertionError("the worker kept listing new requests")

    def close(self) -> None:
        assert self.process.stdin
        self.process.stdin.close()
        self.process.wait()
        self.watchdog.cancel()
        assert self.process.stdout and self.process.stderr
        self.process.stdout.close()
        self.process.stderr.close()


class Listing(unittest.TestCase):
    def test_a_request_that_does_not_fit_with_the_ones_before_is_skipped_not_a_stop(self):
        sys.path.insert(0, str(SERVER.parent))
        import server
        with tempfile.TemporaryDirectory() as directory:
            worker = server.Worker(Path(directory), server.f.Prompts("author", "grade"), 1024)
            large = {"kind": "ask", "request_id": "ask-1", "questions": [{"prompt": "x" * 2048}]}
            small = {"kind": "read_records", "request_id": "read-1", "source_id": "board", "after": None}
            worker.flow.listing = lambda: [large, small]
            self.assertEqual(worker.host_requests({}), {"requests": [small]})


class WorkerCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.state = Path(self.temporary.name)
        self.host = FakeHost()
        # The worker opens a session at the wall-clock time and its first
        # session reads only what was made since then, so these posts are
        # made after it (#44537).
        later = int(time.time()) + 3600
        self.host.board = [post(later + 1, "the ledger records facts"), post(later + 2, "keepers choose their next step")]
        self.workers: list[Worker] = []

    def tearDown(self):
        for worker in self.workers:
            if worker.process.poll() is None:
                worker.close()
        self.temporary.cleanup()

    def start(self) -> Worker:
        worker = Worker(self.state)
        self.workers.append(worker)
        return worker

    def rows(self, output: dict, lane: str) -> list[dict]:
        for row in output["rows"]:
            self.assertEqual(set(row), ROW_FIELDS)
            self.assertIn(row["lane_id"], LANES)
        return [row for row in output["rows"] if row["lane_id"] == lane]

    def test_the_worker_advertises_its_four_tools_once_each(self):
        tools = [tool["name"] for tool in self.start().rpc("tools/list", {})["result"]["tools"]]
        self.assertEqual(sorted(tools), ["lane_act", "lane_host_requests", "lane_host_result", "lane_observe"])

    def test_a_compose_before_the_first_observation_fails_before_effect(self):
        worker = self.start()
        result = worker.act("act-1", {"kind": "compose", "questions": 1})
        self.assertEqual(result["status"], "failed_before_effect")
        self.assertEqual(worker.ok("lane_host_requests", {}), {"requests": []})

    def test_a_compose_without_a_count_or_a_binding_without_a_time_zone_is_refused(self):
        worker = self.start()
        refused = worker.call("lane_observe", {"context": CONTEXT, "binding": BINDING | {"timezone": "Mars/Base"},
                                               "sources": []})
        self.assertTrue(refused["isError"])
        worker.observe()
        self.assertEqual(worker.act("act-1", {"kind": "compose"})["status"], "failed_before_effect")
        self.assertEqual(worker.ok("lane_host_requests", {}), {"requests": []})

    def test_state_survives_a_worker_restart_on_the_same_volume(self):
        first = self.start()
        first.observe()
        composed = first.act("act-1", {"kind": "compose", "questions": 1})
        self.assertEqual(composed["status"], "confirmed")
        self.host.author = answering(first_quote)
        first.run_host(self.host)
        (ask,) = first.ok("lane_host_requests", {})["requests"]
        self.assertEqual(ask["kind"], "ask")
        first.close()

        second = self.start()
        second.observe()
        self.assertEqual(second.ok("lane_host_requests", {})["requests"], [ask])
        (question,) = ask["questions"]
        self.host.answers[ask["request_id"]] = {
            "status": "answered", "responder": {"surface": "dashboard", "actor_id": None, "display_name": None},
            "answered_at": 1_800_000_000.0,
            "answers": [{"question_id": question["question_id"],
                         "response": {"kind": "chose", "choice_ids": ["a"]}}]}
        second.run_host(self.host)
        output = second.observe()
        (reveal,) = self.rows(output, "quiz/questions")
        self.assertEqual((reveal["fields"]["verdict"], reveal["fields"]["key"]),
                         ("correct", {"kind": "choices", "choice_ids": ["a"]}))
        self.assertEqual(reveal["evidence"][0]["uri"], "lane-evidence:" + reveal["evidence"][0]["sha256"])
        (measures,) = self.rows(output, "quiz/measures")
        self.assertEqual(measures["fields"]["participation"], {"n": 1, "d": 1})
        (session,) = self.rows(output, "quiz/sessions")
        self.assertEqual(session["fields"]["state"], "answered")

    def test_a_written_answer_is_graded_through_the_worker(self):
        worker = self.start()
        worker.observe()
        worker.act("act-1", {"kind": "compose", "questions": 1})
        self.host.author = answering(first_quote)
        worker.run_host(self.host)
        (ask,) = worker.ok("lane_host_requests", {})["requests"]
        (question,) = ask["questions"]
        self.host.answers[ask["request_id"]] = {
            "status": "answered", "responder": {"surface": "dashboard", "actor_id": None, "display_name": None},
            "answered_at": 1_800_000_000.0,
            "answers": [{"question_id": question["question_id"], "response": {"kind": "wrote", "text": "facts"}}]}
        self.host.grade = lambda payload: {"status": "answered", "slot": "s", "output": {
            "verdict": "correct", "rationale": "names facts"}}
        worker.run_host(self.host)
        (reveal,) = self.rows(worker.observe(), "quiz/questions")
        self.assertEqual((reveal["fields"]["verdict"], reveal["fields"]["by"]), ("correct", "judgment"))
        self.assertEqual(worker.ok("lane_host_requests", {}), {"requests": []})

    def test_a_result_for_no_listed_request_is_not_accepted_and_a_malformed_one_is_an_error(self):
        worker = self.start()
        worker.observe()
        worker.act("act-1", {"kind": "compose", "questions": 1})
        self.assertEqual(worker.ok("lane_host_result", {"request_id": "elsewhere", "result": {"status": "x"}}),
                         {"accepted": False})
        (request,) = worker.ok("lane_host_requests", {})["requests"]
        broken = worker.call("lane_host_result", {"request_id": request["request_id"],
                                                  "result": {"status": "answered"}})
        self.assertTrue(broken["isError"])
        self.assertEqual(worker.ok("lane_host_requests", {})["requests"], [request])

    def test_no_key_is_published_before_the_answer(self):
        worker = self.start()
        worker.observe()
        worker.act("act-1", {"kind": "compose", "questions": 1})
        self.host.author = answering(first_quote)
        worker.run_host(self.host)
        output = worker.observe()
        self.assertEqual(self.rows(output, "quiz/questions"), [])
        published = json.dumps(output)
        self.assertNotIn('"key"', published)
        # first_quote cites the first eight bytes of the first post.
        self.assertNotIn("the ledg", published)
        self.assertNotIn("lane-evidence:", published)

    def test_export_returns_the_whole_log_as_a_retained_artifact(self):
        worker = self.start()
        worker.observe()
        worker.act("act-1", {"kind": "compose", "questions": 1})
        exported = worker.act("export-1", {"kind": "export"})
        data = (self.state / "operator-quiz" / "log.jsonl").read_bytes()
        self.assertEqual(exported["result"], {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
        (artifact,) = exported["output"]["artifacts"]
        self.assertEqual(base64.b64decode(artifact["data_base64"]), data)
        (measures,) = self.rows(exported["output"], "quiz/measures")
        self.assertEqual(measures["evidence"], [{"artifact_id": artifact["id"]}])

    def test_an_unreadable_log_refuses_a_compose(self):
        worker = self.start()
        worker.observe()
        worker.act("act-1", {"kind": "compose", "questions": 1})
        log = self.state / "operator-quiz" / "log.jsonl"
        log.write_bytes(log.read_bytes() + b"not json\n")
        refused = worker.act("act-2", {"kind": "compose", "questions": 1})
        self.assertEqual(refused["status"], "failed_before_effect")
        self.assertTrue(worker.call("lane_host_requests", {})["isError"])


if __name__ == "__main__":
    unittest.main()

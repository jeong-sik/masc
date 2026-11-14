"""The operator lesson against a fake host (RFC operator-lesson §7, L2): what
it lists, what it writes for each result, the rows, and the worker over
stdio."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from typing import Callable
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "operator-lesson"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # records.py

from test_operator_quiz_flow import FakeHost, exact_payload, post  # noqa: E402
import lesson_flow as f  # noqa: E402
import lesson_log as l  # noqa: E402
import lesson_projection as p  # noqa: E402

SERVER = Path(__file__).resolve().parents[1] / "operator-lesson" / "server.py"
BOARD = {"source_id": "board", "kind": "board", "visibilities": ["public"]}
BINDING = {"sources": [], "records": [BOARD], "language": "ko", "since": 0}
PROMPTS = f.Prompts(outline="outline prompt", scene="scene prompt")
CONTEXT = {"instance_id": "operator-lesson-1", "incarnation": "operator-lesson-1"}
LANES = {"lesson/scenes", "lesson/sessions", "lesson/measures"}
# A test that hangs on a read is killed after this long.
DEADLINE_SECONDS = 20


def cite(record: dict) -> dict:
    return {"kind": record["kind"], "source_id": record["source_id"], "pin": record["pin"]}


def entry(entry_id: str, *records: dict) -> dict:
    return {"entry_id": entry_id, "title": f"title of {entry_id}", "points": ["what changed"],
            "sources": [cite(record) for record in records]}


def one_entry_per_record(payload: dict) -> dict:
    entries = [entry(f"e{n}", record) for n, record in enumerate(payload["material"], start=1)]
    return {"status": "answered", "output": {"entries": entries}, "slot": "s"}


def quoting(payload: dict) -> dict:
    """A scene whose one paragraph quotes the start of each record it got."""
    sources = [cite(record) | {"quote": record["text"][:8]} for record in payload["material"]]
    return {"status": "answered", "slot": "s",
            "output": {"title": payload["title"], "paragraphs": [{"text": "what it says", "sources": sources}]}}


class Host(FakeHost):
    def __init__(self):
        super().__init__()
        # None leaves the request waiting, as a lane that has not answered does.
        self.outline: Callable[[dict], dict | None] = lambda payload: None
        self.scene: Callable[[dict], dict | None] = lambda payload: None
        self.clock = 100.0

    def produce(self, request: dict) -> dict | None:
        if request["kind"] == "exact_output":
            answer = self.outline if request["output"] == "outline" else self.scene
            return answer(exact_payload(request))
        return super().produce(request)

    def run(self, flow: f.Flow) -> None:
        """Delivers one result per listing until only waiting requests are left."""
        for _ in range(500):
            listing = flow.listing()
            self.listed.extend(listing)
            ready = [(request, result) for request in listing if (result := self.produce(request)) is not None]
            if not ready:
                return
            request, result = ready[0]
            self.clock += 1
            if not flow.deliver(request["request_id"], result, self.clock):
                raise AssertionError(f"{request['request_id']} was listed and then refused")
        raise AssertionError("the package kept listing new requests")


class Base(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.state = Path(self.temporary.name)
        self.flow = f.Flow(self.state, PROMPTS, lambda request: True)
        self.host = Host()
        self.host.board = [post(1, "the ledger records facts"), post(2, "keepers choose their next step"),
                           post(3, "an open question never expires")]

    def tearDown(self):
        self.temporary.cleanup()

    def compose(self, action="act-1", scenes=3, binding=BINDING):
        return self.flow.compose(action, scenes, binding, float(len(self.flow.sessions())))

    def session(self, session_id) -> l.Session:
        return next(s for s in self.flow.sessions() if s.session_id == session_id)

    def lesson(self, action="act-1", scenes=3) -> l.Session:
        """A whole lesson with a host that outlines and writes."""
        self.host.outline, self.host.scene = one_entry_per_record, quoting
        session_id = self.compose(action, scenes)
        self.host.run(self.flow)
        return self.session(session_id)


class Compose(Base):
    def test_a_lesson_reads_outlines_and_writes_each_scene(self):
        session = self.lesson()
        self.assertEqual(session.state, l.WRITTEN)
        self.assertEqual([scene.title for scene in session.written], ["title of e1", "title of e2", "title of e3"])
        source = session.written[0].paragraphs[0].sources[0]
        self.assertEqual((source.kind, source.pin, source.quote), ("board_post", "p-1", "the ledg"))
        kinds = [request["kind"] for request in self.host.listed]
        self.assertEqual(kinds.index("exact_output"), kinds.count("read_records"))

    def test_the_same_action_again_names_the_same_session_and_writes_nothing(self):
        first = self.compose()
        before = self.flow.log.read()
        self.assertEqual(self.compose(), first)
        self.assertEqual(self.flow.log.read(), before)

    def test_a_binding_without_since_is_refused(self):
        for binding in ({"records": [BOARD], "language": "ko"}, BINDING | {"since": True},
                        BINDING | {"since": "yesterday"}, BINDING | {"since": -1},
                        BINDING | {"since": float("inf")}, BINDING | {"since": 10 ** 400}):
            with self.assertRaises(f.InvalidBinding):
                self.compose(binding=binding)
        self.assertEqual(self.flow.sessions(), [])

    def test_a_request_body_is_on_disk_and_in_the_log_before_it_is_listed(self):
        session_id = self.compose()
        self.host.run(self.flow)
        (listed,) = self.flow.listing()
        self.assertEqual(listed["output"], "outline")
        (requested,) = self.session(session_id).requests
        self.assertEqual(requested.digest, f.digest(listed))
        self.assertEqual(self.flow.requests.read(requested.digest), listed)
        self.host.outline = one_entry_per_record
        self.host.run(self.flow)
        session = self.session(session_id)
        for request, body in zip(session.scene_requests, self.flow.listing()):
            self.assertEqual(request.digest, f.digest(body))
            self.assertTrue(self.flow.requests.path(request.digest).exists())

    def test_a_restarted_worker_lists_the_same_requests(self):
        self.host.outline = one_entry_per_record
        self.compose()
        self.host.run(self.flow)
        again = f.Flow(self.state, PROMPTS, lambda request: True)
        self.assertEqual(again.listing(), self.flow.listing())
        self.assertEqual(len(again.listing()), 3)

    def test_a_scene_request_carries_only_the_records_its_entry_cites(self):
        self.host.outline = one_entry_per_record
        self.compose()
        self.host.run(self.flow)
        for body in self.flow.listing():
            (record,) = exact_payload(body)["material"]
            self.assertEqual(exact_payload(body)["title"], f"title of e{record['pin'][2:]}")

    def test_a_workspace_with_nothing_new_fails_as_no_material(self):
        self.host.board = []
        session_id = self.compose()
        self.host.run(self.flow)
        self.assertEqual(self.session(session_id).failure, l.NoMaterial())


class Outline(Base):
    def outlined(self, *entries: Callable[[dict], dict], scenes=3) -> l.Session:
        self.host.outline = lambda payload: {"status": "answered", "slot": "s",
                                             "output": {"entries": [make(payload) for make in entries]}}
        session_id = self.compose(scenes=scenes)
        self.host.run(self.flow)
        return self.session(session_id)

    def test_an_entry_that_cites_a_record_not_read_is_dropped_alone(self):
        unread = {"kind": "board_post", "source_id": "board", "pin": "p-9"}
        session = self.outlined(lambda m: entry("e1", unread), lambda m: entry("e2", m["material"][0]))
        self.assertEqual([e.entry_id for e in session.entries], ["e2"])
        (rejected,) = session.rejected
        self.assertEqual((rejected.index, rejected.reason), (0, l.SourceNotRead(l.Cite("board_post", "board", "p-9"))))

    def test_a_repeated_id_an_entry_beyond_the_scenes_and_an_incomplete_one_are_dropped(self):
        session = self.outlined(lambda m: entry("e1", m["material"][0]), lambda m: entry("e1", m["material"][1]),
                                lambda m: entry("e2", m["material"][1]), lambda m: entry("e3", m["material"][2]),
                                lambda m: entry("e4", m["material"][2]) | {"points": []},
                                lambda m: entry("e5") | {"title": " "}, scenes=2)
        self.assertEqual([e.entry_id for e in session.entries], ["e1", "e2"])
        self.assertEqual([(r.index, r.reason) for r in session.rejected],
                         [(1, l.DuplicateEntryId()), (3, l.BeyondRequestedScenes()), (4, l.Incomplete()),
                          (5, l.Incomplete())])

    def test_an_entry_the_log_cannot_keep_is_dropped_alone(self):
        session = self.outlined(lambda m: entry("e1", m["material"][0]) | {"title": "\ud800"},
                                lambda m: entry("e2", m["material"][0]))
        self.assertEqual([e.entry_id for e in session.entries], ["e2"])
        self.assertIsInstance(session.rejected[0].reason, l.NotRecordable)

    def test_a_rejection_whose_cite_the_log_cannot_keep_is_still_written(self):
        unkeepable = {"kind": "board_post", "source_id": "board", "pin": "p-\ud800"}
        session = self.outlined(lambda m: entry("e1", unkeepable), lambda m: entry("e2", m["material"][0]))
        self.assertEqual([e.entry_id for e in session.entries], ["e2"])
        self.assertIsInstance(session.rejected[0].reason, l.NotRecordable)

        def scene(payload):
            written = quoting(payload)
            written["output"]["paragraphs"][0]["sources"] = [unkeepable | {"quote": "x"}]
            return written

        self.host.scene = scene
        self.host.run(self.flow)
        session = self.session(session.session_id)
        self.assertEqual(session.state, l.WRITTEN)
        self.assertIsInstance(session.rejected_scenes[0].reason, l.NotRecordable)

    def test_an_outline_with_no_entry_that_passes_fails_the_session(self):
        session = self.outlined(lambda m: entry("e1"))
        self.assertEqual((session.state, session.failure), (l.FAILED, l.NoEntryPassed()))
        self.assertEqual(self.flow.listing(), [])

    def test_an_output_of_another_shape_is_not_accepted(self):
        self.host.outline = lambda payload: {"status": "answered", "output": {"entries": [{"entry_id": "e1"}]}}
        self.compose()
        with self.assertRaises(f.InvalidResult):
            self.host.run(self.flow)

    def test_each_final_failure_of_the_outline_has_its_reason(self):
        cases = {"invalid_output": l.OutlineInvalidOutput, "output_limit_reached": l.OutlineInvalidOutput,
                 "outcome_unknown": l.OutlineOutcomeUnknown, "not_allowed": l.NotAllowed,
                 "request_id_reused": l.NotAllowed, "result_exceeds_frame": l.ResultExceedsFrame}
        for number, (status, failure) in enumerate(cases.items()):
            self.host.outline = lambda payload, status=status: {"status": status, "reason": "no slot"}
            session_id = self.compose(f"act-{number}")
            self.host.run(self.flow)
            self.assertIsInstance(self.session(session_id).failure, failure, status)

    def test_an_input_refusal_drops_earlier_lessons_then_halves_the_material(self):
        self.lesson("act-0")
        sent: list[dict] = []

        def refusing(payload):
            sent.append(payload)
            return {"status": "input_refused", "kind": "context_overflow"}

        self.host.board += [post(4, "a lane rests after a refusal"), post(5, "a cursor moves with an outline")]
        self.host.outline = refusing
        session_id = self.compose("act-1")
        self.host.run(self.flow)
        self.assertEqual([(len(s["earlier"]), len(s["material"])) for s in sent], [(3, 2), (0, 2), (0, 1)])
        self.assertEqual(self.session(session_id).failure,
                         l.OutlineInputRefused(f"{session_id}-outline-2", "context_overflow"))

    def test_a_request_too_large_for_the_frame_is_cut_before_it_is_listed(self):
        limit = 600
        self.flow.fits = lambda request: len(json.dumps(request)) <= limit
        session_id = self.compose()
        self.host.run(self.flow)
        (listed,) = self.flow.listing()
        self.assertLessEqual(len(json.dumps(listed)), limit)
        self.assertEqual([m["pin"] for m in exact_payload(listed)["material"]], ["p-3"])
        self.flow.fits = lambda request: False
        other = self.compose("act-2")
        self.host.run(self.flow)
        self.assertEqual(self.session(session_id).state, l.SUPERSEDED)
        self.assertEqual(self.session(other).failure, l.OutlineRequestExceedsFrame(f"{other}-outline-0"))


class Scenes(Base):
    def written(self, scene: Callable[[dict], dict | None]) -> l.Session:
        self.host.outline, self.host.scene = one_entry_per_record, scene
        session_id = self.compose()
        self.host.run(self.flow)
        return self.session(session_id)

    def test_a_quote_that_is_not_in_its_record_rejects_the_scene(self):
        def misquoting(payload):
            scene = quoting(payload)
            if payload["material"][0]["pin"] == "p-2":
                scene["output"]["paragraphs"][0]["sources"][0]["quote"] = "keepers chose"
            return scene

        session = self.written(misquoting)
        self.assertEqual(session.state, l.WRITTEN)
        self.assertEqual([scene.entry_id for scene in session.written], ["e1", "e3"])
        (rejected,) = session.rejected_scenes
        self.assertEqual(rejected.reason, l.QuoteNotInRecord(0, l.Cite("board_post", "board", "p-2")))

    def test_a_failed_scene_does_not_stop_the_others_and_is_not_asked_again(self):
        session = self.written(lambda payload: {"status": "invalid_output"} if payload["material"][0]["pin"] == "p-1"
                               else quoting(payload))
        self.assertEqual([scene.entry_id for scene in session.written], ["e2", "e3"])
        self.assertEqual([r.reason for r in session.rejected_scenes], [l.InvalidOutput()])
        self.assertEqual(self.flow.listing(), [])
        self.assertEqual(sum(1 for r in self.host.listed if r.get("output") == "scene"
                             and r["request_id"].endswith("-scene-1")), 1)

    def test_each_final_failure_of_a_scene_has_its_reason(self):
        cases = {"not_allowed": l.SceneNotAllowed("no slot"), "request_id_reused": l.SceneNotAllowed("request_id_reused"),
                 "input_refused": l.InputRefused("context_overflow"), "output_limit_reached": l.InvalidOutput(),
                 "outcome_unknown": l.OutcomeUnknown(), "result_exceeds_frame": l.SceneResultExceedsFrame()}
        for number, (status, reason) in enumerate(cases.items()):
            self.host.outline = one_entry_per_record
            self.host.scene = lambda payload, status=status: {"status": status, "reason": "no slot",
                                                              "kind": "context_overflow"}
            # Each lesson reads from where the last one stopped, so each needs a new record.
            self.host.board.append(post(10 + number, "a new record for this lesson"))
            session_id = self.compose(f"act-{number}", scenes=1)
            self.host.run(self.flow)
            session = self.session(session_id)
            self.assertEqual((session.state, [r.reason for r in session.rejected_scenes]), (l.WRITTEN, [reason]),
                             status)

    def test_a_source_outside_the_entry_a_bare_paragraph_and_a_blank_one_reject_the_scene(self):
        other = {"kind": "board_post", "source_id": "board", "pin": "p-3", "quote": "an open"}

        def scene(payload):
            written = quoting(payload)
            paragraph = written["output"]["paragraphs"][0]
            match payload["material"][0]["pin"]:
                case "p-1":
                    paragraph["sources"] = [other]
                case "p-2":
                    written["output"]["paragraphs"].append({"text": "and so on", "sources": []})
                case _:
                    paragraph["text"] = "  "
            return written

        session = self.written(scene)
        self.assertEqual([r.reason for r in session.rejected_scenes],
                         [l.SourceNotInEntry(0, l.Cite("board_post", "board", "p-3")), l.ParagraphWithoutSource(1),
                          l.Incomplete()])
        self.assertEqual(session.written, ())

    def test_a_scene_request_that_does_not_fit_the_frame_is_rejected_without_a_request(self):
        self.host.outline = one_entry_per_record
        session_id = self.compose()
        self.flow.fits = lambda request: request.get("output") != "scene"
        self.host.run(self.flow)
        session = self.session(session_id)
        self.assertEqual((session.state, session.scene_requests), (l.WRITTEN, ()))
        self.assertEqual({r.reason for r in session.rejected_scenes}, {l.RequestExceedsFrame()})


class Sessions(Base):
    def test_a_later_compose_supersedes_a_reading_session_and_leaves_a_writing_one(self):
        self.host.outline = one_entry_per_record
        writing = self.compose("act-1")
        self.host.run(self.flow)
        self.host.outline = lambda payload: None
        self.host.board.append(post(4, "a lane rests after a refusal"))
        reading = self.compose("act-2")
        self.host.run(self.flow)
        latest = self.compose("act-3")
        self.assertEqual([self.session(s).state for s in (writing, reading, latest)],
                         [l.WRITING, l.SUPERSEDED, l.READING])
        self.assertEqual(self.session(reading).superseded_by, latest)
        self.assertEqual(len([r for r in self.flow.listing() if r.get("output") == "scene"]), 3)
        self.host.scene = quoting
        self.host.run(self.flow)
        self.assertEqual(self.session(writing).state, l.WRITTEN)
        self.assertFalse(self.flow.deliver(f"{reading}-outline-0", {"status": "invalid_output"}, 1.0))

    def test_the_first_lesson_reads_from_since_and_the_next_from_the_last_outlined_cursor(self):
        first = self.compose("act-1", binding=BINDING | {"since": 2})
        self.host.run(self.flow)
        (request,) = self.flow.listing()
        self.assertEqual([m["pin"] for m in exact_payload(request)["material"]], ["p-2", "p-3"])
        firsts = [r for r in self.host.listed if r["kind"] == "read_records"]
        self.assertEqual((firsts[0]["after"], firsts[0]["since"]), (None, 2.0))
        # Superseded while reading: its material is read again.
        second = self.compose("act-2", binding=BINDING | {"since": 2})
        self.host.outline, self.host.scene = one_entry_per_record, quoting
        self.host.run(self.flow)
        self.assertEqual(self.session(first).state, l.SUPERSEDED)
        self.assertEqual([scene.entry_id for scene in self.session(second).written], ["e1", "e2"])
        self.host.board.append(post(4, "a lane rests after a refusal"))
        self.host.listed.clear()
        third = self.compose("act-3", binding=BINDING | {"since": 2})
        self.host.run(self.flow)
        reads = [r for r in self.host.listed if r["kind"] == "read_records"]
        self.assertEqual((reads[0]["after"], "since" in reads[0]), ("000002", False))
        self.assertEqual([e.sources[0].pin for e in self.session(third).entries], ["p-4"])

    def test_a_refused_read_fails_the_session_with_the_hosts_reason(self):
        session_id = self.compose()
        (request,) = self.flow.listing()
        self.assertTrue(self.flow.deliver(request["request_id"], {"status": "not_allowed", "reason": "no grant"}, 1.0))
        self.assertEqual(self.session(session_id).failure, l.NotAllowed(request["request_id"], "no grant"))

    def test_an_unreadable_log_refuses_every_write(self):
        self.compose()
        with open(self.flow.log.path, "ab") as handle:
            handle.write(b'{"event":"scene_graded"}\n')
        fresh = f.Flow(self.state, PROMPTS, lambda request: True)
        for attempt in (lambda: fresh.compose("act-2", 1, BINDING, 5.0), fresh.listing,
                        lambda: fresh.deliver("x", {"status": "records"}, 1.0)):
            with self.assertRaises(l.LogError):
                attempt()

    def test_history_that_contradicts_itself_is_an_error(self):
        grants = (l.Grant("board", "board", ()),)
        opened = l.SessionOpened("s-1", "act-1", 1, grants, "ko", 0.0, 1.0)
        requested = l.OutlineRequested("s-1", "s-1-outline-0", "ab")
        outlined = l.Outlined("s-1", "s-1-outline-0", (l.Entry("e1", "t", ("p",), (l.Cite("board_post", "board", "p-1"),)),))
        asked = l.SceneRequested("s-1", "e1", "s-1-scene-1", "cd")
        rejected = l.SceneRejected("s-1", "e1", "s-1-scene-1", l.InvalidOutput())
        for history in ([requested], [opened, opened], [opened, outlined], [opened, requested, outlined, requested],
                        [opened, requested, outlined, asked, asked], [opened, requested, outlined, rejected],
                        [opened, requested, outlined, asked, rejected, rejected],
                        [opened, requested, outlined, l.SessionFailed("s-1", l.NoMaterial())]):
            with self.assertRaises(l.LogError):
                l.fold(history)

    def test_every_event_reads_back_as_written(self):
        session = self.lesson()
        events = self.flow.log.read()
        self.assertEqual([l.event_of_json(json.loads(json.dumps(l.event_to_json(e)))) for e in events], events)
        self.assertEqual({type(e) for e in events}, {l.SessionOpened, l.MaterialRead, l.OutlineRequested, l.Outlined,
                                                     l.SceneRequested, l.SceneWritten})
        with self.assertRaises(l.LogError):
            l.event_of_json(l.event_to_json(session.written[0]) | {"grade": 1})


class Rows(Base):
    def test_rows_show_each_scene_each_session_and_the_counts(self):
        self.host.outline = lambda payload: {"status": "answered", "slot": "s", "output": {"entries": [
            entry("e1", payload["material"][0]), entry("e2", payload["material"][1]), entry("e3")]}}
        self.host.scene = lambda payload: quoting(payload) if payload["material"][0]["pin"] == "p-1" \
            else {"status": "outcome_unknown"}
        session_id = self.compose()
        self.host.run(self.flow)
        output = p.observation(self.flow.sessions(), 999.0)
        rows = {row["lane_id"]: row for row in output["rows"]}
        self.assertEqual(set(rows), LANES)
        self.assertEqual(output["rows"][0]["lane_id"], p.SCENES)
        scene = rows[p.SCENES]
        self.assertEqual((scene["fields"]["body"], scene["fields"]["sources"][0]["quote"]), ("what it says", "the ledg"))
        self.assertEqual(scene["evidence"][0]["sha256"], scene["fields"]["sources"][0]["sha256"])
        fields = rows[p.SESSIONS]["fields"]
        self.assertEqual((fields["session_id"], fields["state"]), (session_id, l.WRITTEN))
        self.assertEqual(fields["scenes"], {"requested": 3, "outlined": 2, "written": 1, "rejected": 1, "waiting": 0})
        self.assertEqual(rows[p.MEASURES]["fields"],
                         {"sessions": {"reading": 0, "writing": 0, "written": 1, "failed": 0, "superseded": 0},
                          "scenes_written": 1, "rejected_entries": {"incomplete": 1},
                          "rejected_scenes": {"outcome_unknown": 1}, "failed_sessions": {}})
        self.assertEqual(p.observation(self.flow.sessions(), 5.0), output)


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

    def run_host(self, host: Host) -> None:
        """The host cycle: list, deliver one ready result, list again."""
        for _ in range(100):
            ready = [(r, result) for r in self.ok("lane_host_requests", {})["requests"]
                     if (result := host.produce(r)) is not None]
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


class WorkerCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.state = Path(self.temporary.name)
        self.host = Host()
        self.host.board = [post(1, "the ledger records facts"), post(2, "keepers choose their next step")]
        self.host.outline, self.host.scene = one_entry_per_record, quoting
        self.workers: list[Worker] = []

    def tearDown(self):
        for worker in self.workers:
            worker.close()
        self.temporary.cleanup()

    def worker(self) -> Worker:
        self.workers.append(Worker(self.state))
        return self.workers[-1]

    def test_a_compose_before_the_first_observation_or_without_scenes_fails_before_effect(self):
        worker = self.worker()
        early = worker.act("act-1", {"kind": "compose", "scenes": 2})
        self.assertEqual(early["status"], "failed_before_effect")
        worker.observe()
        for action in ({"kind": "compose"}, {"kind": "compose", "scenes": 0}, {"kind": "compose", "scenes": True},
                       {"kind": "grade"}, {"kind": "export", "scenes": 1}):
            self.assertEqual(worker.act("act-2", action)["status"], "failed_before_effect", action)
        self.assertEqual(worker.ok("lane_host_requests", {}), {"requests": []})

    def test_a_binding_without_since_is_not_observed(self):
        result = self.worker().call("lane_observe", {"context": CONTEXT, "sources": [],
                                                     "binding": {k: v for k, v in BINDING.items() if k != "since"}})
        self.assertTrue(result["isError"])

    def test_a_lesson_over_stdio_survives_a_restart_and_exports_its_log(self):
        worker = self.worker()
        worker.observe()
        confirmed = worker.act("act-1", {"kind": "compose", "scenes": 2})
        self.assertEqual(confirmed["status"], "confirmed")
        self.host.scene = lambda payload: None
        worker.run_host(self.host)
        waiting = worker.ok("lane_host_requests", {})["requests"]
        self.assertEqual([r["output"] for r in waiting], ["scene", "scene"])
        restarted = self.worker()
        restarted.observe()
        self.assertEqual(restarted.ok("lane_host_requests", {})["requests"], waiting)
        self.host.scene = quoting
        restarted.run_host(self.host)
        output = restarted.observe()
        self.assertEqual({row["lane_id"] for row in output["rows"]}, LANES)
        self.assertEqual([row["title"] for row in output["rows"] if row["lane_id"] == "lesson/scenes"],
                         ["title of e1", "title of e2"])
        exported = restarted.act("act-2", {"kind": "export"})
        (artifact,) = exported["output"]["artifacts"]
        self.assertEqual(exported["result"]["bytes"], (self.state / "operator-lesson" / "log.jsonl").stat().st_size)
        self.assertEqual(artifact["id"], "log")


if __name__ == "__main__":
    unittest.main()

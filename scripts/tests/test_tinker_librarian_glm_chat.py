# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for scripts/tinker/librarian/glm_chat.py and the GLM lane of eval_admission.py.

The endpoint is a fake `post` that returns invented bodies, so nothing is sent.
`glm_chat` writes the Tinker caller's rows, and that module imports openai, so
this file runs with `uv run`.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import eval_admission as V
import glm_chat as G
import synth_rows as RW
import synth_spec as S
from tinker_oai import NO_RESPONSE, RETRY_PAUSE_S, TRANSIENT_RETRIES, call_from_row

from tinker_librarian_synth_fixtures import PLANTED, candidates_of, label_answer, request

type Response = tuple[int, str] | None


def error_body(code: object, message: str = "m") -> str:
    return json.dumps({"error": {"code": code, "message": message}})


def completion(content: str) -> str:
    return json.dumps({"choices": [{"finish_reason": "stop",
                                    "message": {"content": content, "reasoning_content": "생각"}}],
                       "usage": {"prompt_tokens": 10, "completion_tokens": 3,
                                 "prompt_tokens_details": {"cached_tokens": 4}}})


class Endpoint:
    """A fake post: it answers from a list of responses and keeps every body it is given."""

    def __init__(self, *responses: Response) -> None:
        self.responses = list(responses)
        self.bodies: list[bytes] = []

    def __call__(self, body: bytes) -> Response:
        self.bodies.append(body)
        return self.responses.pop(0)


class Pauses:
    def __init__(self) -> None:
        self.seconds: list[float] = []

    def __call__(self, seconds: float) -> None:
        self.seconds.append(seconds)


def logged(log: Path) -> list[dict[str, object]]:
    return [cast(dict[str, object], json.loads(line)) for line in log.read_text(encoding="utf-8").splitlines()]


class RequestTest(unittest.TestCase):
    def test_the_body_holds_what_masc_sends_a_glm_slot_and_nothing_else(self) -> None:
        self.assertEqual(json.loads(G.request_body("glm-x", ["프롬프트", "스키마"])),
                         {"response_format": {"type": "json_object"}, "thinking": {"type": "enabled"},
                          "model": "glm-x", "messages": [{"role": "user", "content": "프롬프트"},
                                                         {"role": "user", "content": "스키마"}]})

    def test_the_key_follows_the_model_and_the_messages(self) -> None:
        key = G.call_key(G.request_body("glm-x", ["a", "b"]))
        self.assertEqual(G.call_key(G.request_body("glm-x", ["a", "b"])), key)
        self.assertNotEqual(G.call_key(G.request_body("glm-y", ["a", "b"])), key)
        self.assertNotEqual(G.call_key(G.request_body("glm-x", ["a", "c"])), key)


class ReplyTest(unittest.TestCase):
    def test_a_spent_usage_window_under_a_429_stops_where_the_status_alone_retries(self) -> None:
        message = "Usage limit reached for 5 hour. Your limit will reset at 2026-11-09 20:00:00"
        self.assertEqual(G.read_reply((429, error_body("1308", message))), G.Stop(f"GLM 1308: {message}"))
        self.assertEqual(G.read_reply((429, "")), G.Transient(None))

    def test_each_code_class_leads_to_its_reply(self) -> None:
        expected = {G.Stop: ("1001", "1220", "1113", "1309", "1310", "1316", "1321"),
                    G.Transient: ("1302", "1305", "1312", "1230", "1234", "500"),
                    G.Failed: ("1261", "1200", "1214", "1301", "1315", "9999")}
        for kind, codes in expected.items():
            for code in codes:
                with self.subTest(code=code):
                    self.assertEqual(G.read_reply((400, error_body(code))), kind(f"GLM {code}: m"))

    def test_an_error_in_a_200_body_is_read_and_so_is_an_integer_code(self) -> None:
        self.assertEqual(G.read_reply((200, error_body(1305))), G.Transient("GLM 1305: m"))
        self.assertEqual(G.read_reply((200, error_body(1308))), G.Stop("GLM 1308: m"))

    def test_a_null_or_empty_error_is_no_error(self) -> None:
        bodies: tuple[dict[str, object], ...] = ({"error": None, "choices": []}, {"error": {}, "choices": []})
        for body in bodies:
            with self.subTest(body=body):
                self.assertEqual(G.read_reply((200, json.dumps(body))), G.Answered(body))

    def test_an_error_without_a_code_is_an_invalid_request_named_by_its_json(self) -> None:
        self.assertEqual(G.read_reply((200, json.dumps({"error": {"type": "x"}}))), G.Failed('GLM: {"type":"x"}'))
        self.assertEqual(G.read_reply((429, json.dumps({"error": {"code": True, "message": "b"}}))),
                         G.Failed("GLM: b"))
        self.assertEqual(G.read_reply((429, json.dumps({"error": "busy"}))), G.Failed('GLM: "busy"'))

    def test_without_a_code_the_status_decides(self) -> None:
        self.assertEqual(G.read_reply(None), G.Transient(None))
        self.assertEqual(G.read_reply((503, "<html>bad gateway</html>")), G.Transient(None))
        self.assertEqual(G.read_reply((408, "")), G.Transient(None))
        self.assertEqual(G.read_reply((404, "")), G.Failed(None))
        for body in ("not json", "[]"):
            with self.subTest(body=body):
                self.assertEqual(G.read_reply((200, body)), G.Failed("the HTTP 200 body is not a JSON object"))


class CallerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.log = Path(self.tmp.name) / "calls.jsonl"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def caller(self, endpoint: Endpoint, max_calls: int = 10, pauses: Pauses | None = None) -> G.Caller:
        return G.Caller(self.log, max_calls, endpoint, pauses if pauses is not None else Pauses())

    def test_a_reply_is_logged_and_asked_again_without_sending(self) -> None:
        endpoint = Endpoint((200, completion("{}")))
        caller = self.caller(endpoint)
        call = caller.ask(model="glm-x", label="synth:glm:i1", messages=["a", "b"])
        assert call is not None
        self.assertEqual((call.status, call.finish, call.content, call.reasoning, call.error),
                         (200, "stop", "{}", "생각", None))
        self.assertEqual((call.prompt_tokens, call.cached_tokens, call.completion_tokens), (10, 4, 3))
        self.assertEqual(call.answer(), "{}")
        self.assertIs(caller.ask(model="glm-x", label="synth:glm:i1", messages=["a", "b"]), call)
        self.assertEqual(len(endpoint.bodies), 1)
        self.assertEqual([call_from_row(r) for r in logged(self.log)], [call])

    def test_a_quota_failure_stops_the_caller_with_glms_message(self) -> None:
        endpoint = Endpoint((429, error_body("1308", "reset at 20:00")))
        caller = self.caller(endpoint)
        self.assertIsNone(caller.ask(model="glm-x", label="l1", messages=["a"]))
        self.assertEqual(caller.stopped, "GLM 1308: reset at 20:00")
        self.assertIsNone(caller.ask(model="glm-x", label="l2", messages=["b"]))
        self.assertEqual(len(endpoint.bodies), 1)
        [row] = logged(self.log)
        self.assertEqual((row["status"], row["error"], row["content"]), (429, "GLM 1308: reset at 20:00", None))

    def test_a_rate_limit_is_sent_again_after_a_pause(self) -> None:
        pauses = Pauses()
        caller = self.caller(Endpoint((429, error_body("1302")), (200, completion("{}"))), pauses=pauses)
        call = caller.ask(model="glm-x", label="l", messages=["a"])
        assert call is not None
        self.assertEqual(call.answer(), "{}")
        self.assertEqual(pauses.seconds, [RETRY_PAUSE_S])
        self.assertEqual([r["status"] for r in logged(self.log)], [429, 200])

    def test_an_error_stated_in_a_200_body_is_not_kept_as_a_reply(self) -> None:
        call = self.caller(Endpoint((200, error_body(1305)), (200, completion("{}")))).ask(
            model="glm-x", label="l", messages=["a"])
        assert call is not None
        self.assertEqual(call.answer(), "{}")
        self.assertEqual([(r["status"], r["error"]) for r in logged(self.log)], [(200, "GLM 1305: m"), (200, None)])

    def test_no_response_is_sent_again(self) -> None:
        call = self.caller(Endpoint(None, (200, completion("{}")))).ask(model="glm-x", label="l", messages=["a"])
        assert call is not None
        self.assertEqual(call.answer(), "{}")
        self.assertEqual([r["status"] for r in logged(self.log)], [NO_RESPONSE, 200])

    def test_a_transient_failure_that_stays_is_the_calls_result(self) -> None:
        pauses = Pauses()
        endpoint = Endpoint(*[(429, error_body("1305", "busy"))] * (TRANSIENT_RETRIES + 1))
        caller = self.caller(endpoint, pauses=pauses)
        call = caller.ask(model="glm-x", label="l", messages=["a"])
        assert call is not None
        self.assertEqual((call.status, call.error, call.answer()), (429, "GLM 1305: busy", None))
        self.assertEqual(pauses.seconds, [RETRY_PAUSE_S * n for n in range(1, TRANSIENT_RETRIES + 1)])
        self.assertEqual(len(endpoint.bodies), TRANSIENT_RETRIES + 1)
        self.assertIsNone(caller.stopped)

    def test_a_failed_call_is_its_result_and_a_rerun_sends_it_again(self) -> None:
        first = self.caller(Endpoint((400, error_body("1261", "Prompt exceeds max length"))))
        failed = first.ask(model="glm-x", label="l", messages=["a"])
        assert failed is not None
        self.assertEqual((failed.status, failed.error), (400, "GLM 1261: Prompt exceeds max length"))
        self.assertIsNone(first.stopped)
        again = Endpoint((200, completion("{}")))
        call = self.caller(again).ask(model="glm-x", label="l", messages=["a"])
        assert call is not None
        self.assertEqual((call.answer(), len(again.bodies)), ("{}", 1))

    def test_the_cap_counts_the_logged_requests_and_stops_before_sending(self) -> None:
        self.caller(Endpoint((500, ""), (200, completion("{}")))).ask(model="glm-x", label="a", messages=["a"])
        endpoint = Endpoint((200, completion("{}")))
        caller = self.caller(endpoint, max_calls=3)
        self.assertEqual(caller.sent, 2)
        self.assertIsNotNone(caller.ask(model="glm-x", label="a", messages=["a"]))
        self.assertIsNotNone(caller.ask(model="glm-x", label="b", messages=["b"]))
        self.assertIsNone(caller.ask(model="glm-x", label="c", messages=["c"]))
        self.assertEqual(caller.stopped, "3 requests were sent under this log, the cap is 3")
        self.assertEqual(len(endpoint.bodies), 1)


class LaneTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        folder = Path(self.tmp.name)
        self.req = request(PLANTED, candidates_of((S.CandidateKind.CORRECTION, S.CandidateKind.TRANSIENT)))
        requests = folder / "requests.jsonl"
        requests.write_text(json.dumps({"request": RW.row_of(self.req)}, ensure_ascii=False) + "\n",
                            encoding="utf-8")
        [self.item] = V.synth_items(requests)
        self.log = folder / "calls.jsonl"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def rows(self, *responses: Response) -> tuple[list[dict[str, object]], Endpoint]:
        endpoint = Endpoint(*responses)
        lane = V.GlmLane(G.Caller(self.log, 10, endpoint, Pauses()))
        return V.run_item(lane, [("g1", "glm-a"), ("g2", "glm-b")], self.item), endpoint

    def test_a_glm_run_sends_each_target_its_measured_call_and_no_warm_call(self) -> None:
        answer = label_answer(self.req)
        rows, endpoint = self.rows((200, completion(answer)), (200, completion(answer)))
        self.assertEqual([json.loads(b)["model"] for b in endpoint.bodies], ["glm-a", "glm-b"])
        self.assertEqual({tuple(m["content"] for m in json.loads(b)["messages"]) for b in endpoint.bodies},
                         {(self.item.text, V.schema_instruction())})
        self.assertEqual([(r["target"], r["valid"], r["cost_usd"], r["error"]) for r in rows],
                         [("g1", True, 0.0, None), ("g2", True, 0.0, None)])
        self.assertEqual(rows[0]["state_correct"], rows[0]["candidates"])

    def test_a_row_names_glms_error(self) -> None:
        rows, _ = self.rows((400, error_body("1261", "Prompt exceeds max length")), (200, completion("{}")))
        self.assertEqual((rows[0]["status"], rows[0]["error"], rows[0]["valid"], rows[0]["problems"]),
                         (400, "GLM 1261: Prompt exceeds max length", False, ["no_answer"]))

    def test_a_stopped_lane_leaves_the_rest_of_the_item_unanswered(self) -> None:
        rows, endpoint = self.rows((200, completion("{}")), (429, error_body("1310", "weekly")))
        self.assertEqual([r["target"] for r in rows], ["g1"])
        self.assertEqual(len(endpoint.bodies), 2)

    def test_each_provider_takes_its_own_limit(self) -> None:
        for provider, budget, max_calls in (("glm", 1.0, None), ("tinker", None, 5), ("glm", 1.0, 5),
                                            ("tinker", None, None)):
            with self.subTest(provider=provider, budget=budget, max_calls=max_calls):
                args = argparse.Namespace(provider=provider, budget=budget, max_calls=max_calls)
                with self.assertRaises(SystemExit):
                    V.lane_of(args, self.log, {})


if __name__ == "__main__":
    unittest.main()

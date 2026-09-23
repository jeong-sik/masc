"""Grade answers to quiz questions against the record, never against the answerer.

This worker does not write questions. It reads the questioner's latest output
(`lane_output`) and, separately, the same fact deck (`snapshot_file`). An answer
arrives as a `lane_act` request; the grade is the comparison of the chosen text
with the `answer` of the fact the question was asked from, in the same deck
incarnation. The grade row carries the record, so a wrong answer leads straight
to the original.

State lives only in this worker incarnation. Retained action receipts and
outputs are the host's durable record; nothing here is replayed after restart.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from protocol import (InvalidInput, OUTPUT_SCHEMA, evidence, object_value, optional_string,
                      sources_from_json, stable_id, string)

TEXT = {"type": "string", "minLength": 1}
# Fields whose answer names a person; an answerer who is that person is answering about themself.
SELF_FIELDS = frozenset({"author", "claimant"})
CONTEXT_SCHEMA = {"type": "object", "additionalProperties": False,
                  "required": ["instance_id", "incarnation"],
                  "properties": {"instance_id": TEXT, "incarnation": TEXT}}
ANSWER_SCHEMA = {"type": "object", "additionalProperties": False,
                 "required": ["kind", "question_id", "choice"],
                 "properties": {"kind": {"type": "string", "const": "answer"},
                                "question_id": TEXT, "choice": TEXT,
                                "answerer": {"type": "string", "minLength": 1,
                                             "description": "Claimed label; the host keeps the authenticated requester"}}}
ACTION_SCHEMA = {"type": "object", "additionalProperties": False,
                 "required": ["context", "request_id", "action"],
                 "properties": {"context": CONTEXT_SCHEMA, "request_id": TEXT, "action": ANSWER_SCHEMA}}
OBSERVE_SCHEMA = {"type": "object", "additionalProperties": False,
                  "required": ["context", "binding", "sources"],
                  "properties": {"context": CONTEXT_SCHEMA, "binding": {"type": "object"},
                                 "sources": {"type": "array", "items": {"type": "object"}}}}


def exact(value, keys, label, optional=()):
    value = object_value(value, label)
    extra = set(value) - set(keys) - set(optional)
    missing = set(keys) - set(value)
    if extra or missing:
        raise InvalidInput(f"{label} fields must be exactly {sorted(keys)}"
                           + (f" (+ optional {sorted(optional)})" if optional else ""))
    return value


class Grader:
    def __init__(self):
        self.context = None
        self.questions: dict[str, dict] = {}
        self.deck: dict[str, dict] = {}
        self.deck_incarnation = None
        self.coverage: list[dict] = []
        self.grades: list[dict] = []
        self.results: dict[str, dict] = {}

    def bind(self, raw):
        context = exact(raw, ["instance_id", "incarnation"], "context")
        for key in context:
            string(context[key], f"context.{key}")
        if self.context is not None and self.context != context:
            raise InvalidInput("request targets a different worker incarnation")
        self.context = context

    def output(self):
        answered = len(self.grades)
        correct = sum(row["fields"]["correct"] for row in self.grades)
        others = [row for row in self.grades if not row["fields"]["about_answerer"]]
        score = {"id": stable_id(self.context["incarnation"] if self.context else "unbound", "score"),
                 "lane_id": "quiz/score", "kind": "value",
                 "title": f"맞힌 문제 {correct} / 푼 문제 {answered}",
                 "observed_at": self.grades[-1]["observed_at"] if self.grades else time.time(),
                 "subject_id": "quiz/score", "clock": None, "actor": None,
                 "fields": {"answered": answered, "correct": correct,
                            "excluding_about_answerer": {
                                "answered": len(others),
                                "correct": sum(row["fields"]["correct"] for row in others)},
                            "by_answerer": self.by_answerer(),
                            "scope": "this grader incarnation"},
                 "evidence": [], "related_ids": [row["id"] for row in self.grades]}
        return {"rows": [*self.grades, score], "coverage": self.coverage}

    def by_answerer(self):
        table: dict[str, dict] = {}
        for row in self.grades:
            name = row["fields"]["answerer_claimed"] or "(unnamed)"
            entry = table.setdefault(name, {"answered": 0, "correct": 0, "about_self": 0})
            entry["answered"] += 1
            entry["correct"] += int(row["fields"]["correct"])
            entry["about_self"] += int(row["fields"]["about_answerer"])
        return table

    def observe(self, args):
        args = exact(args, ["context", "binding", "sources"], "observe arguments")
        self.bind(args["context"])
        object_value(args["binding"], "binding")
        questions, deck, deck_incarnation, coverage = {}, {}, None, []
        for source in sources_from_json(args["sources"]):
            skipped, seen = set(), 0
            for item in source.observations:
                kind = item.get("kind")
                if kind == "lane_output":
                    for upstream in object_value(item.get("output"), "output").get("rows", []):
                        fields = upstream.get("fields", {})
                        if "question_id" in fields and "choices" in fields:
                            questions[fields["question_id"]] = upstream
                            seen += 1
                elif kind == "fact":
                    record, = evidence([object_value(item.get("record"), "fact.record")])
                    deck[string(item.get("id"), "fact.id")] = {
                        "field": string(item.get("field"), "fact.field"),
                        "answer": string(item.get("answer"), "fact.answer"), "record": record}
                    deck_incarnation = source.incarnation
                    seen += 1
                else:
                    skipped.add(str(kind))
            status = source.coverage(skipped)
            status["complete"] = source.complete and not skipped and seen > 0
            coverage.append(status)
        self.questions, self.deck, self.deck_incarnation = questions, deck, deck_incarnation
        self.coverage = coverage
        return self.output()

    def refuse(self, request_id, reason):
        return {"status": "failed_before_effect",
                "result": {"reason": reason, "request_id": request_id}, "output": self.output()}

    def act(self, args):
        try:
            args = exact(args, ["context", "request_id", "action"], "action arguments")
            self.bind(args["context"])
            request_id = string(args["request_id"], "request_id")
            action = exact(args["action"], ["kind", "question_id", "choice"], "action",
                           optional=["answerer"])
        except InvalidInput as error:
            return self.refuse(None, str(error))
        if request_id in self.results:
            return self.results[request_id]
        if action["kind"] != "answer":
            return self.refuse(request_id, "only kind=answer is supported")
        question = self.questions.get(action["question_id"])
        if question is None:
            return self.refuse(request_id, "question_id is not in the latest observed questions")
        if action["choice"] not in question["fields"]["choices"]:
            return self.refuse(request_id, "choice is not one of the question's choices")
        fact_id = question["fields"].get("source_event_id") or question["subject_id"]
        fact = self.deck.get(fact_id)
        if fact is None:
            return self.refuse(request_id, "the question's fact is not in this grader's deck")
        if question["fields"].get("incarnation") != self.deck_incarnation:
            return self.refuse(request_id, "the deck changed since the question was asked")
        if fact["field"] != question["fields"].get("field"):
            return self.refuse(request_id, "the deck fact no longer has the question's field")
        answerer = optional_string(action.get("answerer"), "answerer")
        # One graded attempt per (question, claimed answerer). A new request_id is
        # not a second chance; the first grade stands. The label is self-claimed,
        # so this limits honest retries and score inflation, not a determined liar.
        first = next((row for row in self.grades
                      if row["subject_id"] == action["question_id"]
                      and row["fields"]["answerer_claimed"] == answerer), None)
        if first is not None:
            return self.refuse(request_id, f"already answered by {answerer or 'an unnamed answerer'}; "
                                           f"the first grade {first['id']} stands")
        correct = action["choice"] == fact["answer"]
        # The answerer is the person the question is about (code-reviewer c-70d137e0):
        # they can answer from memory without re-reading, which is not what the quiz
        # measures. Graded as usual, counted apart in the score.
        about_answerer = (answerer is not None and fact["field"] in SELF_FIELDS
                          and answerer == fact["answer"])
        grade = {"id": stable_id(self.context["incarnation"], "grade", request_id),
                 "lane_id": "quiz/grades", "kind": "event",
                 "title": ("정답 ✓ — " if correct else "오답 ✗ — ") + question["title"],
                 "observed_at": time.time(), "subject_id": action["question_id"],
                 "clock": None, "actor": answerer,
                 "fields": {"question_id": action["question_id"], "choice": action["choice"],
                            "correct": correct, "answer": fact["answer"], "fact_id": fact_id,
                            "deck_incarnation": self.deck_incarnation,
                            "answerer_claimed": answerer, "about_answerer": about_answerer,
                            "request_id": request_id},
                 "evidence": [fact["record"]], "related_ids": [question["id"]]}
        self.grades.append(grade)
        result = {"status": "confirmed",
                  "result": {"checked": f"choice compared with the answer of fact {fact_id} "
                                        f"in deck incarnation {self.deck_incarnation}",
                             "correct": correct, "question_id": action["question_id"],
                             "request_id": request_id},
                  "output": self.output()}
        self.results[request_id] = result
        return result


def main():
    grader = Grader()
    tools = [
        {"name": "lane_observe", "description": "Read the latest questions and the fact deck; report grades so far.",
         "inputSchema": OBSERVE_SCHEMA, "outputSchema": OUTPUT_SCHEMA,
         "annotations": {"readOnlyHint": True, "destructiveHint": False,
                         "idempotentHint": True, "openWorldHint": False}},
        {"name": "lane_act", "description": "Grade one answer against the record the question was asked from.",
         "inputSchema": ACTION_SCHEMA,
         "annotations": {"readOnlyHint": False, "destructiveHint": False,
                         "idempotentHint": True, "openWorldHint": False}}]
    for line in sys.stdin:
        request_id = None
        try:
            request = object_value(json.loads(line), "request")
            request_id = request.get("id")
            if "id" not in request:
                continue
            method, params = request.get("method"), object_value(request.get("params", {}), "params")
            if method == "initialize":
                result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                          "serverInfo": {"name": "masc-quiz-grader", "version": "0.1.0"}}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": tools}
            elif method == "tools/call":
                name, arguments = params.get("name"), params.get("arguments")
                try:
                    if name == "lane_observe":
                        output = grader.observe(arguments)
                    elif name == "lane_act":
                        output = grader.act(arguments)
                    else:
                        raise InvalidInput("unknown tool")
                    result = {"content": [{"type": "text", "text": json.dumps(output, ensure_ascii=False)}],
                              "structuredContent": output, "isError": False}
                except InvalidInput as error:
                    result = {"content": [{"type": "text", "text": str(error)}], "isError": True}
            else:
                print(json.dumps({"jsonrpc": "2.0", "id": request_id,
                                  "error": {"code": -32601, "message": "Method not found"}}), flush=True)
                continue
            response = {"jsonrpc": "2.0", "id": request_id, "result": result}
        except json.JSONDecodeError:
            response = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
        except InvalidInput as error:
            response = {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": str(error)}}
        print(json.dumps(response, ensure_ascii=False, allow_nan=False), flush=True)


if __name__ == "__main__":
    main()

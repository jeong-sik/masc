# pyright: strict
"""Capped, cached chat calls to Z.AI's GLM coding endpoint, in the request MASC's GLM slot sends.

`request_body` holds what MASC's exact admission output sends a glm-coding slot
(packages/agent_core/lib/llm_provider: exact_output_ready_admission.ml
`exact_config`, backend_openai_request.ml, reasoning_dialect.ml
`request_control_fields`): the model, the user messages in order, thinking
enabled, a `json_object` response format and `max_tokens`. GLM's wire takes no
schema, so the schema instruction rides as the last user message, as in MASC.
MASC copies the exact lane's `max_output_tokens` to every slot as `max_tokens`
(runtime_exact_output_registry.ml) and leaves the field out only when the lane
declares none; the caller passes the value the lane holds after rollout.
`exact_config` clears the sampling fields and keeps the slot's effort, and the
GLM slot declares none, so the body carries no reasoning_effort, sampling field
or stream flag.

GLM names a failure by a code in the body, {"error": {"code", "message"}}, also
under an HTTP 429: a spent usage window (1308) arrives as a 429 that the status
alone reads as a rate limit. `read_reply` reads the code as MASC does
(backend_glm.ml `check_glm_error_json` and `classify_glm_error`). Under another
status than 200, only the quota and context-overflow classes take the place of
the status (complete_common.ml `provider_refusal`); every other class keeps it.
In a 200 body the class decides (complete_sync.ml). A quota or auth class stops
the run and keeps GLM's message, which names the reset time. MASC moves on to
its next slot after an auth failure; the harness stops, since no later request
under the same key passes. A 408, 429 or 5xx whose code does not decide, no
response, and a rate limit or server class in a 200 body are sent again up to
TRANSIENT_RETRIES times. Any other failure is that call's result, as MASC then
moves on to its next slot.

Every attempt is appended to the call log as a `tinker_oai.Call` row. A rerun
with the same log reuses each reply, so a run stopped on a spent window resumes
after the reset. A caller sends at most `max_calls` requests under one log,
counting the attempts already in it. An attempt counts once its row is written:
a run killed while requests wait for their reply leaves no rows for them, so
the next run can send one request more than the cap for each one in flight.
Calls draw on the key's usage quota and carry no per-token price here.
ZAI_API_KEY comes from the environment and is never written.
"""

from __future__ import annotations

import hashlib
import http.client
import json
import os
import threading
import time
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass
from enum import Enum
from pathlib import Path
from typing import assert_never, cast

from tinker_oai import (HTTP_OK, NO_RESPONSE, RETRY_PAUSE_S, TRANSIENT_RETRIES, Call, call_from_row,
                        completion_call, transient)

HOST = "api.z.ai"
PATH = "/api/coding/paas/v4/chat/completions"
KEY_ENV = "ZAI_API_KEY"
# The GLM provider timeout of the live runtime config (2026-11-09).
TIMEOUT_S = 1200

type JsonObject = dict[str, object]
# One POST of a request body: the HTTP status and body text, or None when no response arrived.
type Post = Callable[[bytes], tuple[int, str] | None]


class ErrorClass(Enum):
    """backend_glm.ml `glm_error_class`."""

    AUTH = "auth"
    RATE_LIMITED = "rate_limited"
    QUOTA = "quota"
    SERVER = "server"
    INVALID_REQUEST = "invalid_request"
    CONTEXT_OVERFLOW = "context_overflow"


def classify(code: str) -> ErrorClass:
    """backend_glm.ml `classify_glm_error`. Every other code, listed there or not, is an invalid request."""
    match code:
        case "1000" | "1001" | "1002" | "1003" | "1004" | "1100" | "1110" | "1111" | "1112" | "1120" | "1220":
            return ErrorClass.AUTH
        case "1302" | "1303" | "1305" | "1312":
            return ErrorClass.RATE_LIMITED
        case ("1113" | "1308" | "1309" | "1310" | "1311" | "1313" | "1314" | "1316" | "1317" | "1318" | "1319"
              | "1320" | "1321"):
            return ErrorClass.QUOTA
        case "1230" | "1234" | "500":
            return ErrorClass.SERVER
        case "1261":
            return ErrorClass.CONTEXT_OVERFLOW
        case _:
            return ErrorClass.INVALID_REQUEST


@dataclass(frozen=True, slots=True)
class GlmError:
    """backend_glm.ml `glm_error`: the code (absent when the envelope names none) and the message."""

    code: str | None
    message: str

    def error_class(self) -> ErrorClass:
        return classify(self.code) if self.code is not None else ErrorClass.INVALID_REQUEST

    def text(self) -> str:
        return f"GLM {self.code}: {self.message}" if self.code is not None else f"GLM: {self.message}"


def error_of(data: JsonObject) -> GlmError | None:
    """backend_glm.ml `check_glm_error_json`: the body's `error` member, unless it is absent, null or {}.
    The code is read from a string or an integer; the message is `message`, else the member's JSON."""
    err = data.get("error")
    if err is None or err == {}:
        return None
    fields = cast(JsonObject, err) if isinstance(err, dict) else {}
    code, message = fields.get("code"), fields.get("message")
    named = str(code) if isinstance(code, str) or (isinstance(code, int) and not isinstance(code, bool)) else None
    text = message if isinstance(message, str) else json.dumps(err, ensure_ascii=False, separators=(",", ":"))
    return GlmError(named, text)


@dataclass(frozen=True, slots=True)
class Answered:
    """HTTP 200 with a JSON object body that names no error."""

    data: JsonObject


@dataclass(frozen=True, slots=True)
class Stop:
    """A quota or auth failure: the caller stops, and a rerun with the same log resumes."""

    error: str


@dataclass(frozen=True, slots=True)
class Transient:
    """Sent again after a pause, up to TRANSIENT_RETRIES times. `error` is None when only the status tells."""

    error: str | None


@dataclass(frozen=True, slots=True)
class Failed:
    """The attempt is the call's result. `error` is None when only the status tells."""

    error: str | None


type Reply = Answered | Stop | Transient | Failed


def refusal(error: GlmError) -> Reply:
    """An error in a 200 body: complete_sync.ml gives its class an HTTP status, and that decides."""
    text = error.text()
    match error.error_class():
        case ErrorClass.AUTH | ErrorClass.QUOTA:
            return Stop(text)
        case ErrorClass.RATE_LIMITED | ErrorClass.SERVER:
            return Transient(text)
        case ErrorClass.INVALID_REQUEST | ErrorClass.CONTEXT_OVERFLOW:
            return Failed(text)
        case _ as never:
            assert_never(never)


def status_refusal(status: int, error: GlmError | None) -> Reply:
    """Another status than 200: only a quota, auth or context-overflow class takes its place."""
    if error is None:
        return Transient(None) if transient(status) else Failed(None)
    text = error.text()
    match error.error_class():
        case ErrorClass.AUTH | ErrorClass.QUOTA:
            return Stop(text)
        case ErrorClass.CONTEXT_OVERFLOW:
            return Failed(text)
        case ErrorClass.RATE_LIMITED | ErrorClass.SERVER | ErrorClass.INVALID_REQUEST:
            return Transient(text) if transient(status) else Failed(text)
        case _ as never:
            assert_never(never)


def json_object(text: str) -> JsonObject | None:
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return None
    return cast(JsonObject, data) if isinstance(data, dict) else None


def read_reply(response: tuple[int, str] | None) -> Reply:
    """What one attempt came back with, read as MASC reads it."""
    if response is None:
        return Transient(None)
    status, text = response
    data = json_object(text)
    error = error_of(data) if data is not None else None
    if status != HTTP_OK:
        return status_refusal(status, error)
    if error is not None:
        return refusal(error)
    if data is None:
        return Failed("the HTTP 200 body is not a JSON object")
    return Answered(data)


def request_body(model: str, messages: Sequence[str], max_tokens: int) -> bytes:
    """The body MASC sends a glm-coding slot for an exact output."""
    body = {"response_format": {"type": "json_object"}, "thinking": {"type": "enabled"}, "model": model,
            "max_tokens": max_tokens, "messages": [{"role": "user", "content": m} for m in messages]}
    return json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()


def call_key(body: bytes) -> str:
    """A request's cache key: the endpoint and the body bytes."""
    return hashlib.sha256(f"https://{HOST}{PATH}\n".encode() + body).hexdigest()


def sender(key: str) -> Post:
    """POST to the chat completions path with `key` as the bearer token."""

    def post(body: bytes) -> tuple[int, str] | None:
        connection = http.client.HTTPSConnection(HOST, timeout=TIMEOUT_S)
        try:
            connection.request("POST", PATH, body=body,
                               headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
            response = connection.getresponse()
            return response.status, response.read().decode(errors="replace")
        except (OSError, http.client.HTTPException):
            return None
        finally:
            connection.close()

    return post


class Caller:
    """Thread-safe. `ask` returns None, and sets `stopped`, once the caller stops."""

    def __init__(self, log: Path, max_calls: int, post: Post | None = None,
                 sleep: Callable[[float], None] = time.sleep) -> None:
        self._log = log
        self._lock = threading.Lock()
        logged: list[Call] = []
        if log.exists():
            for line in log.read_text(encoding="utf-8").splitlines():
                call = call_from_row(json.loads(line))
                if call is not None:
                    logged.append(call)
        self._cache: dict[str, Call] = {c.key: c for c in logged if c.replied()}
        self.max_calls = max_calls
        self.sent = len(logged)
        self.stopped: str | None = None
        self._post = post if post is not None else sender(os.environ[KEY_ENV])
        self._sleep = sleep

    def ask(self, *, model: str, label: str, messages: Sequence[str], max_tokens: int) -> Call | None:
        """Send user messages in order. A logged reply with the same key is returned without sending.
        Otherwise the last attempt: a reply, a failure that is the call's result, or a transient
        failure that used up TRANSIENT_RETRIES. None once the caller stops: on a quota or auth
        failure, or instead of a request past `max_calls`."""
        body = request_body(model, messages, max_tokens)
        key = call_key(body)
        retry = 0
        while True:
            with self._lock:
                hit = self._cache.get(key)
                if hit is not None:
                    return hit
                if self.stopped is None and self.sent >= self.max_calls:
                    self.stopped = f"{self.sent} requests were sent under this log, the cap is {self.max_calls}"
                if self.stopped is not None:
                    return None
                self.sent += 1
            call, reply = self._attempt(key, label, body)
            match reply:
                case Answered() | Failed():
                    return call
                case Stop():
                    return None
                case Transient():
                    if retry == TRANSIENT_RETRIES:
                        return call
                    retry += 1
                    self._sleep(RETRY_PAUSE_S * retry)
                case _:
                    assert_never(reply)

    def _attempt(self, key: str, label: str, body: bytes) -> tuple[Call, Reply]:
        """Send once and log the attempt. A reply is cached; a Stop stops the caller."""
        sent = round(time.time(), 3)
        t0 = time.monotonic()
        response = self._post(body)
        wall = round(time.monotonic() - t0, 2)
        status = NO_RESPONSE if response is None else response[0]
        reply = read_reply(response)
        match reply:
            case Answered(data=data):
                call = completion_call(key, label, status, data, wall, sent)
            case Stop(error=error) | Transient(error=error) | Failed(error=error):
                call = Call(key, label, status, None, None, None, 0, 0, 0, wall, sent, error)
            case _:
                assert_never(reply)
        with self._lock:
            if call.replied():
                self._cache[key] = call
            if isinstance(reply, Stop) and self.stopped is None:
                self.stopped = reply.error
            with self._log.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(asdict(call), ensure_ascii=False) + "\n")
        return call, reply

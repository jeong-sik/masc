# pyright: strict
"""Budgeted, cached chat calls to Tinker's OpenAI-compatible endpoint.

Every call is appended to one JSONL log. A rerun that points at the same log
reuses each HTTP 200 answer under the same key, so an interrupted run resumes
and pays only for calls that have no answer yet. A connection error or an error
status is sent again on the rerun.

TINKER_API_KEY comes from the environment and is never written.
"""

from __future__ import annotations

import hashlib
import json
import os
import threading
import time
from collections.abc import Sequence
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import cast

from openai import APIConnectionError, APIStatusError, APITimeoutError, OpenAI
from openai.types.chat import ChatCompletionUserMessageParam

BASE_URL = "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1"
# USD per million tokens, https://tinker-docs.thinkingmachines.ai/tinker/models/models_and_pricing/ (2026-11-08).
PRICE = {"prefill": 0.30, "cached": 0.03, "sample": 1.00}
# Upper estimate for the budget check. Measured admission prompts are 0.634 tokens per char.
CHARS_TO_TOKENS = 0.7
HTTP_OK = 200
NO_RESPONSE = 0
TIMEOUT_S = 900


@dataclass(frozen=True, slots=True)
class Call:
    key: str
    label: str
    status: int  # NO_RESPONSE when no HTTP response arrived
    finish: str | None
    content: str | None
    reasoning: str | None  # reasoning_content, kept for training on the teacher's thinking
    prompt_tokens: int
    cached_tokens: int
    completion_tokens: int
    wall_s: float
    sent_at: float | None  # epoch seconds when the request left; None in rows logged before 2026-11-09

    def cost(self) -> float:
        uncached = max(0, self.prompt_tokens - self.cached_tokens)
        return (uncached * PRICE["prefill"] + self.cached_tokens * PRICE["cached"]
                + self.completion_tokens * PRICE["sample"]) / 1e6

    def answer(self) -> str | None:
        """The answer text of a complete reply: HTTP 200 and finish_reason "stop"."""
        return self.content if self.status == HTTP_OK and self.finish == "stop" else None


def call_from_row(row: object) -> Call | None:
    if not isinstance(row, dict):
        return None
    r = cast(dict[str, object], row)
    key, label, wall, sent = r.get("key"), r.get("label"), r.get("wall_s"), r.get("sent_at")
    texts = [r.get(k) for k in ("finish", "content", "reasoning")]
    ints = [r.get(k) for k in ("status", "prompt_tokens", "cached_tokens", "completion_tokens")]
    if (not isinstance(key, str) or not isinstance(label, str) or not isinstance(wall, (int, float))
            or not (sent is None or isinstance(sent, (int, float)))
            or not all(v is None or isinstance(v, str) for v in texts) or not all(isinstance(v, int) for v in ints)):
        return None
    finish, content, reasoning = (cast(str | None, v) for v in texts)
    status, prompt, cached, completion = (cast(int, v) for v in ints)
    return Call(key, label, status, finish, content, reasoning, prompt, cached, completion, float(wall),
                float(sent) if sent is not None else None)


def call_key(model: str, effort: str, max_tokens: int, attempt: int, messages: Sequence[str]) -> str:
    return hashlib.sha256(json.dumps([model, effort, max_tokens, attempt, list(messages)],
                                     ensure_ascii=False).encode()).hexdigest()


class Caller:
    """Thread-safe. `ask` returns None, and sets `stopped`, once a call could exceed the budget."""

    def __init__(self, log: Path, budget: float) -> None:
        self._log = log
        self._lock = threading.Lock()
        logged: list[Call] = []
        if log.exists():
            for line in log.read_text(encoding="utf-8").splitlines():
                call = call_from_row(json.loads(line))
                if call is not None:
                    logged.append(call)
        self._cache: dict[str, Call] = {c.key: c for c in logged if c.status == HTTP_OK}
        self.budget = budget
        self.spent = sum(c.cost() for c in logged)
        self.stopped: str | None = None
        self._client = OpenAI(base_url=BASE_URL, api_key=os.environ["TINKER_API_KEY"], timeout=TIMEOUT_S,
                              max_retries=2)

    def ask(self, *, model: str, label: str, messages: Sequence[str], effort: str, max_tokens: int,
            attempt: int = 0) -> Call | None:
        """Send user messages in order. A cached HTTP 200 call with the same key is returned without sending."""
        key = call_key(model, effort, max_tokens, attempt, messages)
        with self._lock:
            hit = self._cache.get(key)
            if hit is not None:
                return hit
            chars = sum(len(m) for m in messages)
            worst = (chars * CHARS_TO_TOKENS * PRICE["prefill"] + max_tokens * PRICE["sample"]) / 1e6
            if self.stopped is not None or self.spent + worst > self.budget:
                self.stopped = self.stopped or f"spent {self.spent:.4f} + worst {worst:.4f} > {self.budget}"
                return None
            self.spent += worst  # reserved, corrected below
        call = self._send(key, label, model, messages, effort, max_tokens)
        with self._lock:
            self.spent += call.cost() - worst
            if call.status == HTTP_OK:
                self._cache[key] = call
            with self._log.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps(asdict(call), ensure_ascii=False) + "\n")
        return call

    def _send(self, key: str, label: str, model: str, messages: Sequence[str], effort: str,
              max_tokens: int) -> Call:
        params: list[ChatCompletionUserMessageParam] = [{"role": "user", "content": m} for m in messages]
        sent = round(time.time(), 3)
        t0 = time.monotonic()
        try:
            raw = self._client.chat.completions.with_raw_response.create(
                model=model, messages=params, extra_body={"reasoning_effort": effort, "max_tokens": max_tokens})
            status, body = raw.http_response.status_code, raw.http_response.text
        except APIStatusError as e:
            return Call(key, label, e.status_code, None, None, None, 0, 0, 0, round(time.monotonic() - t0, 2), sent)
        except (APIConnectionError, APITimeoutError):
            return Call(key, label, NO_RESPONSE, None, None, None, 0, 0, 0, round(time.monotonic() - t0, 2), sent)
        wall = round(time.monotonic() - t0, 2)
        data = cast(dict[str, object], json.loads(body))
        choices = cast(list[dict[str, object]], data.get("choices") or [{}])
        message = cast(dict[str, object], choices[0].get("message") or {})
        usage = cast(dict[str, object], data.get("usage") or {})
        details = cast(dict[str, object], usage.get("prompt_tokens_details") or {})
        content, finish, reasoning = message.get("content"), choices[0].get("finish_reason"), message.get(
            "reasoning_content")
        return Call(key, label, status, finish if isinstance(finish, str) else None,
                    content if isinstance(content, str) else None, reasoning if isinstance(reasoning, str) else None,
                    int(cast(int, usage.get("prompt_tokens") or 0)), int(cast(int, details.get("cached_tokens") or 0)),
                    int(cast(int, usage.get("completion_tokens") or 0)), wall, sent)

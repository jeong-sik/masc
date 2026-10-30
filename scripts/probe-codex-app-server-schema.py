#!/usr/bin/env python3
"""Ask whether the Codex app-server enforces turn/start's outputSchema.

The sibling probe (probe-structured-output-enforcement.py) covers HTTP wires
that take `response_format`. Codex takes neither that nor the `--output-schema`
flag documented for `codex exec`: this transport speaks the app-server protocol,
whose generated schema declares `outputSchema` on v2 TurnStartParams as
"Optional JSON Schema used to constrain the final assistant message for this
turn". A declaration is not a measurement, so this drives the protocol and asks.

The method is the sibling's: make the prompt and the schema disagree. The prompt
asks for a key `additionalProperties: false` forbids, and whoever wins says
whether the schema is enforced or merely accepted. Both arms run -- without the
field as a control, with it as the test -- because a run where the prompt alone
already produces the right shape proves nothing either way.

The handshake mirrors lib/runtime/runtime_codex_app_server.ml so that what is
measured is the request that adapter sends: initialize with experimentalApi, the
initialized notification, account/read, thread/start with the same four fields,
then turn/start. turn/start answers `inProgress`; the answer arrives later as
item/completed notifications with turn/completed as the terminal frame, which is
the pair the adapter reads.

Measured 2026-08-30 (n=5): without the field the prompt won every run
({"ok":true,"note":"hello"}); with it the schema won every run ({"ok":true}).

Usage:
    python3 scripts/probe-codex-app-server-schema.py [-n N] [--cwd DIR]

Exit status is 1 when the field is present and the schema did not win every run.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import threading

SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {"ok": {"type": "boolean"}},
    "required": ["ok"],
}
CONFLICT_PROMPT = (
    'Return a JSON object with two keys: "ok" set to true, and "note" set to '
    'the string "hello". Include both keys.'
)

PROMPT_WON = "prompt-won"
SCHEMA_WON = "schema-won"


class AppServer:
    """One `codex app-server` process, spoken to over stdio JSON-RPC."""

    def __init__(self, cwd: str) -> None:
        self.proc = subprocess.Popen(
            ["codex", "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            cwd=cwd,
        )
        self.stderr_tail: list[str] = []
        threading.Thread(target=self._drain_stderr, daemon=True).start()

    def _drain_stderr(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self.stderr_tail.append(line.rstrip())
            del self.stderr_tail[:-20]

    def _write(self, obj: dict) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def _read(self) -> dict | None:
        assert self.proc.stdout is not None
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError(f"app-server closed the stream; stderr={self.stderr_tail[-3:]}")
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            return None

    def request(self, rid: int, method: str, params: dict) -> dict:
        self._write({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        for _ in range(4000):
            msg = self._read()
            if msg is None:
                continue
            if msg.get("id") == rid and ("result" in msg or "error" in msg):
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg["result"]
        raise RuntimeError(f"{method}: no response within the read budget")

    def notify(self, method: str) -> None:
        self._write({"jsonrpc": "2.0", "method": method})

    def await_turn_answer(self) -> str:
        """Read to turn/completed and return the final agent message."""
        final: str | None = None
        fallback: str | None = None
        for _ in range(8000):
            msg = self._read()
            if msg is None:
                continue
            method = msg.get("method")
            if method == "item/completed":
                item = (msg.get("params") or {}).get("item") or {}
                text = item.get("text")
                if not isinstance(text, str):
                    content = item.get("content")
                    if isinstance(content, list):
                        text = "".join(
                            b.get("text", "") for b in content if isinstance(b, dict)
                        )
                if isinstance(text, str) and text.strip():
                    if item.get("role") == "final_answer" or item.get("itemType") == "agentMessage":
                        final = text
                    else:
                        fallback = text
            elif method == "turn/completed":
                turn = (msg.get("params") or {}).get("turn") or {}
                status = turn.get("status")
                if status != "completed":
                    raise RuntimeError(f"turn status={status} error={turn.get('error')}")
                return final or fallback or ""
        raise RuntimeError("no turn/completed within the read budget")

    def close(self) -> None:
        try:
            if self.proc.stdin is not None:
                self.proc.stdin.close()
        except OSError:
            pass
        self.proc.terminate()


def read_verdict(text: str) -> tuple[str, str]:
    text = (text or "").strip()
    if not text:
        return "empty", ""
    unfenced = re.sub(r"^```[a-z]*\n|\n```$", "", text).strip()
    try:
        value = json.loads(unfenced)
    except json.JSONDecodeError:
        return "not-json", text[:80]
    if not isinstance(value, dict):
        return "not-object", text[:80]
    if "note" in value:
        return PROMPT_WON, text[:80]
    if set(value) == {"ok"}:
        return SCHEMA_WON, text[:80]
    return f"other:{sorted(value)}", text[:80]


def one_turn(cwd: str, with_schema: bool) -> tuple[str, str]:
    server = AppServer(cwd)
    try:
        server.request(
            1,
            "initialize",
            {
                "clientInfo": {"name": "masc-probe", "title": "MASC probe", "version": "0"},
                "capabilities": {"experimentalApi": True},
            },
        )
        server.notify("initialized")
        server.request(2, "account/read", {"refreshToken": False})
        thread = server.request(
            3,
            "thread/start",
            {
                "cwd": cwd,
                "approvalPolicy": "never",
                "permissions": ":read-only",
                "ephemeral": False,
            },
        )
        thread_id = thread.get("threadId") or (thread.get("thread") or {}).get("id")
        if not thread_id:
            raise RuntimeError(f"thread/start returned no id: {json.dumps(thread)[:160]}")

        params: dict = {
            "threadId": thread_id,
            "input": [{"type": "text", "text": CONFLICT_PROMPT}],
        }
        if with_schema:
            params["outputSchema"] = SCHEMA
        server.request(5, "turn/start", params)
        return read_verdict(server.await_turn_answer())
    finally:
        server.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-n", "--runs", type=int, default=5)
    parser.add_argument("--cwd", default="/tmp", help="thread/start cwd (default: /tmp)")
    args = parser.parse_args()

    print(f"runs per arm: {args.runs}\n")
    results: dict[bool, dict[str, int]] = {}
    for with_schema in (False, True):
        tally: dict[str, int] = {}
        sample = ""
        for _ in range(args.runs):
            try:
                verdict, text = one_turn(args.cwd, with_schema)
            except Exception as error:  # noqa: BLE001 - reported, not swallowed
                verdict, text = f"{type(error).__name__}: {error}"[:90], ""
            tally[verdict] = tally.get(verdict, 0) + 1
            sample = sample or text
        results[with_schema] = tally
        label = "outputSchema" if with_schema else "no outputSchema (control)"
        line = ", ".join(f"{c}/{args.runs} {k}" for k, c in sorted(tally.items(), key=lambda i: -i[1]))
        print(f"  {label:26s} {line}")
        if sample:
            print(f"  {'':26s} sample: {sample}")

    control = results[False]
    test = results[True]
    print()
    if test.get(SCHEMA_WON) != args.runs:
        print("the schema did not win every run: outputSchema is not enforced here")
        return 1
    if control.get(PROMPT_WON, 0) == 0:
        print(
            "the schema won, but the control never produced the forbidden key —\n"
            "the prompt alone may account for the result. Rerun or strengthen the conflict."
        )
        return 1
    print("outputSchema is enforced: the control lets the forbidden key through, the test does not.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

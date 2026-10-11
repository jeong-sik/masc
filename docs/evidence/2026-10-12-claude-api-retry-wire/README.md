# Claude provider retry wire boundary

Reproduce the decoder assertions with
`python3 docs/evidence/2026-10-12-claude-api-retry-wire/run.py .`.
An optional second argument selects the original private capture instead of
the normalized tracked frames. The runner prints no private frame contents.

An actual installed Claude Code 2.1.296 read-only synthetic-file probe emitted
10 `system/api_retry` frames and exited 1. Its terminal frame had
`subtype=success` but `is_error=true`: the subtype alone is not success.
The existing Runtime_claude_code terminal decoder already checks `is_error`.
No model thinking, successful tool execution or final model reply was verified.

The complete new production `runtime_claude_api_retry.ml` was interpreted with
installed Yojson against the original private capture. All 10 notices decoded;
their attempt/max-retries/delay/null-status values were retained. Executed
assertions rejected a different session, negative count, float delay, blank
UUID and duplicate attempt, and distinguished an ordinary system status.
Interpreter exit 0; syntax and whitespace checks also passed. This is not a
Dune build, whole-module integration typecheck or installed runtime test.

`captured-retries.jsonl` preserves the observed numeric retry fields. Session
and observation UUIDs use explicit synthetic aliases; private error text and
unrelated fields are omitted. The original capture hash and tested production
decoder hash are in `receipt.json`. The parser does not retain private errors
or turn provider counters into MASC gates. Delay is an observation, not a timer.

This unit establishes the typed wire boundary only. The Runtime_claude_code
system branch currently ignores api_retry; the new decoder is not yet called
there. Runtime observations, Keeper durable/live events and Web/TUI projection
remain required work. No formal approval, merge or UI completion is claimed.

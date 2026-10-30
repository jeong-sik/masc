# Current context on a resumed Codex Keeper

The installed `2578d7fec3061b0a8a05301eb465ae0521ce5461` runtime composed
20,087 bytes of developer instructions for exhibit-designer at 11:35:43 UTC.
The corresponding native turn nevertheless declared that no work remained.
Its persisted Codex conversation contains only the three initial developer
items from 10:06:09 UTC; the 11:35:48 UTC user item contains the 131-byte
autonomous cue. The allowlisted observations are in `observed-before.json`.

This is evidence about persisted native history and host composition, not a
capture of the provider's HTTP model request. The raw MASC trace's `prompt`
field alone never described the developer-instruction channel.

The Keeper adapter assembled changing context into `developerInstructions`
on `thread/resume`, which the vendor does not apply to a thread that already
has developer items. So a Keeper whose instructions changed mid-thread is
read under the instructions the thread opened with. That gap is open.

The first repair injected the current developer context on every turn through
`thread/inject_items`. It was withdrawn before merge.
[OpenAI's app-server documentation](https://learn.chatgpt.com/docs/app-server#inject-items-into-a-thread)
states that `thread/inject_items` persists supplied items and includes them in
subsequent model requests, and the injected context carried the observation
frame, which is rebuilt every turn. `Keeper_unified_prompt.mli` forbids exactly
that: 943 of 945 user messages in one keeper's checkpoint were byte-identical
world-state frames, 59% of the payload (#25193, operator decision 2026-07-20).
The instructions alone would accumulate the same way, one copy per turn, and
the API carries no receipt or idempotency key, so a `Retry_previous` after a
lost `turn/start` writes what the previous attempt already wrote.

The durable form this needs is the one the session store already uses for the
tool surface: a digest whose change drops the settlement so the next turn opens
a fresh thread (`reconcile_tool_surface`). That wants the turn intent separated
from the identity half of the composed system prompt first, or every turn would
restart the thread.

`test_keeper_codex_current_context` drives the production Keeper adapter
through actual fixture processes. It checks that a fresh thread carries the
instructions and context of the turn that opened it, that a resume writes no
thread items and does not carry that turn's world state, that the thread
identity is retained, and that a failed injection does not submit a model
turn. This checks transport, not model understanding.
Local validation is parse-only plus `git diff --check`; native execution
belongs to CI. No live Keeper was changed or restarted by this repair.

# OpenAI-compatible content terminal ownership

Parent: `b321dc9e25f90b2e0814fd118933671b87095617`.

The configured GLM Coding provider uses OpenAI-compatible HTTP. The
`Complete_stream` HTTP `on_data` callback forwards parsed chunks to
`Streaming.openai_sse_parse_result_to_events`. Previously a finish closed
blocks but left admission live: later content used the same closed indexes,
repeated finishes emitted repeated stops, and a bare sentinel left unfinished
blocks open. This is source evidence of a reachable missing lifecycle guard,
not evidence that the live GLM service sent invalid trailing content.

The request-local owner now stores a closed variant for live content, finished
content (with the typed wire finish), and stopped message. Finish publication
commits only after successful projection, preserving tool-route rollback.
Content after finish and chunks after the sentinel reject without mutation.
Usage-only trailers and identical finish replays preserve usage without
reopening content. A conflicting finish rejects. The first sentinel flushes
pending inline reasoning and closes unfinished blocks before MessageStop;
it does not fabricate a successful stop reason. A repeated sentinel is a no-op.
Gemini, Responses API, and Ollama projection paths do not use this admission
phase. No keyword, substring, elapsed-time, or count heuristic was added.

## Verification

Executed in the isolated checkout on 2026-10-12:

```
ocamlc -stop-after parsing packages/agent_core/lib/llm_provider/streaming.mli
ocamlc -stop-after parsing packages/agent_core/lib/llm_provider/streaming.ml
ocamlc -stop-after parsing packages/agent_core/test/test_streaming_openai.ml
git diff --check
```

All returned exit 0. These are syntax and whitespace evidence only.

Two registered behavioral tests cover reasoning/saying closure, late content
and tool rejection, conflicting finish, usage trailers, duplicate finish and
sentinel, and sentinel closure without a fabricated finish. They were **not
executed**. Type checking, builds, CI, live provider behavior, installation,
and rendered TUI/dashboard evidence remain unverified.

The typed converter does not receive the original wire payload, so admission
errors carry an empty raw field rather than reconstructing or inventing wire
evidence. Other parse failures retain their existing raw evidence.

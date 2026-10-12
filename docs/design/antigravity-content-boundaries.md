# Antigravity response content boundaries

Antigravity response steps now retain their content identity until their own
terminal update. A background tool completing cannot close an open response,
and separate response steps no longer share normalized Text index 0.

## Contract

`Runtime_antigravity.Text_completed {step_index; ending}` follows the last
nonempty delta of an identified `agent_response` in `DONE` or `ERROR`.
`Response_done` and `Response_error` are content endings, not turn results or
MASC execution receipts. The Keeper adapter closes only the Text block mapped
to that exact step. It emits `MessageStop` only for `Turn_finished`.

Every named response gets a stable normalized index. The first Text uses 0;
later Text, native tools and MASC tools share one allocator. Anonymous content
has its own entry and is never adopted by an unrelated named completion.
A missing, malformed or unknown step index cannot close an existing named
block. Unknown step types retain their existing open-vocabulary admission and
do not supply a model content ending.

An exact repeated terminal update, or a repeated ending with no delta, adds no
content or stop. Changed text, a reopened step, or a changed terminal state for
a closed response fails as a protocol error before publishing more content.
A terminal result suffix may continue the last open Text block; if that block
already ended, the suffix receives a new index instead. Existing paragraph
separators and final-answer reconciliation remain in place.

## Producer evidence

The [official headless CLI documentation](https://www.antigravity.google/docs/cli/headless/)
identifies response steps with `step_index`, describes partial `ACTIVE` updates
followed by a completed `DONE` step, and permits a short response as one `DONE`
update carrying `text_delta`. This is the authority for treating a completed
step as closed, separately from the terminal `result` event.

The installed `/Users/dancer/.local/bin/agy` reported version 1.3.1 and SHA256
`88db8b4d21ece4999fa58e0b54cea77154e47b319ee178d086c446262317f3fa`.
Read-only inspection of its Go functions found `PollPrintmode` at
`0x102591250`, with explicit `DONE`/`ERROR` terminal classification at
`0x102591424`–`0x102591484`. It obtains response text through
`storePlannerText` (`0x102592020`), which accepts the PlannerResponse payload,
and then calls `StripThoughts`. `streamJSONEmitter.EmitStepUpdate`
(`0x1027b9640`) serializes the resulting TextDelta. The internal protobuf's
Thinking fields are not evidence of a public CLI Thinking stream.

These are documentation and installed-binary source observations, not a
captured model session. No normal producer witness was found for Tool/Internal
text becoming model speech, so this change does not broaden text attribution
rules. It neither adds Thinking text nor infers reasoning from token counts.

## Regression fixtures and validation limits

`test_runtime_antigravity` exercises the real JSON parser/runtime and the
Keeper's public test projection:

| Input sequence | Required observation |
| --- | --- |
| Two open response steps with a native tool between them | Distinct Text indices; each response stop closes its own index |
| Native completion while response text is open | Only the native index closes; the response accepts its later suffix |
| Single `DONE` with unnewline text, then a tool | Text and its stop precede the tool start |
| Repeated identical ending | One normalized content stop and no repeated text |
| Reopened/changed completed step | Protocol error before the changed content is emitted |
| Missing index or a completion with no mapped Text | An unrelated named Text remains open |
| Result suffix after open/closed Text with an intervening tool | Continue the open index, or allocate a new index after the tool |

The unnewline and overlapping-step fixtures are protocol edge cases, not
claims of captured producer output. Existing multi-step/final reconciliation,
usage, MCP ordering and native-outcome fixtures retain their assertions.
Syntax parsing and whitespace checks can validate source shape; they do not
establish type checking, fixture execution, live runtime or TUI behavior.

The shared content redactor consumes these exact normalized block stops through
its existing source-owned FIFO. This unit changes no redaction policy, journal
schema, model-response activity indicator or provider terminal-result behavior.
Content ends may occur while the overall turn and other tools remain active.

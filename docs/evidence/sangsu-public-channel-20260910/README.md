# Historical Sangsu public narration cases

The operator's reported narration pattern is present in three actual assistant
rows in `<masc-root>/keeper_chat/sangsu.jsonl`, dated 2026-09-04 UTC. Case metadata
and exact source-row/journal digests are in `cases.json`. Source bodies remain in
local diagnostics rather than publishing private conversation/reasoning text.

All three recorded runtime profiles are `ollama_cloud.deepseek-v4-pro`, with
thinking enabled. The operation event journals separately contain 165, 751 and
629 thinking deltas. The narration itself nevertheless arrives in a declared
text block, as 35, 37 and 40 public deltas respectively, before a
`keeper_surface_post` tool call. That tool's content is the separate user-directed
answer; its dashboard post is also visible in the conversation history.
`reply_details` then retains the narrated text with outcome
`external_effect_completed`. The narrated stream equals the persisted final
assistant row in all three cases.

This is evidence of a distinct output-ownership problem, not proof that typed
ThinkingDelta was converted to TextDelta. Raw provider traces referenced by these
turn records are no longer present, so the original HTTP channel origin cannot
be established from these retained artifacts. Provider-input records still exist,
but replaying historical voice/host-effect tools is neither needed nor appropriate
for this diagnostic.

The existing paired-tag and typed-block fixes in #34905 do not correct this
shape: there is no tag or mismatched channel in these retained public events.
A test limited to streamed-answer/final-answer equality would also pass this bug.
Acceptance must additionally establish which output owns user speech when the
same turn emits assistant narration and an explicit surface-post effect.

Do not filter phrases such as “the operator asked me” or infer intent from prose.
Model-authored commentary, explicit user speech and final effect settlement need
an authoritative protocol distinction. If no such distinction is available before
the first byte, already-published narration cannot be retroactively made safe by
final replacement. Support scope and streaming guarantees must state this limit.

Status: historical storage and event evidence confirmed; no replay acceptance or
fix claim for these cases yet. This does not establish the separate transient UI
replacement symptom: these three cases retain the narrated text even at the end.

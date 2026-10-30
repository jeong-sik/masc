# Transcript and event normalization audit

Baseline: `5a9d7aeac2e609a5dab261204cf89825155860b6`.
Reviewer: `independent_source_review`.
Scope: existing live decoder, journal log, transcript fold, and producer paths
needed to establish reachability. No production source changed. No Dune build,
compiled test, PTY, provider session, or CI run was performed. The traces below
are source-derived reproductions, not observed runtime screenshots.

## P2: Buffered attachment can send newer events ahead of older events

Primary location: `lib/server/server_routes_http_keeper_stream.ml:3598-3605`.
Consumer locations: `bin/masc_tui_keeper_chat_log.ml:60-84` and
`bin/masc_tui_types.ml:2961-2983`.

`publish_acceptance` marks the sink accepted under `buffered_mu`, takes the
pending list, releases the mutex, and only then writes the pending list.
From that point the sink sends newly published events directly. The writer
mutex serializes writes but does not put pending events ahead of these new
events.

This is reachable with the supported serving-domain configuration. Owner
execution is installed on the bootstrap switch
(`server_runtime_bootstrap.ml:992-995`, `keeper_owner_registry.ml:242`,
`keeper_owner.ml:1292-1319`), while HTTP routes are built on the separate
serving domain (`server_runtime_bootstrap.ml:2120-2140`). Owner publication
calls the live sink directly at `server_routes_http_keeper_stream.ml:3061`.
The default single-domain mode alone is insufficient proof: its uncontended
writer path appears not to yield. This finding specifically depends on
serving-domain isolation being enabled.

An interleaving after replay has emitted the prefix through sequence 9:

1. While acceptance/replay is running, owner buffers seq 10 Text("A") and
   seq 11 Tool_started(Read).
2. HTTP domain takes `[10,11]`, sets `accepted=true`, and releases the mutex.
3. Owner domain sends seq 12 Text("B") directly before HTTP flushes pending.
4. HTTP domain sends seq 10 then seq 11.
5. The TUI folds `B, A, Tool_started` in arrival order. Its log never inserts
   older sequences into their sequence positions. Its resume cursor is 12.

The visible text is `BA` before the tool, although the journal says `A`, tool,
then `B`. A final canonical reply cannot repair all preceding tool/text
positions: when the tool is now the last trail node, canonical `B` is appended
after it while the wrong `BA` progress node remains. Sorting timestamps only
at renderer level cannot split that already-coalesced text node.

## P2: Final reply duplicates text when reasoning splits one response

Primary location: `bin/masc_tui_keeper_chat_transcript.ml:2438-2453,2473-2499`.

The final recorded reply contains all text of the final response, but `drawn`
replaces only the last text stretch. Thinking starts a separate trail node
(`437-451`) without ending the response that the final reply represents.

Source-derived trace:

```text
Run_started
Text("A")
Thinking("R")
Text("B")
Reply_details(reply="A\nB", outcome=Visible_reply)
Run_finished

drawn = Text("A"), Thinking("R"), Reply("A\nB")
```

The prefix `A` appears twice, including with reasoning hidden. This is not
the intended case of commentary before a tool round: no tool round occurred.

A concrete accepted producer input is one Claude assistant envelope whose
content is `[text A, thinking R, text B]`, followed by a successful result
whose result is absent/null (or explicitly `A\nB`).
`lib/runtime/runtime_claude_code.ml:1531-1555` emits the content blocks in that
order and records both text blocks; `1635-1649` uses their newline-joined text
when the result text is absent. The Keeper adapter forwards Text and Thinking
separately (`lib/keeper/keeper_claude_code_runtime.ml:204-217`) and returns
`content=[Text turn.text]` (`1318`). The final Keeper result reads
`Agent_core.Types.text_of_content` (`lib/keeper/keeper_agent_run.ml:2033`) and
the chat route publishes that canonical reply
(`lib/server/server_routes_http_keeper_stream.ml:2825-2832`).
The client parser accepts this shape; no native provider session was run to
measure its frequency. AGENT_CORE also permits text/thinking/text content and
joins its text blocks in `packages/agent_core/lib/llm_provider/types.ml:1978`.

## P2: Stream usage loses counters that the provider already reported

Primary locations: `bin/masc_tui_keeper_chat_live.ml:247-254`,
`bin/masc_tui_keeper_chat_log.ml:136-137`, and
`bin/masc_tui_keeper_chat_transcript.ml:2059-2061`.

There are two connected loss points in the same field-preservation contract:

1. `KEEPER_STREAM_MESSAGE_START` includes `usage` (producer projection at
   `lib/server/server_keeper_chat_agui_projection.ml:150-158`), but both live
   normalization and journal replay discard everything except `model`.
2. Later sparse usage snapshots replace the entire previous usage record;
   absent counters overwrite counters already reported with `None`.

The Anthropic parser seeds usage at message_start and accepts sparse
message_delta usage (`packages/agent_core/lib/llm_provider/streaming.ml:32-56,
126-163`). These are actual producer shapes, not invented counters.

```text
message_start usage={input_tokens=500, output_tokens=0,
                     cache_read_input_tokens=100}
message_delta usage={output_tokens=7}
```

The TUI emits only `tokens: out 7`; input and cache counts were reported but
are gone. Even if a later delta supplies input/cache, the next output-only
delta removes them again. Live and replay agree on the wrong result.
`stream_tokens_text` (`transcript.ml:366-389`) only renders fields left in the
current record. Preserve reported fields within one provider message and
reset them at the next message boundary.

## Leads not counted as confirmed P2 findings

- Duplicate `Runtime_attempt_started` carrying the same attempt_index still
  clears totals and wraps existing text as superseded before checking whether
  the index changed (`transcript.ml:1997-2035`). A direct fold demonstrates
  that behavior, but no legitimate production path emitting that repeat with
  a new sequence was established; ordinary same-sequence replay deduplicates.
- A continuation's next Run_started clears the previous checkpoint reply
  (`1966-1973`); because control statuses are reconstructed only from the
  single current `reply`, its previously drawn checkpoint status disappears.
  This needs the intended status-history contract checked before severity is
  assigned. The underlying journal event is retained.
- Skill delivery decoration uses only provider tool_use_id (`2267-2287`,
  `2355-2364`), but the straightforward collision example is guarded by
  `Keeper_skill_activation_ledger.record` (`2309-2327`), which rejects a
  conflicting activation in the same trace. It is not claimed as a confirmed
  reachable overwrite without an independently established bypass.
- Log gaps/order by themselves are not a separate finding: the normal
  observer path requests journal pages instead of mixing observer frames
  into the log. The concrete ordering defect above is the supported
  multidomain attachment interleaving.

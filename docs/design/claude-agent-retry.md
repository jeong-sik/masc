# Claude root Agent retry observations

This unit builds on numeric-wire SSOT base `d80cc0df17fee941dd2b7e3188fc6228c2751d97`. It preserves foreground Agent retry notes and their later clear as provider observations on an existing root native call. It does not infer child execution, success, model resumption, Thinking or model-response completion.

## Producer evidence

The inspected Claude Code 2.1.292 binary has SHA256 `97a01e5bc74a199e67189435d0331ea3a24eac2e07db4b76d9148c5b0386138f`. Byte offsets below identify this binary, not a portable source version:

| Offset | Observed producer contract |
| --- | --- |
| 184619746 | SDK `tool_progress` schema includes required tool ID/name, nullable parent ID, integer elapsed, UUID/session and optional `subagent_type`/`subagent_retry`. Retry counts, delay and nullable status are integer fields; the schema does not establish positive bounds. |
| 199011150 | A foreground child's `system/api_error` produces `agent_api_retry`, retaining agent ID/type, attempt, max retries, retry delay, status and category. The generated progress ID remains opaque. |
| 193327373, 193328511 | `uBo` receives the actual native call ID; the wrapper retains an existing literal parent ID or that call ID. |
| 195380451 | `x_t` adds a fresh progress UUID. |
| 198844331 | `tpe` serializes `tool_progress`, literal tool name `Agent`, parent call, progress ID, UUID/session, `elapsed_time_seconds: 0`, subagent type and retry fields. It emits no heartbeat field. |
| 199010279, 199010628 | After a prior retry, a subsequent eligible non-API-error event emits `resolved: true`; serialization omits `subagent_retry`. Query-model-change and spinner-mode events return before this clear. |
| 217188915, 217337245 | The headless path sends internal progress through `nS`/`tpe`; engine twins are dropped. |
| 199013364 | Detaching sets the callback's stop flag, and its initial guard stops subsequent forwarding. Detached child retry is outside this contract. |

This is installed-source evidence and a supported causal scenario, not a live provider incident. Non-heartbeat shell forwarding is separately remote/container gated; this unit makes no claim that MASC's default local invocation receives it.

## Authority and state

The runtime admits retry metadata only with the expected session, an exact open `Root_response` built-in `Agent` call, and `Native_full` posture. Existing native-start UUID, ordinal and parent-scope authority remains intact. No ID prefix, substring, child name or session alone supplies call ownership.

The progress-envelope UUID registry is shared with heartbeat and retains a typed frame. Exact replay, changed payload with the same UUID and cross-kind UUID reuse publish no second observation. Valid but unowned frames claim their UUID so a later start cannot adopt the replay; malformed and foreign-session frames claim none, preserving the prior heartbeat policy.

Each owned root Agent retains its latest retry binding: opaque progress ID plus observed child agent ID/type and whether a note is pending. A clear contains no child agent ID; it is accepted only against the earlier binding with the same progress ID and type. Thus `P1 retry → P2 retry → P1 clear` cannot clear the P2 note. A new report for a different child under the same root occurrence is refused. Duplicate clears, clear before note and late observations after close are ignored. Root call end does not manufacture a clear.

The outer wire parser has a narrow observation exception: exactly one `type: tool_progress`, no heartbeat field, a literal `Agent` candidate, subagent type field, and only the serializer's known keys. Duplicated retry identity/note fields reach the strict retry decoder and are ignored, including duplicate/conflicting tool names when one is `Agent`. Authentication, duplicate top-level type, generic `heartbeat: false`, and duplicate unknown fields retain the existing strict JSON policy. Unique unknown retry fields are ignored as unsupported observations.

## Shared wire and consumers

`Runtime_native_tools.progress` adds `Retry_observed` with two closed payloads:

- `retry_reported`: `agent_id`, `subagent_type`, `attempt`, `max_retries`, `retry_delay_ms`, nullable `error_status`, and `error_category`.
- `retry_cleared`: `agent_id` and `subagent_type`, recovered only from the validated prior runtime binding.

The shared codec rejects extra, duplicate, missing or incorrectly typed fields. All retry integers use `Runtime_json_integer.of_json`, matching dashboard `Number.isSafeInteger`; signed values remain provider facts. The canonical codec's nonblank predicate uses OCaml `String.trim` (space, tab, LF, CR and form feed). Dashboard retry validation preserves the same literal Unicode content rather than applying ECMAScript `trim` and dropping a server-emitted observation. This is a wire-contract rule, not a claim that the built-in provider emits blank-looking agent metadata. No requested-model or timing fallback is introduced. Subagent type and error category pass through the existing redaction callback; opaque agent identity is retained for correlation.

The existing adapter callback, scoped native occurrence bridge, direct stream, autonomous journal, AG-UI projection, TUI `Live.feed` and dashboard wire validator carry the same typed progress. No new side channel bypasses occurrence, scope or sequence validation. Retry callbacks cannot flush held Text/Thinking content.

The TUI stores retry separately from heartbeat/output/message measurements. Report and clear leave byte count, last real heartbeat value and arrival clock, local elapsed, authored body, model activity, call outcome and turn phase unchanged. Clear displays “provider retry notice cleared”. A retained note on a call that is no longer running displays “last observed provider retry”. Existing tool outcome/error status remains authoritative and separate. Dashboard accepts and retains the typed metadata without promoting it to authored text or a MASC execution receipt; this unit does not add a dashboard retry view.

## Verification scope

| Fixture | Observable boundary |
| --- | --- |
| `test_runtime_claude_code` | Real fake-CLI receive loop through healthy terminal; malformed/nested duplicate fields; exact root/native-full/session ownership; replay and cross-kind UUID conflicts; P1/P2 clear correlation; closed starts; unrelated/auth JSON stays strict. |
| `test_keeper_claude_code_runtime` | Actual runtime and Keeper adapter callbacks into direct scoped stream and autonomous durable journal, live/replayed TUI state, decreasing heartbeat and withheld Text/Thinking secret preservation. |
| `test_tui_native_tool_progress` | Shared bridge/SSE/live/journal roundtrip; signed numeric parity and redaction; separate retry state and unchanged measurement clocks/body/phase; ended note wording; old scope/missing owner/terminal rejection. |
| `test_tui_keeper_chat_transcript`, `test_runtime_codex_app_server` | Existing exhaustive progress consumers include the new closed variant. |
| Dashboard `schemas/sse.test.ts`, `keeper-stream.test.ts` | Strict retry payload vocabulary, safe integers/null status, malformed fields and authored text/receipt noninterference. |

At implementation handoff, only parser checks were executed. A later bounded measurement directly loaded the complete canonical OCaml numeric/progress implementations and the actual Dashboard SSE decoder. Its 23 observations exposed six Unicode metadata disagreements; after aligning the decoder with the canonical codec, all 22 comparable observations agree. Duplicate-key rejection is separately observed at the server boundary because JavaScript object parsing discards repeated keys. Typed retry/clear round-trip, redaction, null status, integral numeric spelling and safe-integer boundaries are included. This does not establish public-interface typechecking, the runtime/adapter fixture, full repository build, CI, deployment, live provider behavior or actual terminal screenshots.

The separate PTY followup should extend the existing native-progress/model-response scenario with an open Agent and unchanged authored body: retry report, clear with the turn still in progress, another report followed by native end without clear, and stale clear rejection established by the runtime fixture. Capture actual frames from the built candidate, retaining existing Thinking/Streaming/response-ended distinctions and decreasing heartbeat evidence. The displayed clear must not claim resumed model work or completed child execution. Detached child identity/progress and non-heartbeat shell progress remain outside this repair.

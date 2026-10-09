# Godfile refactoring campaign, 2026-10-08

Tracking issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).
Baseline: `559c028cc22bc79c320de58d0a004abb1547eaa2`.

This campaign covers tracked code files with at least 2,000 lines. The initial
inventory contains 171 candidates: 75 production source/style/interface files,
90 tests, 3 tooling files and 3 evidence scripts. `inventory.json` records each
baseline path and its current audit state. A line count selects candidates; it
is not a defect verdict or a new build gate. Forty production candidates received
bounded changes; their other responsibilities remain pending. The other 35
production candidates still require semantic review. All 171 candidates remain
in the campaign until their responsibilities and necessary repairs are assessed.

| PR | Concrete boundary or defect | Changed production file |
| --- | --- | --- |
| [#41868](https://github.com/jeong-sik/masc/pull/41868) | Shared types and pure HTTP/transcript projection; audio and trace effects resolved by the owner | `keeper_chat_store.ml` |
| [#41858](https://github.com/jeong-sik/masc/pull/41858) | Shared protocol declaration; resolve protocol/API format once | `runtime_toml.ml` |
| [#41871](https://github.com/jeong-sik/masc/pull/41871) | Invalid persisted kinds cannot impersonate utterances or acknowledge pending input | `keeper_chat_store.ml` |
| [#41872](https://github.com/jeong-sik/masc/pull/41872) | Pure calendar, segment grammar and ordering separated from storage effects | `dated_jsonl.ml` |
| [#41879](https://github.com/jeong-sik/masc/pull/41879) | Pure line-window projection after backend acquisition | `keeper_tool_filesystem_runtime.ml` |
| [#41890](https://github.com/jeong-sik/masc/pull/41890) | Failure card extracted; completed media retained on history reload; diagnostics remain separate from speech | `dashboard/src/components/chat/primitives.ts` |
| [#41899](https://github.com/jeong-sik/masc/pull/41899) | One closed row classification; server failure producer; shared terminal authority and all consumers updated | `keeper_chat_store.ml`, `server_routes_http_keeper_stream.ml`, chat primitives |
| [#41915](https://github.com/jeong-sik/masc/pull/41915) | Pure terminal mouse protocol separated from domain JSON contracts; direct input/scroll consumers updated | `tui_decode.ml/.mli`, main TUI and render primitives |
| [#41932](https://github.com/jeong-sik/masc/pull/41932) | Strict pure Read coordinate decoding; effects sequenced after successful decode; private duplicate guidance variant removed | `keeper_tool_filesystem_runtime.ml` |
| [#41955](https://github.com/jeong-sik/masc/pull/41955) | Canonical retained media projection; image acquisition effects separated from rendering; media-only autonomous and failure rows keep output | main TUI and history consumers |
| [#41962](https://github.com/jeong-sik/masc/pull/41962) | Pure schedule snapshot/wake readers separated from HTTP/store effects; private parser helpers | `masc_tui_loader.ml` |
| [#41963](https://github.com/jeong-sik/masc/pull/41963) | Attempt checkpoint projection and validated sink boundary owned separately; unused result copy and testing forwarders removed | `keeper_turn_driver.ml/.mli` |
| [#41969](https://github.com/jeong-sik/masc/pull/41969) | Blocking orphan inventory/preservation owned separately; pure writer/sweep filename grammar shared; existing public API bound directly | `atomic_write.ml`, `fs_compat.ml` |
| [#41972](https://github.com/jeong-sik/masc/pull/41972) | Duplicate recovery report types/projections removed; existing consumer reads canonical rich rows and exact operation identities | `atomic_write.ml/.mli`, publication reconciliation tests |
| [#41974](https://github.com/jeong-sik/masc/pull/41974) | Ordinary atomic replacement effect owner separated; direct public bindings; cancellation docs and cold file-ingestion evidence corrected | `atomic_write.ml/.mli`, `fs_compat.ml/.mli`, blob tests |
| [#41987](https://github.com/jeong-sik/masc/pull/41987) | Pure turn completion policy and response normalization; ignored history argument and testing forwarders removed; Muse fixture preparation repaired | `keeper_agent_run.ml/.mli`, direct adapter and policy tests |
| [#41992](https://github.com/jeong-sik/masc/pull/41992) | HITL request/domain owner with explicit host/config acquisition before pure projection; shared HTTP/CLI captured bundle and direct test consumers | `hitl_summary_worker.ml/.mli`, HITL fixture |
| [#42003](https://github.com/jeong-sik/masc/pull/42003) | Ignored fallback cwd repaired through owned directory FD; native/Eio refusal authority, shared path rule and redundant spawn forwarder removal | `process_eio.ml/.mli`, foreground owner and shared spawn C |
| [#42013](https://github.com/jeong-sik/masc/pull/42013) | Eio foreground capture/cleanup effect owner; duplicate two-stream and pipeline drains removed; callback dispatch simplified and grace docs corrected | `process_eio.ml/.mli`, Eio capture owner, direct consumers |
| [#42016](https://github.com/jeong-sik/masc/pull/42016) | Pure tool-schema contract owns strict decoding, projection and private construction; public signature and direct provider/MCP consumers preserved | `llm_provider/types.ml`, schema contract owner |
| [#42021](https://github.com/jeong-sik/masc/pull/42021) | Existing approval projection owner receives chat writes, replay reconciliation, broadcasts and failed logs; pure readiness and distinct native admission preserved | `keeper_approval_queue.ml/.mli`, projection/result owners |
| [#42024](https://github.com/jeong-sik/masc/pull/42024) | Pure fleet counts/source ages and JSON separated from durable discovery/read/diagnostic effects; owner lifecycle and storage completeness remain distinct | `keeper_event_queue_persistence.ml/.mli`, fleet projection owner |
| [#42027](https://github.com/jeong-sik/masc/pull/42027) | Ignored declaration caller parameters and forwarding helper removed; host-owned access and meaningful dispatch provenance retained | `lane_addon_runtime.ml/.mli`, tool/HTTP and direct test consumers |
| [#42036](https://github.com/jeong-sik/masc/pull/42036) | Private canonical Board partition data and pure wire/ledger framing separated from storage/entropy effects; public signature and nominal/private boundaries preserved | `keeper_board_attention_partition.ml`, private types/wire owners |
| [#42060](https://github.com/jeong-sik/masc/pull/42060) | Private canonical current-row kinds, schema/identity and strict decoder separated from ledger storage, outbox and evidence caches; public signature preserved | `keeper_reaction_ledger.ml`, private wire owner |

Gate decision projection is tracked in [#42091](https://github.com/jeong-sik/masc/pull/42091): private canonical data and pure JSON/diagnostic projection retain the public API while approval, CAS, audit and recovery effects stay in their owner. See [gate-projection/README.md](gate-projection/README.md).

Event queue transitions and strict current snapshot/receipt encoding are separated in [#42095](https://github.com/jeong-sik/masc/pull/42095). The wire codec shares the canonical immutable admission rules; schedule occurrence projection stays at the public boundary. See [event-queue-wire/README.md](event-queue-wire/README.md).

Memory OS support maintenance and snapshot calculation are separated from storage and recovery in [#42098](https://github.com/jeong-sik/masc/pull/42098). Shared canonical data keeps the strict decoder and pure calculation aligned. See [memory-support-core/README.md](memory-support-core/README.md).

Async request strict records and client projection are separated from worker/storage authority in [#42100](https://github.com/jeong-sik/masc/pull/42100). Pending elapsed time acquires its timestamp at the boundary; completed entries keep their clock-free path. See [msg-async-wire/README.md](msg-async-wire/README.md).

Unified prompt event fields and schedule grouping are separated from catalog/assembly effects in [#42106](https://github.com/jeong-sik/masc/pull/42106). Its direct rendering fixture now initializes isolated embedded prompt assets. See [prompt-event-fields/README.md](prompt-event-fields/README.md).

Memory tool mutation argument validation and typed failure/effect policy are separated from execution in [#42110](https://github.com/jeong-sik/masc/pull/42110). A checked type re-export retains one shared store vocabulary. See [memory-tool-validation/README.md](memory-tool-validation/README.md).

The declared branch dependencies follow that order, starting at `main`.
GitHub may group a subset into a native stack; inspect live membership rather
than inferring it from the direct branch bases.
Draft publication does not mean merge, deployment, independent GitHub approval,
or an executed behavior test. REST stack membership must be refreshed before
any review or integration decision.

## Defect evidence

The current chat contract has one closed row role. A server request failure is
persisted through `append_request_failure_once` as `Request_failure`, so it cannot
impersonate Keeper speech, acknowledge pending input, or enter conversation
memory. There is no independent chat `kind` field or writer argument. Completed
media and exact live traces survive history reload, including the default
workspace filter and grouped work rendering. See [failure-row/README.md](failure-row/README.md)
for the current contract, store scenarios, browser interactions and TUI PTY proof.

## Evidence and pending checks

Subsequent operator-authorized Core/dated JSONL compilation and the three
row-kind tests passed on the combined source head; see
[local-validation.md](local-validation.md) for scope, commands and logs.
Dashboard failure/output and current row-contract checks subsequently passed; see
[failure-output/README.md](failure-output/README.md) and
[failure-row/README.md](failure-row/README.md). Mouse grammar/input/reader checks,
TUI compilation and SGR PTY interaction passed; see
[mouse-protocol/README.md](mouse-protocol/README.md). Remaining targets are scoped
in the individual evidence documents rather than inferred from adjacent checks.
TUI retained media, canonical history and image acquisition checks are recorded
in [tui-output-media/README.md](tui-output-media/README.md).
Schedule projection extraction and its existing PTY consumer checks are recorded
in [tui-schedule-decode/README.md](tui-schedule-decode/README.md).
Attempt checkpoint ownership and selected existing scenarios are recorded in
[attempt-checkpoint/README.md](attempt-checkpoint/README.md).
Atomic orphan ownership and its existing isolated filesystem checks are recorded
in [atomic-orphan-owner/README.md](atomic-orphan-owner/README.md).
Canonical publication report consumption and removal of duplicate types/projections
are recorded in [publication-report-types/README.md](publication-report-types/README.md).
Ordinary replacement ownership, corrected cancellation docs and cold file-ingestion
proof are recorded in [atomic-replace-owner/README.md](atomic-replace-owner/README.md).

`validation.log` records successful OCaml 5.5.1 parse-only checks on the changed
source/interface files, combined diff whitespace checking, and validation of
this stack's changelog fragments through the production fragment parser.
These checks do not establish OCaml type correctness or runtime behavior.

| Changed contract | Direct consumers | Behavior targets (row_kind subset subsequently executed) |
| --- | --- | --- |
| Chat types, resolved JSON projection and strict kind decode | History endpoints, pending-message classification, transcript selection | `test_keeper_chat_store`, `test_keeper_mention_scope`, `test_dashboard_http_core` |
| Protocol resolution/editor declarations | Provider parsing and structured runtime editor | `test_runtime_provider_auth_headers`, `test_runtime_claude_code_config`, `test_runtime_muse_serve_config`, `test_runtime_antigravity` |
| Dated JSONL layout | Reads, range selection, pruning and rotation | `test_dated_jsonl` |
| Line-window slice | Owned filesystem and sandbox Read backends, existing For_testing adapter | `test_keeper_tool_read_window` |

Each code slice received independent adversarial source review. A missing
changelog PR citation was reported as P2, repaired across the affected fragments,
and checked through the fragment parser. EOF whitespace P3s are corrected in the
kind slice. Reviews are source evidence only; current-head review receipts belong
in the individual PR descriptions. There is no independent GitHub approval.
At the initial source-review boundary, Core compilation and behavior targets
were unverified and no local Dune build was run. The later operator request
authorized the narrow compilation and row-kind execution recorded separately.
No full build, CI watch loop, live runtime probe or deployment was run.
The Core check requires an approved leader-selected candidate under the current
execution protocol; no selection receipt or approval is fabricated here.

## Next work

Skill activation immutable data and pure summary ownership:
[#42089](https://github.com/jeong-sik/masc/pull/42089),
[skill-activation-summary/README.md](skill-activation-summary/README.md).

The follow-up removes ignored summary helper inputs while retaining the actual
storage read limit: [#42087](https://github.com/jeong-sik/masc/pull/42087),
[reaction-summary-inputs/README.md](reaction-summary-inputs/README.md).

Reaction-ledger strict current-row ownership and isolated evidence/cache/ACK checks
are recorded in [reaction-ledger-wire/README.md](reaction-ledger-wire/README.md).

Board partition data/wire ownership, durable FSM scenarios and compiler boundary
checks are recorded in [board-partition-wire/README.md](board-partition-wire/README.md).

Unused Lane declaration caller removal and its existing editing/private ownership
checks are recorded in [lane-declaration-access/README.md](lane-declaration-access/README.md).

Pure event-queue fleet projection and its actual storage/concurrency and adjacent
health checks are recorded in [event-queue-fleet-projection/README.md](event-queue-fleet-projection/README.md).

Approval chat ownership, distinct native receipt authority and isolated consumer
checks are recorded in [approval-chat-projection/README.md](approval-chat-projection/README.md).

Pure tool-schema contract ownership and decoder/wire/API-boundary evidence are
recorded in [tool-schema-contract/README.md](tool-schema-contract/README.md).

Eio foreground capture/cleanup ownership, shared drains and direct child-output
checks are recorded in [eio-capture-owner/README.md](eio-capture-owner/README.md).

The reproduced ignored-cwd fallback defect and directory-acquisition/refusal
repair are recorded in [process-fallback-cwd/README.md](process-fallback-cwd/README.md).

HITL judgment context acquisition, pure request projection and domain decoding
are recorded in [hitl-request-context/README.md](hitl-request-context/README.md).

Pure Keeper response normalization, removal of the ignored history argument,
and direct consumer checks are recorded in
[turn-response-contract/README.md](turn-response-contract/README.md).

Continue semantic review of every pending production candidate in
`inventory.json`, then relevant tests/tooling. Start with `lib/tui_decode.ml`,
which combines multiple domain payload contracts, and
`lib/keeper/keeper_turn_driver.ml`, which combines runtime selection, retry
planning, input projection and effect dispatch. Trace concrete callers before
choosing a split; top-level names alone do not establish a defect.

The Read-coordinate follow-up reproduced an out-of-range integer offset returning
the file head as a successful read. Pure strict decoding and sequencing of path
resolution after decode are now recorded in
[read-window-input/README.md](read-window-input/README.md). The byte-budget parser
and remaining filesystem responsibilities still require semantic review.

Keep future units independently reviewable, move effects to their owning edge,
use shared typed contracts rather than compatibility layers, and preserve strict
storage atomicity, cancellation and acknowledgement evidence. The goal remains
active until the full candidate set has been semantically assessed and necessary
changes have the appropriate verification evidence.

Composition result and failure projection are separated from runtime effects in [#42113](https://github.com/jeong-sik/masc/pull/42113). See [composition-projection/README.md](composition-projection/README.md). Remaining execution and settlement policies are still pending audit.

Connector durable-request construction, strict replay and target projection are separated from Gate/transmission effects in [#42114](https://github.com/jeong-sik/masc/pull/42114). See [connector-replay/README.md](connector-replay/README.md). Remaining handler policies require semantic audit.

MicroVM build-link invalid paths retain their actual refusal reason in [#42118](https://github.com/jeong-sik/masc/pull/42118), including the direct sandbox-runtime diagnostic consumer. See [microvm-link-refusal/README.md](microvm-link-refusal/README.md). Both candidates retain their remaining lifecycle and execution audit scope.

Pure microVM build-link paths, scan decisions and action/target selection have a canonical owner in [#42120](https://github.com/jeong-sik/masc/pull/42120). See [microvm-build-plan/README.md](microvm-build-plan/README.md). The same candidate remains partially improved.

Codex child environment projection is separated from environment/config/path acquisition in [#42121](https://github.com/jeong-sik/masc/pull/42121). See [codex-environment-projection/README.md](codex-environment-projection/README.md). Protocol, subprocess and remaining configuration semantics are still pending audit.

Declared runtime settings and capability JSON are separated from live acquisition in [#42122](https://github.com/jeong-sik/masc/pull/42122). See [runtime-declaration-projection/README.md](runtime-declaration-projection/README.md). Remaining probe/cache/resolution policies require semantic audit.

Keeper state-diagram evidence acquisition and redacted projection are separated in [#42124](https://github.com/jeong-sik/masc/pull/42124). See [keeper-state-evidence/README.md](keeper-state-evidence/README.md). Remaining API responsibilities are pending audit.

Claude child environment policy is separated from account/path/environment reads in [#42126](https://github.com/jeong-sik/masc/pull/42126). See [claude-environment-projection/README.md](claude-environment-projection/README.md). Remaining protocol and lifecycle policies require semantic audit.

Canonical Board candidate data, strict codecs and pure projections are separated from persistence/wake in [#42130](https://github.com/jeong-sik/masc/pull/42130). See [board-candidate-wire/README.md](board-candidate-wire/README.md). Remaining lifecycle/effect semantics stay pending after crossing below2000 lines.

Pure Board worker callback/provenance and execution disposition are separated from durable transitions in [#42133](https://github.com/jeong-sik/masc/pull/42133). See [board-worker-disposition/README.md](board-worker-disposition/README.md). Remaining scheduling/state effects require semantic audit.

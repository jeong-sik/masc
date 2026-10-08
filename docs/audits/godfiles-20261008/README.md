# Godfile refactoring campaign, 2026-10-08

Tracking issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).
Baseline: `559c028cc22bc79c320de58d0a004abb1547eaa2`.

This campaign covers tracked code files with at least 2,000 lines. The initial
inventory contains 171 candidates: 75 production source/style/interface files,
90 tests, 3 tooling files and 3 evidence scripts. `inventory.json` records each
baseline path and its current audit state. A line count selects candidates; it
is not a defect verdict or a new build gate. Seventeen production candidates received
bounded changes; their other responsibilities remain pending. The other 58
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

# Godfile refactoring campaign, 2026-10-08

Tracking issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).
Baseline: `559c028cc22bc79c320de58d0a004abb1547eaa2`.

This campaign covers tracked code files with at least 2,000 lines. The initial
inventory contains 171 candidates: 75 production source/style/interface files,
90 tests, 3 tooling files and 3 evidence scripts. `inventory.json` records each
baseline path and its current audit state. A line count selects candidates; it
is not a defect verdict or a new build gate. Semantic review remains pending
for 70 production candidates. Five production files received bounded changes;
their other responsibilities have not been declared audited or complete.

| PR | Concrete boundary or defect | Changed production file |
| --- | --- | --- |
| [#41868](https://github.com/jeong-sik/masc/pull/41868) | Shared types and pure HTTP/transcript projection; audio and trace effects resolved by the owner | `keeper_chat_store.ml` |
| [#41858](https://github.com/jeong-sik/masc/pull/41858) | Shared protocol declaration; resolve protocol/API format once | `runtime_toml.ml` |
| [#41871](https://github.com/jeong-sik/masc/pull/41871) | Invalid persisted kinds cannot impersonate utterances or acknowledge pending input | `keeper_chat_store.ml` |
| [#41872](https://github.com/jeong-sik/masc/pull/41872) | Pure calendar, segment grammar and ordering separated from storage effects | `dated_jsonl.ml` |
| [#41879](https://github.com/jeong-sik/masc/pull/41879) | Pure line-window projection after backend acquisition | `keeper_tool_filesystem_runtime.ml` |
| [#41890](https://github.com/jeong-sik/masc/pull/41890) | Failure card extracted; completed media retained on history reload; diagnostics remain separate from speech | `dashboard/src/components/chat/primitives.ts` |

The declared branch dependencies follow that order, starting at `main`.
GitHub may group a subset into a native stack; inspect live membership rather
than inferring it from the direct branch bases.
Draft publication does not mean merge, deployment, independent GitHub approval,
or an executed behavior test. REST stack membership must be refreshed before
any review or integration decision.

## Defect evidence

The old `parse_line_decoded` mapped every unrecognized kind to `Utterance`.
`Keeper_world_observation_message_scope.acknowledged_turn_refs` and
`answered_delivery_keys` treat utterances as answers when their turn/delivery
identity matches pending input. The repaired decoder rejects present unknown,
blank and wrong-type values, retains read-drop evidence and causes the strict
reader to return an error. Absence retains the writer's utterance semantics.
The replaced scenario checks persisted malformed input through loading and
pending classification, including strict rejection after permissive loading.
Its source is reviewed. The row-kind group subsequently passed under an
operator-requested local check; see [local-validation.md](local-validation.md).

## Evidence and pending checks

Subsequent operator-authorized Core/dated JSONL compilation and the three
row-kind tests passed on the combined source head; see
[local-validation.md](local-validation.md) for scope, commands and logs.
Dashboard failure/output scenarios and their store checks subsequently passed; see [failure-output/README.md](failure-output/README.md). The other behavior targets below remain unexecuted.

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

Continue semantic review of every pending production candidate in
`inventory.json`, then relevant tests/tooling. Start with `lib/tui_decode.ml`,
which combines multiple domain payload contracts, and
`lib/keeper/keeper_turn_driver.ml`, which combines runtime selection, retry
planning, input projection and effect dispatch. Trace concrete callers before
choosing a split; top-level names alone do not establish a defect.

Also follow up `read_line_window_of_args` in the filesystem runtime:
`Safe_ops.json_int_opt` accepts float/string coercions and maps unparseable
present values to absence. Establish whether production descriptor validation
already rejects them and whether direct callers bypass it before changing this
boundary. The current extraction deliberately retains its existing behavior.

Keep future units independently reviewable, move effects to their owning edge,
use shared typed contracts rather than compatibility layers, and preserve strict
storage atomicity, cancellation and acknowledgement evidence. The goal remains
active until the full candidate set has been semantically assessed and necessary
changes have the appropriate verification evidence.

# One chat row classifier

Parent source: `e4ef766db26ef86065b37f6a2105404e60bba495` (#41890).
Issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).

Keeper speech is an `assistant` row. A failed request is a server-owned
`request_failure` row. There is no independent row `kind`, `Row_kind` module,
or `assistant_kind` append argument. Both results use the same `terminal_result`
slot, so a failure and a reply cannot append contradictory terminals for one
operation. Completed media and turn trace remain attached to the failed result.

The two semantic producer APIs share the store-owned redaction, serialized
lookup/append, tool ordering and quarantine logic. Unknown persisted top-level
fields are refused by both history decoding and append-once provenance scanning.
The dashboard boundary accepts only the closed row vocabulary. No compatibility
writer, reader, dual format or migration is added. This contract requires fresh
Keeper transcripts for deployment; this session changes no live transcript,
queue, operation or running process.

## Executed evidence

| Changed boundary | Direct check | Result |
| --- | --- | --- |
| Store writer/readers and row semantics | `test_keeper_chat_store` | 83 passed before the final trace assertion; final `failure_records` group 4 passed |
| Same terminal authority, retained media/trace, pending input | `test_keeper_chat_store -- test failure_records` | Four scenarios passed; failed result then reply and reply then failure each retain one terminal |
| Conversation memory and causal acknowledgement | `test_keeper_mention_scope` | 34 passed |
| Durable journal reconciliation | `test_keeper_chat_journal_audit` | 19 passed |
| Shared slot codec | `test_keeper_chat_delivery_identity` | 8 passed |
| History rendering classification | `test_tui_keeper_chat_history` | 76 passed |
| Deferred original/native attempts | `test_keeper_direct_runtime_resume test authority` | 3 passed |
| Restart recovery and exact delegate reply | `test_keeper_owner test actor 40-42,72` | 4 passed |
| Dashboard history, rendering, transport schema and delivery state | Five focused Vitest files | 540 passed; final renderer subset 11 passed |
| Dashboard action/provenance consumers | Two focused Vitest files | 81 passed |
| TypeScript contracts | `pnpm --dir dashboard typecheck` | passed |
| Current TUI executable | focused Dune build | [tui-build.json](tui-build.json) records command and exit |
| Dashboard rendering | production component browser fixture | default workspace visibility filter applied; image decoded, audio played, failure displayed as System, diagnostics expanded/collapsed/copied; [browser.json](browser.json) |

Raw logs are in this directory. The browser receipt and
[overview.png](overview.png), [collapsed.png](collapsed.png),
[expanded.png](expanded.png) are from the current local component fixture.
The browser evidence is not a deployed service or a real provider run.
The first zero-match runtime-resume invocation is excluded from evidence;
the corrected `authority` group above actually ran three scenarios.
The final state reconciliation regression also passed after correcting its typed trace fixture; it keeps the failed server result visible and preserves the matching live trace once. No full build, full CI, installation or deployment is claimed.

## Independent review repair

The independent review of `2615e48583bbe80d0f2754658ccd1410a561abd6` found a P2:
reconciled System failures retained live trace in state but were excluded from
workspace work bundles. Three renderer scenarios reproduce the missing bundle
([work-before.log](work-before.log)). Failed results now terminate their work
bundle while keeping System authorship; a failure never generates a Chat reply
step from diagnostic text. The scenarios cover no preceding tools, the same
turn's tools and a different turn's tools ([work-after.log](work-after.log)).
The five focused dashboard files subsequently pass 540 scenarios.

The browser now uses actual state reconciliation and `groupToolCalls=true`,
verifies retained thinking is visible, no Chat step is created from failure, and
diagnostics remain collapsed until opened. [work.png](work.png) and the updated
browser receipt capture that displayed work. This extends the earlier media-only
fixture proof; it remains local fixture evidence.

## Remaining scope

The TUI's persisted rich media needs a dedicated output projection: it now reads
failure authorship correctly and keeps upload attachment metadata, but its
ordinary assistant branch also does not display persisted image/voice blocks.
That UI limitation is not solved by removing a classifier. Continue that repair
and semantic review of every remaining Godfile candidate.

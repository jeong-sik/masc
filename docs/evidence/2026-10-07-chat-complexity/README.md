# Chat complexity and boundary audit

Audited commit: `5a9d7aeac2e609a5dab261204cf89825155860b6` (2026-10-07).
Scope: TUI chat rendering, state/journal transitions, live and replay event folds,
Codex, Claude Code, Antigravity and OpenAI-compatible/GLM stream paths.

This is a bug-discovery audit. Production fixes are not implied by this report.
No local Dune build, behavioral suite, PTY scenario or provider session was run.
The metadata/body defect was observed in operator-supplied screenshots. The
other findings are source-backed counterexamples with explicitly stated inputs
and configuration. They are not claimed as reproduced production incidents.

## Findings

| ID | Priority | Trigger and consequence | Evidence |
|---|---|---|---|
| UX1 | P2 | A user types only `엉...`, but their speech block also contains generated request ID and receipt text. Diagnostic metadata is indistinguishable from authored content. | User screenshots; `identify_chat_entries`, render_chat:2268-2290; pending construction:1840-1848 |
| F1 | P2 | Final reply history arrives before an overlapping partial journal page. The assistant row makes the TUI permanently stop fetching that still-open journal, losing final event reconciliation and termination. | [State lifecycle](state-lifecycle-audit.md), main:16317 |
| F2 | P2 | Two Keepers legitimately use the same operation ID. An unavailable or in-flight journal for one suppresses the other's journal because tracking omits the Keeper key. | [State lifecycle](state-lifecycle-audit.md), types:7082,7191 |
| F3 | P2 | A held journal supplies a settled visible answer. `/find` searches only the history rows left after that answer was suppressed in favor of the journal, and reports no match. Its scroll count also omits held blocks. | [Renderer search](renderer-search-audit.md), render_chat:2330,2350 |
| F4 | P2, conditional | With a separate serving domain, a newly published event overtakes the buffered events being drained at attachment. The client folds arrival order, potentially displaying text/tool events out of order. | [Transcript](transcript-audit.md), server stream:3598; independently challenged in [vendor audit](vendor-audit.md) |
| F5 | P2 | One accepted Claude response contains Text A, Thinking, Text B and a final reply containing A+B. Final reconciliation replaces only B, so A appears twice. Actual provider frequency was not measured. | [Transcript](transcript-audit.md), transcript:2438,2473 |
| F6 | P2 | A provider reports input/cache usage at message start, then output-only usage deltas. Start normalization drops input/cache and sparse updates replace rather than preserve prior counters. | [Transcript](transcript-audit.md), live:247, log:136, transcript:2059 |

Repairs, source-review identities, executed checks and remaining gaps are tracked
in [repair evidence](repair-evidence.md). Those later results do not alter this
audit's frozen baseline. The conditional serving-domain race is not generalized
to the default single-domain configuration.

## Complexity observations

`ast_complexity.ml` uses the installed OCaml 5.5.1 parser, not keyword counting.
`metrics.jsonl` contains the measured named function bindings; `metrics-summary.json`
records the frozen commit, inventory size and ranked results.

The source-decision score is `1 + if/loop decisions + (match arms - 1) + try
handlers + guarded cases + short-circuit boolean decisions`. Function-case arms
are included. The report also records source span, decision nesting, explicit
field/ref/table/buffer mutation sites, and distinct field/callee names. Callback
and nested-function decisions are included in the aggregate score, with a
separate score excluding nested function bodies. Bindings overlap: do not sum
these scores into a codebase total.

This is an AST-based approximation for prioritizing inspection, **not exact CFG
McCabe complexity, Sonar Cognitive Complexity, path coverage or a quality gate**.
It omits implicit exception edges, detailed pattern decision trees and dynamic
call paths. Deep boolean expression nesting can contribute to the nesting count.
No numeric limit is being introduced into product behavior or CI.

| Function | Lines | AST decision score | Excluding nested functions | Mutation sites |
|---|---:|---:|---:|---:|
| `render_keeper_message` | 1,483 | 220 | 111 | 17 |
| `apply_async_message` (all TUI surfaces) | 3,553 | 934 | 798 | 445 |
| transcript `apply_delta` | 245 | 66 | 60 | 44 |
| live `custom_deltas_unvalidated` | 206 | 58 | 58 | 0 |
| Codex `await_turn_terminal` | 387 | 52 | 52 | 17 |
| `keeper_message_waiting_requests` | 59 | 22 | 1 | 0 |
| `keeper_message_find_scroll` | 45 | 4 | 4 | 0 |

The search defect sits in a low-score function whose input excludes a whole
rendered source. The more useful risk is the duplicated projection contract:
render, search, source suppression, queue placement and journal termination each
make independent decisions about what a conversation contains or whether it is
complete. Reducing one function's branch count would not by itself fix that.

Method background: [NIST SP 500-235, Structured Testing](https://www.nist.gov/publications/structured-testing-testing-methodology-using-cyclomatic-complexity-metric).
Its control-flow approach informs inspection order; the audit additionally
checks cross-function state and identity invariants.

## Reproduce the measurement

Run from a separate checkout of `5a9d7aeac2e609a5dab261204cf89825155860b6`,
copying this report's `ast_complexity.ml` into that checkout first. Running the
command against another revision measures that revision, not the frozen baseline.
The repaired sample instead uses the commit and three files in
`repaired-projection-metrics-summary.json`.

```sh
ocaml -I +compiler-libs ocamlcommon.cma \
  docs/evidence/2026-10-07-chat-complexity/ast_complexity.ml \
  bin/masc_tui_render_chat.ml bin/masc_tui_message_layout.ml \
  bin/masc_tui_keeper_chat_live.ml bin/masc_tui_keeper_chat_log.ml \
  bin/masc_tui_keeper_chat_history.ml bin/masc_tui_keeper_chat_transcript.ml \
  bin/masc_tui_keeper_chat_queue.ml bin/masc_tui_types.ml bin/masc_tui.ml \
  lib/runtime/runtime_codex_app_server.ml lib/runtime/runtime_claude_code.ml \
  lib/runtime/runtime_antigravity.ml lib/keeper/keeper_chat_agent_core_stream_bridge.ml
```

The analyzer was executed successfully. This command parses source only; it does
not typecheck or execute MASC. Broader provider inspection is documented in the
vendor report and is not misrepresented as a metric measurement of every file.

## Repair boundaries suggested by the defects

- Share one typed conversation projection between drawing and search, preserving
  raw speech independently of metadata.
- Decide completion from operation/journal lifecycle, not the existence of an
  assistant row. Scope journal state by Keeper plus typed source.
- Preserve event order through the buffered-to-live handoff.
- Reconcile final text by response/message identity and content blocks, retaining
  commentary before tools without duplicating text around reasoning.
- Merge partial usage within a provider-message boundary; reset at the next one.

Unproven or guarded leads are explicitly excluded in the component reports.

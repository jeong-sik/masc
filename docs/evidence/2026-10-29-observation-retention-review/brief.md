# Design review request: recurring "state lost at boundaries" fix class

You are asked for an independent second opinion on a maintenance-strategy verdict. Challenge it directly; do not be agreeable.

## Repository context

`masc` — an OCaml multi-agent coordination server with a terminal UI (TUI), a web dashboard, and "Keeper" agents. Its written constitution (docs/constitution.xml) imposes:

- Add new state/fields/gates **only when durable truth is damaged** without them. No speculative mechanisms.
- No tests disconnected from real failures ("no heuristic checks unconnected to a functional failure").
- Evidence-based workflow; per-site minimal fixes are the norm.
- There is precedent for invariant-pinning tests: "the transcript is always the fold of the log" is pinned by a property test.

## Observation (from git history)

Last 500 commits: 202 fixes, of which **29 (~14%)** match the pattern "retain/preserve/keep X across Y" — an accepted observation or declaration is silently lost when some boundary is crossed. Eight representative fixes, mapped to mechanisms:

| Group | Mechanism | Examples |
|---|---|---|
| A | Context-rebuild paths (Resume/Start/replay/tool-reply) do not re-derive observations the live path accumulated | correlation keys lost after tool replies (#45853); Goal criterion lost through tool requests and held-session Resume (#45791); reasoning truncated across streaming boundaries and replay (#45950); provider-retry observation hidden after turn failure (#46327) |
| B | Interruption/restart treated as terminal, dropping live facts | execution ownership lost at interruption (#46132); declared (not yet booted) guests lost at server restart (#46168) |
| C | Concurrent-writer lifecycle FSM: error path overwrites a confirmed outcome | evidence export confirmed saves lost on lock-release failure (#46169) |
| D | Periodic refresh replaces whole state instead of merging activity fields | browser-lane selection dropped during page-refresh cadence (#46098) |

Related prior art: RFC-0099 (session lifecycle, transport layer) explicitly declares execution-boundary ownership out of scope, pointing to typed contracts in `lib/tool_types/tool_result.mli` and `lib/keeper/keeper_gate_replay.mli`.

## The verdict under review

1. A single generic retention layer/runtime mechanism is the wrong fix: the four mechanisms are genuinely heterogeneous, and the constitution forbids speculative state.
2. Each of the 29 per-site fixes was individually correct (minimal state added exactly where durable truth was damaged).
3. The class keeps recurring because nothing obligates a new/modified boundary path to prove equivalence with the live path.
4. Proposal: a short RFC (no runtime changes) declaring the invariant — *"an accepted observation or declaration survives every boundary that does not intentionally end it"* — plus an obligation: when adding or altering a boundary path, attach a round-trip property test (`rebuild(state) ⊇ accepted observations`). Cite the transcript-fold test as the pattern.

## Questions

a. Is the invariant the right abstraction, or is it misframed (too strong / too weak / wrong axis)?
b. Is "no new runtime layer" correct, or is there a cheap structural fix (e.g., a single append-only observation journal that all rebuild paths read) that would actually be justified despite the constitution?
c. What failure modes would the round-trip property-test obligation miss (e.g., boundaries that are intentionally lossy, performance, test flakiness, observation volume)?
d. Anything in the 8-fix → 4-mechanism mapping you would reclassify?
e. Concrete counter-proposals are welcome. If you think doing nothing (per-site fixes forever) is optimal, argue that.

Answer concisely and concretely; verdict first, then reasoning. If the proposal is fundamentally sound but needs adjustment, say exactly what to change.

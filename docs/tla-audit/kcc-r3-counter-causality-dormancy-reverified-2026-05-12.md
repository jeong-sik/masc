# KCC R-3 — KeeperCounterCausality.tla: future-design dormancy banner re-verified (first-entry audit)

**Date**: 2026-05-12 · **Iteration**: 76 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (first entry)
**Spec**: `specs/keeper-state-machine/KeeperCounterCausality.tla` (127 LOC, 2 vars, bug-model paired)
**OCaml**: none — the spec is a **future-design invariant**, not a runtime mirror
**Verdict**: **clean / dormant** — the spec's `STATUS: FUTURE-DESIGN INVARIANT` banner (written 2026-04-20, see #8795 / #8642 family) is still accurate on every claim it makes. No drift, nothing to implement, nothing to wire. This PR refreshes the banner's "as of" line with a 2026-05-12 re-verification and a brief expansion of each check, plus this memo.

## What the spec is

`KeeperCounterCausality.tla` models a single invariant the redesigned Agent Modal hover tooltip *would* need: every counter increment must be attributable to one causing event (`CausePresentWhenCounted == counter > 0 => last_cause \in CauserEvents`). The redesign (`.claude/plans/curried-moseying-whisper.md`) proposes a per-counter `{last_incremented_at, last_cause_event}` pair serialized from the state-machine handlers so a user hovering `compaction_count` sees "last +1 at 14:22:03, cause: Compaction_completed". The bug model (`BuggyBumpWithoutEvent`) is the "incremented site updated, attribution site not" drift that adding a new event would introduce.

This is **first-entry sub-class 5 (dormancy)** — and it was *already disclosed*: the banner is explicit, names the audit issue (#8795), tells the future implementer exactly what to do ("drop this banner and add the spec to the runner alongside the standard #8642-family OCaml<->TLA+ mapping comment"), and the spec is correctly kept out of `scripts/tla-check.sh`. There is nothing to fix — only to confirm the disclosure hasn't gone stale.

## Re-verification (2026-05-12) — all four checks still hold

| Banner claim (as of 2026-04-20) | 2026-05-12 result | Status |
|---|---|---|
| `rg "last_cause\|last_incremented\|last_bumped" lib/ -t ml` → 0 hits | still 0 hits | ✓ unchanged |
| `.claude/plans/curried-moseying-whisper.md` not wired | repo has **no `.claude/plans/` tree**; `rg "curried-moseying-whisper" .` matches only this spec file | ✓ — the redesign plan is referenced nowhere in the codebase (the `~/.claude/plans/curried-moseying-whisper.md` on the local machine is an unrelated session-plan artifact, not in the repo) |
| OCaml has the counters but no cause pair | `lib/dashboard/dashboard_http_keeper.ml:keepers_dashboard_json` serializes `("compaction_count", \`Int m.runtime.compaction_rt.count)` (lines 1204, 1771) — a plain int; `compaction_rt : compaction_runtime` (`lib/keeper/keeper_meta_contract.ml:314`) carries no `{last_incremented_at, last_cause_event}` field | ✓ unchanged |
| NOT in `scripts/tla-check.sh` runner | `rg "KeeperCounterCausality" scripts/*.sh` → no match | ✓ unchanged |
| `.cfg` / `-buggy.cfg` exist | `KeeperCounterCausality.cfg` + `KeeperCounterCausality-buggy.cfg` present (TTrace files from a past TLC run also present) | ✓ — the spec is self-checkable the moment it's added to a runner |

## Spec internal sanity (bonus — the spec itself is well-formed)

- `BumpFromEvent` is the only clean increment path and it always pairs `counter' = counter + 1` with `last_cause' = e` for `e \in CauserEvents` — exactly the invariant the implementation must preserve.
- `BuggyBumpWithoutEvent` increments without touching `last_cause`; from `Init` (`last_cause = "none"`) this immediately violates `CausePresentWhenCounted` because `"none" \notin CauserEvents`. So the buggy cfg is guaranteed to catch the modelled drift — the Bug-Model contract (clean OK / buggy violated) holds by construction.
- `NonCauserEvent` (`UNCHANGED vars` for `e \in EventKind \ CauserEvents`) models the common case where most events flow through the state machine without touching any given counter — important so `Fairness == WF_vars(BumpFromEvent)` doesn't force every event to bump.

## Trade-off / follow-up

- No fix-PR follow-up is owed. The single thing that would change this spec's status is the cause-stamping feature landing in the runtime — at which point the implementer (per the banner's own instruction) drops the `STATUS` banner, adds the `#8642`-family `OCaml ↔ TLA+ mapping` table, and adds `KeeperCounterCausality` to `scripts/tla-check.sh`. This memo + the refreshed banner keep the dormancy disclosure honest until then.
- This is the second dormancy spec confirmed clean by a first-entry audit (after the implemented-but-clean KCB R-1 iter 70). The corpus's future-design specs are well-disclosed; the audit value here is anti-staleness, not gap-finding.

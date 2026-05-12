# KAQ R-14 — KeeperApprovalQueue.tla: first-entry audit — model accurate; it projects onto the `submit_and_await` variant (the `submit_pending` no-fiber path is out of scope, undisclosed) and the bug-action comment misattributed the `entry.resolver = None` case — sub-class 1

**Date**: 2026-05-12 · **Iteration**: 89 (`/loop` FSM/TLA+/OCaml drift hunt) · **Phase**: R (first-entry audit of a previously-unaudited spec)
**Spec**: `specs/keeper-state-machine/KeeperApprovalQueue.tla` (144 LOC, bug-model paired) — operator-approval-queue control flow; pins "every suspended fiber on `Eio.Promise.await` eventually wakes (resolved or expired)"
**OCaml**: `lib/keeper/keeper_approval_queue.ml` (1402 LOC) — `submit_and_await`@997, `submit_pending`@1090, `expire_stale`@1336, `resolve`-side@~879; `type entry` with `resolver : Agent_sdk.Hooks.approval_decision Eio.Promise.u option`@74
**Verdict**: **Model accurate (FSM over `pending_count` / `suspended_fibers` / `submitted_total`; `Submit` ↑both, `Resolve`/`ExpireStale` ↓both, `Done` stutter; bug-action `ExpireStaleNoResolve` ↓`pending_count` only → `SafetyInvariant` violated). All cited symbols exist; the spec was already symbol-anchored (iter 64 N-2.a). Two small documentation imprecisions, both fixed comment-only: (1) the model projects onto the `submit_and_await` variant — `keeper_approval_queue.ml` has a *second* submit entry point, `submit_pending` (`~resolver:None` + an `on_resolution` callback, returns the id immediately — NO suspended fiber), whose failure mode is a dropped callback, not a permanently blocked fiber; that's a legitimate projection but wasn't disclosed in the mapping. (2) the `ExpireStaleNoResolve` body comment said it "maps to code paths where `entry.resolver` is None at expire time, OR a future refactor moves the cleanup before the resolve" — the first clause is a misattribution: a `None`-resolver entry is a `submit_pending` request with NO suspended fiber, so dropping it doesn't produce the modelled harm; the real regression is the second clause.** Model body byte-identical; TLC re-verified (clean = no error, 23 states / 10 distinct; buggy = `SafetyInvariant` violated).

## Why this spec

iter 86 (KeeperTurnSlot) / iter 87 (OperatorPauseBroadcast) / iter 88 (KeeperWorkPipeline) worked through never-first-entry-audited specs; KeeperApprovalQueue (144 LOC, bug-model paired) is the next, and it's an Eio-promise-suspension spec — exactly the kind where a "which variant does the model cover" question matters.

## What was checked

| Spec element | Runtime | Status |
|---|---|---|
| `Submit` (↑`pending_count`, ↑`suspended_fibers`) | `submit_and_await`@997 — `Eio.Promise.create ()`@1017, registers entry with `~resolver:(Some resolver)`@1034, then the caller blocks on `Eio.Promise.await` | ✓ — models the `submit_and_await` variant |
| `Resolve` (↓both) | operator/rule-engine path — `match entry.resolver with Some r -> Eio.Promise.resolve r decision`@~881-882, plus the `Fun.protect`-finally cleanup removes the `pending` entry | ✓ |
| `ExpireStale` (↓both) | `expire_stale`@1336 — `match entry.resolver with Some r -> Eio.Promise.resolve r (Agent_sdk.Hooks.Reject reason)`@1384-1385 (`Some` branch), `None -> f (Agent_sdk.Hooks.Reject reason)`@1389 (callback branch); both then drop the `pending` entry | ✓ — the model abstracts only the effect on the suspended-fiber population (the `Some resolver` branch) |
| `entry.resolver` | `type entry` field `resolver : Agent_sdk.Hooks.approval_decision Eio.Promise.u option`@74 | ✓ |
| bug-action `ExpireStaleNoResolve` (↓`pending_count` only) | a future refactor moving the `pending` cleanup before the `Eio.Promise.resolve resolver (Reject ...)` in `expire_stale`'s `Some` branch — leaves the suspended fiber blocked | ✓ — well-formed (drives `suspended_fibers > pending_count` → `SuspensionMatchesPending` false; if the queue then drains, `QuiescentImpliesResolved` false) |
| `.cfg` / `-buggy.cfg` | both present | ✓ |
| Bug-Model contract | clean = no error (23 states, 10 distinct); buggy = `SafetyInvariant` violated — re-verified this PR | ✓ — well-formed |
| line-ref drift | none — already symbol-anchored (iter 64 N-2.a; the preamble already records the +245..+413 line drift from iter 63 #14919 that prompted the symbol switch) | ✓ |

## The two doc imprecisions (sub-class 1: coverage gap — *disclosure-only*)

### (1) The `submit_and_await` vs `submit_pending` projection wasn't disclosed

`keeper_approval_queue.ml` has two submit entry points:
- `submit_and_await`@997 — creates an `Eio.Promise`, registers the entry with `~resolver:(Some resolver)`, then **blocks the caller on `Eio.Promise.await`**. The entry has a *suspended fiber*. This is the variant the spec models (`suspended_fibers` counts these).
- `submit_pending`@1090 — registers the entry with `~resolver:None` + `~on_resolution:(Some on_resolution)` (a callback), returns the id `: string` immediately. **No suspended fiber.** The decision is delivered later via the `on_resolution` callback. Its failure mode is a *dropped callback*, not a permanently blocked fiber — weaker, and out of scope here.

The original "Runtime entities modelled" block described `pending` as "Each entry carries a resolver that wakes the suspended fiber" — true only for the `submit_and_await` variant. **Fix**: the entity block now says each entry carries *either* a resolver (`submit_and_await`) *or* an `on_resolution` callback (`submit_pending`), and a new "Scope (which path is modelled)" paragraph spells out the projection and why the `submit_pending` path is out of scope. Same shape as the iter-86 KeeperTurnSlot alphabet-projection disclosure and the iter-78/79/80 `PhaseSet`-projection disclosures.

### (2) The `ExpireStaleNoResolve` comment misattributed the `entry.resolver = None` case

The bug-action comment said `ExpireStaleNoResolve` "maps to code paths where `entry.resolver` is None at expire time, or where a future refactor moves the cleanup before the resolve". The first clause is wrong: an `entry.resolver = None` entry is a `submit_pending` request — it has **no suspended fiber**, so `expire_stale` dropping it (its `None` branch already calls `f (Reject ...)`, but even if it didn't) wouldn't leave a fiber blocked, i.e. wouldn't produce the harm `ExpireStaleNoResolve` models. The real regression is the second clause: a future refactor moving the `pending` cleanup *before* the `Eio.Promise.resolve resolver (Reject ...)` in the `Some` branch (for a `submit_and_await` entry). **Fix**: rewrote the comment to name the `submit_and_await` / `Some resolver` branch as the regression site, and added an `NB:` noting that an `entry.resolver = None` entry is a `submit_pending` request with no suspended fiber (its weaker dropped-callback failure mode is out of scope, per the header).

## Sub-class placement & follow-up

- Class = **sub-class 1 (coverage gap), disclosure-only form** — the model is accurate for the variant it covers; only the documentation under-disclosed the projection, and the bug-action comment misattributed one runtime case. Comment-only fix.
- No follow-up PR owed. Comment-only — model body byte-identical; `specs/INDEX.md` regenerated (KeeperApprovalQueue content-hash bump `c54c2c2887ad` → `b06c654f89e4`). The spec is in the `make -C specs check-clean` runner; CI re-checks it.
- (Optional, low-priority) a future spec could add a second projection covering the `submit_pending` / `on_resolution`-callback path and its dropped-callback failure mode — but that's a different (weaker) safety property and probably not worth a model; the disclosure is sufficient.
- This is *not* an RFC-gated subsystem — it's an operator-approval *queue control-flow* spec; `keeper_approval_queue.ml` is the queue mechanism, not a credential/identity action handler (the approval *decisions* are consumed elsewhere). Not credential/keeper_gh/host_config, not repo_manager, not operator_control credential handlers, not keeper_sandbox/shell, not dashboard credential component, not .claude/hooks, not instructions/workflow. RFC-WAIVED.
- **Remaining never-first-entry-audited specs after this**: a few small ones (KeeperEventQueue, KeeperHeartbeat, KeeperTaskAcquisition, KeeperCircuitBreaker — depending on how "audited" is counted; several had partial entries earlier). Plus the standing follow-ups: KeeperWorkPipeline model-bug fix (iter 88), OperatorPauseBroadcast-buggy deadlock-vs-property (iter 87), the `\.ml:[0-9]` zero-tolerance lint (waiting on #14971 + #14975 merge).

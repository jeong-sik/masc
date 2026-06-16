---
rfc: "0239"
title: "Concurrency ownership model (per-site mutex/atomic → protection by construction)"
status: Draft
created: 2026-06-15
updated: 2026-06-15
author: vincent
supersedes: []
related: ["RFC-0059", "RFC-0225", "RFC-0237"]
implementation_prs: []
---

# RFC-0239 — Concurrency ownership model

## §1 Problem (evidence-grounded)

Over a three-day window (2026-06-12 .. 2026-06-15) masc accumulated a burst of
data-race fixes. Each fix wraps one piece of module-global mutable state in an
`Eio.Mutex.t` or replaces a `ref` with an `Atomic.t`. The fixes are individually
correct. The pattern is the problem: nothing in the type system marks which
mutable state is shared across concurrent execution contexts, so each site is
discovered, diagnosed, and patched by hand — an N-of-M migration with no `M`
known in advance.

### §1.1 The campaign (15 commits, ~22 distinct sites)

All commits are on `main`, located by `git log --since` plus
`git log -S "Eio.Mutex"` / `git log -S "Atomic.make"`, then filtered to remove
the Discord-thread feature commits (`thread` keyword false positives) and the
`thread`-through plumbing commit `296c109cf` (Provider_config, not thread-safety).

| SHA | site(s) made concurrency-safe | primitive |
|-----|-------------------------------|-----------|
| `b0fa91bcf` | `lib/transport_bridge.ml` provider registry | `Atomic.t` record |
| `74f4dfadd` | `lib/tool_operator.ml` operator tool registry | `Atomic.t` record |
| `e96de3a7c` | `lib/keeper/keeper_turn_fsm.ml` `last_transition_at`; `lib/keeper/keeper_turn_runtime_budget.ml` `runtime_budget_logged` | `Eio.Mutex.t` ×2 |
| `9a2bd58cd` | `lib/otel_dispatch_hook/otel_dispatch_hook.ml` + `lib/otel_spans/otel_spans.ml` override refs | `Atomic.t` ×3 |
| `e21457975` | `lib/voice/voice_bridge.ml` health cache | `Atomic.t` record |
| `d9c9c4d05` | `lib/mcp_server.ml` `workspace_config` (+ call-site reads across `lib/server/*`) | `Atomic.t` |
| `6554d84cf` | `lib/board/board_moderation.ml` global store | `Eio.Mutex.t` |
| `0e0755d94` | `lib/streamable_http.ml` `session.last_seen` | `Atomic.t` |
| `220047b5a` | `lib/dashboard/dashboard_harness_health.ml` JSONL stores (`pre_compact_store`, `wake_payload_store`) | `Eio.Mutex.t` + `Atomic.t` |
| `9ad99d0af` | `lib/server/lsp_message_router.ml` id counter + pending table | `Atomic.t` + table |
| `ffa95ede6` | `lib/server/server_dashboard_http_memory_subsystems.ml` entry cache | `Eio.Mutex.t` |
| `442cf22c2` | `lib/cdal/adversarial_eval.ml` finding-id counters | `Atomic.t` |
| `7045d5a56` | `lib/gate/channel_gate_discord_state.ml` thread-parent table | `Eio.Mutex.t` |
| `913567fbb` | `lib/keeper/keeper_accountability.ml` snapshot cache refresh | `Eio.Mutex.t` |
| `1449fc061` | `lib/server/server_auth.ml` stale-token warn dedup table | `Eio.Mutex.t` |

Counting distinct protected mutable-state objects (not call-site files), the
campaign added 22 declarations: 11 `Eio.Mutex.create ()` and 11 `Atomic.make`,
enumerated from the added `+` lines:

```
git show <15 SHAs> | grep '^+' | grep -E 'Eio.Mutex.create|Atomic.make' | sort | uniq -c
```

The audit estimate of "~23" is accurate. This RFC uses the exact figure 22.

### §1.2 The smoking gun: an invalidated assumption, replicated per site

`keeper_turn_fsm.ml` (`e96de3a7c`) replaced this comment verbatim:

```
- Single-domain Eio means Hashtbl ops are atomic at OCaml level (no
- preemption inside a single op), so no explicit mutex is required.
+ Keeper turns run on concurrent Eio fibers, so serialize Hashtbl access
+ with an [Eio.Mutex.t].
```

The same "single-domain → no lock needed" assumption is documented across the
actor primitives that were *supposed* to own this state:

- `lib/core/actor_mailbox.mli:6` — "Single-Domain only — PR-6 wraps these in a
  `Domain_pool` for parallel dispatch."
- `lib/core/actor_types.mli:3` — "Single-Domain only. RFC-0059 Phase 2 PR-5".

That assumption is false today. The runtime ships a process-wide multi-domain
executor:

- `lib/core/domain_pool.ml` / `.mli` — a policy layer over
  `Eio.Executor_pool`, "PR-6 of RFC-0059 introduces this module as a primitive.
  PR-7 (keeper actor migration) and PR-8 (repo sync async) consume it for
  parallel actor dispatch and parallel git command execution"
  (`domain_pool.mli:20`).
- `recommended_domain_count` spawns `max 2 (recommended - 1)` worker domains
  (`domain_pool.mli:30`).
- `lib/orchestrator.mli:26` and `lib/server/server_runtime_bootstrap.mli:28`
  thread a `Domain_manager.t` through bootstrap.

Concurrently, the codebase forks fibers at 117 sites
(`rg -c 'Fiber.fork|Fiber.both|Fiber.all|Fiber.fork_daemon' lib/`). Even within
a single domain, `Eio.Mutex.use_rw` is required across a read-then-write because
`Eio.Stream.take` / IO inside the critical region yields to peer fibers
(`server_auth.ml` `1449fc061` had to hand-write double-checked locking: `use_ro`
to test the cooldown, then re-check under `use_rw` because "another fiber may
have just logged").

### §1.3 The failure mode: no type distinguishes shared from fiber-local

OCaml's type system says nothing about *who may touch* a `ref`, `Hashtbl.t`, or
`Atomic.t`. A function-local `Hashtbl.create` inside one fiber is private and
safe; an identical `let tbl = Hashtbl.create 64` at module top level is shared
across every fiber and domain that calls the module — and the two are
syntactically indistinguishable. The compiler cannot flag the unsafe one. So:

- Adding a new `Fiber.fork` or a `Domain_pool.submit` can silently make a
  previously-safe module-global racy, with **no compile error**.
- Discovery is by crash, by audit, or not at all. The 15-commit campaign is the
  audit path; the `total_turns` 385→370 rewind documented in RFC-0237 §1 /
  RFC-0225 §3.2 is the crash path.
- Each fix is bespoke (mutex vs atomic; whether double-checked locking is
  needed; whether `~protect:true` is needed for cancellation safety). There is
  no shared abstraction, so each site re-derives the same reasoning and can get
  it subtly wrong (e.g. read-modify-write under two separate `Atomic` ops is not
  atomic; `use_ro` for a region that mutates is wrong).

The current state of the codebase makes the hazard quantifiable:
`rg 'Hashtbl.create' lib/ | wc -l` = 376 (many function-local and safe);
top-level `Atomic.make` ≈ 82; top-level `ref` ≈ 84; 90 modules pair a Hashtbl
with a mutex/atomic. The denominator of "module-global mutable state reachable
from concurrent contexts" is unknown, which is exactly why this is an N-of-M
migration that never terminates by construction.

### §1.4 The abstraction that should already own this: RFC-0059 actors, unadopted

RFC-0059 Phase 2 built an actor model whose stated invariant is the solution to
this problem (`actor_types.mli:8`):

> Internal state is owned by the actor's own loop fiber (closure-captured) —
> deliberately not exposed in the type — to enforce the "messages are the only
> inputs" invariant of the actor model. External code interacts via
> `Actor_mailbox.send`; reading internal state requires sending a query message.

State owned by a single loop fiber and reachable only through a typed mailbox
needs no lock — protection is structural. But `Actor_mailbox.run` /
`Actor_mailbox.create` have **zero production consumers**:

```
rg 'Actor_mailbox\.(run|create|send)' lib/ bin/ test/ | grep -v 'lib/core/actor_mailbox'
# → only doc-comment references in actor_types.mli and tests in test_actor_mailbox.ml
```

RFC-0059 PR-7 (keeper heartbeat → actor) and PR-8 (repo sync async) — the
consumers named in `domain_pool.mli:20` — never landed. The infrastructure to
make this state safe-by-construction exists and is idle, while the runtime
acquired multi-domain parallelism (PR-6 did land) that the per-site campaign is
now chasing.

## §2 Goal and non-goals

**Goal.** Make shared mutable state protected *by construction*: the type system
distinguishes "shared, requires synchronized access" from "fiber-local, free",
so that adding concurrency cannot silently introduce a race, and so the set of
sites needing review is enumerable rather than discovered by crash.

**Non-goals.**

- Not a rewrite of correct existing locks. The 22 campaign fixes stay; this RFC
  changes how *future* shared state is declared and provides a path to migrate
  the highest-churn existing sites.
- Not a ban on `Atomic.t`. A single-word counter behind one `Atomic` op is a
  legitimate, lock-free, correctly-typed shared cell. The hazard is multi-step
  read-modify-write and compound state, not atomics per se.
- Not a performance RFC. No throughput claim is made or required; the lock
  contention of these low-frequency control-plane tables is not the motivation.

## §3 Design options

Three options, evaluated against Rich Hickey's "simple made easy": *simple* =
unentangled (one concept, one place), not *easy* = familiar/at-hand. A per-site
mutex is easy (drop it in) but complex (couples the lock discipline to every
caller and braids it through the call graph).

### §3.1 Option A — `Shared.t` owned-resource module (typed lock capability)

A `lib/core/shared.ml` wrapper that owns a value and a mutex together; the value
is reachable only through `with_read` / `with_write` callbacks. The mutex is not
a separate top-level binding the caller can forget.

```ocaml
module Shared : sig
  type 'a t
  val create : 'a -> 'a t
  val with_read  : 'a t -> ('a -> 'b) -> 'b          (* Eio.Mutex.use_ro *)
  val with_write : 'a t -> ('a -> 'a * 'b) -> 'b      (* use_rw ~protect:true; new state returned *)
  val update     : 'a t -> ('a -> 'a) -> unit
end
```

A lint/grep gate (§4) then asserts: no top-level `Hashtbl.create`, `ref`, or
`Atomic.make` in `lib/` except inside `Shared.create` (or an allowlist of
audited single-word atomics).

- **Pro (simple).** One concept owns "value + its lock"; the lock cannot be
  acquired in the wrong mode or forgotten because the only way to read/write is
  through the wrapper. `with_write` returning the new state forces the
  read-modify-write to be one critical section, eliminating the
  `Atomic.get`-then-`Atomic.set` race class. Mechanical to apply; small diff per
  site; reuses the existing `Eio.Mutex` semantics the team already understands.
- **Pro (gate-able).** The "no bare module-global mutable" lint is decidable by
  AST/grep, so the migration has a measurable, monotonic completion criterion
  (count of violations → 0).
- **Con (does not eliminate the lock).** It is still lock-based serialization,
  just packaged. Contention, deadlock-on-nested-`with_write`, and "held the lock
  across an IO that yields for 30s" remain possible — the wrapper makes them
  *visible* (the callback body is the critical section) but does not make them
  *impossible*. Hickey's caution applies: it reduces complexity but does not
  remove the underlying complecting of shared state with control flow.
- **Con (callback-colored).** Every access becomes a closure; deeply nested
  `with_write` invites accidental lock reentrancy (`Eio.Mutex` is not
  reentrant → deadlock). Needs a documented "no nested Shared access" rule, which
  is a discipline, not a type guarantee.
- **Con (does not address compound invariants across two `Shared.t`).** Two
  separately-locked shared cells that must be updated together reintroduce
  lock-ordering reasoning the wrapper cannot enforce.

### §3.2 Option B — agent/subsystem-as-actor (message passing, extend RFC-0059)

Adopt the idle RFC-0059 actor model: each piece of long-lived mutable
control-plane state (keeper turn FSM bookkeeping, board moderation store, otel
override registry, session table) becomes the private state of one actor loop
fiber, mutated only by messages on a typed `Actor_mailbox`. No mutex, because no
shared access — the loop fiber is the single writer.

- **Pro (simple, Hickey-aligned).** This is the un-complecting move: shared state
  and concurrency are *separated* — state lives in one place (the loop), and
  concurrency is a queue of values, not interleaved memory access. The handler
  pattern-matches a closed message sum, so "forgot to handle a new mutation"
  is a compile error (`actor_types.mli:14`), unlike a forgotten lock which is a
  silent race.
- **Pro (already specced + built).** `Actor_mailbox` / `Actor_types` exist with
  bounded inbox + backpressure; `Domain_pool` exists to host actors on worker
  domains. This RFC would land RFC-0059's deferred PR-7/PR-8 rather than invent
  new infrastructure.
- **Con (largest blast radius).** Converting a synchronous `lookup tbl k` into
  "send a query message, await an `Eio.Promise` reply" changes call-site shape
  everywhere and adds latency for read-heavy paths (every dashboard read of
  keeper state becomes a round-trip). The campaign's tables are frequently read
  on hot HTTP paths; an actor round-trip per read is a real cost.
- **Con (deadlock by mailbox cycle).** Actor A querying actor B which queries A
  is a distributed deadlock that no type catches; bounded inboxes turn it into a
  backpressure stall. Replaces lock-ordering reasoning with mailbox-topology
  reasoning — different complexity, not obviously less.
- **Con (migration cost dominates).** 22 sites of heterogeneous shape (counters,
  caches, registries, dedup tables) do not all fit "one long-lived stateful
  loop." A dedup table that is logically a pure memoization does not want an
  actor; forcing it into one is over-abstraction (the inverse anti-pattern).

### §3.3 Option C — typed `Domain_safe` phantom + `Atomic`-only shared scalars

Encode shared-ness in a phantom type: `('a, [`Shared]) cell` vs
`('a, [`Local]) cell`, where only `Shared` cells expose synchronized accessors,
and restrict shared compound state to immutable snapshots swapped via a single
`Atomic.t` (read = `Atomic.get` returns an immutable value; write = build a new
immutable value, `Atomic.set`, or CAS-loop for read-modify-write).

- **Pro (lock-free reads, immutable by construction).** Readers never block;
  the value they get is a consistent immutable snapshot. This is the pattern
  several campaign fixes already converged on independently (`transport_bridge`
  / `tool_operator` "atomic *record*", `voice_bridge` health-cache record). It
  matches Hickey directly: values, not places.
- **Pro (CAS makes RMW honest).** A `compare_and_set` loop forces the
  read-modify-write to be expressed as such, eliminating the two-op atomic race
  that a naive `Atomic.get; Atomic.set` allows.
- **Con (write contention / retry storms).** Under frequent writers, the CAS
  loop livelocks or wastes work rebuilding snapshots; for a high-write dedup
  table this is worse than a mutex. Suited to read-mostly state only.
- **Con (whole-value replacement cost).** A 64-entry table updated one key at a
  time becomes "copy the map, insert, CAS" — fine for an immutable `Map`,
  wasteful for a mutable `Hashtbl`. Requires migrating `Hashtbl` to immutable
  `Map`, a larger change than wrapping it.
- **Con (phantom types are advisory, not load-bearing here).** The phantom only
  helps if every construction goes through the typed constructor; a stray
  `Atomic.make` still compiles. So Option C *still* needs the §4 grep gate to be
  enforceable — the type alone does not close the hole.

### §3.4 Recommendation

**Adopt Option A (`Shared.t`) as the default for the existing 22 + future
sites, with Option C (immutable-snapshot `Atomic`) as the sanctioned pattern for
read-mostly scalars/records, and reserve Option B (actors) for the small number
of genuinely long-lived stateful loops where RFC-0059 already intended it
(keeper heartbeat/turn coordination).**

Rationale: the failure mode in §1 is *"shared mutable state is
indistinguishable from local, so it is missed."* The minimal fix for that exact
failure is to make shared mutable state syntactically distinct and
gate-enforceable (Option A + §4 lint), which is decidable and has a terminating
completion metric. Option B is the most simple in Hickey's sense but its
migration cost and read-latency change are disproportionate to a control-plane
that is mostly read-mostly tables; forcing all 22 into actors is the
over-abstraction the project's own guidance warns against ("무리한 추상화를 하느니
코드 반복"). Option C is correct for the records the campaign already converted
this way, so it is folded in as a recommended sub-pattern rather than a
competing whole. Option B stays on the table for keeper coordination as the
already-specced RFC-0059 destination, sequenced after the lint exists.

## §4 Validation — proving no un-synchronized shared state remains

The completion criterion must be decidable, not "we think we got them all."

1. **Grep/lint gate (primary, decidable).** A CI check
   (`ci/concurrency-ownership-check.sh`) asserts: in `lib/`, every top-level
   `Hashtbl.create`, `ref`, and `Atomic.make` is either (a) inside
   `Shared.create`, (b) an immutable-snapshot atomic registered in an explicit
   allowlist with a one-line justification, or (c) provably function-local
   (inside a `let ... =` body that is not a module-level binding). Heuristic
   seed (to be tightened to AST in implementation):

   ```
   rg -n '^let [a-z_][a-zA-Z0-9_]* *(:[^=]*)?= *(ref |Atomic.make|Hashtbl.create)' lib/
   ```

   The gate's violation count is the migration's burn-down number; "done" =
   count reaches the allowlist size and stays there (ratchet, like masc's
   existing code-smell baseline). This makes the N-of-M *enumerable*: M is the
   grep count, not an unknown.

2. **Compiler-enforced access (Option A guarantee).** Once a site is wrapped, its
   underlying `Hashtbl`/`ref` is not exported from `Shared.t`; the only way to
   touch it is `with_read`/`with_write`. A caller that bypasses the lock will not
   type-check because the raw value has no path. This is the "by construction"
   half — the grep gate finds un-migrated sites, the type closes migrated ones.

3. **TLA+ model for the actor sub-design (Option B sites only).** For any state
   migrated to RFC-0059 actors, model the mailbox protocol per CLAUDE.md
   §"TLA+ Bug Model": a clean `Next` that preserves a `SingleWriter` invariant
   (only the loop fiber mutates state) and a `NextBuggy = Next \/ DirectMutation`
   where an external fiber writes state directly; the `SingleWriter` invariant
   must hold under clean and be violated under buggy. This proves the actor
   boundary actually excludes external mutation, rather than asserting it in a
   comment. Not required for Option A/C sites (the type system is the proof
   there).

4. **Regression characterization, not per-site duplication.** One
   characterization test per *primitive* (`Shared.with_write` runs the
   callback under the lock; a concurrent two-fiber increment via `Shared` does
   not lose updates), plus the existing site-specific tests already added by the
   campaign (e.g. `test_keeper_accountability`, `test_adversarial_eval`,
   `test_channel_gate_discord_state`). The point of by-construction protection is
   that we do *not* need 22 near-identical race tests — the abstraction is tested
   once and the compiler guarantees its use.

## §5 Boundary

- **In scope.** A `lib/core/shared.ml` primitive; a CI grep/lint gate enumerating
  un-synchronized module-global mutable state; a migration plan for the 22
  campaign sites and any sites the gate surfaces; an Option-B path note for
  keeper coordination state that points at RFC-0059's deferred PRs.
- **Out of scope.** Rewriting correct existing `Atomic.t` scalar counters;
  performance tuning of lock-free vs lock-based access; the keeper actor
  migration itself (separate PR series under RFC-0059 if Option B is chosen for
  a given subsystem); any credential / auth / sandbox surface (none touched —
  `server_auth.ml`'s dedup table is a log-cooldown cache, not a credential).
- **Risk.** The grep gate can false-positive on legitimately fiber-local
  top-level bindings (rare) and false-negative on shared state hidden behind a
  functor or first-class module. The implementation must tighten the seed grep to
  an AST query (e.g. via `ppxlib` or the existing code-smell tooling) before the
  gate is made blocking; until then it runs advisory.

## §6 Alternatives considered

- **Keep patching per-site (status quo).** Rejected: this is the N-of-M
  anti-pattern the audit flagged (CLAUDE.md §"워크어라운드 거부 기준" #3). M is
  unknown, the migration never terminates, and each new `Fiber.fork`/
  `Domain_pool.submit` can reopen a fixed site with no compiler signal.
- **A single global GIL-style lock around all shared state.** Rejected:
  re-complects everything onto one lock, serializes unrelated subsystems, and
  reintroduces the multi-domain parallelism cost that `Domain_pool` was built to
  gain. The opposite of the goal.
- **Ban multi-domain (`Domain_pool`) and rely on single-domain fiber
  cooperation.** Rejected on two grounds: (1) it does not even fix the bug —
  `1449fc061` proved a read-then-write across a yielding region races *within*
  one domain; (2) it discards landed RFC-0059 PR-6 parallelism for git/actor
  dispatch. Single-domain is a comment-level assumption that was already false.
- **Trust code review to catch new shared state.** Rejected: the 22 sites are
  the evidence that review did not catch them; an enumerable lint gate is the
  only mechanism that gives a monotonic completion metric.

## §7 RFC-0059 / RFC-0225 / RFC-0237 alignment

- **RFC-0059.** This RFC revives RFC-0059's actor invariant
  (`actor_types.mli:8`) as the structural answer for the subset of state that
  fits an actor (Option B), and treats the never-landed PR-7/PR-8 as the
  sequenced follow-on for keeper coordination state.
- **RFC-0225 / RFC-0237.** Those closed one concrete instance of the same class:
  a concurrent write (the `~force` last-writer-wins path) that rewound a
  cumulative counter. RFC-0237 fixed it by routing through CAS+merge (an
  Option-C-shaped immutable-snapshot move). This RFC generalizes that posture
  from "the counter" to "all module-global mutable state": make the unsafe write
  unrepresentable rather than fixing each rewind after it is observed.

## §8 Ledger / index note (non-blocking)

This RFC takes `0239`. `docs/rfc/.next-number` reads `0238` (the
`RFC-0238` file already exists on disk, a pre-existing ledger/disk drift); index
and ledger reconciliation is handled separately by the maintainer to avoid
merge conflicts on `docs/rfc/README.md`. This document does not edit the index.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>

# RFC-0314 — Keeper Recurring Producer (register the autonomous-repeat tasks the runtime already dispatches)

- Status: Draft
- Area: `lib/keeper/keeper_recurring.ml` (registry), `lib/keeper/keeper_heartbeat_loop_dispatch_recurring.ml` (consumer, already wired), MCP tool surface (`lib/tool_schemas/`, `lib/keeper_tool_surfaces.ml`), dashboard projection `lib/server_keeper_background.ml`
- Builds on / touches: the keeper autonomous-background design (`docs/design/keeper-autonomous-background-goal-matrix.html`), PR #23543 (the display + projection half)
- Evidence base: adversarial self-review 2026-07-07 — `rg "Keeper_recurring.add" lib/ bin/` returns **zero** production call sites; the only callers are `test/test_keeper_recurring.ml` and `test/test_server_keeper_background.ml`.

## Problem (audited)

`Keeper_recurring` is a half-wired subsystem:

- **Consumer exists and runs live.** `keeper_heartbeat_loop_dispatch_recurring.ml` calls `Keeper_recurring.reenable_due_tasks` then `Keeper_recurring.dispatch_due` on every keepalive cycle, executing due tasks (`Broadcast` today) and updating `last_run_ts` / `run_count` / `failure_count`.
- **Producer does not exist.** `Keeper_recurring.add` — the only registration entry point — has **no caller in `lib/` or `bin/`**. No MCP tool, no config seed, no bootstrap path registers a recurring task. The module docstring says *"Re-register via MCP tools after restart if needed,"* but that tool was never built (or was removed).

Consequence: `Keeper_recurring.list_all ~base_path` is **always empty in production**. Any surface that reads it — including the `server_keeper_background` dashboard projection added in PR #23543 — renders nothing. The dispatch machinery is dead code in practice because nothing feeds it.

This is why PR #23543's panel was **held**: shipping an always-empty panel would present a working feature that never has data.

## Boundary and principles

- **MASC owns this; OAS is untouched.** Recurring tasks are a keeper-workspace concept. No dependency is added to `lib/keeper_runtime` provider paths or OAS.
- **Not a pause/existence lever.** A recurring task is autonomous *activity*, not a constraint. It never pauses or gates a keeper (consistent with RFC-0313). A failing task auto-disables after `max_failures` and is re-enabled by the heartbeat — it never propagates to keeper existence.
- **Judgment stays at the LLM boundary.** Whether a keeper *should* register a recurring watch is a keeper decision (it calls the tool), not a heuristic in the runtime.
- **No new deterministic scheduler.** Cadence-based, time-anchored jobs already have a home in `lib/schedule` (Interval recurrence). This RFC is only for the keeper-native, in-memory, broadcast-style repeat that `keeper_recurring` already models — not a second scheduler.

## Proposal

Add the missing producer as a typed MCP tool surface, mirroring existing keeper self-service tools.

1. **MCP tools** (dashboard-and-keeper visible):
   - `masc_recurring_add` — `{ label: string; interval_sec: int (>0); action: <closed variant> }` → registers via `Keeper_recurring.add ~base_path ~keeper_name:<caller>`. `base_path` comes from the authenticated workspace context; `keeper_name` is bound to the calling actor (a keeper registers its own tasks; it cannot register for another).
   - `masc_recurring_remove` — `{ id: string }` → `Keeper_recurring.remove ~base_path`.
   - `masc_recurring_list` — read-only, returns the caller's tasks.
2. **Action variant stays closed.** `Keeper_recurring.action` remains a sum type (`Broadcast` today). New actions are added by extending the variant, never by a string field — the projection's `action_kind_to_string` and the tool parser both fail to compile on an unhandled variant.
3. **Persistence decision (open question).** Tasks are in-memory and die on restart. Either (a) keep ephemeral and document that keepers re-register on wake, or (b) persist under `.masc/keeper/<name>/recurring.json` and reload on register. Recommendation: start ephemeral (a) — matches current semantics; add persistence only if operators report churn.
4. **Unblock the display half.** Once the producer exists, un-hold PR #23543's `KeeperBackgroundPanel` (backend projection + API type already merged) so the surface renders real data.

## Non-goals

- Cron/daily time-anchored jobs (that is `lib/schedule`).
- Cross-keeper task registration.
- Any pause/existence coupling.

## Verification

- Tool round-trip: `add` → heartbeat `dispatch_due` fires the action → `list` reflects `run_count`/`last_run_ts` → `server_keeper_background` projection surfaces it non-empty.
- Boundary: a keeper cannot register a task for another keeper (actor binding test).
- Failure path: a task exceeding `max_failures` auto-disables and is re-enabled by the heartbeat (existing `test_keeper_recurring.ml` behavior), never touching keeper phase.
- Exhaustiveness: adding a new `action` variant fails to compile in both the tool parser and the projection until handled.

## Rollback

The tools are additive and read/registration-only. Removing the tool surface reverts to the current (producer-less) state; the projection returns to always-empty. No data migration.

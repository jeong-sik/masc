---
rfc: "schedule-history-and-outcome"
status: Draft
---

# RFC — A schedule's past and its result

- Status: Draft
- Decision driver: an operator asked where a schedule's usage, inputs, outputs,
  and past runs are read, and the answer was nowhere. The inputs are there; the
  rest is either unprojected or unrecorded, and the surface reports the three
  cases in the same words.
- Area: `lib/server/server_dashboard_schedule_projection.ml`,
  `lib/schedule/schedule_store.mli`, `bin/masc_tui_render.ml`
  (`schedule_detail_lines`), `bin/masc_tui_loader.ml`, and — for C only —
  whatever stamps a turn with the stimulus that started it.

## What an operator can read today (measured)

Read from the live server at `127.0.0.1:8935` on 2026-09-01.

`GET /api/v1/dashboard/scheduled-automation`

```
status: ok
request_count: 323   requests: 20   request_limit: 20   truncated: true
counts: cancelled 217, succeeded 95, scheduled 10, expired 1,
        due 0, running 0, failed 0
fsm: active_count 10, terminal_count 313
payload_target: keeper:kidsnote 9, keeper:sangsu 4, keeper:edgar.a.poe 4,
                keeper:analyst 1, keeper:code-reviewer 1, keeper:taskmaster 1
```

Three separate gaps, at three different costs.

| | What is missing | Where it already exists |
|---|---|---|
| A | Every retained wake but the newest | `Schedule_store.state.wakes` holds up to 32 per schedule |
| B | 303 of 323 requests | The store holds them; the projection caps at 20 |
| C | What the wake produced | Nowhere: no turn carries the schedule's identity |

### A — the wake history is stored and not projected

`Schedule_store.state` is `{ version; updated_at; schedules; wakes }`. A wake
record carries `started_at`, `finished_at`, `due_at`, `payload_digest`,
`status`, `detail`, and `error`. The store keeps every in-flight wake and, per
schedule, the newest `terminal_wakes_retained_per_schedule = 32` terminal ones
(`schedule_store.ml`, `prune_wakes`); the list is newest-first because each new
wake is consed onto it.

The projection calls `Schedule_store.last_wake_for_schedule_instance`, which is
a `List.find_opt` returning the first match, and emits that one row. So the
detail pane can only ever say `LAST WAKE`: of the up-to-32 attempts the store
kept, an operator reads one.

Nothing needs to be recorded for A. It is a projection that was never written.
The 32 is a real ceiling and this RFC does not raise it -- it makes the
difference between 1 and 32 readable, and says which of the two numbers a
reader is looking at.

### B — the page is capped and the cap is invisible where it matters

`schedule_projection_request_limit = 20`, active rows sorted first. With ten
active requests, the page carries ten terminal rows out of 313.

The standalone Schedules surface words this honestly
(`Requests: 323  (page shows first 20)`). The selected Keeper's Automation tab
does not: it filters the same 20-row page by `payload_target = "keeper:<name>"`
and, matching nothing, said `(no schedules for this Keeper)`. That sentence
reports an unobserved store as an empty one. A separate change makes the tab
say which of the two it is; it does not let the operator read the rows.

### C — the turn is reached and then loses its name

The first draft of this section said no turn carries the schedule that started
it. Reading the code changed the shape of the gap, and the correction matters
because it moves the work.

The chain from a schedule to a turn **exists and is already projected**. A live
schedule row carries `keeper_reaction_evidence`:

```
{"projection_status": "...", "source": "keeper_reaction_ledger",
 "keeper_name": "sangsu", "schedule_id": "sched-757df3...",
 "stimulus": "schedule_due", "reaction_kind": "turn_started",
 "stimulus_id": "dc125b31...", "stimulus_seen": ..., "turn_started_seen": ...}
```

So an operator can already read: this schedule fired, the stimulus was seen, a
turn started, and here is when. What cannot be read is **which turn**.

`Keeper_reaction_ledger.event_queue_turn_started_json` writes `stimulus_id`,
`post_id`, `stimulus_kind`, and `recorded_at`. It writes no turn identity, and
it cannot: `record_replay_owned_turn_started_reactions` runs in
`keeper_heartbeat_loop.ml` *before* `run_keeper_cycle`, and
`Keeper_unified_turn.turn_success` returns only `keeper_meta` afterwards.
Neither side of that call has a turn identity to record, because **no durable
turn identity exists**.

That is the real finding. The join is missing not because the schedule side
forgot to carry an id, but because the thing it would point at has no name. The
detail pane states the consequence in the two lines it has:

```
Attribution   wake/turn only; no schedule-to-tool/result join
Inspect       Keeper Calls or Activity after the recorded turn start
```

That is honest, and it makes the operator do a join by hand over keeper name
and a timestamp — the one join a reader cannot verify, because two schedules
due in the same minute are indistinguishable afterwards.

## Decision

- **D1 — the exact-schedule lookup returns the wake list, newest first.**
  `scheduled_automation_exact_lookup_json` already reads the whole store for one
  `schedule_id` and is not on the aggregate's cache. It gains a `wakes` array of
  the records for that `schedule_instance_id`, bounded by an explicit limit that
  the response states alongside the total, the way the aggregate states
  `request_count` against `request_limit`. The aggregate is unchanged: the fleet
  page has no room for per-row history and no reader for it.

- **D2 — the detail pane reads wakes, and the surface fetches the exact
  lookup.** `LAST WAKE` becomes `WAKES (n of m)` listing status, started,
  finished, and error per attempt. The TUI's schedule detail currently renders
  from the aggregate row it already has; under D1 it loads the exact lookup for
  the selected `schedule_id`, which is also what makes D3 reachable.

- **D3 — the exact lookup takes a target, so a Keeper's schedules are complete.**
  A `payload_target` selector on the aggregate route returns that target's
  requests without the fleet-wide cap standing between them and the reader. The
  Keeper detail Automation tab asks for `keeper:<name>` instead of filtering a
  page it did not choose. The fleet page keeps its cap and its shared cache; a
  selector bypasses the aggregate cache exactly as the `schedule_id` lookup
  already does.

- **D4 — a turn gets a durable identity, and the reaction that starts it
  records that identity.** Not the reverse. The schedule side already carries
  `stimulus_id` and the ledger already binds it to `turn_started`; adding a
  schedule id to a turn would duplicate a pointer that exists. What is absent
  is a name for the turn, so the existing pointer has nothing to point at.

  This is the one part of this RFC that adds durable state, and it is the case
  the project's rule admits: "this work happened because that schedule fired"
  is currently reconstructed by a human comparing a `turn_started` timestamp
  against Keeper Calls, and two schedules due in the same minute are
  indistinguishable afterwards. A reconstruction is not evidence.

  D4 does **not** introduce a schedule-to-tool join table. The turn carries a
  name; the join is a read.

  **Cost, measured rather than assumed.** The identity has to be minted at the
  turn boundary and travel two ways: back to the `turn_started` reaction that
  is written before the cycle, and forward onto whatever a reader would filter
  Keeper Calls by. `run_keeper_cycle` currently returns `turn_success`, which
  carries `keeper_meta` alone. So D4 touches `Keeper_unified_turn`'s result
  type and the heartbeat loop's ordering — the hottest path in the system —
  which is why it is last here and why it is worth its own review rather than
  riding with the projections.

- **D5 — the three empty readings stay three sentences.** `no schedules exist`,
  `none on the page the server sent`, and `the store could not be read` are
  different facts. The Schedules surface separates the third already; the
  Automation tab now separates the second. Nothing in this RFC merges them
  again.

## What this does not do

- No new store. A, B, and their projections read `Schedule_store` as it is.
- No retention change. `terminal_wakes_retained_per_schedule` stays 32. A
  schedule that woke ninety times has 32 readable attempts, not ninety, and the
  projection states the retained count rather than implying completeness.
- No result *content* on the schedule surface. D4 makes the trace possible; the
  operator still reads the work itself on Keeper Calls or Activity, now by
  identity rather than by clock.

## Order, and why

D1 and D2 land first and alone: they are a projection and a read of it, they
turn 1 wake into all of them, and they carry no durable change. D3 next — it is
also read-only but it touches the aggregate route's contract, so it should not
ride with the pane rewrite. D4 last and by itself, because it is the only part
that adds a durable field, and because it is worth nothing until there is a
surface that reads it, which D1–D3 build.

## Verification

- D1: a store fixture with three wakes for one instance and one for a replaced
  instance projects exactly the three, newest first, and states 3 of 3. A
  fixture at the retention ceiling states what it kept, never a larger total it
  cannot produce.
- D2: the pane renders `WAKES (3 of 3)` and each attempt's error, and reports
  the count against the total when the limit bites.
- D3: a target selector over a fixture with more requests than the fleet limit
  returns all of that target's rows; the unselected aggregate still truncates.
- D4: a turn started by a schedule wake and the `turn_started` reaction that
  preceded it name the same turn identity; two schedules due in the same minute
  resolve to two different turns; a turn with no stimulus still has a name.

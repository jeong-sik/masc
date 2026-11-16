# Keepers list: past failure, current state, next attempt

2026-11-06. Started from an operator report: in the Keepers list, a Keeper whose
last turn failed and a Keeper that is failing right now read the same. The
operator saw it in the TUI and reported the same for the dashboard; this note
examines the TUI only. It records why the TUI cannot tell them apart, what one
live snapshot shows, how other tools separate the same things, and which part
of a fix needs no server change. A proposal here is not a decision.

The [observation record](../evidence/research/2026-11-06-keepers-list-past-now-next/README.md)
states what was captured, how, and what was left out. The
[interactive preview](2026-11-06-keepers-list-past-now-next-preview.html) is a
design aid drawn with browser layout, not an executable TUI. Its rows come from
a later snapshot of the same workspace (04:30 UTC) with Keeper and account names
replaced, and the actions marked `[sim]` change state in the page only.

## Why one label covers two meanings

`primary_activity_of_row` (`bin/masc_tui_keeper_list_model.ml:193`) picks one
activity per row. It ORs two inputs into `failed` (line 198) and tests `failed`
before any live activity (line 206):

```ocaml
let failed =
  health = Some Masc.Tui_decode.Health_failing
  || activity = Some Masc.Tui_decode.Keeper_activity_attempt_failed
in
```

The two inputs describe different times.

- `Health_failing` is the server phase `Failing`. The server sets it when
  `turn_healthy` or `heartbeat_healthy` is false
  (`lib/keeper_registry/keeper_state_machine.ml:61-64`). The turn flag is "the
  record of a turn that already ended" (`lib/keeper/keeper_registry.ml:397`):
  one failed turn turns it false and only a later successful turn turns it
  true again (`keeper_state_machine.ml:83-87`), and while no turn runs it
  stays. The heartbeat flag follows `Heartbeat_failed` and `Heartbeat_ok` the
  same way (`:75-82`). Both describe the past: the last ended turn failed, or a
  heartbeat failed. The list does not say which. The kind of the most recent
  failure is in `kr_last_failure.kf_cause` (`heartbeat`, `turn`, `provider` and
  five more, `lib/keeper/keeper_tool_surface_ops.ml:292-300`).
- `Keeper_activity_attempt_failed` means "The turn is still open after a
  provider attempt failed" (`lib/tui_decode.mli:1420`). It describes now: a turn
  is running and one attempt inside it has failed.

Every live activity (`Preparing`, `Streaming`, `Running`, `Tool_waiting`,
`Model_waiting`) is reachable only when `failed` is false. A Keeper whose last
turn failed and that is now streaming a probe turn shows `failure`. The arm
`Some Keeper_activity_attempt_failed -> Failure` at line 230 cannot be reached,
because `failed` already took that case.

The presentation adds a second collapse. The label is `failure`
(`bin/masc_tui_render_keepers.ml:157`), the mark is `!`
(`bin/masc_tui_keeper_mark.ml:22`), the colour is `Theme.bad` for both
`Held_call` and `Failure` (`bin/masc_tui_render_keepers.ml:175`), and
`group_of_activity` puts `Held_call`, `Question`, `Confirmation` and `Failure`
in the `Attention` group. A call that waits for the operator and an automatic
retry loop share a glyph, a colour and a group.

The row does carry both facts, as one sentence. For a failing row,
`keeper_failure_context` (`bin/masc_tui_render_keepers.ml:99`) writes
`<current activity> · last failed · <cause word> · <age>` into the RUNTIME
cell, or into DETAIL when that cell is hidden
(`bin/masc_tui_render_schedule.ml:294`). It is built from the typed pair
`{ kfs_current_activity; kfs_last_failure }` that
`Tui_decode.keeper_failure_status_of_readings` makes only for a `Failing` row
(`lib/tui_decode.ml:4885`). So the data to split the present from the past is
already joined in one value. It does not help the reader of the NOW column,
which says `failure`, and the sentence has three limits: the cause word is the
eight-way `kf_cause` (all 15 rows in the snapshot below say `provider`), it is
one string cut to the width of a column that normally holds the runtime id, and
the group and the colour ignore it.

The server's hint does not separate rows either. `kr_next_action` is a hint for
the operator, and for every failing Keeper it is `Probe`
(`lib/keeper/keeper_status_runtime.ml`, `keeper_next_action_path`,
`KH_failing -> Probe`). The same file explains why: the phase keeps probing on
its own, and once turns and heartbeats are both healthy it returns to
`Running`. No failure count moves it anywhere else; besides that recovery, only
a stop or pause request or the fiber's death leaves `Failing`
(`lib/keeper_registry/keeper_state_machine.ml`, `derive_phase`).

## What one live snapshot shows

One workspace, two roster reads 12.7 minutes apart, one status read between
them, and the per-turn decision logs for the 12 hours before the first read.
Counts are from that workspace at that time. Keeper and account names are not
reproduced. Method and limits are in the observation record.

At 01:26:31 UTC the roster had 40 rows: 15 failing, 18 offline, 7 healthy.

| Field on the 15 failing rows | Value |
| --- | --- |
| `last_failure.cause` | `provider` on all 15 |
| `next_action` | `probe` on all 15 |
| `runtime_blocker_signature` | null on all 15 |
| `runtime_path_rest` | 4 resting, 11 serving |
| `runtime_lane_observation.evidence.terminal`: ending runtime, cause arm, nested category | 7 `glm-coding.glm-5.3-flash`, `provider_rate_limited`; 4 `muse.muse-spark-1.3`, `masc` with `provider_attempt_effect_fenced`; 2 `claude_code.claude-sonnet-5-5`, `core` category `provider`; 1 the same runtime, `core` category `api`; 1 `antigravity_subscription.claude-sonnet-5-5-low`, `core` category `config` |
| Candidates walked in the last turn (`evidence.failures`) | 1 on 7 rows, 3 on 8 rows |
| `retry_after` on the terminal cause | null on all 15 |

The list shows the same label, the same cause word and the same next action for
all 15, while five different typed causes sit behind them. The row JSON already
carries that evidence. The Keeper detail pane prints it, and the list does not
read it.

| 12.7 minutes later | Value |
| --- | --- |
| Rows still failing | 7. The other 8 had recovered, and none of the 8 still carried `last_failure` |
| Server judgement of the 7 | One value for all 7: `needs_attention`, reason `provider_runtime_error`, next human action `inspect_provider_runtime_cause`, disposition `Alert` with `unknown_runtime_blocker` |
| `failing_since` | null on the 7 still failing |

Recovery erases the record that the Keeper had failed, so the roster cannot show
"recovered a minute ago". The server's judgement does not separate a rate limit
that clears itself from a configuration error that needs a person, and it is
not meant to yet. When no receipt disposition is present, the trust snapshot
sends seven named blocker classes, including
`Blocked_by_provider_runtime_error`, to `Alert` with `Unknown_runtime_blocker`,
and a comment there calls the choice of reason "a display decision of its own"
(`lib/keeper/keeper_runtime_trust_snapshot_core.ml:71`, issue
[#43018](https://github.com/jeong-sik/masc/issues/43018), open).

Turn outcomes show how different the 15 rows were. For each row, count the
half-hour buckets (of the 24 before the first read) that contain at least one
turn with outcome `error`:

| Buckets with an error turn (of 24) | Rows | Turns in the 12 hours |
| --- | --- | --- |
| 21 to 24 | 3 | 819 (all `error`), 25 (all `error`), 21 (all `error`) |
| 9 | 1 | 41, of which 13 `error` |
| 2 to 5 | 10 | 8 to 174 turns; 2 to 7 `error` each |
| 0 | 1 | none |

Two rows read the same `! failure`. One ran 819 turns in 12 hours and every one
ended in `error`: it has been failing for the whole window. Another ran 174
turns, 167 of them without error, and its last turn failed. The roster has no
field that holds this difference.

## What other tools do

Read on 2026-11-06 from the linked pages.

| Tool | What it separates | Source |
| --- | --- | --- |
| Claude Code, agent view | Sessions grouped by state; Needs input is yellow, Failed is red, and a failed session sits in the closing group with finished and stopped ones. Row age and `waiting 3m` are two different numbers | [agent-view](https://code.claude.com/docs/en/agent-view) |
| Claude Code, retry line | `Retrying in Ns · attempt x/y` with exponential backoff, default maximum 10 retries, and an error label that names the reason | [errors](https://code.claude.com/docs/en/errors) |
| Codex CLI | `Reconnecting... {retry_count}/{max_retries}` while a stream retries | [responses_retry.rs](https://github.com/openai/codex/blob/main/codex-rs/core/src/responses_retry.rs) |
| OpenClaw model failover | A rate-limit cooldown uses only timing the provider stated ("does not invent rate-limit cooldowns"). When every candidate fails, the summary lists each attempt and the soonest cooldown expiry. `/status` names the active fallback and why | [model-failover](https://docs.openclaw.ai/concepts/model-failover) |
| Apache Airflow | `up_for_retry` (failed, retries left, will be scheduled again) is a different state from `failed` | [tasks](https://airflow.apache.org/docs/apache-airflow/stable/core-concepts/tasks.html) |
| Supervisor | `BACKOFF` (still retrying) is a different state from `FATAL` (gave up, needs a manual start) | [subprocess](http://supervisord.org/subprocess.html) |
| Kubernetes | `kubectl get pods` prints a status word such as `CrashLoopBackOff` and a `RESTARTS` count on one row | [pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/) |

Four patterns repeat. A retrying state has its own word and is not a terminal
failure (Airflow, Supervisor, Claude Code, Codex). Two durations are two
numbers when they mean different things (Claude Code). A time appears only when
its source stated it (OpenClaw). A count of attempts sits beside the state
(Claude Code, Codex, Kubernetes). Only OpenClaw describes a walk over several
candidates, which is the Keeper case: a walk that ends at one runtime and one
reason. It reports the walk as per-attempt records after the fact.

## What the TUI can change without a server change

The TUI list model reads decoded values from `Tui_decode`. Whether each need
below is met today:

| Need | Source | In the TUI today |
| --- | --- | --- |
| Show the live activity of a failing row | `kfs_current_activity` from `keeper_failure_status_of_readings` | Yes. It is decoded and the RUNTIME cell prints it as text. The NOW column and the group do not use it |
| Mark "the last ended turn or a heartbeat failed" without hiding the activity | `Health_failing`; the kind of the latest failure in `kf_cause`; the two flags in `kl_conditions` (`lib/tui_decode.mli:872-884`, read today only by the detail pane) | Yes |
| Tell an operator-owned stop from an automatic retry (colour, group) | the readings above with `Held_call`, `Question`, `Confirmation` | Yes |
| Age of the last failure | `kr_last_failure.kf_at_unix` (`float option`) | Yes |
| Why the last turn ended: the ending runtime, its typed cause and how many candidates were tried | `kr_runtime_lane_observation` (`lib/tui_decode.mli:780`), a `Keeper_runtime_walk_evidence.t` with `terminal` and `failures` | Yes. The detail pane prints it (`bin/masc_tui_render_keepers.ml:1820`) and the list does not read it. The server binds it to the receipt's turn, "never to the Keeper's current runtime or a newer decision" (`lib/keeper/keeper_execution_receipt.mli`), so it must be shown with that turn's time |
| Group rows by underlying cause | the same value: an exhaustive match over `Keeper_request_failure.cause` and the closed types nested in its `Core` and `Masc` arms | Yes. The summary text and `runtime_blocker_signature` (null on all 15) are not inputs |
| A wait the provider stated | `Provider_rate_limited { retry_after : float option }`, "the provider's relative wait hint in seconds, not a promise that MASC scheduled a retry" (`lib/keeper_runtime/keeper_request_failure.mli`) | Yes, when it is `Some`. It was `None` on all 15 |
| The next event this row waits for | waiting-inventory items `Waiting_source_schedule_waiting` and `Waiting_source_runtime_quota_spent` with `kwi_due_at : float option` (`lib/tui_decode.mli:1352,1382`) | Yes, only when such an item exists |
| Runtime resting or serving | `runtime_path_rest` in the list JSON | Not decoded: no use of the field name in `lib/tui_decode.ml`, `lib/tui_decode.mli` or `bin/`. A decoder addition, no server change. It carries no time: for a quota the provider did not date, the walk's release is `now` plus a fallback, "so it moves on every read" (`lib/keeper/keeper_tool_surface_ops.ml:308-310`) |
| Recent turn outcomes, failing since | turn history | No. Only the decision logs and the transitions API hold them |
| "Needs a person" | a closed server value | No. The value that exists says `Unknown_runtime_blocker` for these rows (#43018) |

Eight of eleven needs are met by values the TUI already decodes, two of the
eight only when the value is present. One needs a decoder addition. Two need
server work, and that work belongs in its own proposal.

## What the preview adds beyond the list

The preview also draws Schedules' next run and Memory's catch-up on the same
time axis as the Keepers list (past on the left, now in the middle, next on the
right), a memory age ladder, and the workspace memory pipeline. None of it is
part of a first increment. It is recorded here so a later RFC can take it up.

- Memory age is display only. A re-observation is not a strength signal
  (RFC-0418, `lib/keeper/keeper_memory_os_types.mli:333-334`), so an age
  computed on the screen must not be called stale. The preview reserves "stale"
  for values the server writes: `Retirement_source_changed` and
  `Retirement_source_unavailable` (`lib/keeper/keeper_memory_os_current.mli:376-377`),
  and the workspace briefing observation `Missing | Current | Stale`
  (`lib/workspace_memory/workspace_memory_briefing.mli:9`).
- A briefing pass continues from the previous summary only when the contract is
  equal and the previous source keys are a subset of the new target. Otherwise
  it starts from scratch (`lib/workspace_memory/workspace_memory_briefing.ml:91`).
  The preview's curator simulation follows that rule.
- Some Keeper memory facts are absent from the workspace ledger and stay absent
  across a 30-minute window. The server record does not say why, so the preview
  labels them `absent` and does not call them queued.

## Not observed

- A candidate TUI build. No capture of the real list at 80, 120 or 200 columns
  exists, and the preview does not substitute for one.
- The web dashboard's screen. The browser extension was not connected in the
  session that took the snapshot.
- The running server's commit for the snapshots. Code coordinates above were
  read on main `e1001bccf3a` after the snapshots.
- Whether the failing rows were mid-turn at the first read. The roster has no
  current-activity field, and per-row status reads were not kept.
- Status screens of LiteLLM, OpenRouter, Portkey, LangGraph, Hermes and Orca.

# Claude native task observations

This prerequisite preserves the installed Claude Code task edge protocol at the
runtime and Keeper adapter boundary. It does not yet connect the task callback
to Keeper journals, TUI or Dashboard, or extend the CLI process lifetime.

Claude's native Agent call and the task it launches have different lifetimes.
A call can return `async_launched` before its task reports progress or a terminal
notification. The runtime therefore emits `Native_task_observed` through a
separate callback. It never reopens a native content index or emits a MASC tool
execution receipt.

## Producer authority

The source basis is installed Claude Code 2.1.292, binary SHA256
`97a01e5bc74a199e67189435d0331ea3a24eac2e07db4b76d9148c5b0386138f`.
Offsets below are zero-based file byte coordinates, not runtime addresses.

- SDK task schemas and run ordering: 184620453–184626890; progress schema:
  184643080–184643855. `spawn_depth=1` explicitly means a top-level subagent.
  A resumed task keeps its task ID and gets a newer run ID. Runs of the same
  task compare lexicographically; their spelling otherwise has no contract.
- Registry `dn/an` queues started/updated/notification edges:
  188963030–188967100. Its `owned_by_subagent` field is a producer-only extra;
  `ln` provides it for child-owned local bash tasks. It supplies no positive
  ownership proof for Agent tasks.
- `WZ` and `eVo` register background/foreground tasks using the literal native
  `toolUseId`: 195236160–195238889. The actual async Agent launch path passes
  its tool context's ID, starts `B8`, and returns a launch result:
  199006740–199008812.
- `B8` emits task progress independently of the foreground Agent callback:
  198899900–198902078. `Lse` queues progress at 195222454–195222957, including
  the producer-only `workflow_progress` field, which this projection ignores.
- Queue drain stamps session/UUID; headless forwards it through the outbound
  iterator and writes verbose stream-json before transcript filtering:
  185750554–185754666, 217468970–217470092, 217458744–217460690.
- Terminal emission claims ordinarily suppress repeat terminal edges until
  registration clears the claim (`Hso`, 185750499; `dn`, 188965462). The SDK
  also permits later task notifications to replace the displayed report.
  Fresh notification UUIDs remain distinct observations on an owned run.
- Task progress and terminal `duration_ms` schemas use signed integers. `Lse`
  emits `Date.now() - startTime` (195222454–195222957); task initialization
  records `Date.now()` (188926809–188926995). The Agent result computes
  `totalDurationMs: Date.now() - M` without clamping (198887975–198888665),
  which the task terminal path forwards unchanged (198902600–198903150).
  Clock adjustment can therefore produce a negative elapsed observation.
- `task_updated.patch.total_paused_ms` also has a signed integer schema
  (184620453–184626890). The registry forwards changed `totalPausedMs`
  without clamping (188963030–188967100). A permission-wait path subtracts
  two `Date.now()` values (216066796–216068296), and its teammate caller adds
  that signed delta to `totalPausedMs` (216082061–216083561). This last
  inspected producer is an in-process teammate, not proof of a negative pause
  emitted by an admitted Root Agent. No universal nonnegative pause contract
  is established by these sources.

These are inspected producer/source contracts, not a live provider run or a
captured user session.

## Admission and identity

Only `task_started`, `task_updated`, `task_progress`, and `task_notification`
enter the task edge decoder. The exact kind/field candidate boundary lets
malformed observations reach recursive duplicate-key validation and typed
decoding without failing an otherwise healthy model turn. Authentication and
other protocol JSON remain strict. Numeric fields use `Runtime_json_integer`;
task counters are provider observations, not root usage or runtime budgets.
Elapsed `duration_ms` and `total_paused_ms` preserve signed safe integers;
they are neither clamped nor used to discard an otherwise owned observation.
Absolute `end_time` retains the inherited nonnegative timestamp admission;
the inspected Root completion/failure producer assigns `Date.now()` directly,
whereas elapsed durations subtract two readings. The SDK schema and public
transport integer domain are broader than that private timestamp check. No
pre-epoch provider observation was reproduced.
The common JSON/OCaml exact-integer boundary still rejects fractions, strings
and unsafe numbers before the observation claims its UUID. A valid negative
clock claims that UUID normally: exact or conflicting replays cannot replace
its value. This clock correction does not change token/tool count validation,
blank identity admission, duplicate-key handling, or task terminal authority.

A registration needs the expected session, explicit task/run/call identity,
`local_agent`, the provider-defined root depth, and no contradictory parent.
The call must be an unambiguous `Root_response` / `Built_in Agent` occurrence
under `Native_full`. A known closed call is allowed: queue draining can place
the first task registration after the native launch result. Its original
assistant UUID and content ordinal remain the owner. Names, descriptions,
ID prefixes, and session equality alone never establish ownership.

The invocation-local UUID ledger is shared with heartbeat and retry metadata.
Exact and conflicting UUID replays cannot publish another observation or acquire
a later owner. Malformed/foreign frames do not claim UUIDs. Valid unowned task
edges retain an unowned exact run, so losing a registration does not let a later
call adopt the prior task. A newer registered run can establish fresh ownership;
an older run cannot overwrite it. A run-less frame never selects the latest run.

An established task owner survives native call closure; it never retargets to
a later native call. Task registration declares no task status.
`Task_terminal_unobserved` means only that terminal evidence has not arrived,
not that a task is currently running. A terminal status patch or notification
changes the public observation boundary to `Task_terminal_observed`. Later
metadata-only/terminal patches and fresh terminal notices preserve that boundary.
Progress or a nonterminal status patch cannot reopen the sealed run; resumption
needs a fresh registration with the provider's newer run ID. Consumers receive
the post-event boundary instead of reconstructing another lifecycle machine.

Raw prompt, description, summary, error and output-file bodies are not retained
in these observations. Optional subagent/tool names remain provider metadata;
future wire consumers must apply the existing redaction boundary. No task frame
updates or flushes Text/Thinking, root model/usage, heartbeat/retry state, native
completion, model response completion, or Keeper turn state.

`background_tasks_changed` remains an informational **level snapshot**. Its
replace semantics and potentially earlier delivery do not register or tombstone
edge owners, and absence never implies task completion.

## Consumer boundary and remaining work

| Source/API | Direct consumer | Focused witness |
| --- | --- | --- |
| Runtime task types and `Native_task_observed` | `Keeper_claude_code_runtime` and runtime event tests | `test_runtime_claude_code` fake CLI through actual `await_terminal` |
| Adapter `?on_native_task_observation` | Optional direct adapter caller; unset by `Keeper_turn_driver` | `test_keeper_claude_code_runtime` direct adapter with scoped Yolo |
| Task boundary and native owner | Future driver/hook/transport consumer | Not connected in this prerequisite |

Runtime cases cover first registration after native return, parallel root call
ordinals, interleaved tasks, lexical run ordering, cross-kind UUID collisions,
unowned-before-owner edges, malformed/numeric telemetry and unchanged root
body/model/usage. The adapter fixture interleaves actual task frames with held
secret prefixes in both Text and provider Thinking. It preserves scoped Yolo
admission and checks that task callbacks emit no Agent Core lifecycle/content
events and cannot flush those prefixes. These fixtures are authored; execution
requires the approved CI route and has not been claimed here.
The runtime clock fixture drives actual `await_terminal` with negative,
zero, positive and signed safe-boundary values in progress, pause patches and
terminal usage. It asserts the retained values, UUID replay behavior, original
owner, task boundaries and unchanged root/native completion. Rejected clock
payloads are followed by corrected frames with the same UUID to check that
malformed telemetry did not reserve it. This fixture is authored, not executed
provider or adjusted-clock evidence.

Next transport work must connect `Keeper_turn_driver` to the typed observation
hook, direct/autonomous collectors, journal/AG-UI codecs, TUI and Dashboard.
The existing native-progress bridge requires an active native content block and
must not carry task events after its call closes. Actual terminal captures remain
required for UI evidence.

The process-lifetime gap remains: MASC keeps stdin open for control/MCP replies,
returns on the first root result, and terminates its CLI. The installed headless
result router holds results for background Agent tasks only when input is closed
(`Ky`, 217107162; result routing, 217150275–217153090). Consequently tasks may
outlive that first result. Full support requires an owned process/session receiver
with user interleaving, cancellation, resume and reconnect behavior. This parser
does not wait for every task, restrict background execution, fabricate completion,
or claim post-result delivery.

# Native task transport vocabulary and codec

This prerequisite adds `Runtime_native_tasks`, a pure low-level vocabulary and
public DTO. `Runtime_claude_code` re-exports the same status, event, usage and
terminal-boundary types. Its admitted native owner and callback observation stay
private and distinct: a decoded DTO cannot be used as runtime ownership evidence.
No driver, collector, journal, AG-UI, Dashboard or TUI publisher consumes the new
DTO yet. This change does not retain a CLI after the root result.

The source base is `1b256dcbedcf682f8b9119deb1191cf886a456ff`. The actual Claude
2.1.292 producer and the existing admission rules are documented in
[Claude native task observations](claude-native-task-observations.md). This codec
changes none of those rules. It does not parse raw Claude task frames or duplicate
session/call/run admission, UUID replay, or run-order state.

## Public data and admitted ownership

`Runtime_native_tasks.t` is a private record with a validating `make` and
`of_json`. Its constituent records are transport data. Successful construction
proves structural/numeric consistency only. It cannot establish a real operation,
Keeper, provider session, consumed input, native call or task run. There is no API
from this type to `Runtime_claude_code.native_task_owner` or
`native_task_observation`.

The future Keeper converter must use the admitted runtime observation, the
materialized driver attempt, and an exact originating input-ticket witness. It
must freeze that association once, not attach the newest input ticket or current
runtime when a delayed task frame arrives. Input-ticket transport carries three
opaque strings:

- `receiver_generation`: host-generated invocation/receiver UUID;
- `session_id`: the actual Start session identity or resumed provider conversation;
- `client_uuid`: the host-generated UUID on the SDK user envelope.

The prerequisite input-attribution module is present in this base. These fields
describe its ticket boundary without importing or granting its private evidence;
this codec neither generates tickets nor asserts that any input was consumed.
The invocation session and original native owner session must be equal. They are
retained separately so a converter mismatch is rejected rather than silently
rewriting one side.

The originating native occurrence is its session, literal call ID, assistant
envelope UUID and block ordinal. It can already be closed. Current stream scope,
current message ID, tool block index and a MASC execution receipt are absent.
Routing run plus lane-attempt index is not an invocation ID:
`Keeper_claude_code_runtime.run` can call `run_without_lifecycle` again inside
`context_overflow_shrink_sequence`. Its actual retry-safety rule still requires no
observed response/tool effect; the codec does not authorize retries after Agent
activity.

The origin names the real operation **or** autonomous turn through a closed
variant. It also names the Keeper, routed attempt, task and provider task run.
Operation/autonomous identifiers are opaque at this low-level boundary; the
future converter takes them from their existing authoritative host types. The
codec does not parse ID spelling or import Keeper modules into `masc.runtime`.
Canonical base-path/runtime authority remains the authenticated outer journal or
subscription scope. Batch subscriber aliases do not replace the original owner.

## Canonical JSON

`schema` is exactly `masc.native_task_observation.v1`. The five required outer
fields are `schema`, `origin`, `uuid`, `event` and `boundary`.

```json
{
  "schema": "masc.native_task_observation.v1",
  "origin": {
    "keeper_name": "alpha",
    "source": {"kind": "operation", "operation_id": "owning-operation"},
    "attempt": {
      "routing_run_id": "materialized-routing-run",
      "runtime_id": "claude-lane",
      "lane_attempt_index": 0
    },
    "invocation": {
      "receiver_generation": "actual-host-generation",
      "session_id": "actual-session",
      "client_uuid": "actual-host-input-uuid"
    },
    "native_call": {
      "session_id": "actual-session",
      "call_id": "provider-call",
      "call_envelope_uuid": "provider-assistant-envelope",
      "call_ordinal": 0
    },
    "task_id": "provider-task",
    "run_id": "provider-run"
  },
  "uuid": "provider-task-observation",
  "event": {"kind": "registered", "is_backgrounded": true},
  "boundary": "terminal_unobserved"
}
```

The values above illustrate fields; they are not captured provider identities.
Autonomous source is `{"kind":"autonomous_turn","turn_ref":"..."}` and cannot
also carry `operation_id`. Every nested object is closed and rejects duplicate
keys. Required fields cannot be omitted. Optional event fields encode `None` by
omission; explicit null is invalid. Missing, false and true boolean observations
remain different values. Identity strings are preserved byte for byte without
trimming, prefix parsing or spelling-based ownership tests. The producer’s string
schema does not justify adding nonblank checks for task metadata.

| Event kind | Payload | Allowed post-event boundary |
| --- | --- | --- |
| `registered` | Optional subagent_type, is_backgrounded, skip_transcript, ambient | terminal_unobserved |
| `patched` | Optional status, is_backgrounded, end_time, total_paused_ms | pending/running/paused require terminal_unobserved; completed/failed/killed require terminal_observed; a metadata-only patch can retain either |
| `progress_reported` | Required usage; optional last_tool_name | terminal_unobserved |
| `terminal_reported` | Required completed/failed/stopped outcome; optional reason, usage, skip_transcript, ambient | terminal_observed |

These consistency checks come from the actual runtime registry branches.
`worker_restart` is allowed only with a stopped notification. The codec is
stateless: it does not deduplicate observations, infer missing events, compare
provider runs, or authorize a previously sealed run to reopen. Consumers must
retain the supplied boundary and use the admitted event sequence. Registration
has no status. Terminal-unobserved does not mean running or pending. Task progress
and termination provide no root model-content, model-usage, native-call completion
or Keeper-turn authority.

`Runtime_json_integer.of_json` is the single numeric decoder. Integral JSON numbers
such as `1`, `1.0` and `1e0` have the same meaning. Values must fit both OCaml int
and the ECMAScript safe integer interval `[-(2^53-1), 2^53-1]`. This precision limit
is not a task budget. Provider usage, end_time and total_paused_ms retain signed
safe values; no positivity constraint is inferred from their names. Only actual
host lane and native block ordinals are nonnegative. The current private Claude
frame decoder additionally rejects blank identities, negative token/tool counts
and negative absolute `end_time`; this public DTO proves neither private
admission nor provider ownership and does not widen that decoder's authority.
Signed elapsed and pause observations remain admitted by both boundaries.
`make` uses the same numeric
and event/boundary validators as `of_json`, so `to_json` cannot emit unchecked
integers from an externally constructed `t`.

## Content and presentation boundary

`redact` changes only supplied `subagent_type` and `last_tool_name`. Empty or
Unicode metadata remains a string, including after redaction. All identities,
numbers, enums and optional flags remain unchanged. The future publishing
converter must redact before durable append and the public serializer must apply
the same boundary. The codec does not touch or flush model Text/Thinking buffers.
Raw prompt, description, summary, error, output_file and arbitrary JSON are not
part of this DTO.

`ambient=true` must not contribute to activity; `skip_transcript=true` must not
create an inline transcript entry. Omission does not supply false. A partial
replay must retain missing visibility metadata as unknown. The next UI reducer
must keep task facts separate from native tool and root-response state, with
source-owned identities rather than USER/assistant body prefixes.

## Validation and remaining work

The authored `test_runtime_native_tasks` suite covers lifecycle/optional flags,
operation/autonomous origins, signed numeric equivalence and limits, exact object
boundaries, session mismatch, terminal consistency, redaction and opaque identity,
and compile-time vocabulary equality at the real Runtime_claude_code interface.
It is wired to `masc.runtime`; it has not been built or run here.

At the earlier `6725552ed808f8d25bc61f0855ea1e74ae8f4a89` base, a bounded
interpreter observation evaluated the complete actual
`Runtime_json_integer.ml` and `Runtime_native_tasks.ml`, sealed the latter against
its entire actual `.mli`, then checked 33 literal transport cases: 21 accepted,
12 rejected. The accepted canonical values survived Bun JSON serialization and
an OCaml decode unchanged. The actual repository Dashboard SSE parser rejected
the intentionally unregistered `KEEPER_NATIVE_TASK_OBSERVATION` name. That is a
measured current consumer gap, not task SSE/UI support. Original arguments,
inputs, outputs, source hashes and parser diagnostics are retained under
`/tmp/masc-native-task-wire-measurement-20261008/` for the handoff. No local Dune,
full runtime build, model/provider call, HTTP binding, PTY or CI was run.

Required following units remain: input-ticket-to-native attribution, Keeper
converter, driver/hook and direct/autonomous collectors, shared journal/AG-UI
payload consumers, TUI/Dashboard task presentation, and a separately owned
session/task journal receiver after the root closes. Existing turn journals and
HTTP streams close at root termination; appending late tasks there would not make
them visible. A later actual-terminal witness must show a settled answer, the
original background task, and a new input simultaneously with unchanged authored
bodies. This pure prerequisite supplies no such execution or screen evidence.

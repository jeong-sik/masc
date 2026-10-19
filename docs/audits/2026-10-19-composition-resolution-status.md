# Original Composition resolution in exact status reads

Relates #42799 and follows #43969. The original objective still includes Ask to
Task/useful work, preparation attribution/frozen discovery, all Composition
forms, held/shared-backend continuity, TUI usability/visibility, and matched
Before/After with unsuccessful and incomplete samples. This is the status
producer and delivery boundary needed by the remaining TUI detail work.

## As-Is / To-Be

| Boundary | Before | Source behavior after this change |
| --- | --- | --- |
| Status after explicit logical resolution | `keeper_composition_status` only serializes the original physical worker. A resolved waiting run still looks physically waiting without its logical decision. | The physical status remains original. Separate `continuation` data is observed original journal state, unavailable evidence, or explicitly not a Composition. Observed state includes original owner/generation, source Task, journal version, observation time and optional terminal decision. |
| Failed logical read | No separate coordinate. | The physical reading remains present; logical failure is `unavailable`, never unresolved, absent, successful or replacement authority. |
| Manifest admission | Payload is rebuilt from the entry when sealing a completed result. | The actual status producer captures one immutable payload. Serialization and manifest verification use that exact payload and SDK occurrence. A later observation cannot replace its timestamp or source. |
| Result delivery | Existing physical/source/activation checks. | The captured logical observation is also revalidated at binding, physical handoff observation and ledger persistence. Resolved or unavailable state cannot create a successful result binding. Diagnostics retain the captured logical observation. |
| Terminal lookup outside active inventory | The generic async observation surface enumerates active records only. | An authenticated exact lookup reads one original `submitted_by`/request pair, including terminal records, without scanning history or changing the active inventory. |

`GET /api/v1/async-requests/status?submitted_by=OWNER&request_id=REQUEST`
uses the existing `CanAdmin` and workspace-read wrapper. Each identity must occur
exactly once. The persisted submitter is distinct from the target Keeper and
from the authenticated operator. The response schema is
`masc.async-request-status/v1`; outer states are `observed`, `absent`,
`unavailable`, and `rejected`. `observed.request` is the same status projection
used by the actual Keeper status tool. Its HTTP projection omits the status-Tool
kind marker and does not invent an SDK invocation or classify an ordinary async
request as a Composition.
Absence and rejected/unavailable evidence grant no replay right.

## Original authority and observation lifetime

The journal observation validates immutable source and admitted current/prior
physical membership under the original run transaction. It captures exact
journal bytes by digest and observation time, then checks that the physical
record is still canonical. Resolved state additionally requires the exact
canonical waiting/lost resolution owner. Artifact/dependency readiness is not
required to observe a terminal decision and is never execution authority.

An unresolved reading is an observation, not successful admission. Original
request, workspace and journal version determine observation equality; current
time does not. The projection does not attach a current Keeper Task or replace
the queried physical attempt with a successor. Physical and logical coordinates
are not an atomic cross-store snapshot. A concurrent physical change yields
logical unavailability; a later journal change invalidates a retained delivery
binding at its next existing authority check.

The status snapshot is opaque. The producer captures the original physical
serialization, logical reading and actual SDK occurrence together. Its manifest
check consumes the captured payload rather than regenerating dynamic elapsed
time or a later logical reading. A successful status-tool lookup proves a read,
not effect success, Task completion, logical admission or physical delivery.

The active-inventory endpoint, its worker-ownership counts and startup recovery
projection are unchanged. The new exact endpoint is demand-driven and does not
enumerate terminal history. Composition lookups add strict journal/physical
checks; no lower latency or throughput improvement is claimed.

## Authored scenarios and remaining evidence

The real owned-job/Composition permanent-mismatch scenario now reads the actual
Keeper status tool before and after explicit resolution. It retains the physical
wait and original source Task, observes the terminal logical rejection, keeps an
old observation immutable, rejects that stale observation as current, and reads
the exact terminal attempt through the HTTP projection. Wrong submitter reads
are rejected without exposing a request payload. The existing live-worker/disk
ownership scenario also reads a request whose target differs from its submitter,
and verifies that the target cannot substitute for the original owner.

These compound protocol/resource scenarios are authored and **unexecuted**. No
layout, wording, row-order, snapshot, PTY or invocation-count test is added.
Validation is OCaml parsing and whitespace inspection only. There was no local
build/typecheck/test, CI dispatch/watch, native/model/controller run, installation,
restart, live configuration/prompt write, merge, visible UI or performance run.

The Tools async pane still consumes active inventory. Its actual request
selection/detail read, strict decoder, retained source-specific observations and
physical/logical display are the next required producer/consumer connection.
This backend/status unit does not complete that TUI requirement, usable input,
paint proof, runtime continuity or matched actual Before/After. All six original
axes remain active.

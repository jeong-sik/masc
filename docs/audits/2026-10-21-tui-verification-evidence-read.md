# TUI original verification evidence reads

This audit describes source implementation only. Parsing does not prove typing,
linking, behavior, actual protocol traffic, input usability or visible frames.

## As-Is / To-Be

| Boundary | Before | After |
| --- | --- | --- |
| No result / another Task | Always `loading...` | Never-asked/unconfirmed distinct from actual in-flight |
| Same Task reopened | Task ID alone admits a late callback | Exact original verification/Task key and immutable read ticket |
| Same Task, new submission | Content parser ignores envelope identity | Unique Task and verification IDs required before content decode |
| Refresh | Detail entry clears old evidence; failures replace it | Same-key last good evidence retained with progress/typed failure |
| Workspace read | Separate endpoint check then raw evidence GET | Original bound GET with precondition and matching server receipt |
| Parse | JSON on the read caller | Immutable response decoded through the existing CPU worker |
| Close/withdraw | Detail ID check; no evidence-owned source ticket | Retire exact admission, request cancellation of its original job |
| Diagnostics | No evidence request lifecycle | Correlated requested/caller/delivery/admission/job observations |

The evidence source reuses the existing immutable Fetched state machine with a
parameterized error. String-error panes keep their existing aliases, states,
transitions, generation and suspension text. Typed consumers use that same
implementation; they do not render an error to choose state. A typed
`suspend_with` has the original suspension behavior and the ordinary `suspend`
chooses its existing string. No new cache, timer, limit, retry loop or coordinator.

A detail read captures its original verification request and Task, ticket,
physical cancellation-job token, workspace authority/read epoch and workspace
observation. Reply admission requires the original pending wrapper and epochs;
normal workspace completion envelopes remain. Clearing a workspace retains the
next fetched generation. A reopened same Task or successor workspace cannot
reuse an old callback. Detail close and explicit supersession address the
original registered observation job; late cleanup cannot erase a newer job.
Workspace suspension retains the previous source/error and retires admission.

The shared uncached `read_response` prepares the concrete precondition path
before transport and validates the same admission receipt as JSON readers.
Missing/duplicate successful-read receipts refuse; server non-success statuses
retain HTTP classification. Health-identity bindings cannot use a raw response
as decoded identity proof. Other JSON/cache readers are unchanged. The actual
evidence caller captures its binding before dispatch, so it does not borrow a
sibling collector's root or the current root after yielding. No evidence cache
or fallback is introduced. Auth refresh, transport body policy and server
CanAdmin/evidence authority remain unchanged. Unbound generic callers retain
raw-read semantics; the TUI evidence consumer is explicitly bound.

The HTTP consumer preserves transport, HTTP, invalid JSON and invalid payload
failures and adds workspace-unconfirmed classification. The identity decoder
rejects missing/duplicate/mismatched Task/verification fields and duplicate
result envelopes. Evidence access and contents retain the existing decoder.
A server response for a newer submission of the same Task becomes an explicit
failure of the old detail; it cannot silently replace that old evidence. The
verdict protocol and approval/input authority are unchanged.

## Visibility and observation

The renderer receives the exact key's typed source view and actual pending
flag. It displays no-value failure, failed retry and retained evidence with its
cause; unconfirmed workspace observations remain labelled as such. Old evidence
never becomes a fresh verification verdict. Text wrapping and pixel reservations
use the same section rows; notice rows offset original picture slots before the
existing heading/viewport transform. Image preparation and existing converter
policy stay outside rendering; no new converter limit is added.

`tui_verification_evidence` routine diagnostics carry original process ID,
workspace paths, Task, verification and source request generation. Events are:
requested, caller_entered, caller_observed or caller_interrupted, not_run,
delivery_formed, applied/discarded, cancellation_requested and
registration_released. These are distinct observations. Delivery formation is
before mailbox enqueue; caller return includes read/decode/image preparation;
registration release follows the original workspace job's cleanup. None proves
paint, useful work, OS/process exit or Task completion. Boundary failure is not
classified as not-started unless the actual on-not-run hook was observed.
Routine-disabled records are absent, not fabricated completed stages.

## Authored scenarios and limits

Two resource/protocol scenarios use actual filed PNG bodies, the existing
operator serializer/readback, actual server workspace precondition validator,
uncached response admission, exact envelope decoder, image preparation with no
pixel output, and production TUI source admission/retirement helpers:

1. Receive the original filed image, reject a new submission under its old key
   while retaining original content, reopen the same new Task/detail under a
   replacement ticket and reject a late callback, then suspend without losing
   the real original resource or admitting its retired response.
2. Refuse a successor root holding the same coordinates, missing/duplicate
   admission receipts and old-workspace callback; retain the exact original
   prepared value through refusal and receive the successor's own resource.

Responses are controlled protocol frames, not a running HTTP server. These cases
are authored, unexecuted, and do not exercise the TUI loop, HTTP client network,
launcher cancellation, log emission, converters, display or live server auth.
The existing picture test adapter is migrated to the new section API; no new
UI wording, layout, row-order, snapshot or PTY assertions are added. Direct Dune
libraries are declared; no Dune/type/link/build or test execution is performed.

## Costs and matched Before/After

The evidence path removes its separate pre-read identity check and keeps one
explicit evidence GET with preconditions/receipt. This is a source request-path
change, not total HTTP count or elapsed-time measurement: auth retries,
connections, server work and other surface reads remain. CPU dispatch adds pool
wait/return and envelope field validation (three small field scans). State,
request/job/epoch metadata and routine closures add allocation. Keeping the
previous evidence, including PNGs, can retain both old and newly prepared values
during refresh. Status notices add wrapping/slot projection work. Existing
cancellation cleanup and converter work can still delay settlement.

No measured cohort exists. Actual comparison must pin source/binary/fixture,
workspace/Task/submission, terminal and logging conditions, and retain failed,
cancelled, interrupted, not-started and unfinished attempts. Per-process times
must not be subtracted across processes. Explicit typed-state/source progress
is not proof the reported continuous live Loading is resolved.

All six original goal axes remain incomplete; current-head independent source
approval, whole-stack acceptance and matched actual TUI/runtime evidence remain
separate. No install, restart, live writes, self approval or merge.

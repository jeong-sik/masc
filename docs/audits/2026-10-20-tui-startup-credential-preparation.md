# TUI workspace-access preparation and input

## Finding and scope

`main` called `Masc_tui_http.install_operator_token` before creating its input
reader and probing terminal capabilities. `react_to_server_contact` also awaited
the same installer on the UI callback after a first-install workspace appeared.
The installer reads local auth configuration, token/credential records and can
wait on the existing durable mint lock. Auth descriptor reads and the Eio lock
path already yield, but their UI caller could not return to terminal input.

This is a source dependency finding, not a measured loading incident. The
existing HTTP surface collector already composes independent readers in parallel;
it is not replaced or described as serial.

## Before / After

| Boundary | Before | After |
| --- | --- | --- |
| Foreground startup installer waits | One before input-reader/probe setup | Zero; one original session child owns the installer |
| Server-contact callback installer waits | One for each admitted bootstrap retry | Zero; active or unconsumed preparation is shared |
| First HTTP request | After initial installer; health can overlap terminal probe | Same dependency through the original outcome promise; no UI-drain/probe-completion prerequisite |
| Header capture after an admitted preparation | UI could not initiate another key action during that wait | HTTP consumer awaits the admitted install before snapshotting the bearer; local editing can continue |
| Completion handoff | Immediate UI callback return | One owned slot; observed outcome is independent of shared mailbox capacity and UI consumption |
| Home | Generic initial connection state | Distinguishes preparing access and a received result awaiting state application |

These counts describe source call sites, not test counts, CPU time, HTTP latency,
first paint or useful Task progress. Each admitted preparation still executes the
same installer once. Normal request counts, role preservation, environment-token
precedence, missing-workspace refusal, verification and durable mint locking are
unchanged. The new source adds one child and one current-outcome promise per
admission, one initial promise per session, a fixed completion slot, timestamps
and diagnostic callbacks. The current promise is published atomically for HTTP
consumers on other Eio domains; control/status/consumption stay on the UI domain.

## Ownership, failure and observation

Requests retain purpose, original base path, host, port and monotonic admission
time. The main process keeps this endpoint/base scope for the session. An active
job and its unconsumed completion are shared; no replacement, timer, retry loop,
new I/O pool, token cache or auth policy is introduced. A retry is still requested
only by the existing pending-workspace rule after actual server contact.

The installer continues to run on the UI Eio domain and uses its existing
filesystem/lock implementations; the controller does not move mutable bearer
state into a systhread. Header builders wait only on an already admitted job.
An installer observation releases its HTTP dependency before UI consumption, even
when the observation is a refusal. Neither promise settlement nor UI consumption
grants a credential, workspace identity or write authority.

`Observed`, `Not_started` and `Unobserved` are separate outcomes. A missing switch
does not run the installer inline. Switch checks precede scheduling; cancellation
of an entered installer retains unknown outcome and re-raises. It does not say
that a durable mint was undone or that physical I/O has stopped. The root switch
still owns actual child/lock settlement. A permanently blocked protected I/O can
therefore still prevent normal exit; no shutdown bound is added.

Admission is recorded before launch; worker entry and observed return are stored
in the original completion. The UI reports its own application time. Detailed
records use existing routine/lazy logging and contain no bearer bytes. Default
routine suppression avoids formatting/emission; enabled logging adds work and
uses the existing potentially lossy console/ring sinks. A missing log is not zero
duration or success. A requested-only record remains unfinished. These phases
are not physical file-read intervals, paint, command acceptance or Task progress.

The finite completion is handled within the existing async-pass deadline. It is
not withheld merely because input remains ready, so continuing edits do not make
access preparation wait for a typing pause. This does not give arbitrary jobs
priority over input or alter the rest of the shared-result scheduling policy.

## Authored protocol scenario and limits

The unexecuted `test_tui_credential_preparation` scenario gates the real production
installer, edits a real draft while its original owner is pending, observes an
absent workspace without creating a credential, consumes that exact result,
creates an isolated auth workspace, and runs the same installer again. During
that retry a real HTTP header builder waits while the draft changes. The scenario
then checks the actual minted/installed bearer against the isolated auth store
and retains the original draft. It does not contact a server, render a frame,
exercise the actual main-loop key dispatch, or hold the operating-system mint
lock. The supplied gate is not physical lock evidence. No helper/count, wording,
row-order, snapshot or PTY test substitutes for those boundaries.

Parsing-only receipts do not prove type conformance, compilation, warnings,
linking, scheduling or scenario success. No local build, typecheck, test, CI,
native/model/audio/PTY run, install, restart or live write was performed.

Startup still waits on runtime-settings resolution/read/parse, terminal setup and
the existing capability probe before ordinary key-loop delivery. Direct metadata
checks, CPU work, pool startup/pressure, terminal output and protected I/O can
still delay it. No whole-startup nonblocking claim or speedup is established.

## Original goal remains open

Actual original Ask → original Task → useful work, exact preparation attribution
and frozen discovery reuse, ordinary/nested/dynamic/effectful Composition resource
continuity, held-job reactivation/shared-backend batches, cold usable input and
TUI readability/visibility, and matched actual Before/After all remain required.
This unit improves one source dependency and exposes its observations. It does
not complete any axis by itself. Future matched cohorts must retain failed,
cancelled, interrupted, refused, not-started and unfinished samples, include the
new child/promise/observation costs, and distinguish input decode, key handling,
state application, actual terminal acceptance and useful work. Runtime execution
remains outside the current code-only authorization.

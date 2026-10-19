# Keeper settings: preserve the edit while saving asynchronously

Source baseline: `f4a20d52053686e8251b5fbe23c728500cb00cf3` (#43690).

## As-Is / To-Be / Before and After

| Boundary after the external editor returns | Baseline | This layer |
| --- | --- | --- |
| Workspace check and settings POST waits in input handling | Two | Zero |
| Total logical successful save HTTP calls | Two | Two, in an owned asynchronous operation |
| Repeated `e` during save | Input loop cannot process it yet | Shares the existing same-Keeper operation |
| Progress/failure visibility | Result action after synchronous completion | Persistent selected-Keeper checking/receipt/recovery notice plus final action |
| Transport loss or invalid success receipt | Generic error, edited local value leaves scope | Explicit unconfirmed outcome with exact original input and patch retained |
| Server-declared unchanged refusal | Generic HTTP error | Typed before-write refusal, separate from unconfirmed outcome |
| Recovery | Fresh editor can lose unsaved changed values | Explicit `e` reads current, restores changed values, and requires editor review |
| Late reply while another Keeper is selected | Conflict path can refresh the original target into the pane | Receipt is retained; a refresh requires current origin and the same selected Keeper |

Counts come from source call boundaries, not elapsed measurements. Preparation
before the editor was already asynchronous and is not counted as newly moved.
The external editor still owns its terminal interaction. Sandbox backend shortcut
saves remain a separate synchronous path. HTTP work, existing timeout policy,
server CAS/write/reconciliation effects and receipt interpretation stay in place.
No interval, cap, timer, environment variable or permission is added.

## Operation and recovery contract

Each operation captures the original editor text, source snapshot, composite
revision-bearing patch, Keeper/workspace/read owner and start clock. UI state
holds the operation's admitted status separately from its atomic worker result.
Checking advances to possible dispatch and a terminal outcome; a terminal result
cannot restart or be replaced. Publishing never waits for a bounded mailbox.
The input drain recovers receipts after queued identity changes. Withdrawal before
dispatch is not-sent; interruption after possible dispatch is unconfirmed. Existing
workspace-owned fiber cancellation remains responsible for actual worker cleanup.

Applied receipts, before-write refusals, revision conflicts, reconciliation-required
responses, applied-but-runtime-sync-failed responses and unconfirmed outcomes stay
distinct. Raw returned JSON is retained for declared outcomes. Before-write refusal
classification requires unique `config_applied=false`, `runtime_sync=not_attempted`
markers and no contradictory `config_application`; malformed, generic or transport
failure does not become a proven refusal. Existing specific refusal cases take
precedence. Invalid success receipts remain unconfirmed.

The UI applies only the original operation's result. Its receipt survives focus,
read authority and workspace withdrawal. Refreshing current Settings additionally
requires the current workspace/read owner, Settings tab and exact selected Keeper.
The operation list has no arbitrary cap or automatic retry. A same-origin pending
save coalesces edit intent; independent Keepers retain separate operations.

After a failed or uncertain save, explicit `e` goes through the existing fresh
snapshot preparation. Pure recovery computes changes against the original
snapshot, overlays only those values onto the current editable projection, and
opens the editor. Current untouched values survive. The old revision and prior
context-shrink confirmation do not authorize another write. Only the subsequent
operator-reviewed edit uses the new snapshot's revision. No recovery path sends
automatically, rewrites the original operation or borrows a foreign workspace's
draft. If current cannot be read, retained input remains available for later
explicit recovery. A changed origin at save admission also retains unposted input.

Start, every successful worker status publication and UI admission have separate
clocks joined by Keeper/start identity. A fast completion may skip an intermediate
UI phase, but worker observations remain logged. No edited body, credential or raw
patch is logged. These observations are not painted frames, actual key latency or
useful Task work, and unfinished starts must remain in future comparisons.

## Evidence and remaining goal

Three feature/ownership scenarios are authored and **unexecuted**: pending edit
coalescing plus receipt/input retention through navigation and authority withdrawal;
explicit current-read recovery preserving changed and untouched values, current
revision, renewed confirmation and successor ownership; changed-origin refusal
retaining exact unposted input. They inspect decisions and retained state. No
wording/layout/row-order/snapshot-output/PTY check is added. HTTP classification is
source-inspected against the server's declared write markers, not executed proof.

Only parser-only source checks, diff hygiene and changelog validation run. Types,
feature/HTTP/cancellation execution, independent current-head approval, CI,
installed binary, runtime, paint and speedup remain unverified. No live product
configuration, prompt, login file or runtime is read or modified. No own merge,
install or restart is performed.

The complete preparation/first-usable-input/readability/visibility/observability,
Ask-to-original-Task-to-useful-work, resource-owned ordinary/nested/dynamic/effectful
Composition, held-job/shared-backend and matched Before/After goal remains open.
Future comparisons retain failed, cancelled, interrupted and unfinished samples.

## Subsequent Sandbox shortcut layer

The following layer includes Sandbox shortcuts in this owned save model. The
historical shortcut above omitted the composite revision required by the server;
the follow-up obtains a fresh snapshot before constructing its profile-only CAS
patch. See [the Sandbox audit](2026-10-18-sandbox-shortcut-owned-save.md).

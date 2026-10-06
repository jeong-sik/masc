# Declaration application observations

The operator Lane Add-ons response keeps file persistence separate from worker
application. Each parsed declaration now has `source_revision` (SHA-256 of the
exact bytes read by the last reconciliation) and `application`:

| kind | Meaning |
|---|---|
| `starting` | On is desired; an accepted running worker has not been observed. |
| `cleaning` | A live or retained owner still needs cleanup or cleanup publication. |
| `applied` + `instance_id` | One exact owner completed startup and is running; other relevant owners have stopped. |
| `inactive` | Off is desired, the inventory is complete and all relevant owners have confirmed cleanup. |
| `failed` + `messages` | Reconciliation, worker operation, cleanup or cleanup publication reported failure. |
| `unknown` + `messages` | The inventory is incomplete/ambiguous, or this caller cannot access operator application details. |

The semantic `desired_revision` names worker inputs and intentionally excludes
`enabled`. `source_revision` includes the activity setting and comments. A UI
tracking its saved/read document must match workspace, path, installation ID,
source revision and semantic revision before attaching an application result to
that document. A mismatch means that the submitted intent has not been observed;
it is not completion. Editing the manifest can change the semantic revision
without changing declaration bytes.

`source_revision` is the last reconciled document, not a fresh read of the file
on every Inspect. Operator Inspect reads current live and retained worker facts
for that document without starting workers or triggering maintenance. Applied
means an accepted running worker, not valid observation output or Goal success.
Errors and absent/unreadable sources must never become completion by timeout.

## Cleanup publication

All owners matching the installation ID or declaration path participate, including
old revisions and retained workers from earlier processes. A current worker's
absence is insufficient. A container creation callback is also insufficient for
startup: `started` becomes true only after the backend accepts the connection.

Historical cleanup owns its record through `Cleaning`, request-persistence
failure, unconfirmed/cancelled cleanup, terminal `Publishing_cleanup`, and
terminal publication failure. Reads
combine disk records with that owned state. A rename or unlink before its directory
sync completes cannot hide pending cleanup. After resource cleanup succeeds,
maintenance retries only the terminal publication; it does not stop the resource
or publish a release event again. Binding removal syncs its directory, including
retries where the record was already unlinked. Cancellation records an explicit
retryable uncertainty before propagating cancellation; it cannot leave a
non-running `Cleaning` marker that silently prevents later recovery.

On cold reads, the captured binding inventory (including absence) must be followed
by a successful containing-directory sync before `complete=true`. If the directory
is absent, sync its first existing ancestor. This reestablishes publication
certainty even after in-memory recovery state was lost. Strict binding writers
sync file contents before rename; a failed directory sync keeps the inventory
incomplete. This read creates no directory and rewrites no record. In-process
pending state still overrides disk state until the publication call settles.

The new application detail is operator-only. Existing visibility-filtered
configuration remains available to other callers, but its application state is
`unknown` with a fixed explanation rather than another owner's worker/error data.

## Delivery boundary and next consumers

The TUI decodes these states and shows them beside current installations and
accepted declaration files. A dirty draft is never the application target. The
accepted base file remains the target after a comparison read; accepting that
revision or a successful save changes it. A different source/input revision,
incomplete inventory or failed read cannot confirm application.

While an editing panel is open, the existing visible-pane cadence reads application
status using an independent request ticket. This does not set foreground loading,
clear drafts, replace a frozen Slice, or erase a save failure/receipt. In the TOML
view, `r` requests that observation immediately. Explicit saves invalidate earlier
observations and trigger a new read after their response. Foreground inventory
reads supersede background reads. Workspace ownership and ticket identity prevent
late replies from crossing a workspace reset or explicit action generation.

Web still ignores these fields. Its decoder, saved-intent correlation and visible
panel refresh consumer remain to be connected. F8 is incomplete until both
consumers and the actual runtime path have been verified. The TUI source change
and focused pure-module tests do not prove a running terminal or worker.

The separation follows the established distinction between desired configuration
and system-observed status in [Kubernetes object spec and status](https://kubernetes.io/docs/concepts/overview/working-with-objects/#object-spec-and-status).
The concrete identity, ownership and cleanup rules above come from MASC's own
source; no Kubernetes dependency or generation counter was added.

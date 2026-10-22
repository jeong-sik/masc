# Released workspace upgrade boundary

An upgrade must preserve the workspace rather than initialize over rejected
state. `Released_workspace_upgrade` provides one offline, per-Keeper transaction.
The caller must pass the server's configured BasePath lease directory and an
existing canonical workspace path. It refuses a workspace already owned by a
server, including one in the calling process.

## Proven released mismatch

At tag `v0.34.0`, `lib/keeper/keeper_types_profile_toml_parser.ml` declared
`keeper.autoboot_enabled` and `keeper.proactive_enabled` as booleans.
`keeper_lifecycle_gate_env.ml` projected them to owner restoration and proactive
work respectively. At tag `v0.35.0` these were replaced by `activation_mode`;
`keeper_activation_mode.ml` defines the three representable combinations:

| Explicit old values: autoboot, proactive | Current mode |
| --- | --- |
| false, false | manual |
| true, false | on_demand |
| true, true | autonomous |

Both old values must be present. The combination false/true, missing values,
a mixture of old and new keys, and any otherwise unsupported configuration
require manual repair. No default is inferred from installed software or old
metadata. The current typed declaration parser must accept the transformed
content, and every unrelated parsed field must remain equal. The existing TOML
editor preserves prompt text and unrelated formatting.

## Backup and recovery

Assessment makes no changes. Apply rechecks the original file snapshot, writes
its exact bytes privately to `.masc/upgrades/<random-id>/original.toml`, and
publishes `manifest.json` containing original/result hashes and the known
transformation. Both files and directory entries are synced before the original
configuration is atomically replaced. The receipt distinguishes a confirmed
sync from an after-rename durability warning.

Interactive setup lists known Keeper upgrades when its workspace check finds
unsupported state. Select one or more Keepers to preserve their configuration
and apply the known mapping. Each selected file has its own backup receipt;
failure stops that selection and returns to assessment. Setup also offers
existing validated configuration backups for restoration. A later edit prevents
restoration from overwriting it.

Advanced operators can inspect the same catalog with
`masc workspace-upgrade --base-path WORKSPACE`. Apply uses `--apply KEEPER` and
the displayed `--source-sha256 SHA256`; restore uses `--restore BACKUP_ID`.
No path or digest entry is needed in the interactive selection flow.

This is one file at a time, not a transaction spanning the entire workspace.
Other files, including runtime and fallback assignments, Task, Board, Goal and
Keeper memory, are untouched. The server must be stopped, and independent file
editors must not write concurrently. Detected edits reject the operation.

After a process restart, `load_recovery` validates a backup identifier, reads
owned private regular files, recomputes the transformation, and compares the
manifest. Restore requires the current configuration to equal that exact
migration output; later user changes are never intentionally overwritten.
The backup remains after restore. Recovering an old schema does not make it
acceptable to the current runtime; it restores the operator's original state.

## Cases that must not be synthesized

Between `v0.34.0` and current main, Goal rows gained required
`criterion_revision`, and pending/proven verification records gained request,
criterion and authority identity. Existing `version` values are write counters,
not schema versions. An old proof cannot acquire those identities by inferring
them from its title, time or current Goal. Such stores remain explicit manual
repair cases in setup preflight; this module neither resets nor rewrites them.

## Input ownership journal generation

The input-wait Owner journal uses `masc.keeper_chat_operations.v3` and SQLite
`user_version=3`. Both `input_checkpoints` and the singleton `input_history`
basis are mandatory even before a trace has an input observation. Missing
tables or a missing basis are damaged authority; ordinary open and read-only
inspection do not create them again. A fresh journal records `fresh` explicitly.
The same rule preserves consumed-input evidence after native call retirement.

Earlier journal generations are refused without rewriting rows, sequence, or
checkpoint evidence. This configuration-upgrade tool does not prepare those
journals. There is no automatic reset or conversion to an unobserved input
state. A rollout must explicitly prepare and verify its journals while the
server is stopped before installing this generation; otherwise the Owner can
remain unavailable. Retaining pending operations and terminal outcomes is part
of that preparation. No live data preparation or restart is implied by a source
change or passing fixture. The response endpoint and producer wiring are separate
implementation layers; the journal table alone does not make a wait actionable.

### Private journal copy preparation

`Keeper_chat_operation_store.Offline.prepare_v2_copy` copies an exactly
validated v2 journal into a caller-reserved empty SQLite destination. SQLite
Backup reads one source transaction; the original journal is not configured,
recovered, or rewritten. The copy preserves every original operation, semantic
execution and frozen batch-member cell, including terminal outcomes and the
next admission sequence. A sequence that could reuse an existing operation's
number, corrupt payloads, or an occupied destination is refused.

The old journal cannot prove which input waits were consumed. The prepared copy
therefore records `prior_unavailable` globally. A trace absent from its rows
returns `Prior_input_unavailable`, including historical traces omitted by the
old schema; it never becomes a fresh unobserved trace. Owner input preparation
and both ordinary and atomic native/input publication refuse that uncertainty.
Checkpoint release and startup sweeping preserve all potentially related
retained evidence until explicit reconciliation exists.

This API prepares a private database only. Its result is not an operator
upgrade receipt, an installation, a freshness check after the function returns,
or confirmation that the destination file and parent directory were synced.
The caller owns both SQLite handles and must reserve the destination and hold
the original configured BasePath lease before promoting any artifact. A failed
or uncertain copy is never installed or retried as if the result proved no write.
This primitive does not import a canonical checkpoint as response authority.

### Operator recovery bundles

Inspect one existing Keeper journal and then prepare the reviewed source bytes:

```bash
masc workspace-upgrade journal inspect --base-path WORKSPACE --keeper KEEPER
masc workspace-upgrade journal prepare --base-path WORKSPACE --keeper KEEPER --source-sha256 SHA256
masc workspace-upgrade journal bundle --base-path WORKSPACE --bundle BUNDLE_ID
```

The first command reads the owned journal and displays its SHA-256 without
initialization or conversion. The second requires that digest and acquires the
same configured BasePath lease as server startup. An active server, changed
source bytes or descriptor identity, or a SQLite `-journal`, `-wal` or `-shm`
entry refuses preparation. Companion evidence is retained and requires a
separate recovery step; this command does not checkpoint or roll it back.

`Keeper_journal_preparation` preserves exact original bytes in
`.masc/upgrades/journals/<bundle-id>/original.sqlite3`. Only that private backup
is opened with SQLite. It prepares `prepared.sqlite3`, confirms handle closure
and file/directory syncs, rechecks the live source, and publishes `manifest.json`
last through the shared atomic writer. The original journal is never replaced.
The CLI digest pins reviewed bytes; its new invocation captures descriptor
identity again and fences it throughout that preparation.

A manifest rename followed by a sync failure returns a publication with
`durability_confirmed=false`; an error may leave an unpublished bundle whose ID
is retained for inspection. Neither outcome means no write or permits a blind
retry. No bundle or original evidence is automatically deleted.

The third command reads a published bundle after restart, verifies its owned
files and hashes, and compares the original v2 and prepared v3 schemas, all
original cells, next sequence and unavailable-input floor. Rewriting a hash
cannot conceal a changed prepared sequence. This proves the bundle's internal
relationship; it does not authenticate a wholly rewritten bundle from another
same-UID process, certify past fsyncs, or prove that the live source remains
unchanged. It grants no installation authority.

The manifest records the canonical workspace location. Reading through a
symlink to that same location is supported. Moving or copying the workspace
to another location does not rebind its bundle: an internally valid bundle
returns a workspace mismatch naming the recorded and current locations.
Keep the original, prepared file and manifest together. Do not edit the
manifest paths or replace the live journal to bypass this refusal; relocation
requires an explicit reconciliation step that is not implemented yet. A damaged
bundle remains invalid even when its workspace has also moved.

Failed preparations can leave partial evidence directories. Keep these until
their outcome is understood; the current commands do not distinguish evidence
that is safe to delete and do not provide a cleanup operation. Repeating a
failed or uncertain preparation creates another bundle, rather than repairing
the first one or proving that the earlier attempt made no write.

Both preparation and inspection report `ready_to_install=false`. The explicit
input-selection step below can prepare a separate derivative. Source revalidation
before installation is a separate required step below. Preparation alone cannot
make the copied journal usable by a Keeper.

### Explicit prior-input adoption in a derivative

The database primitive `Keeper_chat_operation_store.Offline.prepare_input_adoption_copy`
creates a separate derivative of the unresolved prepared journal. Its caller
must supply a nonempty list of explicit `Operator_adopts_checkpoint` decisions,
one exact retained checkpoint reference per selected trace. This is an operator
adjudication of missing input history, not a reconstruction that the old journal
can prove. A canonical file, the largest turn count, or `pending_input=None`
does not establish that an earlier accepted answer was preserved; a decline or
timeout may consume input without appending a message.

The source must have the current exact schema, globally unavailable prior
input and no imported input rows. The destination must be a distinct reserved
empty database. The primitive copies all operation, semantic, frozen batch and
sequence evidence without startup settlement, inserts exactly the selected
references, and keeps the unavailable-history floor. An omitted historical
trace still returns `Prior_input_unavailable`. It never becomes a fresh trace
because it was absent from the decision list. Fresh stores and sources with
already selected input rows are refused rather than reset or overwritten.

`verify_input_adoption_copy` reads the original prepared journal and derivative
in separate read-only snapshots, compares every original cell and the exact
selection, and verifies the unchanged uncertainty floor. A failed or uncertain
commit returns an error even when it installed the selected rows. Readback can
establish which rows actually exist; it cannot certify file/directory syncs or
turn the earlier error into a confirmed publication.

The original published bundle stays immutable: its verifier requires zero
input rows. Native continuation admission and the input producer's complete
pending/message-prefix checks remain in force. A history cut or compaction
cannot bypass those checks through this primitive; its lineage remains
unresolved until a separate valid witness exists.

### Select exact input evidence and publish an adoption bundle

After reviewing the original bundle, assess the selected Keeper's current trace:

```bash
masc workspace-upgrade journal input --base-path WORKSPACE --bundle BUNDLE_ID --trace TRACE_ID
masc workspace-upgrade journal adopt --base-path WORKSPACE --bundle BUNDLE_ID --trace TRACE_ID --checkpoint-sha256 CHECKPOINT_SHA256
masc workspace-upgrade journal adoption --base-path WORKSPACE --adoption ADOPTION_ID
```

Assessment is read-only. It requires an internally verified source bundle,
unchanged live v2 journal, strict current Keeper metadata naming the trace, and
an owned canonical checkpoint whose exact bytes decode for that trace. It shows
the complete pending request and checkpoint digest. Current native and phase
continuations must have the same complete pending request and preserve their
messages as an exact prefix of the selected canonical history. An immutable
native admission seed is checked separately for preserved seed-to-latest message
history; its older pending field is not current input authority. A phase that
independently names that seed still receives the full pending check. Conflicting history, an active
native call, or unknown native effects require explicit repair. This command
does not choose the newest file, infer acceptance from empty pending input, or
reconstruct an earlier consumed answer from the old journal.

The second command is an explicit operator decision to adopt that exact current
input state as the selected baseline. It requires the assessed checkpoint digest,
acquires the configured BasePath lease and revalidates journal, metadata,
canonical bytes, source-bundle files and named retained history. It confirms
durable retention at the input owner's session location, then writes a separate
private `.masc/upgrades/journal-inputs/<adoption-id>/` bundle containing exact
`metadata.json`, exact `checkpoint.json`, `adopted.sqlite3` and a manifest published
last. The live journal, metadata, canonical checkpoint and original bundle remain
unchanged. Only the selected trace gains an input reference; the global unknown
history floor and every original journal cell remain intact.

A source change before manifest publication refuses publication and preserves
partial files and retained artifacts. Retention errors preserve their full typed
installation outcome; cancellation carried by post-commit unwind is re-raised
with its original backtrace. A visible manifest with uncertain parent sync returns
`durability_confirmed=false`. Keep all evidence after failures or uncertainty;
there is no automatic repair, cleanup or permission to retry blindly.

The third command verifies the source bundle, private metadata/checkpoint,
exact selected reference, actual retained payload and derivative database in
read-only mode. A missing retained payload is refused even if the canonical file
still exists; verification never recreates it or borrows canonical authority.
Rehashing changed derivative cells does not make them match the original journal.
This verifies an internal relationship, not current live-source freshness, past
fsyncs or human authorship against a process running under the same UID. Startup
cleanup may remove an unreferenced retained artifact before installation; restart
verification then refuses rather than recreating it.

All these preparation outputs keep `ready_to_install=false`. Installation and
rollback use the separate explicit commands below. History-cut/compaction
reconciliation, new-trace birth, host-response admission, reconnection and the
persistent TUI waiting-state surface remain separate work. Preparation does not
complete #38005 or make a running Keeper use the copy.

### Offline installation and conditional rollback

Journal operations use subcommands, each with its own required arguments.
The top-level released configuration inspection, `--apply` and `--restore`
commands above keep their existing behavior. The journal commands in this Draft
stack are development work; their existence is not whole-rollout acceptance.

```bash
masc workspace-upgrade journal installation-plan --base-path WORKSPACE --adoption ADOPTION_ID
masc workspace-upgrade journal install --base-path WORKSPACE --adoption ADOPTION_ID --source-sha256 ORIGINAL_SHA256 --adopted-sha256 DERIVATIVE_SHA256
masc workspace-upgrade journal installations --base-path WORKSPACE
masc workspace-upgrade journal installation --base-path WORKSPACE --installation INSTALLATION_ID
masc workspace-upgrade journal restore --base-path WORKSPACE --installation INSTALLATION_ID
```

Installation assessment is read-only. It reopens the internally valid source and
adoption bundles, requires the exact original live journal, and checks that the
current strict metadata/canonical still match the adopted selection. Installation
requires both assessed digests and the configured exclusive BasePath lease. It
reconfirms exact retained-payload durability rather than treating an earlier
readback as fsync proof. Only that retained file's witness is refreshed after
this identical-byte rewrite; every unrelated captured snapshot stays unchanged.

Before replacing the journal, installation writes a private durable intent at
`.masc/upgrades/journal-installs/<installation-id>/manifest.json`. An uncertain
intent parent sync refuses journal replacement. Once the intent is confirmed,
it rechecks all evidence and SQLite companion absence and replaces only the
selected Keeper journal through the shared strict atomic writer, preserving its
permissions. The original bundle and adoption derivative remain unchanged. The
installed database keeps unavailable prior history for omitted traces and does
not grant new native continuation or host-response authority.

A target rename followed by a sync failure returns
`durability_confirmed=false`; cancellation propagates even after rename. Keep
the intent and source/adoption bundles. If interruption occurred before an id
was returned, `journal installations` discovers the owned intent directory
without creating it and reports every observed entry with its id and either a
verified observation or its error. Partial/corrupt entries do not hide other
records or trigger repair. After restart, inspection verifies the intent and
classifies actual live bytes as `original_present`, `adopted_present`,
`changed` or `missing`. This is a current snapshot: an intent with original bytes
does not prove an installation never ran, adopted bytes do not certify a past
fsync, and original bytes do not prove rollback completed. Inspection does not
infer current input freshness or permission to retry.

Rollback holds the same lease and requires the live journal to equal the exact
adopted bytes, metadata/canonical to still match the selected input, and SQLite
companions to be absent. It rechecks descriptor/content evidence immediately
before restoring the verified original bytes, preserving current permissions.
A later operation, input edit, or unresolved companion refuses rollback. The
original, derivative and intent remain available after successful or uncertain
restoration. Restoring a v2 journal restores the original operator state; it
does not make that schema acceptable to a v3-only runtime.

The server must be stopped and independent editors must respect this offline
maintenance boundary. Last-read revalidation is not a POSIX atomic
compare-and-swap against a noncooperating writer. Development tests use owned
temporary workspaces only; no live installation or restart is part of this work.
The full stack remains Draft until the remaining continuation and operator-input
contracts are implemented and actually verified.

### Input checkpoint producer boundary

The next input layer captures an Owner-issued witness inside the original
executing child. Publication rechecks its inherited child token, trace, lane,
and exact predecessor in the Owner mailbox. Direct native/input references
advance together; autonomous input changes retain and publish before canonical
persistence. Consumed `pending_input=None` remains an observed retained payload
when the canonical write fails.

Admission also requires the source to preserve the retained input checkpoint's
messages as an exact prefix and its complete pending request. Two empty pending
fields do not prove that an accepted answer was retained. A history cut without
that evidence is refused pending explicit continuation reconciliation. This is
an incomplete recovery boundary, not proof that compaction, host responses,
reconnection, or the operator waiting-state surface are integrated.

### New Keeper trace creation

Actual Keeper creation mints a trace and Keeper UID together, reserves that
session directory exclusively inside the original live intake, and saves a
fresh initial context. It requires a confirmed `Saved` outcome and exact
canonical readback before retaining the initial input checkpoint. The empty
Owner rechecks the live creation capability, incarnation, canonical and retained
bytes, then registers this single trace before publishing metadata or starting
a child. The existing global unavailable-history floor remains unchanged;
unrelated old traces do not become fresh. An ordinary metadata create without
this capability does not grant input authority.

Expired capability, an existing session, changed evidence, an existing different
input reference, or the Owner's integrity/reconciliation fence refuses creation.
A failed or uncertain input registration does not publish metadata or start a
child; an already committed input row and retained checkpoint remain evidence.
Metadata and input registration are separate durable writes, not a single
cross-store transaction. Recovery must inspect their actual outcomes.

Do not merge or install the v3 stack alone. History-cut/continuation
reconciliation, operator-input response/reconnect/TUI integration, and actual
whole-rollout acceptance cases are still required. Offline preparation and a
conditional journal replacement do not substitute for those contracts.

### Retired native response cuts

The typed `Retry_without_thinking` path verifies the exact retained retired
checkpoint and permits removal of only its final incomplete Assistant message,
without a ToolResult. It preserves all other fields except the creation timestamp
and refuses pending input. It does not treat matching `pending=None` alone as
proof of history continuity.

The input producer captures its predecessor against the original retained source.
At actual next native scope publication, the adapter retains the exact cut and
verifies that the actual next seed contains every cut message. Owner revalidates
the original direct child, trace and admission state, then compares both the input
predecessor and retired native state in one SQLite transaction. This binds the new
call and publishes the cut input reference together. A stale predecessor or unknown
native effect leaves both authorities unchanged. An uncertain commit remains an
error even if it installed both; blind replay is refused. Retained files are
preserved as evidence, and cancellation embedded in retention outcomes propagates.

This connects the native retry path only. The operator history-clear boundary
is described below. Authoritative host response admission, reconnect/TUI behavior
and whole-issue acceptance remain unfinished. All #38005 stack layers remain Draft; these changes do not authorize
live installation or merge.

### Confirming retained checkpoint writes

The Native next-call seed, input Producer, Birth and journal-adoption paths use the shared
`Keeper_checkpoint_store.require_confirmed_installation` interpreter. Only an
installed result without auxiliary evidence yields its exact reference. A real
Eio cancellation in observer or unwind evidence is reraised with its original
exception and backtrace; committed bytes remain evidence. Other uncertain or
not-installed results retain the original structured result. The interpreter
performs no I/O and does not reconfirm uncertain durability.

The new focused cancellation cases use actual durable filesystem writes and the
existing observer/unwind test boundary. They establish the staged-result boundary,
not a full Native seed cancellation integration run. The native adapter calls the
same interpreter directly. This writer-boundary evidence does not establish the
remaining #38005 product acceptance.


### Operator history clear and input ownership

`masc_keeper_clear` captures a fresh authority inside its original Owner
Maintenance child before removing the official-client session. The Owner binds
that authority to its trace, original workspace session root and exact input
predecessor. Admission and publication both check every semantic record, including
terminal records with active or unacknowledged native evidence. Running operations,
unavailable prior input and either canonical or retained pending input refuse the
clear before official-session effects. Normal native terminal acceptance first
acknowledges `Retire`; a terminal unknown effect is not equivalent to that receipt.

The plan freezes its candidate bytes. It keeps only System messages when requested
and resets the existing repetition history generation while preserving the ledger
frontier. An equal-turn canonical with different nonhistory state is ambiguous and
is refused; two `pending=None` fields and equal turn counters cannot prove which
context is current. Loading a Keeper working context derives its Session
`message_count`; an absent value or the exact count of that checkpoint's own
messages is history metadata for this comparison. An inconsistent value is
refused, and other context/working-context differences are still checked. The
cleared payload stores its new count before retention and input publication.
A verified earlier partial history clear can be reconciled by
a fresh explicit operator action. A missing or undecodable canonical can be rebuilt
from the observed nonwaiting retained input. Genuinely fresh absent/superseded state
keeps the no-payload behavior; genuinely fresh undecodable state is removed under
the existing session lock. Newer versions and unreadable paths are refused.

Execution durably retains the cleared payload before installing it by exact source
CAS or absent-file admission. The original maintenance child then publishes its
input reference with a journal transaction that rechecks quiescence and predecessor.
The restart marker follows both confirmed commits. Neither a different child nor
a fresh authority can reuse the earlier receipt. Filesystem and SQLite commits are
separate: failures preserve partial evidence, publish no successful clear and write
no restart marker. Availability recovery may reopen the actual journal before a
fresh operator action; it does not blindly replay the old witness. Existing
integrity/reconciliation fences remain in force.

The focused fixtures exercise actual Tool/Owner/Store clearing, original authority,
next input-producer preparation, Owner reinstall, retained recovery, same-turn state
ambiguity, canonical CAS and journal commit uncertainty. Source typing is separate
from actually executing those fixtures. This boundary does not prove a provider
turn, host response admission, reconnect/TUI behavior, live installation or whole
issue completion. The entire #38005 stack remains Draft.

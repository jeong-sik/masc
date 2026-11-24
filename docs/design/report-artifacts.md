# Report artifacts

## Outcome

A Keeper can publish a report, document or self-contained HTML result that the
operator can reopen independently of the conversation. Dashboard Knowledge →
Artifacts provides a searchable catalog and a reader. The conversation card
opens the artifact at the published revision. Revisions preserve previous bytes.

This is the requested Claude Artifacts interaction applied to MASC's existing
workspace, identity and dashboard. It does not require another hosting service.

## User flow

1. A Keeper calls `keeper_artifact_publish` with title, summary, format and
   content. Markdown and HTML are explicit formats, not guessed from prose.
2. Publication persists the exact body before publishing its metadata. The
   author comes from the running Keeper identity. Task and Goal references are
   optional explicit source references.
3. The tool returns the artifact ID, revision and dashboard URL. The dashboard
   renders a compact open card for the successful publication tool result in the
   conversation. The Keeper includes the returned link in its report to users
   of other channels.
4. Knowledge → Artifacts lists published documents. Filter by format or search
   by title, summary or ID. Selecting a result opens the reader beside the list.
5. Switch revisions in the reader, copy the selected body or SHA-256, or
   download its Markdown or HTML source. The reader shows the author, summary
   and any Task or Goal links.
6. Updating an artifact requires its ID and expected latest revision. A stale
   revision produces a conflict without overwriting another publication. The
   stable link follows the latest version; a version link is immutable. An
   omitted Task or Goal retains its preceding revision's link; HTTP `null`
   clears it, and a supplied ID replaces it. The Keeper tool currently accepts
   a supplied ID or omission.

Existing files can be published by passing their body through the same API or
tool. Runtime directories and private conversations are not recursively indexed.
The report producer chooses which output is a standalone artifact.

The November 24 Proposal A+ retired the Dashboard's browser draft editor and
Office document converters. Keepers and API clients publish through the
existing publication endpoints.

## Storage and authority

- Root: `<base-path>/.masc/published_artifacts/`, resolved from workspace config.
- One atomically replaced metadata file per artifact, with newest-first revision
  metadata. A metadata file is the sole publication authority; there is no second
  mutable index or separate latest pointer to reconcile.
- Revision bodies use the existing durable content-addressed `Tool_blob_store`.
  Metadata holds the digest, byte length, explicit format, title, summary, author,
  timestamp and optional source references for every revision.
- Publication takes the artifact transaction lock, checks the expected revision,
  stores bytes durably, and commits metadata durably. Failure leaves the previous
  revision authoritative. A blob without metadata is not a published artifact.
- Listing reads only owned artifact metadata, sorts by update time and never
  reads all bodies. A missing/corrupt entry is reported as a diagnostic, not
  silently converted into an empty successful list.
- Stored IDs, versions, formats and references are validated at boundaries.
  JSON decoding rejects unknown formats or malformed metadata.
- Published content has no automatic expiry. Existing offline blob maintenance
  must preserve references from the artifact catalog.

## HTTP and tool contracts

The artifact catalog, shared-draft and application-input routes are registered
on both the HTTP/1 router and the h2c gateway. Both apply the same workspace,
token and allowed-origin checks. Application inputs remain private to the
authenticated actor and require `CanAdmin`.

The h2c listener reserves its configured shared response capacity for the
encoded response and an in-flight chunk. If capacity is unavailable, a normal
response gets an empty 503; a live draft stream is reset and reconnecting
attempts a fresh snapshot. If one snapshot exceeds the configured capacity,
reconnecting cannot deliver it until the capacity changes. A write may already
have been applied before a 503 or lost connection, so clients must read back its
outcome before retrying.

- `GET /api/v1/published-artifacts`: metadata list plus per-entry diagnostics.
- `GET /api/v1/published-artifacts/<id>?revision=<n>`: selected revision, exact
  body and available revision metadata. Omitted revision means latest.
- `POST /api/v1/published-artifacts`: same publication request as the tool;
  author is the authenticated actor, never supplied in JSON.
- Existing dashboard token authentication and admin permission apply to the
  catalog list, check state and publication routes. Capability-addressed single
  artifact reads (`GET /api/v1/published-artifacts/<id>`) allow unauthenticated
  read-only sharing only when external sharing is enabled for that artifact,
  while still validating any presented token. Responses are private and uncached.
  The server selects the requested revision under the same lock as sharing and
  publication. A read already admitted while sharing was on can finish after a
  revocation, but it cannot pick a revision published after that revocation.
  Enable or revoke sharing with
  `POST /api/v1/published-artifact-shares`. A change supplies `id`, `shared`,
  a UUIDv7 `operation_id`, the observed `expected_version`, the latest observed
  `expected_artifact_revision` and `expected_artifact_sha256`, and both roots in
  `expected_workspace`. A stale share or publication observation returns a
  conflict receipt without applying the change. The receipt is the result of
  that operation; the separately returned `current` snapshot is an observation
  taken after it and can already have been superseded.
  The Dashboard does not substitute a static report snapshot when the live API
  refuses a read; the static asset route also rejects its report-snapshot
  namespace. Previously downloaded or independently copied content remains
  outside the server's control after sharing is revoked, including copies held
  in browser or intermediary caches. In unbound Dashboard asset mode, descendant
  symlinks and multi-link files are refused even when they name ordinary assets.
- A pending first share change may settle on a subsequent read or before a
  later publication. Clients should retain the original operation ID and
  preconditions when checking an uncertain write. Workspace root pairs
  identify paths. Replacing a store at the same canonical paths can satisfy
  the same checks, so replay requires the original store.
- Share snapshots, the migration guard, and per-operation receipts form one
  storage authority; back up and restore them together. Receipts use disk space
  as operations accumulate. A missing historical receipt cannot be distinguished
  from an unused ID. Once a share is migrated, older MASC binaries must not write
  or serve that workspace: they cannot interpret the new state and may overwrite
  it. A new server detects a legacy overwrite but cannot fence an old process.
- `keeper_artifact_publish`: the same store operation using the Keeper's own
  identity. Publication is non-terminal: the Keeper can continue and report its
  durable link. No automatic duplicate Board/chat post is sent by the tool.
- Link: `/dashboard/#/workspace?section=artifacts&artifact=<id>`; append
  `&revision=<n>` for a fixed revision.

## Rendering

The Knowledge reader uses sanitized Markdown and an HTML srcdoc preview
with an empty sandbox. Artifact links from the conversation render sanitized
HTML or Markdown in the workspace reader. Opening the catalog reads metadata.
Selecting a result retrieves the selected body.

## Implementation and evidence

1. Durable catalog, publication tool and HTTP contract. Verify creation,
   restart/read, two revisions, stale-update conflict and exact body integrity;
   inspect auth, malformed input and failed-publication behavior.
2. Navigation, list/reader and publication card. Verify through component tests
   that exercise actual API responses, selection, revision/source views, search,
   missing/error states and stale-request handling. Run dashboard typecheck/lint.
3. Use the real HTTP service in an isolated workspace to publish Markdown and
   HTML, reload their links and check rendering on desktop and mobile.
4. Independent adversarial source review of the final change. Ordinary MASC
   stacks follow the repository's source-review workflow; source checks do not
   establish installed runtime behavior or deployment.

## Design references

- Claude Artifacts: https://support.claude.com/en/articles/17153992-what-are-artifacts-and-how-do-i-use-them
- HTML iframe sandbox: https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/iframe#sandbox
- Existing sources in the Dashboard include the Knowledge artifacts tab,
  the published artifact card and the workspace artifact reader.

External references checked 2026-10-19 KST. These references establish the
interaction and browser primitives; the checks above establish MASC behavior.

## Shared revision confirmation

An explicit check belongs to the workspace and the exact artifact ID, revision
and body SHA-256. Every client reads the same record even when authenticated
actor names differ. Opening a body, previewing an image and
refreshing today's inventory never write a check. A new revision starts without
a check even when its body is byte-identical to an older revision.

`GET /api/v1/published-artifact-checks` returns checks and storage diagnostics.
Only a successful complete listing can establish that a revision has no check;
unavailable or corrupt storage must remain unknown. `POST` accepts `id`,
`revision`, `body_sha256`, `checked` and `expected_change_id` (null for an
authoritatively absent record). Reading requires `CanReadState`; changing the
workspace-wide confirmation requires `CanAdmin`. Both return private, no-store
HTTP responses. The actor comes from authentication, not JSON.
A request may carry `expected_workspace` with canonical base/runtime
roots. The server validates and removes this envelope before strict operation
decoding, refusing mismatched roots before store dispatch. Dashboard requests
without this optional binding retain their existing contract.

Each mutation verifies the published revision and body digest, then compares the
opaque change ID from a stable-lock snapshot. The whole-record atomic replacement
must match that exact file identity and cursor under the same retained stable
lock. A successful check or uncheck
persists a fresh change ID and its actor/time. Unchecking does not delete the
record, so an old checked state cannot overwrite a later uncheck. Conflict
responses return the current record; an uncertain durable commit requires a
refresh before retry. Checks live under the resolved workspace runtime root and
do not modify publication manifests, history or source bytes. Data and lock
leaves are owned regular files; the stable protocol creates a new lock
exclusively and validates an existing descriptor binding before writing it.

### Check retention and storage recovery

The check store retains the latest state for each artifact ID and revision,
including its body digest, change ID, actor and time. Checking and then
unchecking the same revision replaces that record; it does not preserve the
earlier check or its actor/time as an audit trail. Different revisions retain
separate records. An explicit uncheck also creates a record when none exists.

Records are stored as `published_artifact_checks/<id>-r<revision>.json` under
the resolved workspace runtime root. Listing enumerates that directory and
takes a stable-lock snapshot of each `.json` record. Its work therefore grows
with explicitly checked or unchecked revisions, plus malformed `.json` entries,
not with automatically published revisions. Unchecking keeps the record and
does not reduce that inventory. Listing decodes check records without reading
or joining their published revision bodies; clients must still compare the
target digest with the publication inventory.

Malformed record content and a stored record whose digest disagrees with the
published target cannot be overwritten through the normal check/uncheck API.
Refresh or repeated `POST` requests do not repair that evidence. There is no
check-repair endpoint. For operator maintenance, first quiesce check writers for
the workspace, preserve the failing response and original record, and verify the
published revision and its body integrity. An operator can then move the corrupt
or mismatched data leaf outside the check directory, retaining it as evidence.
Keep the transaction's stable lock leaf in place; do not unlink or replace locks
to bypass a refusal. Unsafe ownership, lock or publication failures require their
own diagnosis rather than this data-record reset. After maintenance, refresh both
inventories and require a complete, diagnostic-free read with the expected
publication digest before making a new explicit check. An absent record uses
`expected_change_id: null`; the old confirmation and its change ID are not
restored. This is manual recovery guidance, not an automatic repair performed
by the service.

The publication API currently has no delete operation, and neither publication
nor unchecking removes check records. Any future deletion or retention cleanup
must coordinate retirement of the matching revision checks with publication
removal. A check listing alone does not detect a deleted publication; leaving a
syntactically valid check record behind would otherwise produce no storage
diagnostic. Such a deletion path must preserve transaction lock ownership and
keep the affected confirmation unknown until the coordinated change is complete.

The Dashboard list and the selected reader expose an explicit confirmation
button, including the actor and time for that exact revision. "Today unchecked"
counts current revisions only when both inventories are complete; unavailable,
partial or digest-mismatched evidence stays unknown. The unchecked filter follows
the same rule. Opening a report never checks it automatically.

Successful, conflicting and failed writes all require an authoritative reread;
the controls never optimistically confirm or automatically retry. Retiring the
credential epoch or selected revision retires the local write owner, even when
the server may already have committed its request.

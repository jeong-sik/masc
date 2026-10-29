# Report artifacts

## Outcome

A Keeper can publish a report, document or self-contained HTML result that the
operator can reopen independently of the conversation. The dashboard has an
Artifacts section with a searchable list and a reader. A conversation card and
the list open the same stable artifact link. Revisions preserve previous bytes.

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
4. Work → Artifacts shows title, author, summary, explicit document/web-page
   format and update time. Format and local-calendar-day filters help find
   today's publications or updates. The last successful inventory response
   supplies the displayed list-query time; this is not a human review receipt.
   An explicit HTML quick-preview action reads only that listed revision and
   opens an inert embedded preview, including self-contained images. Selecting a
   result opens a viewport-filling reader above the dashboard. Back to list or
   Escape in the reader controls returns to the searchable catalog. Search filters title, summary and
   author. Empty, loading, missing and failed states remain distinguishable.
5. The reader provides rendered/source views, revision selection, copy-link and
   exact-source download. HTML uses the remaining viewport. Markdown defaults
   to the available width for tables and code, with an optional centered reading
   width. Expand report information for the author, summary
   and any Task or Goal links. A native modal keeps background controls inert.
6. Updating an artifact requires its ID and expected latest revision. A stale
   revision produces a conflict without overwriting another publication. The
   stable link follows the latest version; a version link is immutable.

Existing files can be published by passing their body through the same API or
tool. Runtime directories and private conversations are not recursively indexed.
The report producer chooses which output is a standalone artifact.

## Dashboard editing and file import

The catalog's **파일 가져오기** action accepts one explicitly selected or dropped
UTF-8 HTML/Markdown file. The operator reviews its title, summary, explicit format
and source before publishing. Invalid UTF-8 is refused rather than replaced;
reading a file does not execute or publish it. The reader's **편집** action opens
a source editor. It captures the selected revision and Task/Goal links when
editing starts; a catalog refresh cannot silently rebase that draft.

When an editable draft opens, the editor captures canonical base and MASC roots
from health and requires the base to match its workspace authority. It checks
that the workspace and credentials still own the draft after this read, then
freezes the pair for publication, fixed-revision readback, and latest-version
comparison using the existing workspace precondition headers. The server rejects
a different pair before route dispatch, including a changed MASC root under the
same base. A failed identity read preserves the draft but blocks saving until the
editor is reopened; it never automatically recaptures or publishes the draft.

Credential or workspace-authority retirement closes the old editor but retains
its latest source and metadata under that original owner in the artifact surface.
The inert **이전 접근 상태의 원고** section offers source download and explicit,
confirmed discard; it cannot publish or reopen the draft with replacement
credentials. Imported source is retained before its first edit too. If another
reader is open, close it to access that section. Late publication receipts remain
separate and do not erase a retired draft. Only confirmed readback or an explicit
discard clears the active draft. This retention is in memory while the artifact
surface stays mounted: download before navigating away, reloading, or closing
the browser. It is not durable storage or a shared draft.

Saving uses the existing publication API once and then reads the returned fixed
revision to compare its body and metadata with the submitted draft. The response
identity is retained separately from successful readback. Conflicts retain the
draft and offer a read-only latest-version comparison. An uncertain write never
automatically retries; the operator can download the draft and inspect the
recorded revision. Late publication receipts retain their original workspace
even after the selection or credential changes, without a read under replacement
credentials. There is no automatic publication or confirmation on editor input.

This source editor is the first layer of #45940. Shared drafts, rich-text editing,
anchored comments and human/Keeper document positions require their own explicit
producer/store/consumer contract. Authorship or publication alone is not evidence
that a Keeper is currently viewing or editing a document.

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
- The read-only public Dashboard view sends its artifact request without the
  browser's stored bearer, actor header or cookies. An expired local credential
  therefore does not prevent an otherwise permitted anonymous read. Operator
  views and writes continue to use their captured authentication. Workspace
  authority alone is not operator permission: a tokenless reader uses the
  public view, and an initial operator read refused for lack of permission may
  try an anonymous view. A failed refresh retains an existing operator document
  and draft instead of replacing them with the public view. Retained drafts
  from an earlier authority stay accessible before a new reader dialog opens.
- The Dashboard can show a document read-only while workspace identity is
  pending. Before enabling edits or sharing, it captures both roots, rereads
  the document against them and requires the server's matched workspace-read
  receipt. If identity cannot be confirmed, editing and sharing stay disabled.
  Temporary HTML previews are inert and cannot run scripts; documents whose
  display is generated entirely by scripts may therefore appear blank until
  the workspace-bound read succeeds. Public HTML readers remain interactive.
  The editor and HTML app retain the roots of the admitted document, and their
  writes carry the pair in the body as well as request headers. Relevant draft,
  app-data and publication reads require the workspace-read receipt, including
  the shared-draft event stream.
  The share action requires a known sharing version and rechecks the selected
  revision and latest publication against the original roots.
  Before sending, it retains the exact operation in browser storage; if storage
  is unavailable, this tab does not send. If storage readback fails after a
  write attempt, another tab may have seen the request; this tab retains it in
  memory as unconfirmed, which may be lost on reload. An unconfirmed operation can be checked
  again with its original identity and preconditions, including after a page
  reload in the same browser origin. Checking may apply the original request;
  the recovery row shows its direction and original document. Separate tabs
  still rely on the server's version checks. Browser storage readback and UI
  tests do not establish survival of a browser or operating-system crash.
  A workspace refusal settles that HTTP attempt only; a concurrent attempt in
  another tab can still leave the operation unconfirmed.
  A pending first change may also be settled by a subsequent read or before a
  later publication, even if that publication then conflicts. Dashboard
  automatic link copying waits for an in-flight document refresh and compares
  its result to the independent share verification before copying. A failed or
  indefinitely pending refresh cannot establish a copyable share state. The link pins the
  displayed revision and uses the origin currently open in the browser, which
  may be a local address; it is not evidence that the link is reachable from
  elsewhere.
  Root pairs identify paths, not a durable store incarnation. Replacing a
  workspace with another store at the same canonical paths can satisfy these
  checks; do not replay an uncertain operation across such a replacement.
  Document-check requests have a separate existing workspace contract and are
  not protected by the new artifact share or edit body guards.
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

Markdown uses the existing lazy Markdown renderer, including its sanitizer and
diagram handling. HTML uses a sandboxed `srcdoc` frame with scripts allowed for
self-contained interactive results, without same-origin, popup, form or parent
navigation permissions. A prepended CSP blocks external subresource/fetch, object and nested
frame loads; inline script/style and embedded data images remain available.
The isolated document can navigate itself; this is not a general network
sandbox. It cannot navigate the parent dashboard or read its storage.
Source is displayed as text. Downloads contain the original stored bytes.
Bearer tokens and dashboard credentials are never passed into artifact frames.

The catalog quick preview uses an empty sandbox and disallows scripts in its
initial CSP. It is separate from the interactive full reader: opening the list
does not fetch every body or run HTML reports. Collapsing the preview, replacing
its listed revision or changing credentials retires its request ownership.

## Implementation and evidence

1. Durable catalog, publication tool and HTTP contract. Verify creation,
   restart/read, two revisions, stale-update conflict and exact body integrity;
   inspect auth, malformed input and failed-publication behavior.
2. Navigation, list/reader and publication card. Verify through component tests
   that exercise actual API responses, selection, revision/source views, search,
   missing/error states and stale-request handling. Run dashboard typecheck/lint.
3. Use the real HTTP service in an isolated workspace to publish Markdown and
   interactive HTML, reload their links and capture desktop/mobile browser
   evidence. Browser execution must show HTML interaction and isolation.
4. Independent adversarial source review of the final change. Ordinary MASC
   stacks follow the repository's source-review workflow; source checks do not
   establish installed runtime behavior or deployment.

## Design references

- Claude Artifacts: https://support.claude.com/en/articles/17153992-what-are-artifacts-and-how-do-i-use-them
- HTML iframe sandbox: https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/iframe#sandbox
- Existing sources: `components/chat/artifact-panel.ts`,
  `components/common/markdown.ts`, `Tool_blob_store`, workspace configuration.

External references checked 2026-10-19 KST. These references establish the
interaction and browser primitives; the checks above establish MASC behavior.

## Terminal artifact library

`/artifacts` (alias `/reports`) opens the existing authenticated report inventory
without sending a Keeper message. The command palette also finds it under
Artifacts / Resources. Published reports keep the Admin HTTP authority and exact
revision, byte count, UTF-8 and digest checks used by Resources; MCP resources
remain a separate typed authority.

The library uses the full terminal width by default: Enter opens the selected
reading and Esc returns to the list. `w` selects side-by-side browsing on wide
terminals. `f` cycles all resources, all artifacts, Markdown and HTML. `t` toggles
the local publication day captured at the keypress; the displayed date stays
fixed across midnight until toggled again. A refresh applies that same filter to
new metadata. Today means published or revised, not human-confirmed.

In an open report, `P` enables or revokes external sharing for the entire
artifact, including every revision. After an enabled state has been read back,
the detail shows its fixed-revision public link and `Y` sends that link through
OSC 52. The link uses the TUI's explicitly configured `MASC_HTTP_BASE_URL`;
an absent or invalid origin, local or wildcard literal, and noncanonical
numeric host are reported instead. A
configured origin is not proof of external reachability, and terminal support
for OSC 52 is not confirmed. `o` still opens the local Dashboard, and `y`
copies the report's source rather than its link.
Each share change retires the previous observation and any in-flight report
read. After a confirmed response, a fresh read checks the sharing state; `R`
rereads the exact open revision. If a change returns an error, the server may
still apply it: `P` and `Y` stay disabled for that artifact ID for the rest of
the TUI session, even after a reread. This session-local guard cannot prove the
request has settled across a restart or another client. A failed body read does
not prevent revoking a previously observed shared report.

List selection, search, cursor navigation and read requests all use the same
filtered inventory. Filtering out an open or pending document retires its read
owner; a late reply cannot restore it. The retained inventory still contains all
sources so another filter can reach them. A fixed older report revision stays
readable while its artifact remains in the selected inventory.

The reader starts with compact report metadata. `i` expands its URI, type and
size; `v` changes document/source presentation and `y` copies the selected
original text part through the existing OSC 52 path. These display changes do
not mutate source bytes or request another revision. HTML document mode uses a
standards-parsed, inert terminal reading: headings, paragraphs, lists, tables
and preformatted text. Original mode keeps the HTML syntax. Body search reads
exactly the same terminal projection as drawing. HTML whitespace is interpreted
only in document mode; copied bytes remain the original response.

HTML image declarations retain their original content-part number, including
multiple images inside one part and nested/table images. Image data URIs
are passed unchanged to the existing off-thread image decoder/converter only
when selected for preview. Their bodies are percent-decoded once before optional
base64 decoding; literal plus signs remain plus signs, and URI fragments are not
part of the decoded bytes. The complete original URI stays retained. External
URLs, file paths and non-image data remain explicitly unavailable; selecting
them does not authorize a fetch.
Inline SVG roots are serialized from the parsed HTML tree with element and
attribute namespaces preserved, then offered to the existing offline SVG
renderer on selection. This serialization is separate from the unchanged
original HTML source. Renderer validation still rejects scripts, event
handlers, foreign content, embedded images and external href references;
canvas remains unavailable. Browser CSS layout is not evaluated.
Base64 SVG resource parts and SVG image data URIs retain their declared
format through off-thread decoding and use this same offline renderer.
Retained attachments preserve the original image format separately from the
encoded wire blob's MIME, and verify wire size and digest before rendering.
Other declared image formats keep the existing image converter path.

Selected Resources images, generated/retained chat images and staged composer
attachments use pixel graphics
when the terminal supports them. A truecolour or 256-colour terminal without
those graphics protocols receives a colour character-cell preview instead.
PNG-to-RGBA decoding runs in the same acquisition worker with an aspect-preserving
grid fitted to the captured body box. Alpha is retained for the existing mosaic
renderer and colours go through the terminal palette projection. Temporary
decoder files belong to one attempt and are removed on success and failure.
The owner applies the existing generation, resource-reading and physical
workspace checks before painting either representation. A smaller terminal at
completion refuses the old grid and asks to reopen it; any key dismisses the
preview. Missing decoders and unsupported colour capabilities leave a visible
refusal with the original reading intact. Staged attachments decode their
captured local payload in the same worker without a peer request or verified
server identity; previewing leaves the original encoded attachment intact.
Their result still belongs to the original generation, view, Keeper, workspace
authority and exact staged attachment object. Losing peer confirmation alone
does not withdraw a local draft; replacement or removal of its attachment does.
Selected local file paths use the same background pixel/colour-cell presenter.
Their owner is the original local workspace epoch, so peer reconfirmation alone
does not withdraw them. Local files and staged attachments opened through the
Resources composer do not borrow that surface's unrelated document reading;
only peer Resource images require the original resource response. The worker reads the chosen file once, preserves its
source, and converts the captured bytes through the existing image converters.
This is the file observed by the worker, not a retained file-revision guarantee.
Explicit HTTP(S) image URLs keep their existing browser/download behavior.
Browser layout and copied source bytes are unchanged.
Acquisition progress is a temporary footer observation of the pending read,
bound to its generation, view, Keeper, workspace and original resource reading.
It disappears when that read completes or loses ownership; it is not appended
to conversation history. Actual acquisition and presentation failures still
leave their existing notices.
Scripts, metadata, templates, embedded frames and explicit hidden subtrees do
not contribute reading/image candidates. This reading does not execute CSS or
JavaScript, and does not reproduce a browser's page layout.

## Shared revision confirmation

An explicit check belongs to the workspace and the exact artifact ID, revision
and body SHA-256. Dashboard and TUI can read the same record even when their
authenticated actor names differ. Opening a body, previewing an image and
refreshing today's inventory never write a check. A new revision starts without
a check even when its body is byte-identical to an older revision.

`GET /api/v1/published-artifact-checks` returns checks and storage diagnostics.
Only a successful complete listing can establish that a revision has no check;
unavailable or corrupt storage must remain unknown. `POST` accepts `id`,
`revision`, `body_sha256`, `checked` and `expected_change_id` (null for an
authoritatively absent record). Both routes use the existing Admin authority and
private, no-store HTTP response. The actor comes from authentication, not JSON.
The terminal also supplies `expected_workspace` with canonical base/runtime
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

The TUI library independently reads this inventory on entry and explicit
refresh. Published report rows and the selected fixed revision show the shared
confirmation state; a checked or explicitly unchecked record retains its actor
and time. The list header shows today's unchecked current revisions and the last
successful check-query time. These observations do not write a confirmation.
Pending or failed refreshes, partial inventories, mismatched body digests and
unconfirmed workspace identity leave the current confirmation/count unknown.
Report inventory failure does not hide MCP resources, and MCP failure does not
invalidate an otherwise complete report count. Superseded or withdrawn check
responses cannot restore an older observation. In the list or reader, `c`
explicitly checks or unchecks that selected exact report revision. A pending
change leaves confirmation/count unknown and does not affect source bytes.
The request carries the observed change ID, a captured credential and workspace
binding; it is sent once without credential replacement or automatic write retry.
Success, conflict and uncertain transport all require a fresh shared-state read.
An earlier read cannot certify a still-pending write, and its cached observation
is retired again on settlement. Workspace withdrawal retires the local write
owner even if the server may already have committed. Live cross-client and
installed terminal verification remain separate evidence.

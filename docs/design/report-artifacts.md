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
- Existing dashboard token authentication and admin permission apply to these
  workspace report surfaces. Responses are private and uncached.
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
Named-file previews, browser layout and copied source bytes are unchanged.
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

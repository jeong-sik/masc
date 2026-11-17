# Keeper media fallback (H5)

Keeper projects media for each candidate before dispatch. The original blocks
stay in canonical history; only the request view changes. This document describes
the implementation and its limits. It is not a record of a live provider run.

## Admission and projection

The materialized runtime carries separate image, audio and document capabilities.
`supports-document-input` is independent of `supports-multimodal-inputs`: the
first grants a document, the second grants a request combining media kinds.
Unstated media flags grant nothing. A native Ollama wire and official-client
transports cannot gain document support from a model declaration.

For a candidate that does not admit the original input, `project_input_for_attempt` uses
these rules:

- A supported single modality keeps its original blocks.
- Unsupported images become existing vision readings or explicit unread references.
- Unsupported audio and documents become attachment-bound readings or explicit
  unavailable markers through `Keeper_media_reading`.
- If a runtime supports individual kinds but cannot combine them, every media
  kind in that request uses the text projection. Individual support does not
  silently grant mixed-input support.

The same scan covers the goal, initial history, resumed checkpoint and nested
`ToolResult.content_blocks`. Tool-result identity, outcome, structured result and
original text remain; only its attached request blocks change. The checkpoint
replay projection restores canonical originals after the attempt. A later capable
candidate receives those originals, not another candidate's converted input.

For Agent Core Keeper-history requests, `project_request_media` also runs after
the carried range is selected and materialized. It sees structured media newly
appended by tools as well as selected history. It checks the complete selected
bundle against the same admitted runtime on every request, using the walk's
existing media reader and image projector. Images use the artifact-only
`Store_only` mode here. Discarded atoms do not start readers at this stage.

This projection runs on the request's owning fiber, outside CPU sizing and
demotion previews. Canonical message occurrences remain the source of range
positions and digests. The projected view supplies both wire conversion and
dialect/signed-prefix inspection; a typed projection failure aborts the request.
The wire memo uses projected message values, so a later mixed bundle cannot
reuse an earlier native-document conversion. Tool effects are not rerun to
obtain the reading, and request projection does not rewrite their stored results.

See [runtime configuration](RUNTIME-TOML-REFERENCE.md#modelsidcapabilities) for
the declaration keys. Declaring a capability does not establish upstream support;
verify the concrete model and request wire before enabling it.

## Readings and their identity

`Keeper_media_reading` keys a reading by media kind, source SHA-256 and MIME type.
It uses the supplied media store to load stored attachment bytes. A successful
reading carries its source identity, reader version, text and observation time
under `<base-path>/.masc/media-readings/<keeper>/`.

A successful stored reading is reusable when its source and reader version match.
One lane walk owns one projector and memo, shared by candidates and messages.
A repeated attachment is read at most once during that walk, including when the
reader fails. A later walk can retry an unavailable attachment. Failure is never
stored as a successful reading.

URL and provider file-ID references are not fetched by this reader. They become
explicit unread references. A missing source, absent dependency, reader error or
empty result produces an unavailable marker without invented media content.
The original attachment remains available for another capable candidate.

## Existing external readers

- Audio uses `Voice_bridge.transcribe_audio` and the configured STT endpoint chain.
- PDF uses `Verification_pdf_inspection.extract_text`, which runs the existing
  Poppler text extraction path. It does not render every page to images or take
  a verifier review slot. Other document MIME types report `no_document_reader`.

The walk starts one reader deadline when it first needs a reader. The value comes
from the existing `Keeper_runtime_resolved.provider_call_deadline_sec ()`.
For this pre-provider step it is a wall-clock allowance shared by all attachments;
it is not a remaining turn budget or a limit on Keeper autonomy. Both readers
receive that deadline. Stored readings need no new reader call or deadline.

`Keeper_media_reading_maintenance` owns stored-reading retention. Retention is
separate from admission, original attachment ownership and successful extraction.
This change does not add cleanup of active data.

## Provider serialization boundary

Core request builders also consult the frozen document capability, independently
of Keeper's request-time reader.
Anthropic, Responses, OpenAI Chat/GLM and Gemini replace unsupported documents
with explicit omission placeholders, including through nested tool results.
Native Ollama rejects a document that reaches its serializer. Agent Core
Keeper-history requests now project unsupported structured attachments before
these serializers run. Direct Core callers and official-client internal rounds
do not gain a Keeper reader from the serializer. Canonical tool results remain
separate from the request view.

Anthropic and Responses share that document projection with their history-size
calculation. Anthropic also uses it for signed-reasoning prefix receipts, so the
receipt binds the content actually sent. Representable documents retain their
native bytes when admitted. Responses tool-result documents still use its
existing JSON-text representation; this is not native tool-result PDF support.

## Attached MCP results

Attached identity tools use `Keeper_mcp_content` for ordinary calls and approval
replay. The shared decoder preserves the received order before lane projection.
User-only content, raw `annotations` and per-block `_meta` do not enter that
model projection; resource names, descriptions, URIs and MIME remain visible.
Malformed annotations or media produce a visible failure without retrying the
external operation. Resource links remain references; they are not fetched.

A selected runtime can receive native images when its frozen runtime and
transport admit them; Core calls also require the frozen wire capability.
The path uses the existing supported image MIME types. Other images, audio and
PDF results become references to their exact
decoded bytes. The reference describes the original MIME, including parameters.
Generic embedded blobs, including ZIP files and empty files without a MIME
declaration, remain readable byte resources instead of being guessed into
documents. External MIME declarations cannot mint internal manifest authority.
Approval replay uses references for every media kind. A remote error remains an
error; its visible media is still readable through references.

The received MCP field set is retained separately for audit, including content
excluded by audience. Ordinary calls own it through the tool-call ledger;
approval replay owns it through the existing replay-result sidecar. The model's
latest-call status omits that private envelope reference. Operator audit access
remains separate from the model projection. This does not add a filesystem ACL.

Public byte references belong to a separate typed manifest whose children come
only from bytes this producer actually stored. An exact manifest marker in
canonical tool and approval input blocks preserves those children after interim
audit owners retire. The received private envelope is not a manifest child.
Official-client continuation does not save a Core checkpoint. Its spent replay
sidecar stays until the exact public chat lifecycle reference is durably appended,
or its existing ordinary/correction row is verified and fsynced. Confirmation
failure keeps the sidecar. This canonical chat ledger is outside dated audit
pruning; explicit Keeper removal retains its existing removal semantics.

This path preserves media bytes but does not invoke an external reader by itself.
It does not turn MCP audio or documents into native tool-result media for every
provider. Large text uses the lane's existing externalization threshold;
attached tools no longer declare that text threshold as a bound on native media.

Retained official-client results now keep their original receipt and artifact
references after acknowledgement, under `consumed-tool-results`. Only the pending
directory is delivered to later requests. Publication must be durable before
pending removal. This preserves the original result's blobs, not the transient
`By_address` carrier blob or the separate H5 reading cache. See
[retained result ownership](design/retained-result-ownership.md) for the ordering,
storage cost and remaining lifetime limits.

## Retained host attachment readings

Keeper-history runs share the walk's H5 reader across Core, Codex, Claude Code,
Antigravity and Muse. Their retained carrier is Text, so a normalized host audio
or document attachment needs a reading even when the selected runtime accepts
native media elsewhere. Ordinary native history projection is unchanged.
Completion review receives no retained-media reader.

The decoder admits only validated host receipts and the exact producer's
`response.content_blocks` shape. It reads normalized binary artifact references
for explicit audio/document slots using the sibling's original MIME. Arbitrary
nested JSON, vendor responses and image slots do not authorize reading. Known
unreadable slots produce an explicit unavailable reason without invalidating
the original receipt; URLs and file IDs are not fetched.

The carrier keeps the original encoded context and appends derived JSON keyed
by physical receipt digest and attachment slot. Reused call IDs do not collapse
occurrences. `read_stored` shares raw results, not history-formatted prose, so a
receipt reading does not falsely say that its original is in conversation
history. The existing viewer and active-producer filters run before reading.
Reading does not acknowledge a result or change its success/failure outcome.

Core, Codex and Claude prepare all readings before freezing the run carrier.
Their existing size-refusal hook stores and replaces the complete text, including
the readings; retries reuse that same carrier. Antigravity and Muse prepare the
same derived data in their direct context path, but have no carrier-address
shrink/retry mechanism. Large readings can enlarge those requests; this change
does not establish a size guarantee for either lane.

Consumed receipts retain original artifact bytes. Artifact-only ownership does
not retain the H5 disk cache: maintenance can evict a derived reading, and a
later walk then reads the preserved original again. The current walk still
shares one raw result and deadline. Temporary aggregate-address lifetime also
remains separate.

## Verification and remaining work

The focused behavior fixtures are in `test_keeper_turn_driver_failover`,
`test_runtime_modality_reroute`, `test_gate_keeper_backend`,
`test_runtime_provider_auth_headers` and `test_model_capability_presence`.
The failover suite also exercises the selected request projection and its media
reading and wire memos.
Agent Core's `test_media_document_admission` covers request serialization;
`test_provider_agnostic_reasoning_replay` covers the signed-prefix boundary.

The document capability repair adds cases for independent document/mixed flags,
all initial input locations, nested reading reuse, unsupported bundles,
checkpoint restoration, native wire bounds and provider sizing/prefix consistency.
At the time of this change, these OCaml cases are written but have not run in this
coding session. Syntax checks are not behavior evidence. A real PDF extraction,
STT endpoint, model response, restart and installed-binary continuity run remain
separate evidence requirements.

Attached MCP decoder, Gate and approval-sidecar cases are recorded in the
[MCP candidate evidence](evidence/2026-11-16-farm-mcp-content/README.md). They are
written source cases, not executed service/provider or restart evidence.

Request-time projection covers structured media in the selected Keeper-history
view. It does not cover media introduced later by the caller's custom history
projection, unsupported retained-result shapes, Completion-review requests,
official-client internal rounds, or a position that a provider cannot represent
despite its global document capability. Those paths need their own owners;
rendered receipt text is not parsed to discover attachments. Retained-reading
fixtures cover the decoder, shared reader and actual carrier APIs; execution
status is recorded separately in the Farm execution report. Restarted readings
and signed-prefix continuity still need execution evidence.

Generic non-PDF interpretation and URL/file-ID fetching remain outstanding.
These repairs do not complete the whole Farm multimodal requirement.

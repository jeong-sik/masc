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

An Agent Core tool can return a document after the initial Keeper projection.
Request builders therefore also consult the frozen document capability.
Anthropic, Responses, OpenAI Chat/GLM and Gemini replace unsupported documents
with explicit omission placeholders, including through nested tool results.
Native Ollama rejects a document introduced during a tool round; its initial
Keeper input still uses H5 projection. Neither behavior invokes the H5 reader
inside that tool round. Canonical tool results remain separate from this view.

Anthropic and Responses share that document projection with their history-size
calculation. Anthropic also uses it for signed-reasoning prefix receipts, so the
receipt binds the content actually sent. Representable documents retain their
native bytes when admitted. Responses tool-result documents still use its
existing JSON-text representation; this is not native tool-result PDF support.

## Verification and remaining work

The focused behavior fixtures are in `test_keeper_turn_driver_failover`,
`test_runtime_modality_reroute`, `test_gate_keeper_backend`,
`test_runtime_provider_auth_headers` and `test_model_capability_presence`.
Agent Core's `test_media_document_admission` covers request serialization;
`test_provider_agnostic_reasoning_replay` covers the signed-prefix boundary.

The document capability repair adds cases for independent document/mixed flags,
all initial input locations, nested reading reuse, unsupported bundles,
checkpoint restoration, native wire bounds and provider sizing/prefix consistency.
At the time of this change, these OCaml cases are written but have not run in this
coding session. Syntax checks are not behavior evidence. A real PDF extraction,
STT endpoint, model response, restart and installed-binary continuity run remain
separate evidence requirements.

MCP identity tools that discard non-text blocks, generic non-PDF interpretation,
URL/file-ID fetching and same-round external reading are separate outstanding
work. This repair does not complete the whole Farm multimodal requirement.

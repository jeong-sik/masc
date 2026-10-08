# Tool-schema contract ownership, 2026-10-09

Parent: `ceb642430239cd3be6804386660c2693942a53f1` (#42013).
Tracking issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).

`Llm_provider.Types` mixed message/response/stream declarations with tool-schema
grammar, exact JSON field decoding, nested key validation, parameter projection
and authoritative schema construction. Those schema operations form one pure
contract: a stored authoritative schema must have unique keys and its derived
parameter view must agree with it. Their owner is now `Tool_schema_contract`,
listed in Dune's private modules. `Types` directly includes that signature and
implementation, without duplicating converters, type manifests or validation.

The owner signature keeps `tool_schema` private and exposes validated constructors
and decoders. Raw generated record decoders and unchecked parameter projection
stay hidden. The public `types.mli` is byte-identical to the parent. Message,
response, stream and outcome behavior remains in `Types`; schema ownership does
not introduce runtime, provider transport or filesystem effects.

The derived parameter view has actual validation/introspection consumers, while
the authoritative schema retains enum, range, composition and nested constraints
that the view cannot represent. The two retain their separate meaning. Manual
checkpoint JSON and generated protocol JSON APIs retain their existing encodings
and share the same validation owner. No new alias, migration or permissive reader
is added. Ppx-generated display/error qualification follows the new owner name;
it is diagnostic text, not a provider JSON encoding. Inspected show/pp consumers
are test diagnostics. Custom field-error vocabulary is unchanged.

## Direct consumers and checks

| Boundary / consumer | Actual evidence | Result |
| --- | --- | --- |
| Exact public/manual/generated decoder | Refuse non-object schemas, malformed field values, duplicate/unknown keys, explicit null, and disagreeing schema/parameter pairs; accept unique projection | Existing decoder suite: 28 PASS |
| Schema constructor, Tool handler and provider wire projection | Authoritative constraints reach wire, nullable/composed/boolean properties remain represented, execution-env handler reads its schema, private constructors agree, both current JSON encodings round-trip | Existing fidelity suite: 19 PASS |
| Agent_core public type surface | Role/param/tool choice JSON, messages, usage, response and tool-result projections | Existing Types suite: 60 PASS |
| MCP bridge | JSON schema projection, native MCP schema fields and result handling through fake handlers | Existing MCP suite: 29 PASS |
| Construction/decoder access boundary | Public validated constructor compiles; public and owner record fabrication fail as private types; public and owner raw decoder access fail as unbound values | Four expected compiler refusals and one constructor success |

[checks.json](checks.json) records the focused four-target build (exit 0), 136
unique passing consumer scenarios and four executable fingerprints. The source
fingerprint file covers four changed source/build files and eight inspected
interface/consumer/test sources. No assertions or behavior test inputs were
rewritten to accommodate the extraction.

[api-probes/checks.json](api-probes/checks.json) records the exact small compiler
inputs and terminal diagnostics. The compiler was given the internal byte CMI
directory deliberately; even with that access, the owner's signature rejects raw
decoder access and fabricated records. A namespace-only alias compiled and is
recorded as informational, not proof of private-module installation visibility.
No Dune installation claim is made. Dune documents the private-module boundary
in its [library reference](https://dune.readthedocs.io/en/latest/reference/dune/library.html).

[extraction-comparison.json](extraction-comparison.json) verifies the exact parent
schema blocks against the owner after the declared header/comment change, the
remaining `types.ml` after the two block replacements, the selected owner
signature, and the unchanged public signature. This is extraction evidence,
not a substitute for the executed consumers or independent source review.
Terminal logs normalize trailing whitespace.

## Remaining scope

`types.ml` changes from 2,027 to 1,252 lines; the pure schema owner has 783 lines
and a 164-line interface. This separates one coherent responsibility; it does
not establish that all remaining message/provenance/hash/telemetry/streaming
responsibilities are fully assessed. The baseline candidate remains partial.
All original 171 candidates remain in scope: 18 production candidates have
bounded changes and 57 production candidates still require semantic review.

The checks use the local macOS toolchain and pure/fake-handler fixtures. No live
provider or Keeper lane was invoked. Linux execution, full CI/suites, installation,
merge and deployment are unverified.

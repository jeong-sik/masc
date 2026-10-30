# Checkpoint producer binding (#27894, layer 1)

The last collected provider response already carries a non-secret
`Types.Reasoning_source.t` even when its content has no reasoning. Agent state
and checkpoints previously discarded that session provenance. `provider_binding`
now carries that actual telemetry source through collection, cloning, checkpoint
capture, restore, full JSON/piece encoding, and identity deltas. It is not
re-resolved from a requested config or inferred from a model. Existing per-message
sources remain untouched for histories with multiple producers.

Checkpoint v15 requires an explicit `provider_binding` field. Null represents an
unrecorded binding, including a fresh state; it never invents a provider. Other
checkpoint versions are rejected. Delta v4 carries the same field in identity
replacement, including a binding-only change and explicit clearing. The validated
checkpoint JSON used for hashes contains it. All complete state/checkpoint record
constructors were inspected and updated; synthetic records use explicit null.

The source codec exposed for checkpoint persistence is the existing shared
Reasoning_source codec. Its endpoint material is SHA-256 hashed; raw URLs,
credentials and headers are not stored. During verification, the generated nested
replay-contract decoder admitted duplicate fields. The historical failing probe
is retained as `before-nested-duplicate.json`. The shared Source decoder now uses
`Json_object_keys` only to detect duplicates recursively and parses the original
JSON if none were found. It never installs a normalized identity.

Run the standalone component evidence:

```sh
python3 docs/evidence/2026-10-24-checkpoint-provider-binding/run_fixture.py
```

`result.json` records 16 passing checks and source/compiled hashes. The runner
compiles actual provider-kind, replay-contract and JSON-key modules/interfaces,
and the extracted actual Reasoning_source implementation/interface. It executes
the actual checkpoint provider-binding codec helpers and checkpoint field
builders. The historical field builder is loaded from pinned pre-fix main
`f9803add95065c6af4a69bba130308f402785ecd`; it drops the producer field. The
current field builder preserves it, including with an empty message list.

**Evidence boundary:** the serialization field-builder payload record and
non-binding encoders are fixtures, as are the Error envelope and metadata alias.
This is not a linked Core checkpoint, delta, pipeline or Agent run. No provider
HTTP, installed binary or runtime behavior was exercised. Requirements: OCaml,
findlib, Yojson, Uri, Digestif's C backend, ppx_deriving show/eq/yojson, Python and
Git. Inline tests are not removed from any compiled module.

Source fixtures in `test_checkpoint.ml`, `test_checkpoint_delta.ml` and
`test_pipeline.ml` additionally exercise full/memo JSON, missing/duplicate/null/
malformed bindings, old-version rejection, capture/restore, binding-only delta
hashing/application, and a text-only actual response through collection, clone
and checkpoint sink. Those project suites have not been executed locally. OCaml
parser checks establish syntax only.

This is the provenance layer of #27894. Resume admission remains to be connected
in the upper layer, including typed incompatibility before provider-bound Agent
construction, normal declared endpoint rotation, multiple per-message sources,
and pending-input settlement that makes no provider call. This layer does not
close the issue or claim that silent replay drops are already prevented.

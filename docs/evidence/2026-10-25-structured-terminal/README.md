# Structured terminal wire conformance — issue #27868

Production source base: `90cb0ca40011d36a28b2d4583ce11561e01c993d`.
The historical extraction defects have already been repaired in current main:
Text-only terminal parsing; explicit rejection of multiple Text blocks;
tool-result waiting; refusal/truncation/interruption before JSON success;
and typed schema/parse error evidence. The old run_structured API is absent.

This verification extends the existing test_structured suite through actual
provider wire parsers and the canonical stream accumulator. It does not change
production APIs or policy:

- Chat sync and SSE: content-free refusal/filter, refusal with valid JSON,
  truncation with valid JSON, tool-call-only intermediate and terminal JSON.
- Responses sync: refusal, truncation with valid JSON, tool intermediate and
  terminal JSON. Responses SSE: refusal.delta and refusal.done independently
  survive to structured refusal even when JSON text arrived earlier and the
  final snapshot contains no refusal item.
- Gemini sync and SSE: SAFETY, MAX_TOKENS and normal terminal JSON.
- Anthropic actual SSE parser/accumulator: Thinking at index zero precedes
  terminal Text JSON; extraction does not index the first content block.

The existing suite also contains assertions for tool-result/thinking exclusion, multiple Text
whitespace boundaries, no-text versus malformed/schema failures, and typed
state propagation through inspect and typed extraction, plus safe public
extractor failure labels. schema_extractor intentionally projects string
errors and is not the typed response API.

The new test parses and whitespace checks pass. No local Dune build or
executable test result is claimed here. A separately requested focused CI run
must record its actual checkout, selected cases and result. No provider HTTP,
installed runtime, UI or full regression proof is implied by wire fixtures.
Source hashes identify the already-merged production implementation against
which these new assertions run. The issue remains open pending verification.

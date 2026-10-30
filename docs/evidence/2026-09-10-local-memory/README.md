# Local memory-source evaluation

Observed live configuration: verifier_exact, librarian_exact, hitl_auto_judge
and board_attention_exact select remote runtimes. Local Ollama `/api/tags`
returned 32 installed models, while `/api/ps` initially returned none.
The existing Librarian input is per-Keeper; it does not itself establish
workspace-wide memory consolidation.

The first `qwen3:8b` call in `qwen3-8b/` is a connectivity/structured-output
smoke probe only. Its system prompt exposed the revision answer via the
`corrected_21_seconds` verdict, so its result must not be cited as independent
memory-evaluation capability. Preserve its raw request and response unchanged.

The revised script uses neutral verdicts and separate values, scorer-only
expectations, unique output directories and run provenance. It evaluates
synthetic claims and never writes Keeper memory or runtime configuration.
Even a passing result cannot establish explanation quality, long-term memory
quality, production integration, or universal model reliability.

Next acceptance is an unhinted local-model run, manual source/attribution
review, then a configured advisory role with source-backed workspace-memory
inputs and retrieval evidence. The 18-item objective remains open.

First smoke result: model reported `qwen3:8b`, `done=true`, stop reason
`stop`; 71.35 seconds wall time, 349 input evaluation tokens and 532 output
evaluation tokens. The three source-ID checks passed, but answer leakage
invalidates any independent-capability conclusion. Manual reading found the
explanations preserved the reported source conflicts and correction.

The corrected probe adds an alternate measurement correction (43 to 37
milliseconds), shuffles record order, uses a neutral `corrected` verdict and
requires the extracted value/unit separately. Source IDs, exact case coverage,
finite numbers and response completion are scored together. Free-text
explanation semantics still require manual review. The installed script
captures model/server identity and refuses to overwrite existing output.

## Unhinted result

`qwen3-8b-unhinted/` completed normally (`done=true`) in 145.50 seconds:
477 prompt tokens and 768 output tokens. Aggregate check failed. Artifact
and unresolved-conflict cases passed; both measurement corrections returned
the right value/unit (21 seconds and 37 milliseconds), but `source_ids`
contained only the replacement record (`r2` / `h2`) and omitted the prior
record (`r1` / `h1`). Manual reading confirmed the omitted prior IDs were
mentioned in explanation text, so this is a structured provenance-retention
failure, not a numerical-extraction failure.

The result supports investigating an advisory extraction role with
host-validated source coverage; it does not authorize automatic shared-memory
commit or prove a production role. No runtime settings were changed.

The corrected call began before the script's final timestamp/hash metadata
addition. Its receipt therefore lacks those fields; request/response and
Ollama version/model identity were preserved. Do not attribute the newer
script bytes to that completed invocation without this distinction.

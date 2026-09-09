# Standalone local workspace memory curator

`uv run scripts/curate-workspace-memory.py --context INPUT.json --endpoint LOCAL_OLLAMA_ORIGIN --model MODEL --output NEW_DIRECTORY`

The script consumes the workspace memory inventory from #34931, assigns source
identities, and asks an explicitly selected local Ollama model for shared claims,
conflicts and exclusions. Every source must have a disposition. It preserves
owner, revision, fact position, snapshot hashes, snapshot metadata, invalidations
and read gaps. The result is a **model proposal**, not verified shared memory.
It does not update Keeper memory, runtime configuration or an external service.

Raw endpoint responses and HTTP status are captured before JSON decoding. Model
output is checked with JSON Schema and exact source coverage. These checks do
not prove that a cited source supports a claim or that the synthesis is correct.
The complete input and model request remain available for semantic review.

[Ollama structured output documentation](https://docs.ollama.com/capabilities/structured-outputs)
provides the JSON Schema `format` contract. The endpoint and model are explicit;
no cloud model is selected by default.

## Initial measured run

`qwen3-8b/` ran on qwen3:8b in 44.02 seconds with 709 prompt tokens and 1784 output
tokens reported by Ollama. All four source IDs were accounted for. Semantic
inspection found that it copied contradicted and obsolete claims into shared
claims while also listing conflicts. This is **not a successful consolidation**.
The proposal remained unverified and was not promoted. This run predates the
metadata/raw-response review repairs.

## Validation and remaining work

Five CLI scenarios pass through a real local HTTP fixture and subprocess:
proposal provenance, omitted-source refusal, retraction/invalidation metadata,
remote-response refusal, and raw malformed/HTTP error preservation (some are
subcases). This is not a model-quality evaluation. No local repository build.

Remaining: ongoing server lane, change-triggered scheduling, independent semantic
verification, promotion/retraction of durable shared claims, Keeper recall,
Dashboard/TUI curator state, and long-running collaboration evidence. This CLI is
a manually invokable standalone proposal producer, not an autonomous shared lane.

## Revised 8B run

`qwen3-8b-revised/` completed in 25.86 seconds but was rejected: source IDs appeared
both in evidence references and in exclusions. Its content selected the corrected
21-second measurement but incorrectly treated missing source-bound stores as a
reason to exclude ordinary claims. No proposal.json was written. This is another
failed curator result, not a reliability improvement claim.

The current prompt explicitly separates independent store gaps from source
validity and defines exclusions as sources unused anywhere in the proposal.
The further run with the installed Qwen3.8 27B model completed; see below.

## Qwen3.8 27B observation

`qwen38-27b/` completed in 386.23 seconds (1141 prompt tokens and 4529 output
tokens reported by Ollama). Source coverage passed. Manual source comparison
found one useful shared statement: the analyst corrected the measurement from
12 to 21 seconds, citing both sources. The disputed PDF claim remained a conflict
with both owners attributed; neither alternative was promoted as verified truth.

This is one synthetic scenario and a model proposal, not a reliability estimate
or a completed shared-memory pipeline. The prompts changed between runs, so the
results are not a controlled comparison of model sizes. The long latency supports
further background-role evaluation rather than an interactive-path assumption.
No proposal was applied to Keeper memory.

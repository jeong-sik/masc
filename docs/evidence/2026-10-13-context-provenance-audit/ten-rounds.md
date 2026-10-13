# Ten additional audit rounds

Requested after the initial fixes in PRs #42713, #42716 and #42718.
Starting code: `d349d5853588292f0b0bbdcb6c2c10d8262bbbe2`.
The scope is context/reasoning provenance across provider and Keeper boundaries.
Each round records its invariant, counterexample, source/test evidence, changes,
independent review and remaining execution limits. A source inspection is not a
live-runtime or live-provider pass. Previously completed work is not counted as
one of these ten rounds.

| Round | Boundary | State |
|---|---|---|
| 1 | Malformed context provenance in Librarian evidence | Repaired in #42720; source review PASS; focused CI requested |
| 2 | Suppressed terminal replies and retained context ownership | Repaired in #42722; source review PASS; behavior execution pending |
| 3 | Streamed response provenance and checkpoint collection | Source audit and independent review PASS; no defect confirmed |
| 4 | Hook or persistence failure after provider response | Pending |
| 5 | Nested tool-result content and reasoning redaction | Pending |
| 6 | Checkpoint encoding, restore and metadata validation | Pending |
| 7 | Provider/endpoint/model rotation and replay eligibility | Pending |
| 8 | Multimodal tool-result projections and user attribution | Pending |
| 9 | Count/preview versus frozen generation input | Pending |
| 10 | Cancellation, resumed state and stale checkpoint writes | Pending |

## Round 1: malformed context cannot become new user evidence

Counterexample: a User-role Librarian input contains the typed runtime
context key with an invalid value or more than one occurrence. A unique invalid
value survives checkpoint metadata decoding. Duplicate keys are rejected by that
checkpoint decoder, but can occur in typed in-memory or alternate History input.
The memory-search
repair excludes it, but `Keeper_librarian.message_to_text` treated both cases as
ordinary conversation. Thus its injected body reached both the Librarian prompt
and `observations_for_absorption` under an ordinary speaker header.

Repair: omit both bodies while preserving message positions, distinguish
invalid/duplicate provenance explicitly in the header, and keep marker-looking
text from an untagged real user unchanged. The existing behavioral scenario now
covers all four tagged classifications through prompt variables, rendered
Librarian request and absorption observations. No canonical message is changed.

Execution: parser and focused behavior results will be recorded separately.
Independent source review: `d16a5a884392897f47d3edfe7697671711e64dc7` PASS.
Focused CI: https://github.com/jeong-sik/masc/actions/runs/38358072279 (result not yet read).

## Round 2: retained context must not outlive its suppressed response

The collector stores a Historical context immediately before a signed response.
`Keeper_replay_checkpoint.drop_trailing_assistants` removed that response when a
terminal effect had already delivered the answer or an internal turn excluded
its final note. It stopped at the context message, leaving the response-only
input in replay as a standalone User message. Earlier tool exchanges and their
context were unaffected, making this a tail ownership error rather than a
general history reset.

The repair removes only the immediately preceding Historical carrier when its
paired assistant is removed. It retains prior history, earlier tool-call
context, ordinary User inputs and ordinary completion. The finalization
regression covers terminal-effect suppression and internal-turn suppression,
and includes marker-looking user text as a negative case.

Independent source review: `1586e9677af96915a2129de15112ec7631fbfb6c` PASS
against `d16a5a884392897f47d3edfe7697671711e64dc7`.
Focused behavioral execution is pending; source review does not establish it.

## Round 3: stream assembly and source stamping

Inspected `Pipeline_stage_route.dispatch_stream`,
`Complete.complete_stream_serialized`, `Complete_common.patch_telemetry`,
`Complete_stream_state.signature_of_block`/`content_of_block`, and
`Types.assistant_message_of_response`.

Both HTTP and injected-transport completion results pass through
`patch_telemetry` before collection. It stamps the actual request configuration's
reasoning source. Collection refuses reasoning when that source is absent.
Signature deltas accumulate in order and are joined without text normalization.
Checkpoint collection consumes the completed response, not unfinished SSE deltas.
No source-loss defect was confirmed in these inspected paths.

Existing scenarios located: `test_provider_agnostic_reasoning_replay` rejects
missing source and persists present source; `test_stream_accumulator` checks
thinking signatures; `test_complete_http` exercises real loopback SSE with opaque
Responses reasoning and Anthropic thinking; `test_pipeline` covers sync-to-stream
checkpoint continuation. The latter was included in the completed successful
seven-suite run 38357088798 at its recorded head. The HTTP/SSE suites have not
been newly executed for this audit. This supports the inspected source contract,
not a live-provider or all-runtime streaming certification.

Independent review of these bounded source claims: `diagnosis_review`,
`1586e9677af96915a2129de15112ec7631fbfb6c`, PASS. No P0–P2 or
source-loss counterexample was found in the inspected routes.

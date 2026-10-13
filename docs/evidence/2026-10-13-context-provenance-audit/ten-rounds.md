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
| 1 | Malformed context provenance in Librarian evidence | Repaired in #42720; source review and focused CI PASS |
| 2 | Suppressed terminal replies and retained context ownership | Repaired in #42722; source review and focused CI PASS |
| 3 | Streamed response provenance and checkpoint collection | Source audit and independent review PASS; no defect confirmed |
| 4 | Hook or persistence failure after provider response | Bounded source audit and independent review PASS |
| 5 | Nested tool-result content and reasoning redaction | Repaired in #42725; independent source and focused CI PASS |
| 6 | Checkpoint encoding, restore and metadata validation | Checkpoint audit PASS; cache provenance repaired in #42728; source review and corrected focused CI PASS |
| 7 | Provider/endpoint/model rotation and replay eligibility | Rules reviewed; catalog-source drift addressed with round 9; account identity limit remains |
| 8 | Multimodal tool-result projections and user attribution | Bounded source audit and independent review PASS |
| 9 | Count/preview versus frozen generation input | #42727 and #42728 source review and focused CI PASS |
| 10 | Cancellation, resumed state and stale checkpoint writes | Bounded source audit and independent review PASS |

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

Parser validation passed; focused behavior execution is recorded below.
Independent source review: `d16a5a884392897f47d3edfe7697671711e64dc7` PASS.
Focused CI: https://github.com/jeong-sik/masc/actions/runs/38358072279
completed successfully at the same head.

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
Focused behavioral execution passed at the final documentation/changelog head.
Final documentation/changelog head `681b118d7b69efb0ccf039d0a67c1ad449b49252`
also received source PASS. Targeted run:
https://github.com/jeong-sik/masc/actions/runs/38358410887 (success).

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
seven-suite run 38357088798 at its recorded head. The HTTP/SSE suite later
passed in the cache follow-up run 38360117913 at
`ec46831e2706701fe6a61c132884185beb4daa58`. This supports the inspected
source contract, not a live-provider or all-runtime streaming certification.

Independent review of these bounded source claims: `diagnosis_review`,
`1586e9677af96915a2129de15112ec7631fbfb6c`, PASS. No P0–P2 or
source-loss counterexample was found in the inspected routes.

## Round 4: failed hooks and checkpoint sinks

`Pipeline.stage_collect` rejects a failed `after_turn` hook before appending the
assistant or its retained context. After successful admission, it updates live
state before passing that same state to `Pipeline_checkpoint.persist_for_state`.
A sink failure returns before tool execution. `Agent_execution_runner.with_scope`
passes the error through durable abort rather than reporting completion.
No new provenance-loss counterexample was found in these boundaries.

`test_agent_advanced.test_assistant_checkpoint_failure_suppresses_release_and_tool`
already checks that the rejected snapshot and live state agree on their message
count and that neither tools nor release/boundary callbacks run. Its response is
unsigned: it does not prove retained signed-context bytes or all crash windows.
Independent source review: `diagnosis_review`, base inspection at
`681b118d7b69efb0ccf039d0a67c1ad449b49252`, PASS. No new execution claimed.

## Round 5: nested tool data must not become protocol reasoning

A tool handler can return arbitrary typed `content_blocks`. The shared replay
projection inspects top-level reasoning; nested blocks in a `ToolResult` are
tool data. `Backend_anthropic.anthropic_content_block_to_json` recursively
serialized those nested values as protocol blocks, so a tool-provided Thinking,
RedactedThinking, ReasoningDetails, ToolUse, ToolResult or Audio could make an
invalid Anthropic request. This is distinct from the original prefix mismatch.

The [Anthropic tool-result contract](https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls)
permits text, image, document and search-result nested blocks. Of the existing
typed constructors, the repair preserves Text/Image/Document natively and wraps
the other variants' JSON in a text block inside the same tool result. It keeps
the source checkpoint and block order unchanged. Kimi already selects
`Api_common.kimi_message_to_json` separately, so this boundary change need not
alter its wire. OpenAI/Responses/Ollama use string data for these tool blocks.

The request regression exercises completion and count requests, unsigned/signed
and foreign opaque nested reasoning, nested tool use/results, audio, supported
media, source equality and unchanged Kimi messages. Parser checks passed;
independent source review at `73895a3640f7df56795e5de5b77d06af4889f502`
is PASS. Targeted run: https://github.com/jeong-sik/masc/actions/runs/38358749814
(success at that head). This targeted success is not a live-provider run.

## Round 6: full and delta checkpoint metadata

Inspected `Checkpoint_codec.message_json`, `message_of_json`,
`validated_message_encoding`, `drop_unencodable_json`, `Checkpoint_delta`'s
message splice and Keeper's context/checkpoint conversions. Normal full and
delta paths preserve complete metadata and content. Splice equality includes
metadata; the strict public checkpoint boundary rejects malformed JSON rather
than treating duplicate keys as an ordinary authoritative record. The explicit
unencodable-JSON recovery path may drop invalid payloads and reports that recovery;
it is not evidence that arbitrary malformed metadata is safe to replay.

Existing full/delta metadata roundtrips and nested duplicate-key scenarios were
located. The earlier #42716 finalization-to-disk-to-replay test passed in run
38357586007. No additional ordinary-path metadata loss was found. New full/delta
suite execution was not performed for this audit.

The subsequent response-cache audit found a distinct persistence boundary:
`Cache.response_to_json`/`response_of_json` did not store or restore telemetry.
A signed response cache hit consequently lost its producing reasoning source
and could not pass `Types.assistant_message_of_response`. Its list-filtering
content decoder could also silently remove malformed blocks. The cache repair
stores original telemetry with the existing typed codecs and rejects an
unreadable response as a miss. It does not manufacture a new source on a hit.
The request-level regression follows a signed HTTP response through cache
storage, cache hit and assistant-message collection.

## Round 7: provider, endpoint and model changes

Inspected `Types.Reasoning_source` and `Reasoning_dialect.rotation_policy` with
`Reasoning_history_projection.project`. The source combines provider kind,
canonical model, replay contract and an endpoint/request-path digest. Signed
Anthropic/Gemini and opaque Responses state require the identical source;
self-contained reasoning can rotate endpoints only under its declared policy.
The existing provider-agnostic scenarios check per-dialect selection and changed
endpoint, model and contract. No new violation of that declared rule was found.
Independent review did identify that the contract used to stamp the response
could drift during a catalog reload; round 9's request-policy snapshot addresses
that additional timing boundary. This rule review alone did not prove that the
pre-repair response always received the right source.

Limitation: this identity does not include credentials or the proxy's hidden
account/route. A different account behind an unchanged endpoint is not detected
by the source comparison. No account-rotation safety or live provider matrix is
claimed. Anthropic's prefix-mismatch control in #42713 is a separate mechanism,
not proof that all account changes preserve a reasoning artifact.

## Round 8: multimodal projection and user attribution

Inspected `Tool_result_projection.with_image_followups`, OpenAI's
`messages_of_message_with`, Gemini's `build_request_artifact` and
`contents_of_messages`, and Responses tool output encoding. Synthetic user media
followups are built from a projected copy, after reasoning-history selection;
they do not redefine the latest real user turn in canonical history. Tool-result
labels retain the call identity and error outcome. No additional canonical
user-attribution leak was found in these paths. Round 5 handles unsupported
nested Anthropic protocol blocks separately. No new multimodal live run claimed.

## Round 9: measurement and dispatched input

Inspected `Prepared_completion_request.prepare`, `admit_serialized_body`,
`measure`, and sync/stream routing. Admission saves the serialized body
alongside its prepared request; measurement carries that admitted body into
generation. The stream timeout adjustment updates transport timing without
rewriting body bytes. Independent review found that ordinary measurement itself
still rebuilds the count request from the current catalog. A catalog reload
between serialization and count can therefore count a different projection from
the frozen generation body. Output reservation can drift too: a frozen request
with 64 output tokens could be admitted using a later 16-token catalog ceiling.
Response telemetry similarly re-resolved its reasoning contract after dispatch.

`test_anthropic_input_token_count` covers catalog mutation after measurement,
which misses this earlier window. `test_exact_output_flow` covers a separate
frozen-artifact path whose count projection is already derived from that artifact.
Both were in successful run 38357088798, but that success does not discharge the
new counterexample.

Repair: `Provider_config.freeze_for_request` captures capabilities and Anthropic
policy from the same catalog/manifest snapshot at request preparation, including
absent entries. It preserves explicit caller overrides and disregards a stored
snapshot for a different provider/model identity. The count adapter, serializers
and telemetry access the same prepared configuration. Existing live lookups
retain their behavior for unprepared callers. No user configuration knob was
added. Five new scenarios cover HTTP sync/stream changes before measurement,
the 480 + 64 > 512 reservation counterexample, and a six-provider matrix of
present/absent entries, explicit overrides, identity changes and response source.
Parser validation and independent review of committed head
`e01bb1f3ca1e69b0bc2a5c8d0d7a28d91c8d771b` passed. Its three targeted
suites passed in run https://github.com/jeong-sik/masc/actions/runs/38359308273.
The response-cache key is a separate confirmed finding: it omits
capability defaults and reasoning-source metadata, although those can change
the serialized request. A hit returns the old response without dispatch. The
follow-up must bind cache hits to the actual request; restamping old reasoning
with a new source would hide the mistake. This change does not redefine cache
identity.

Cache follow-up: bind the existing conservative identity to the exact admitted
HTTP codec/body and reuse that body for dispatch. A changed model ceiling or
reasoning-source projection produces a miss; an identical effective body can
still hit. Opaque injected transports supply no HTTP identity and therefore
bypass this optional response cache while continuing to execute normally.
Provider-side prompt caching is unchanged. The HTTP regression checks changed
catalog defaults and compatible/foreign/absent reasoning-source metadata,
admitted-body reuse and no dispatch observer on a cache hit. Separate cases
exercise an injected transport that cannot serialize as HTTP.
Independent `diagnosis_review` source PASS at
`bb81c1374db51bafafa87547f86c7603d458e18d`, against
`e01bb1f3ca1e69b0bc2a5c8d0d7a28d91c8d771b`. Full diff SHA-256:
`1c1d24137e4a7d15e48d3492d2c538a0491925340829fd3ce60367fce8842f9e`.
The final documentation/changelog head
`150774e5346219dd8ee0c2e18817e159a6688310` also received source PASS.
Targeted run https://github.com/jeong-sik/masc/actions/runs/38359756303
passed `test_complete_http` (88 cases) and `test_complete_ext` (10 cases), but
`test_llm_cache` failed 1 of 39 cases. The newly extended nested-tool fixture
expected only `preview` in its text summary, although the existing shared
decoder includes both Text and Thinking data from nested tool blocks. The
fixture now expects the two-line summary `preview` followed by `tool data`
and asserts every nested block,
including its signature, equals the original. No production decoder change
was needed. Corrected head `ec46831e2706701fe6a61c132884185beb4daa58`
received independent source PASS (full diff SHA-256 against the base above:
`7b96e64991d06ea019f8d16e3d46c27ec4b570c27d4706ebf5b27d83c01f9e74`).
All three targeted suites passed at that head (88 HTTP, 10 injected-transport
and 39 cache cases; 137 total) in
https://github.com/jeong-sik/masc/actions/runs/38360117913 .
Subsequent completion-record edits change documentation only and do not
relabel this execution as a run on a later commit.
Cache decoding uses the existing content-block decoder contract; this is not a
claim that every form of arbitrary stored corruption has been tested.

## Round 10: cancellation, resume and stale writers

Inspected `Keeper_checkpoint_store`'s session-lock writes and exact-source CAS,
`Agent_execution_runner.abort_after_exception`, and the pipeline resume frontier.
Lower-turn writes become `Stale_noop`; source-CAS writers compare the exact
checkpoint reference, so competing same-turn candidates cannot both commit.
The resume frontier uses durable turn identity rather than recomputing it from
mutated state. Cancellation is preserved through protected execution abort.

The existing `test_history_link_keeps_transaction_until_cancelled_job_finishes`
holds an accepted history-link job, cancels its caller, and checks that a later
writer cannot pass until the transaction finishes. Existing source-CAS cases
cover equal-turn contention. Ordinary stage saves intentionally allow equal
turn numbers; these observations do not prove exclusion of every possible
same-turn caller. No additional provenance defect was established within this
bounded audit, and those suites were not newly executed.

## Execution and completion limits

Ten boundaries were inspected, with six additional repair findings in rounds
1, 2, 5, 6 (cache response provenance) and 9 (request-policy timing and cache
identity). Independent review and requested behavior results remain separately
recorded above. The production runtime has not been replaced by these branches.
The original #42718 test suite had one pre-existing publication-test contract
failure; its new context-exclusion case passed. Separate test-only PR #42723
repairs that expectation; its targeted suite passed at
`75ee4ca9e8f180aa58abfcc6476890e5c21fafb0` in run 38358719791. This does not
retroactively turn the failed #42718 run into a suite success.

The ten-round audit is complete as a set of reviewed repairs and bounded
verification, rather than a release or runtime certification. The six additional
findings are covered by #42720, #42722, #42725, #42727 and #42728, with both cache
findings in #42728. Every repair has independent source review and focused
behavioral execution. The #42727 matrix covers all six provider kinds in sync
and stream modes, including present/absent catalog entries and explicit
overrides; it uses injected transports, not paid live-provider calls.

The PRs remain open with REST `stack: null`; their explicit branch-chain heads
and bases were checked against the reviewed commits. MASC `code-reviewer` was
asked to review the changes; a queued request is not formal approval. A final
head refresh is sent after this documentation-only completion record is
committed. The read-only runtime health check still reports build
`d95d23b42b8d169946562957d9b7a363c12673ff`, so none of these branch repairs is
claimed to be installed. Same-endpoint hidden account changes remain outside
the source-identity guarantee described in round 7.

# One exact model catalog for request policy

This is the bounded catalog repair for [#27898](https://github.com/jeong-sik/masc/issues/27898)
in [PR #47077](https://github.com/jeong-sik/masc/pull/47077), layer 6 of Native
Stack #47016. The full caller/binding hard cut remains open.

The old TOML projector dropped `supported_models`. Both raw and selected configs
therefore lost an exact declared allow-list. Selected-binding resolution also
let a provider-independent model without a preset inherit its provider's tool
support, although the same bare lookup declared no such support.
Four committed public-entry regressions reproduced these differences before
production sources changed.

Strict JSON capability input now composes into an immutable `Model_catalog`
before provider selection. `Capability_manifest` remains an input parser, with
no separate global state or direct execution-policy API. A single pure catalog
projector supplies raw request preparation and selected/exact-output bindings.
It preserves both `supported_models` and `emits_usage_tokens` declarations.

Composition replaces the complete capability declaration of an exact bare row;
omissions use that declaration's own preset/default rather than previous
capability values. Only the exact previous row's prices, cache multipliers,
task, suggested clients and serving constraint survive. Scoped rows retain
precedence, and JSON does not add provider declarations or bare-model permission.
Existing selected and frozen configs keep their captured policy after a catalog
replacement; fresh selections observe the new catalog.

## Executions

Every row below is the **Test** workflow. All commands use `minimal=true` and
explicit suite selections. Actual case lines are counted once; assertion lines
and repeated failure-detail headings are not extra cases. Results from different
runs are not added together.

| Run | Exact executed head | Ref | Conclusion and actual cases |
| --- | --- | --- | --- |
| [41266069364](https://github.com/jeong-sik/masc/actions/runs/41266069364) | 8c9dd5d3bac49c2230d78cf59486ba582187fd50 | fix/unified-model-catalog-20261101 | Failure, **0 PASS / 4 FAIL**; new composition suite only; production unchanged from parent. |
| [41266725259](https://github.com/jeong-sik/masc/actions/runs/41266725259) | aace51ea47586a6403ba5aa344088dbec6a5e865 | fix/unified-model-catalog-20261101 | Failure, **341 PASS / 3 FAIL** in five focused suites. Composition 10, capabilities 124, provider config 142, exact resolver 17 passed; thinking-control had 48 PASS / 3 FAIL. |
| [41266932293](https://github.com/jeong-sik/masc/actions/runs/41266932293) | 05e6e0232c17324bcf1c69b74376bca0078058bc | fix/unified-model-catalog-20261101 | Failure, **498 PASS / 7 FAIL** in eleven focused suites. All eleven composition cases passed. |
| [41267009494](https://github.com/jeong-sik/masc/actions/runs/41267009494) | 27a4e3337466de8272e2055fd4035795f7ceebe8 | fix/terminal-resume-frontier-20261101 | Failure, **48 PASS / 3 FAIL**; parent reproduces the same thinking-control failures. |
| [41267187007](https://github.com/jeong-sik/masc/actions/runs/41267187007) | 27a4e3337466de8272e2055fd4035795f7ceebe8 | fix/terminal-resume-frontier-20261101 | Failure, **46 PASS / 4 FAIL**; parent reproduces the same two catalog and two serialization failures. |
| [41267419419](https://github.com/jeong-sik/masc/actions/runs/41267419419) | c895615a9bfe6b885cb47a27b9ea80b095d80242 | fix/unified-model-catalog-20261101 | Success, **681 actual PASS / 0 FAIL**: 507 Core cases and 174 MASC runtime-config cases in twelve focused suites. |

The final run includes the same eleven core suites plus the changed MASC
`test_runtime_config_validity` consumer. All requested suites executed and
passed. The seven parent fixture failures are included in that success; the
serialization suite also executes two new caller-boundary cases. The original
four catalog regressions remain in the eleven-case composition suite.

The explicit core selection is:

```text
packages/agent_core/test/test_model_catalog_composition
packages/agent_core/test/test_capabilities
packages/agent_core/test/test_provider_config
packages/agent_core/test/test_exact_output_resolver_snapshot
packages/agent_core/test/test_thinking_control_dialects
packages/agent_core/test/test_model_catalog_default
packages/agent_core/test/test_backend_gemini
packages/agent_core/test/test_responses_reasoning_content
packages/agent_core/test/test_cohere_schema_wire
packages/agent_core/test/test_snapshot_provider_serialization
packages/agent_core/test/test_provider_runtime_binding
```

The eleven composition cases include complete selected/raw policy equality,
base isolation, JSON usage/thinking declarations, metadata preservation, scoped
precedence, anonymous/declared provider permissions, frozen-policy stability,
provider overlay authority and strict input errors. The request-body case
asserts an output ceiling of 17 and reasoning effort `high` through selected,
raw and endpoint-overridden configs.

## Fixture repairs and their limits

Parent execution, rather than unchanged-file comparison alone, establishes the
seven pre-existing failures. Three fixtures asked native backends for IDs absent
from their exact catalog: an undeclared Ollama tag, a dated Anthropic spelling
and a Gemini subscription runtime slot spelling. Positive tests now declare or
request the exact model, without restoring prefix/tag/date inference. The
adjacent passing Gemini control also uses its actual native catalog ID.

OpenRouter fixtures still expected the removed DeepSeek spelling and omitted
the later Nemotron row. They now check the admitted declarations, including the
DeepSeek 1017 ceiling of 393216. The retained
[October 28 evidence](../2026-10-28-openrouter-bindings/README.md) establishes the
exact new IDs, successful tool calls and zero reasoning tokens for `none`; it
does not retain gateway listing evidence for that ceiling or prove every effort
rung. These assertions are declaration checks, not independent measurements or
fresh provider probes.

The two serialization fixtures called an ordinary `Conversation User` message
a recovery nudge. They now use the producer's `Recovery_instruction` origin,
preserving the original merged-content assertions. Two additional actual-wire
cases keep real caller requests separate from tool results on Anthropic and
Gemini. Production merge policy is unchanged.

## Provenance and remaining scope

[manifest.json](manifest.json) contains run/ref/head/conclusion records and
separate raw and selected-capture digests. Complete public job logs remain in
ignored `artifacts/issues-oldest-20261101/unified-model-catalog/`. Retained text
removes UTF-8 BOM and ANSI, selects checkout/suite/case/assertion/failure/summary
lines, removes trailing whitespace and ends with one newline. The selected-text
hash does not certify original raw bytes.

[source-sha256.json](source-sha256.json) records 21 changed-code/fixture and
catalog/support inputs at candidate `c895615`. Twenty remain byte-identical;
the only later source delta is a normal explanatory comment in the catalog
fixture clarifying declaration-versus-measurement provenance. It changes no
declaration, expression or assertion. Evidence and changelog commits are not
executed heads.

Independent adversarial and response source review of base
`27a4e3337466de8272e2055fd4035795f7ceebe8` to `c895615` found no P0-P2. The canonical
Git-object diff identity is
`b3ec7edf18e604799cc887553c2961aff4c429497491eacf857ffd3608052199`.
Final evidence review binds its own current head and diff. Source review is
separate from execution and from formal non-author GitHub approval.

No local Dune build was run. Syntax-only parsing and whitespace checks passed;
neither is a typecheck or full regression. No real provider HTTP, installed
runtime, deployment or Dashboard behavior was exercised. Capability capture
does not establish immutable response-time pricing: the existing pricing and
Agent-turn costing readers still consult the global catalog. The remaining
high-level caller/binding hard cut, those pricing consumers, whole-stack
approval/integration and the issue's full acceptance remain open.

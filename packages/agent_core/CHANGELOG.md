# Changelog

All notable changes to `agent_sdk` are documented in this file.

Historical note: release notes for `0.100.3`, `0.100.5`, and `0.100.6` were
backfilled on 2026-04-04 from existing git tags. The dates below reflect the
original tag dates. `0.100.4` was never tagged or released.

## Unreleased

### Changed

Validated exact-output flows can now be frozen through the direct
`Exact_output.snapshot_validated_flow_evidence` API. The current-only canonical
snapshot preserves declared-order admission, measurement, attempt, transport
advance, semantic rejection, and final acceptance evidence without
reconstructing a live flow during decode.

Execution projection no longer re-checks committed event sequence uniqueness.
The read-only event store supplies only private validated snapshots, and the
journal reducer enforces the exact next sequence before projection mutates its
derived index.

### Bug Fixes

GLM streaming now parses reasoning deltas through the resolved typed
model/provider dialect. The backend no longer hardcodes
`delta.reasoning_content` independently of the catalog.

Gemini streaming and non-streaming responses now share one finish-reason
mapping. A function-call block truncated by `MAX_TOKENS` remains terminal and
is not promoted to executable tool use. Documented policy filters map to
refusal, while a missing or unknown terminal reason remains non-executable
instead of being inferred as `STOP` from tool-block presence.

### Breaking Changes

`Exact_output.execution_error_cause` no longer exposes the removed
`Input_capacity_refused` wrapper. Current callers match the typed
`Serialized_request_refused { http_status }` cause directly; no compatibility
constructor or migration decoder is provided.

`Structured.schema` now contains only the provider-native JSON Schema
parameters and typed parser. The unused forced-tool `name` and `description`
fields, `schema_to_tool_json`, and `extract_tool_input` are removed rather than
retained as compatibility state. Current callers use
`schema_to_json_schema`, `extract`, `extract_stream`, or `schema_extractor`.

`Provider_config` now carries provider-native JSON Schema requests only as
`response_format = JsonSchema schema`. The duplicate `output_schema` record
field, constructor argument, derivation helper, and the Exact Output
contradictory-state errors are removed. This makes the previously gated
inconsistent state unrepresentable; callers must set `response_format`
directly. The boolean `response_format_json` constructor/builder shims and
boolean/null response-format decoding are also removed.

`Tool.t` now has one execution-environment handler shape. `Typed_tool`
constructors return canonical `Tool.t` values directly, and the secondary
typed runtime representation, erasure bridge, and unused agent-tool raw input
field have been removed.

* **checkpoint persistence:** accept only the exact current v10 checkpoint
  schema. All earlier artifacts, including released v9, must be reset rather
  than migrated at runtime.
* **provider tools:** reject historical OpenAI `parameters` lists; current
  callers must supply `input_schema` or an already-provider-shaped JSON Schema
  object.
* **agent/provider:** use `Agent.options.provider_config` as the only provider
  carrier. The historical `options.provider`/`options.base_url`,
  `Agent.create`/`resume` provider override, Builder provider/base-URL setters,
  provider adapter, and `Agent_sdk.create_agent` facade are removed rather
  than migrated. Standalone structured extraction now requires the same exact
  `Provider_config.t`, and agent cards no longer invent Anthropic when no
  provider is configured. Public examples now pass an exact
  `Provider_config.t` or fail-closed catalog binding instead of relying on an
  implicit local/default provider or the historical implementation registry.
  Pricing and raw-key authentication helpers are consumed directly from
  `Llm_provider.Pricing` and `Llm_provider.Provider_config`. Capability facts
  use `Llm_provider.Capabilities` directly, and the turn-only config projection
  lives at `Agent_turn`; the duplicate `Provider` facade is removed.

`Eval.compare` and its implicit lower-is-better policy have been removed.
`Eval.compare_with_specs` now compares only metrics selected by an explicit
`metric_spec`.

The unused `Binding_identity.of_resolved_provider` compatibility bridge has
been removed. Binding identities are constructed only from canonical
`Llm_provider.Provider_config.t` values.

## [0.231.14](https://github.com/jeong-sik/oas/compare/v0.231.13...v0.231.14) (2026-08-06)


### Bug Fixes

* **tool:** send the caller's JSON Schema to providers verbatim ([#2938](https://github.com/jeong-sik/oas/issues/2938)) ([8e3b616](https://github.com/jeong-sik/oas/commit/8e3b61669774e42edc5040e90887b5914c971d33))

## [0.231.13](https://github.com/jeong-sik/oas/compare/v0.231.12...v0.231.13) (2026-08-04)


### Bug Fixes

* **llm:** preserve terminal stop semantics ([#2927](https://github.com/jeong-sik/oas/issues/2927)) ([d57904d](https://github.com/jeong-sik/oas/commit/d57904d07d50ed640446e504870fe9f6a9f0fd3a))
* **session:** reuse OS entropy ID generator ([#2928](https://github.com/jeong-sik/oas/issues/2928)) ([dd3c04a](https://github.com/jeong-sik/oas/commit/dd3c04ae5933be96ab4b75e12760cce9b7158df6))
* **streaming:** fail closed on malformed Gemini SSE parts ([#2930](https://github.com/jeong-sik/oas/issues/2930)) ([715bcb5](https://github.com/jeong-sik/oas/commit/715bcb513d8b5f4a8fb8f143ebf7a08424aaece1))

## [0.231.12](https://github.com/jeong-sik/oas/compare/v0.231.11...v0.231.12) (2026-08-02)


### Bug Fixes

* preserve Ollama NDJSON outcome kinds ([#2916](https://github.com/jeong-sik/oas/issues/2916)) ([b66e2e5](https://github.com/jeong-sik/oas/commit/b66e2e5df62e77e5f414509aa8b039bd6bbae63a))

## [0.231.11](https://github.com/jeong-sik/oas/compare/v0.231.10...v0.231.11) (2026-08-01)


### Bug Fixes

* **sse:** keep first-event deadline until data arrives ([#2915](https://github.com/jeong-sik/oas/issues/2915)) ([63a671b](https://github.com/jeong-sik/oas/commit/63a671ba676e215af379361f0d8079a1e9cd0760))

## [0.231.10](https://github.com/jeong-sik/oas/compare/v0.231.9...v0.231.10) (2026-07-30)


### Bug Fixes

* **exact-output:** complete evidence type disambiguation ([#2907](https://github.com/jeong-sik/oas/issues/2907)) ([c0e003a](https://github.com/jeong-sik/oas/commit/c0e003a198704d5af7efdb33ed8fa3bcd4a3566c))
* **exact-output:** disambiguate evidence records ([#2904](https://github.com/jeong-sik/oas/issues/2904)) ([6cb98e6](https://github.com/jeong-sik/oas/commit/6cb98e65a3b9f2a429c9034a7419fd58fb13ef9e))
* **exact-output:** pin evidence record types ([#2906](https://github.com/jeong-sik/oas/issues/2906)) ([5ff166d](https://github.com/jeong-sik/oas/commit/5ff166df5abab07433a1ef09a9d997a5e23ea6e9))

## [0.231.9](https://github.com/jeong-sik/oas/compare/v0.231.8...v0.231.9) (2026-07-30)


### Bug Fixes

* **test:** format prompt provenance assertions ([#2901](https://github.com/jeong-sik/oas/issues/2901)) ([4c75135](https://github.com/jeong-sik/oas/commit/4c75135f9d307c8caaf9f59e8b04139ab6642e5b))

## [0.231.8](https://github.com/jeong-sik/oas/compare/v0.231.7...v0.231.8) (2026-07-30)


### Bug Fixes

* **exact-output:** constrain canonical JSON to Safe.t ([#2899](https://github.com/jeong-sik/oas/issues/2899)) ([b1fe0ec](https://github.com/jeong-sik/oas/commit/b1fe0ec06816c621b49f276364f7cd6818f53179))

## [0.231.7](https://github.com/jeong-sik/oas/compare/v0.231.6...v0.231.7) (2026-07-30)


### Features

* **exact-output:** persist validated flow evidence ([#2896](https://github.com/jeong-sik/oas/issues/2896)) ([f6cc380](https://github.com/jeong-sik/oas/commit/f6cc380562bfc70fa8d9a1f3d77595f797fbd169))

## [0.231.6](https://github.com/jeong-sik/oas/compare/v0.231.5...v0.231.6) (2026-07-30)


### Features

* **agent:** type extra context carrier provenance ([#2894](https://github.com/jeong-sik/oas/issues/2894)) ([ee920ff](https://github.com/jeong-sik/oas/commit/ee920fff93e99bb704ad7c73175d757e6ce8e394))

## [0.231.5](https://github.com/jeong-sik/oas/compare/v0.231.4...v0.231.5) (2026-07-30)


### Bug Fixes

* **exact-output:** preserve typed advance evidence ([#2892](https://github.com/jeong-sik/oas/issues/2892)) ([7ce45ee](https://github.com/jeong-sik/oas/commit/7ce45ee3aa218b49dc13aaaebba1e2698aa22e2c))

## [0.231.4](https://github.com/jeong-sik/oas/compare/v0.231.3...v0.231.4) (2026-07-29)


### Features

* **exact-output:** project exact request body size ([#2887](https://github.com/jeong-sik/oas/issues/2887)) ([8b2f41d](https://github.com/jeong-sik/oas/commit/8b2f41d38a257b5c1e56f3c560421e64842d4faf))

## [0.231.3](https://github.com/jeong-sik/oas/compare/v0.231.2...v0.231.3) (2026-07-29)


### Bug Fixes

* **glm:** consume the resolved stream dialect ([#2883](https://github.com/jeong-sik/oas/issues/2883)) ([e6b45f1](https://github.com/jeong-sik/oas/commit/e6b45f1255bff9683d6fe5a0d87b0b356dccd749))

## [0.231.2](https://github.com/jeong-sik/oas/compare/v0.231.1...v0.231.2) (2026-07-29)


### Bug Fixes

* **provider:** finish exact carrier hard cut ([#2878](https://github.com/jeong-sik/oas/issues/2878)) ([a5485c7](https://github.com/jeong-sik/oas/commit/a5485c74b8571b90e95fd258a549d54222da9eae))

## [0.231.1](https://github.com/jeong-sik/oas/compare/v0.231.0...v0.231.1) (2026-07-29)


### Bug Fixes

* **exact-output:** keep JSON syntax prompt-only ([#2870](https://github.com/jeong-sik/oas/issues/2870)) ([df78135](https://github.com/jeong-sik/oas/commit/df78135025e6ed489da72cead53d4ccdfd6ec191))

## [0.231.0](https://github.com/jeong-sik/oas/compare/v0.230.0...v0.231.0) (2026-07-29)


### ⚠ BREAKING CHANGES

* **checkpoint:** hard-cut current schema to v9 ([#2867](https://github.com/jeong-sik/oas/issues/2867))
* **persistence:** agent_sdk accepts only current v9 checkpoints and canonical Tool-role result batches. Older checkpoint and tool-history formats are unsupported; reset persisted state instead of adding runtime migration code.
* **provider:** provider-native JSON Schema requests use `response_format` only. The duplicate `output_schema` state and its contradictory-state gates are removed ([#2858](https://github.com/jeong-sik/oas/issues/2858)).
* **tool:** `Typed_tool` constructors return canonical `Tool.t` values directly. The secondary typed runtime, `Agent_tool.create_typed_untyped`, and `Typed_tool.to_untyped` bridges are removed ([#2853](https://github.com/jeong-sik/oas/issues/2853)).

### Bug Fixes

* **checkpoint:** derive v9 diagnostic scope ([#2868](https://github.com/jeong-sik/oas/issues/2868)) ([dee562a](https://github.com/jeong-sik/oas/commit/dee562adf979852a0c01f30fd0af4bfe33d18404))
* **checkpoint:** hard-cut current schema to v9 ([#2867](https://github.com/jeong-sik/oas/issues/2867)) ([494f7d0](https://github.com/jeong-sik/oas/commit/494f7d019186afdb52f5bf84832947b6c1d8497d))
* **eval:** reject incomplete metric comparisons ([#2866](https://github.com/jeong-sik/oas/issues/2866)) ([50e1bf1](https://github.com/jeong-sik/oas/commit/50e1bf1af1af598729c2482e190f8476ecebc3f1))
* **gemini:** centralize finish reason mapping ([#2857](https://github.com/jeong-sik/oas/issues/2857)) ([e18fbb9](https://github.com/jeong-sik/oas/commit/e18fbb931a10ddb6e79cb1d54a6faa8619e0f097))


### Code Refactoring

* **persistence:** hard-cut legacy tool and checkpoint shapes ([#2851](https://github.com/jeong-sik/oas/issues/2851)) ([6660d26](https://github.com/jeong-sik/oas/commit/6660d26629ac1d7215ece5e9379b6cfecdbcf11b))

## [0.230.0](https://github.com/jeong-sik/oas/compare/v0.229.1...v0.230.0) (2026-07-28)


### ⚠ BREAKING CHANGES

* **hooks:** Stable pre-tool approval now requires Hooks.ElicitToolApproval and Builder.with_tool_approval; generic ElicitInput/with_elicitation is BeforeTurn-only.

* **exact-output:** `Exact_output.execute_once` is no longer public; freeze
  caller-selected candidates with `snapshot_flow`, create one affine flow with
  `start_flow`, then call `execute_flow_once` with caller-owned callbacks and
  semantic `validate` ([#2844](https://github.com/jeong-sik/oas/issues/2844))
  ([9d01ab7](https://github.com/jeong-sik/oas/commit/9d01ab7c9cf8450bd619dd5fdf168c03fc5ed1ca)).

`Hooks.PreToolUse` no longer accepts generic `ElicitInput` as tool execution
authority. Existing callers must keep `ElicitInput`/`with_elicitation` at
`BeforeTurn`, and migrate exact tool approval to
`ElicitToolApproval { question }` plus `Builder.with_tool_approval`. The
approval callback is synchronous and caller-owned; only `Approved` executes the
exact invocation, while `Denied`, `Timed_out`, a missing callback, and callback
failure open no effect. OAS does not install a timer, persist a pending approval,
or issue a resume token at this boundary.

Exhaustive consumers must also handle `ElicitToolApproval`,
`K_ElicitToolApproval`, and `ToolApprovalCompleted`, and direct `Agent.options`
record construction must provide the new `tool_approval` field.

### Bug Fixes

* **hooks:** require typed pre-tool approval ([fca7a1c](https://github.com/jeong-sik/oas/commit/fca7a1c3b58075abd993d8e571ab03550e13fa86))
* **hooks:** 도구 실행 전에 pre_tool_use 입력을 확정 ([#2840](https://github.com/jeong-sik/oas/issues/2840)) ([aa71724](https://github.com/jeong-sik/oas/commit/aa71724de3db3ed92d5f6fcf1b8fd8258c387713))

## [0.229.1](https://github.com/jeong-sik/oas/compare/v0.229.0...v0.229.1) (2026-07-28)


### Features

* **provider:** admit and observe the exact final request body ([#2838](https://github.com/jeong-sik/oas/issues/2838)) ([dab626d](https://github.com/jeong-sik/oas/commit/dab626d2b1ef60e3f3707ebe43a544cc98e1b1b7))


### Bug Fixes

* **ci:** restore exact-output baseline ([#2839](https://github.com/jeong-sik/oas/issues/2839)) ([12f92b0](https://github.com/jeong-sik/oas/commit/12f92b0641684df4040475d78c95a2dbfdbeafa3))

## [0.229.0](https://github.com/jeong-sik/oas/compare/v0.228.0...v0.229.0) (2026-07-27)

### Breaking Changes

`Exact_output` removes flow preference, domain settlement, scope retirement,
and recovery stores. `snapshot_flow` freezes only the caller-declared candidate
order, and the sole `execute_flow_once` entry point now requires a semantic
validator. Exhaustive consumers must handle typed semantic rejection traces.

### Features

* **exact-output:** validate each candidate result and advance through the
  frozen Runtime order without a second lifecycle authority
  ([#2831](https://github.com/jeong-sik/oas/pull/2831))
* **exact-output:** admit ordinary text Runtimes for JSON-syntax requests using
  a strict OAS-owned instruction and exact JSON parsing; native provider schema
  remains capability-gated
  ([#2831](https://github.com/jeong-sik/oas/pull/2831))
* **catalog:** add provider-scoped Ollama Cloud Qwen 3.5 and Gemma 4 31B JSON
  mode capabilities without claiming native JSON Schema support
  ([#2831](https://github.com/jeong-sik/oas/pull/2831))

## [0.228.0](https://github.com/jeong-sik/oas/compare/v0.227.1...v0.228.0) (2026-07-27)

### Breaking Changes

`Exact_output.execution_error_cause` adds the provider-neutral
`Input_capacity_refused` variant. Exhaustive consumers must handle explicit
context-window and serialized-request refusals.

### Bug Fixes

* **exact-output:** follow the runtime's frozen successor after a typed
  pre-generation input-capacity refusal
  ([#2828](https://github.com/jeong-sik/oas/issues/2828))
  ([15644b9](https://github.com/jeong-sik/oas/commit/15644b9f20080c113fa6095e272e8c6522a147a4))

## [0.227.1](https://github.com/jeong-sik/oas/compare/v0.227.0...v0.227.1) (2026-07-27)

### Bug Fixes

* **retry:** preserve exact observed Ollama context-overflow wire errors as
  typed capacity failures ([#2825](https://github.com/jeong-sik/oas/issues/2825))
  ([2aa9e15](https://github.com/jeong-sik/oas/commit/2aa9e1565e66a77636c3fd8712cfe2c6661c8188))

## [0.227.0](https://github.com/jeong-sik/oas/compare/v0.226.1...v0.227.0) (2026-07-27)

### Breaking Changes

`Exact_output.measurement_receipt_snapshot` no longer exposes the nested
`visit` field. Read receipt identity through
`measurement_receipt_flow_id`, `measurement_receipt_visit_ordinal`,
`measurement_receipt_candidate_id`,
`measurement_receipt_candidate_binding_sha256`,
`measurement_receipt_catalog_generation_fingerprint`, and
`measurement_receipt_catalog_evidence_sha256`.

The durable receipt decoder accepts only the current complete schema.
Discard retired nested-`visit` snapshots produced before 0.226.1 and recreate
them from fresh flow state; there is no compatibility decoder or migration
path. Current-schema 0.226.1 receipts remain valid in 0.227.0.

### Features

* **exact-output:** document measurement receipt hard cut ([#2823](https://github.com/jeong-sik/oas/issues/2823)) ([ca5ce0e](https://github.com/jeong-sik/oas/commit/ca5ce0e36ad7768fe29db857e60039a64bfc0192))

## [0.226.1](https://github.com/jeong-sik/oas/compare/v0.226.0...v0.226.1) (2026-07-27)

Compatibility notice: this patch release unintentionally included the breaking
measurement receipt shape above. Consumers should upgrade directly to 0.227.0.

### Features

* **exact-output:** own durable measurement receipts ([#2820](https://github.com/jeong-sik/oas/issues/2820)) ([0592665](https://github.com/jeong-sik/oas/commit/0592665ba6b772b608e78989f6dbd40d470676fa))

## [0.226.0](https://github.com/jeong-sik/oas/compare/v0.225.0...v0.226.0) (2026-07-27)

`v0.225.0...v0.226.0` contains one commit — the release commit itself ([#2814](https://github.com/jeong-sik/oas/issues/2814)). No library change shipped in this version.

The generated body previously listed ~292 pull requests reaching back to `#10`, all of them already described in the sections below. `v0.224.0` and `v0.225.0` were tagged by hand inside feature PRs ([#2813](https://github.com/jeong-sik/oas/issues/2813), [#2815](https://github.com/jeong-sik/oas/issues/2815)) rather than by release-please, and neither tag has a GitHub Release object, so release-please resolved its previous release as `v0.223.2` and regenerated everything after it. Release sections and version bumps are written by release-please only; feature PRs append under `## Unreleased`.

## [0.225.0](https://github.com/jeong-sik/oas/compare/v0.224.0...v0.225.0) (2026-07-26)

### Breaking Changes

* **exact-output preference lifecycle:** replace caller-sized raw recovery and
  process-local scope removal with provider-neutral evidence recovery and a
  current-schema durable scope-retirement intent. OAS validates the complete
  evidence set, derives capacity from distinct active scopes, restores
  reservation and success high-water marks, and prevents retired or stale
  settlements from resurrecting a scope. No legacy aliases, historical
  decoder, migration path, or provider/model/pricing policy is included.

### Bug Fixes

* **retry:** classify HTTP 413 as typed `Request_body_refused_by_provider`
  instead of an unknown invalid request, without fabricating measured size
  limits (#2818).

## [0.224.0](https://github.com/jeong-sik/oas/compare/v0.223.2...v0.224.0) (2026-07-26)

### Breaking Changes

* **exact-output durable domain settlement:** replace process-local
  `settle_flow_domain` and its already-settled error with a provider-neutral
  current-schema durable intent, caller commit fence, deterministic idempotent
  receipt, typed nonblocking concurrent-publication outcome, and restart-only
  preference recovery. Recovery restores OAS-owned reservation and
  success-ordinal high-water marks before an active preference store can create
  snapshots. No compatibility wrapper or predecessor decoder is provided.
* **exact-output flow settlement:** require an explicit hard capacity when
  creating a scope-local preference store, add explicit scope removal and typed
  capacity/released-scope failures, and replace caller-provided success
  timestamps with an OAS-owned monotonic ordinal frozen at structural success.
  Domain settlement receipts are now private evidence values, so callers can
  inspect but cannot construct them.
* **tool lifecycle:** replace independently writable tool-call id, turn, and
  schedule copies across hooks, events, results, failures, and execution
  callbacks with one run-scoped `Tool.Invocation.t`. The invocation now owns
  its canonical `Tool.schedule`; `Hooks.tool_schedule` remains a type alias,
  not a second representation. Provider wire messages, SDK errors, and the
  compatible durable journal retain their external shapes and are projected
  from the invocation at those boundaries. Raw-trace tool and hook records add
  occurrence fields while remaining backward-readable. See the
  [0.216 migration guide](docs/migrations/0.216-tool-invocation-ssot.md).
* **agent-as-tool inputs:** remove `Agent_tool.config.input_parameters` and
  scalar-string invocation. The advertised and consumed input contract is now
  exactly one required object field, `prompt`; see the
  [0.213 migration guide](docs/migrations/0.213-agent-tool-input.md).
* **HTTP deadlines:** remove the implicit 60-second request/connect deadline
  and 30-second response-drain deadline. `timeout_s` and
  `connect_timeout_s` are enforced only when explicitly supplied, and a
  deadline without a clock now returns typed `AcceptRejected` instead of
  silently running unarmed.
* **hooks:** remove `Skip`/`K_Skip` and `Override`/`K_Override`. A
  `PreToolUse` hook now either executes the real tool with `Continue`, rejects
  it with `Block`; OAS no longer owns approval orchestration or fabricates a
  successful tool result without executing a tool.
* **hook failures:** make `HookFailed.stage` a closed `Hooks.hook_stage`, remove
  the unvalidated `Hooks.invoke` entry point, and make the internal
  `Agent_tools` execution surface return completed results alongside typed hook
  or observer failures. A failed post-execution hook is an agent error after
  the real tool completion has been observed and checkpointed; it is never
  rewritten as a retryable tool result.
* **durable journal:** `Durable_event.append` now returns an explicit observer
  error carrying the original exception and raw backtrace. The event remains
  committed before callback notification; ordinary callback failures are no
  longer silently discarded, while cancellation and fatal exceptions still
  propagate.
* **hooks:** establish 0.209 as the supported compatibility floor for
  `Hooks.Block` and `K_Block`, which were incorrectly shipped in the 0.208.21
  patch line. Exhaustive matches must handle the new variants; see the
  [hook decision migration guide](docs/migrations/0.209-hook-block.md).
* **context:** remove the public `Agent_sdk.Context_intent` module. Consumers
  must move query-intent classification to their own typed boundary; see the
  [0.209 migration guide](docs/migrations/0.209-context-intent-removal.md).
  The usual deprecation window is waived as a safety exception: restoring the
  removed implementation or a compatibility shim would preserve heuristic
  string matching and a silent model-error fallback.
* **agent:** remove numeric lifecycle ceilings, repeated-call idle heuristics,
  exit predicates, and their errors/hooks. `Agent.run` has no turn, idle-turn,
  tool-round, cost, or token-budget stop gate; those counters remain telemetry.
  Callers own whole-run Eio cancellation/deadlines, while provider body and
  stream-idle deadlines apply only when explicitly configured.
* **runtime:** remove turn ceilings from runtime, session, and subagent
  contracts. Turn counts remain observations and never stop a lane.
* **scheduling:** remove request-priority classes, numeric ranks, implicit
  defaults, and agent/completion priority fields. Provider capacity scheduling
  now grants queued requests in FIFO arrival order; resumed permits rejoin the
  same queue and cannot bypass older work.
* **provider calls:** remove synchronous automatic retry/backoff APIs and their
  hidden defaults. `Complete.complete`, `Complete.complete_stream`, and the
  Agent pipeline now perform exactly one provider attempt and return the typed
  result unchanged; callers own any later asynchronous attempt or runtime
  rotation.
* **agent provider configuration:** remove the lossy
  `Provider.config_of_provider_config` adapter and its orphan
  `Provider.default_api_key_env_of_kind` helper. `Builder.with_provider_config`
  now carries the exact typed provider identity, wire kind, endpoint,
  credential, headers, request path, and capability overrides through Agent
  dispatch without catalog, URL, model-name, or environment reinterpretation.
  `Builder.with_provider` and `Builder.with_provider_config` replace one another;
  the last setter selects the active provider representation.
* **pricing observation:** preserve absent cache multipliers as `float option`
  and make `Provider.estimate_cost`/`Llm_provider.Pricing.estimate_cost` return
  `Estimated | Incomplete` instead of inventing a multiplier. Pricing lookup
  accepts an optional exact provider identity, and `Agent_turn.accumulate_usage`
  now receives the typed provider config and returned model identity explicitly.
  These values remain telemetry only and never gate execution. See the
  [0.212 provider/pricing migration guide](docs/migrations/0.212-explicit-provider-pricing.md).
* **implicit recovery:** remove `Lenient_json`, `Correction_pipeline`,
  `Tool_use_recovery`, `Tool_failure_episode`, `Tool_failure_recovery`, and
  `Reflexion`. OAS no longer repairs malformed model JSON/tool calls, detects
  repeated-failure episodes, asks a hidden judge for a retry plan, or runs a
  convergence loop. Model content and typed tool failures stay on the ordinary
  provider/tool path without a second recovery decision layer.
* **tool results:** remove implicit call-time stubbing, relocation/offload
  stores (`Context_offload`, `Tool_result_store`, and
  `Content_replacement_state`), replacement events, and MCP output truncation.
  Tool and MCP content now reaches the provider unchanged.
* **tool surface:** remove selector, index, progressive-disclosure, and schema-
  disclosure layers. Every registered tool is sent with its full schema, and
  dispatch uses the exact registered name.
* **tool exposure:** remove the synchronous `Guardrails` name-filtering layer,
  per-turn filter overrides, and `Tool_set.filter`. Every caller-supplied tool
  reaches the provider unchanged; policy gates belong at the caller boundary.
* **governance:** remove the standalone approval pipeline, approval callback,
  `ApprovalRequired` hook decision, priority-rule policy
  engine, score-to-risk judge facade, parent-to-child policy channel, and its
  `Tool_op` tool-set operation algebra, along with the product-governance
  boundary lint. HITL and model judgment remain caller-owned callbacks over
  the generic hook/provider surfaces.
* **context:** remove `Context_reducer`, `Budget_strategy`, the
  `Agent.options.context_reducer` extension point, automatic compaction,
  threshold-based preparation, and overflow retry. Exact message and tool
  content is the default; a provider `ContextOverflow` is returned unchanged
  after one request. A caller that needs pruning or repair transforms its input
  before invoking OAS or handles the typed overflow outside OAS.
* **handoff:** make each target's exact name a normal tool backed by a real
  delegate closure. Remove `Agent_handoff`, `Agent_tool_name_alias`,
  `Succession`, prefixed aliases, stub handlers, transcript scans, compressed
  successor-DNA generation, and post-execution result replacement.
* **tool descriptors:** remove permission risk levels, mutation aliases,
  shell/workdir constraints, evidence roles, kinds, notes, examples, and the
  `Typed_tool_safe` permission facade and three-class concurrency taxonomy. A
  descriptor now contains only a caller-declared `Concurrent` or `Serial`
  execution mode; absence means `Serial`. Raw trace v2 and session tool
  catalogs expose only that structural mode and reject the removed fields.
* **events:** each subscriber owns a bounded FIFO with an explicit validated
  capacity and either drop-oldest or drop-newest behavior. There is no hidden
  capacity, default loss policy, or publisher-blocking mode. Queue depth,
  offered events, drained events, and drops remain observable.
* **telemetry events:** `Telemetry_bus.drain` now returns one typed decode
  result per queued event. Malformed telemetry remains in-order as explicit
  `decode_failure` evidence instead of disappearing from the observation
  stream.
* **event projections:** remove `Event_forward`,
  `Relay_delivery`, `Slot_scheduler_event_bridge`, and the orphan
  `SlotSchedulerObserved` payload. OAS retains the typed Event_bus and provider
  slot snapshot; external file/custom delivery and product scheduler projection
  belong to caller-owned connectors.
* **runtime control:** remove the orphan SDK-client permission taxonomy, session
  policy snapshot, `Sdk_client_types`, and Runtime permission/hook control
  channel. Session start, spawn, and finalize no longer wait on implicit control
  requests or a fixed timeout; a caller may still reject a tool explicitly with
  the generic typed `Hooks.Block` decision. Runtime stdio now accepts only
  canonical protocol envelopes. This hard cut is reported as Runtime protocol
  version `oas-runtime-0.2`.
* **runtime MCP:** remove the request policy carrier that no provider transport
  consumed. It no longer changes cache keys or advertises tool names that were
  absent from the actual provider request.
* **heuristic evaluation:** remove `Uncertain`, `Response_harness`, and
  `Checkpoint_validation`. Their confidence defaults, free-form first-number
  score extraction, and compressed-text token-overlap/marker grading are no
  longer SDK behavior.
* **harness:** keep turn counts as observations only; remove `Sandbox_runner`,
  turn/tool-count pass/fail assertions, and performance ceilings.
* **experiments:** remove `Code_snippet_eval` and its
  `OAS_EXPERIMENTAL_CODE_SNIPPET` environment gate. OAS no longer owns an
  arbitrary numeric adoption verdict for a caller's tool strategy.
* **wire observation:** remove OAS-owned capture files, paths, locks, queues,
  capacities, environment activation, and writer lifecycles. Streaming callers
  may supply one typed nonblocking offer that receives redacted provider chunks;
  caller rejection and ordinary callback exceptions become typed telemetry
  without changing the provider result. Injected transports receive only an
  OAS-owned raw-chunk sink, not the caller callback, so redaction and failure
  handling remain inside OAS. Persistence and resource policy remain entirely
  caller-owned.
* **catalog bootstrap:** remove ambient `OAS_MODEL_CATALOG`,
  `OAS_PROVIDER_CATALOG`, and `OAS_CAPABILITY_MANIFEST` discovery. The embedded
  OAS model catalog is the default; callers install explicit model, provider,
  or capability overrides through the typed `load_file`/`set_global` APIs.
* **catalog identity:** remove dot-qualified model-id rewriting and provider
  registry alias/case normalization, including the legacy `Model_registry`
  facade. Provider-independent model selection uses declared prefixes, while
  provider-scoped capability selection requires the complete normalized
  provider/model pair. Runtime provider binding accepts the exact registered
  provider id. Provider-catalog aliases remain local to explicit catalog
  lookup and are never registered as runtime provider identities.
* **environment configuration:** remove the unused numeric, boolean, list, and
  key-value policy parsers from `Llm_provider.Cli_common_env`, remove the
  environment-backed `Defaults` facade, and retire the stale
  config-externalization guide. Runtime behavior belongs in explicit typed
  configuration; the module retains only provider-bootstrap string lookup and
  trimming helpers.
* **durable workflows:** remove the separate `Durable` typed step-chain engine.
  `Durable_event` remains the generic append/replay journal; callers own job and
  workflow orchestration.
* **test support:** remove the production `Provider_mock` module and top-level
  re-export. Scripted provider responses remain test-only code, not an SDK
  runtime provider.
* **eval/harness execution stack:** remove the nine unwired
  `Agent_sdk` module re-exports — `Eval_baseline`, `Eval_report`,
  `Eval_collector`, `Eval_otel_bridge`, `Harness_case`, `Harness_dataset`,
  `Harness_report`, `Harness_runner`, and `Trace_eval` — along with the
  backing modules, `Eval.run_metrics`'s `trace_summary` field, and
  `Eval.{compare_statistical,run_metrics_to_json,set_trace_summary}`.
  The stack's only entry point (`oas eval` CLI) was deleted in #1814; the
  execution chain had zero production consumers since. Shared types
  (`Agent_sdk.Harness.verdict`) and the residual `Eval.create_collector`
  test surface stay. See PR #2689.

### Features

* **durable execution:** add an optional typed terminal-disposition sink to
  `Agent.execution_store`. After the terminal journal commit it distinguishes
  safe locator retirement from operator repair required for an admitted Tool
  attempt whose external effect outcome is unknown, without changing the
  existing Agent run surfaces or classifying error strings (#2687).

### Bug Fixes

* **eval collection:** atomically cancel and drain event-bus subscriptions
  before finalizing metrics so already accepted lifecycle and tool events are
  not discarded.
* **runtime lifecycle:** reject participant registration on an already closed
  switch, keep a settlement handle for cancellation races, cancel every
  snapshotted session lane before joining any one lane, and preserve reserved
  exceptions across runtime observer boundaries. Non-fatal event-bus,
  participant-failure persistence, and unexpected participant-lane failures
  are also emitted as runtime `System_message` observations without rolling
  back durable events or cancelling unrelated lanes.
* **checkpoint persistence:** add a finite one-way migration for the closed set
  of exact released v5/v6 checkpoint JSON shapes before strict v8 decoding.
  Released v5 had pre-preserve capped, preserve capped, and preserve unbounded
  top-level shapes without a checkpoint-version bump. Retired cap values are
  type-checked and removed, missing pre-release fields are filled only with
  `null`/empty structural values, and partial or cross-era combinations are
  rejected. Usage pricing gaps, legacy failed tool results, and MCP session
  records are normalized without inventing model identity, failure provenance,
  or an HTTP reconnect URL. Legacy MCP sessions are rejected when reconnecting
  stdio would widen their saved subprocess environment; released HTTP policy
  metadata is removed because HTTP reconnect never consumed it. Versions 1-4
  remain unsupported and the v8 domain is not widened. This runtime migration
  was removed after the release; current OAS accepts only v8.
* **agent resume:** make an explicitly supplied `Agent.resume ~config` the
  complete runtime configuration SSOT. Checkpoints still restore conversation,
  usage, turn count, and context, but can no longer overwrite the caller's
  current agent name, model, system prompt, sampling, reasoning, or tool-choice
  configuration. When `~config` is omitted, persisted checkpoint configuration
  fields are restored over current defaults; runtime fields not represented by
  the checkpoint use those defaults.
* **defaults:** restore `Mcp_http.default_config` as a compatibility value; use
  `Mcp_http.make_default_config ()` for call-time environment resolution.
* **agent:** reject configured MCP servers explicitly when a required runtime
  resource is absent instead of silently omitting every server. Every MCP
  connection requires a switch; only stdio MCP additionally requires a process
  manager, so HTTP-only configurations remain usable without one. Reject
  wrong-typed optional config fields and ambiguous MCP transport objects;
  required MCP connection setup is transactional and rolls back every earlier
  connection in LIFO order without replacing the primary failure.
  Remove the inert inline `Agent_config.tools` type and parser surface; tools
  are executable values registered in code or discovered through configured
  MCP servers, never schema-only JSON entries that are rejected later.
* **provider parsing:** reject malformed provider-catalog roots, entries,
  duplicate/unknown fields, scalar/list types, auth/capability shapes, and
  malformed Ollama message bodies instead of coercing them to defaults,
  unauthenticated configs, or empty successful responses.
* **provider requests:** resolve tool-choice validation and OpenAI-compatible
  serialization from the same typed provider/model capability projection, so
  a provider-level default cannot override an exact model declaration.
* **checkpoint stages:** give the post-context-injection snapshot its own
  `After_context_injection` stage and checkpoint id instead of overwriting the
  earlier `After_tool_results_appended` snapshot for the same turn.
* **tool observability:** emit durable/raw-trace execution lifecycle records
  only after `PreToolUse` returns `Continue`. `Block` remains model-visible but
  no longer fabricates `Tool_called`/`Tool_completed` evidence for a tool that
  did not run. Post-hook and hook-observer failures propagate explicitly after
  an already completed tool has been recorded.
* **runtime evidence:** keep participant failure cause and completion anomaly
  as typed single sources of truth. Live, completed, and failed lifecycle
  payloads now share one nested common record but expose disjoint outcome
  fields; a failed event requires a cause and a completed event cannot carry
  one. Legacy flat/error shapes and non-positive dropped-delta counts are
  rejected instead of being silently preferred or erased.
* **HTTP deadlines:** distinguish expiry of the caller-owned non-streaming body
  deadline from an `Eio.Time.Timeout` raised inside the selected transport. An
  inner timeout now propagates unchanged instead of being relabelled as the
  outer body deadline.
* **harness replay:** preserve an exact zero response-step count instead of
  fabricating a minimum turn, and fail a live fixture explicitly when its
  advertised raw trace cannot be read instead of silently grading without the
  trajectory. Turn counts remain observation-only metrics.

## [0.223.2](https://github.com/jeong-sik/oas/compare/v0.223.1...v0.223.2) (2026-07-25)


### Bug Fixes

* **error-domain:** `Invalid_request 가 전달받은 typed reason 을 버리고 있었다 ([#2808](https://github.com/jeong-sik/oas/issues/2808)) ([71d5332](https://github.com/jeong-sik/oas/commit/71d5332790a012d8ad7203d91f800f6471893c41))
* **exact-output:** admit Gemini anyOf nullable enums ([#2812](https://github.com/jeong-sik/oas/issues/2812)) ([acca09a](https://github.com/jeong-sik/oas/commit/acca09a43ca6d38c54622e770356b572261f7555))
* **exact-output:** measure constrained flow admission ([#2807](https://github.com/jeong-sik/oas/issues/2807)) ([48bda5a](https://github.com/jeong-sik/oas/commit/48bda5a06fa4f37d01c5ab744d9be532a411f86d))

## [0.223.1](https://github.com/jeong-sik/oas/compare/v0.223.0...v0.223.1) (2026-07-25)


### Bug Fixes

* **llm-provider:** restore Eio 1.3 compatibility ([#2805](https://github.com/jeong-sik/oas/issues/2805)) ([e2db255](https://github.com/jeong-sik/oas/commit/e2db255ff6e9f88b809f3a15494108a7013483cc))

## [0.223.0](https://github.com/jeong-sik/oas/compare/v0.222.2...v0.223.0) (2026-07-24)


### ⚠ BREAKING CHANGES

* **exact-output:** Replace admit_flow/ready_flow with snapshot_flow/flow_snapshot and change start_flow/before_advance contracts.

### Features

* **exact-output:** expose outward dispatch fact ([#2804](https://github.com/jeong-sik/oas/issues/2804)) ([4dab217](https://github.com/jeong-sik/oas/commit/4dab21717f8ba0f30e63095c9a3914adf51e6e51))
* **exact-output:** settle current-candidate admission ([72cb98d](https://github.com/jeong-sik/oas/commit/72cb98dc08d13ae3e8bc734ed940a9d21fd1cc76))
* **exact-output:** settle scoped domain success ([#2799](https://github.com/jeong-sik/oas/issues/2799)) ([7a0fa77](https://github.com/jeong-sik/oas/commit/7a0fa77eaaa60e4979e9f160a22cb122ff7a71b2))


### Bug Fixes

* **exact-output:** remove nested settlement lock ([#2803](https://github.com/jeong-sik/oas/issues/2803)) ([cbedc1e](https://github.com/jeong-sik/oas/commit/cbedc1e04e3c5c482d3026600b2fbd388ed64e8b))
* **llm-provider:** adopt Eio 1.4 network errors ([#2802](https://github.com/jeong-sik/oas/issues/2802)) ([4942c15](https://github.com/jeong-sik/oas/commit/4942c1556ded36529a080985e788df1e009b2102))

## [0.222.2](https://github.com/jeong-sik/oas/compare/v0.222.1...v0.222.2) (2026-07-24)


### Features

* add evidence-backed token serving admission ([#2796](https://github.com/jeong-sik/oas/issues/2796)) ([5a82100](https://github.com/jeong-sik/oas/commit/5a8210019d0d119cd209becf47aef0f124e1f0a8))
* **llm-provider:** admit exact request body limits ([#2791](https://github.com/jeong-sik/oas/issues/2791)) ([417c5c1](https://github.com/jeong-sik/oas/commit/417c5c1c34025a36889b6671f5ae02acada41f27))

## [0.222.1](https://github.com/jeong-sik/oas/compare/v0.222.0...v0.222.1) (2026-07-24)


### Features

* **exact-output:** anchor opaque provider trace ([#2789](https://github.com/jeong-sik/oas/issues/2789)) ([0a07ae2](https://github.com/jeong-sik/oas/commit/0a07ae2d14c1832a83ecda4c2525ee7e703f0877))

## [0.222.0](https://github.com/jeong-sik/oas/compare/v0.221.1...v0.222.0) (2026-07-23)


### ⚠ BREAKING CHANGES

* **tool:** canonicalize terminal-tool contracts under Tool_contract, remove legacy Tool and Hooks schedule aliases, and require exact durable provider-response receipts.

### Features

* **tool:** enforce typed terminal-tool exclusivity ([aef2002](https://github.com/jeong-sik/oas/commit/aef2002bc00c84d999db5cc09a44d666890e70da))

## [0.221.1](https://github.com/jeong-sik/oas/compare/v0.221.0...v0.221.1) (2026-07-23)


### Features

* **exact-output:** add affine outer flow ([#2781](https://github.com/jeong-sik/oas/issues/2781)) ([4659b54](https://github.com/jeong-sik/oas/commit/4659b5488f2c93010024d929715911a3646606c5))

## [0.221.0](https://github.com/jeong-sik/oas/compare/v0.220.5...v0.221.0) (2026-07-22)


### ⚠ BREAKING CHANGES

* bind exact-output admission to immutable catalog snapshots ([#2777](https://github.com/jeong-sik/oas/issues/2777))
* remove JSON fence stripping APIs, add supported_models to Model_catalog.model_entry, and add Unsupported_target_model admission errors.

### Code Refactoring

* bind exact-output admission to immutable catalog snapshots ([#2777](https://github.com/jeong-sik/oas/issues/2777)) ([52c265f](https://github.com/jeong-sik/oas/commit/52c265fb7dc03cf9324bd576587fada5f01f544c))
* hard-cut exact-output admission and repair HTTP cache lifecycle ([#2778](https://github.com/jeong-sik/oas/issues/2778)) ([d1aa21e](https://github.com/jeong-sik/oas/commit/d1aa21eab0cdcdb6f72aef2fb2837f88d119d566))

## [0.220.5](https://github.com/jeong-sik/oas/compare/v0.220.4...v0.220.5) (2026-07-22)


### Bug Fixes

* **agent-sdk:** restore exact-output public compile ([#2773](https://github.com/jeong-sik/oas/issues/2773)) ([ea03a7d](https://github.com/jeong-sik/oas/commit/ea03a7d85080431a0809beebfe2c613fceafb963))

## [0.220.4](https://github.com/jeong-sik/oas/compare/v0.220.3...v0.220.4) (2026-07-22)


### Bug Fixes

* **agent-sdk:** freeze exact-output resolver snapshot ([#2772](https://github.com/jeong-sik/oas/issues/2772)) ([c653e8b](https://github.com/jeong-sik/oas/commit/c653e8bc43fb4245586824fa8a6b33aaf25ce3db))
* **exact_output:** add explicit ready_plan type annotations for mli contract match ([#2770](https://github.com/jeong-sik/oas/issues/2770)) ([b25a420](https://github.com/jeong-sik/oas/commit/b25a420ad0407755fe570f748a39be0c8be378fd))

## [0.220.3](https://github.com/jeong-sik/oas/compare/v0.220.2...v0.220.3) (2026-07-22)


### Features

* **exact-output:** add provider-neutral single surface ([#2768](https://github.com/jeong-sik/oas/issues/2768)) ([0171a27](https://github.com/jeong-sik/oas/commit/0171a27cea82895ca1c730d246927734b9256d0f))

## [0.220.2](https://github.com/jeong-sik/oas/compare/v0.220.1...v0.220.2) (2026-07-22)


### Bug Fixes

* **llm_provider:** support stop_reason provider dialects and preserve empty completion stop_reason in GLM parser ([#2766](https://github.com/jeong-sik/oas/issues/2766)) ([ca7a02b](https://github.com/jeong-sik/oas/commit/ca7a02b7da5be364aeeae1f2a873cd73959aae43))

## [0.220.1](https://github.com/jeong-sik/oas/compare/v0.220.0...v0.220.1) (2026-07-22)


### Bug Fixes

* **streaming:** allow empty delta id and name strings as Ok None in SSE parser ([#2764](https://github.com/jeong-sik/oas/issues/2764)) ([c1eaa88](https://github.com/jeong-sik/oas/commit/c1eaa88bf72e680a61f7f4e3eafae627d916b4c4))

## [0.220.0](https://github.com/jeong-sik/oas/compare/v0.219.0...v0.220.0) (2026-07-22)


### ⚠ BREAKING CHANGES

* **llm_provider:** a Document block sent to an OpenAI-compatible Chat Completions row that does not declare `supports_document_input`, or to the Ollama native wire, now fails with a named error instead of silently going out as an image. Declare `supports_document_input = true` on the catalog row to opt in.

### Features

* **llm:** add exact output admission surface ([#2761](https://github.com/jeong-sik/oas/issues/2761)) ([0bb8101](https://github.com/jeong-sik/oas/commit/0bb8101516b7d1b20d852e55f5b16996d547e545))


### Bug Fixes

* **llm_provider:** stop emitting Document blocks as image_url ([#2755](https://github.com/jeong-sik/oas/issues/2755)) ([abc60cb](https://github.com/jeong-sik/oas/commit/abc60cba24d760c88f687fa24b5f2e39ae531bda))
* **llm_provider:** surface unmodeled empty-completion stop_reason ([#2743](https://github.com/jeong-sik/oas/issues/2743)) ([10df33e](https://github.com/jeong-sik/oas/commit/10df33e94f1dcc72f563a298a6ec7ad40216e3ec))

## [0.219.0](https://github.com/jeong-sik/oas/compare/v0.218.0...v0.219.0) (2026-07-21)


### ⚠ BREAKING CHANGES

* Agent_sdk no longer re-exports the 22 modules listed above. Handoff is exported instead; construct Handoff.handoff_target records directly where Subagent.to_handoff_target was used before.
* Agent_sdk no longer re-exports the 22 modules listed above. Handoff is exported instead; construct Handoff.handoff_target records directly where Subagent.to_handoff_target was used before.

### Code Refactoring

* drop the test-only agent_sdk re-export surface (9 remaining modules) ([#2735](https://github.com/jeong-sik/oas/issues/2735)) ([2a817f8](https://github.com/jeong-sik/oas/commit/2a817f878fa1df3a91f3d90b0d91eb9c22ca5b91))
* retire the legacy Api/Streaming/Provider_intf dispatch island ([#2738](https://github.com/jeong-sik/oas/issues/2738)) ([2bd2e07](https://github.com/jeong-sik/oas/commit/2bd2e07924d087d9047a150cc1d6b51a3b61d941))

## [0.218.0](https://github.com/jeong-sik/oas/compare/v0.217.4...v0.218.0) (2026-07-21)


### ⚠ BREAKING CHANGES

* agent_sdk no longer re-exports Runtime_server, Runtime_sync, Runtime_projection, Runtime_evidence, Runtime_replay, Runtime_server_types, Runtime_server_resolve, Runtime_continuation, Runtime_health. The 9 modules and their dedicated tests are deleted.
* remove Internal-declared zero-consumer modules ([#2690](https://github.com/jeong-sik/oas/issues/2690))
* remove unwired eval/harness execution stack ([#2689](https://github.com/jeong-sik/oas/issues/2689))

### Features

* **agent:** publish AgentStarted/AgentCompleted/AgentFailed lifecycle events ([#2725](https://github.com/jeong-sik/oas/issues/2725)) ([658587a](https://github.com/jeong-sik/oas/commit/658587ae4babec35a6916add37fd1238ad2ef693))
* **llm_provider:** profile request shape on client 4xx for opaque provider rejections ([#2677](https://github.com/jeong-sik/oas/issues/2677)) ([1bc962f](https://github.com/jeong-sik/oas/commit/1bc962f5bfb3d8d86677e40c7244513ec4a8c793))


### Bug Fixes

* **llm_provider:** drop coordinator name from docstrings for SDK independence ([#2733](https://github.com/jeong-sik/oas/issues/2733)) ([27d7c69](https://github.com/jeong-sik/oas/commit/27d7c697e5ddcee35bbee2496e3a34ec8de9c5ed))
* **streaming:** bound first-event wait with a separate TTFT budget, not the inter-token idle timeout ([#2722](https://github.com/jeong-sik/oas/issues/2722)) ([#2723](https://github.com/jeong-sik/oas/issues/2723)) ([2b57090](https://github.com/jeong-sik/oas/commit/2b5709065733e83b1bd249558066a141ce5b13b6))


### Code Refactoring

* remove 9 unreachable runtime cluster modules (preserve Runtime_store/Sessions_store live surface) ([#2737](https://github.com/jeong-sik/oas/issues/2737)) ([194ec9a](https://github.com/jeong-sik/oas/commit/194ec9a93b5ed4ca34bafe6d6ee6b1dc53606268))
* remove Internal-declared zero-consumer modules ([#2690](https://github.com/jeong-sik/oas/issues/2690)) ([541d998](https://github.com/jeong-sik/oas/commit/541d998deb97054cf47555d3fab05567a9b8b90a))
* remove unwired eval/harness execution stack ([#2689](https://github.com/jeong-sik/oas/issues/2689)) ([132bb27](https://github.com/jeong-sik/oas/commit/132bb274c56bdfe953cbe6cb558e01b013e0d694))

## [0.217.4](https://github.com/jeong-sik/oas/compare/v0.217.3...v0.217.4) (2026-07-20)


### Bug Fixes

* **api:** reject unencoded explicit thinking on the legacy openai body path too ([#2716](https://github.com/jeong-sik/oas/issues/2716)) ([#2720](https://github.com/jeong-sik/oas/issues/2720)) ([262957a](https://github.com/jeong-sik/oas/commit/262957ae2235747bcf25afef88fdbb0281ea243a))
* **llm_provider:** reconcile EndTurn with tool blocks to StopToolUse so complete tool calls are executed, not left dangling ([#2728](https://github.com/jeong-sik/oas/issues/2728)) ([4c2abbd](https://github.com/jeong-sik/oas/commit/4c2abbd6fcddcfcd7f4d77d2044b908a69c7dd07))
* **pipeline:** resolve context limit before measuring tokens ([#2693](https://github.com/jeong-sik/oas/issues/2693)) ([a266f7a](https://github.com/jeong-sik/oas/commit/a266f7ab24547dd30822728837d89a3b2e56436e))

## [0.217.3](https://github.com/jeong-sik/oas/compare/v0.217.2...v0.217.3) (2026-07-20)


### Bug Fixes

* **ollama:** hard-cut native tool-loop replay and correlation ([#2710](https://github.com/jeong-sik/oas/issues/2710)) ([f7754cb](https://github.com/jeong-sik/oas/commit/f7754cbf46dfbcfab746e6a34ea610cc593ccdfe))
* **pipeline:** classify durable Error_occurred error_domain from the error, not hardcoded "Api" ([#2717](https://github.com/jeong-sik/oas/issues/2717)) ([eebb5d5](https://github.com/jeong-sik/oas/commit/eebb5d53902f91d46e8ae0b4fba08637d7c5f99d))

## [0.217.2](https://github.com/jeong-sik/oas/compare/v0.217.1...v0.217.2) (2026-07-20)


### Bug Fixes

* **llm_provider:** log reasoning_replay_dropped at Info, not Warn ([#2721](https://github.com/jeong-sik/oas/issues/2721)) ([658a910](https://github.com/jeong-sik/oas/commit/658a91091154be543685840fad73bd8936f8ac1e))

## [0.217.1](https://github.com/jeong-sik/oas/compare/v0.217.0...v0.217.1) (2026-07-20)


### Bug Fixes

* **agent:** resume matches the run's original prompt, not the latest (injected) User message ([#2683](https://github.com/jeong-sik/oas/issues/2683)) ([#2715](https://github.com/jeong-sik/oas/issues/2715)) ([2ac114e](https://github.com/jeong-sik/oas/commit/2ac114eb8162d2242b83fd0b9871613d9a67b3df))

## [0.217.0](https://github.com/jeong-sik/oas/compare/v0.216.7...v0.217.0) (2026-07-20)


### ⚠ BREAKING CHANGES

* **streaming:** reject malformed tool-call batches ([#2702](https://github.com/jeong-sik/oas/issues/2702))

### Bug Fixes

* **execution:** resume settled turn after partial-close crash instead of aborting Failed ([#2683](https://github.com/jeong-sik/oas/issues/2683)) ([#2713](https://github.com/jeong-sik/oas/issues/2713)) ([ec09415](https://github.com/jeong-sik/oas/commit/ec094155a96de55a5b821571c5c49129f6fb3467))
* **llm_provider:** decode overflow wire finish_reason so empty-completion classifier is reachable ([#2621](https://github.com/jeong-sik/oas/issues/2621)) ([#2703](https://github.com/jeong-sik/oas/issues/2703)) ([6525705](https://github.com/jeong-sik/oas/commit/6525705d2d2e78648b5387a9a2477a46c1b939a8))
* **llm_provider:** reject non-finite/negative retry_after at parse boundary ([#2644](https://github.com/jeong-sik/oas/issues/2644)) ([#2708](https://github.com/jeong-sik/oas/issues/2708)) ([a4395af](https://github.com/jeong-sik/oas/commit/a4395afc82c0ee5e562f4022af8b7af55ef68c4e))
* **llm_provider:** reject unencoded explicit thinking ([#2716](https://github.com/jeong-sik/oas/issues/2716)) ([1000d42](https://github.com/jeong-sik/oas/commit/1000d42fb81f2e34fd225ad1da492608e3c584d6))
* **llm_provider:** sanitize base_url in admission conflict warning ([#2706](https://github.com/jeong-sik/oas/issues/2706)) ([a72b785](https://github.com/jeong-sik/oas/commit/a72b785e46f33e15d16d7191add052e5cad769df))
* **streaming:** reject malformed tool-call batches ([#2702](https://github.com/jeong-sik/oas/issues/2702)) ([69a0dcd](https://github.com/jeong-sik/oas/commit/69a0dcd5a16fd1498a95b2493937feae4774443b))

## [0.216.7](https://github.com/jeong-sik/oas/compare/v0.216.6...v0.216.7) (2026-07-19)


### Bug Fixes

* **agent:** share exact provider turn identity ([#2709](https://github.com/jeong-sik/oas/issues/2709)) ([0615043](https://github.com/jeong-sik/oas/commit/0615043447fbd57ab647b8430f4d192535889fc3))

## [0.216.6](https://github.com/jeong-sik/oas/compare/v0.216.5...v0.216.6) (2026-07-19)


### Features

* **llm_provider:** admit Kimi with native token count ([#2705](https://github.com/jeong-sik/oas/issues/2705)) ([c939488](https://github.com/jeong-sik/oas/commit/c9394887755aedb2b69c039838a62595ab146d4a))


### Bug Fixes

* **agent:** make projected provider input the admission SSOT ([#2707](https://github.com/jeong-sik/oas/issues/2707)) ([cadea00](https://github.com/jeong-sik/oas/commit/cadea00fc86a73a4c3afc03758d3b02610f309c0))

## [0.216.5](https://github.com/jeong-sik/oas/compare/v0.216.4...v0.216.5) (2026-07-19)


### Features

* **agent:** expose durable execution projection ([#2701](https://github.com/jeong-sik/oas/issues/2701)) ([976cacd](https://github.com/jeong-sik/oas/commit/976cacd24b958cc3eea299101ec8ae973026e01d))
* **agent:** expose typed execution terminal disposition ([#2694](https://github.com/jeong-sik/oas/issues/2694)) ([66f6831](https://github.com/jeong-sik/oas/commit/66f6831e14b1cd579710e7ad6812139ca8f220ae))

## [0.216.4](https://github.com/jeong-sik/oas/compare/v0.216.3...v0.216.4) (2026-07-18)


### Features

* **agent:** enforce prepared-request fit admission ([#2678](https://github.com/jeong-sik/oas/issues/2678)) ([9b7132f](https://github.com/jeong-sik/oas/commit/9b7132f055ccac4c0d5166ae58e63f61f800d46a))
* **error:** expose canonical SDK categories ([#2674](https://github.com/jeong-sik/oas/issues/2674)) ([6928060](https://github.com/jeong-sik/oas/commit/6928060de7567be9f1c690fd7cadb132dbf64a72))
* **execution:** hard-cut Agent tool authority ([#2683](https://github.com/jeong-sik/oas/issues/2683)) ([fe027bb](https://github.com/jeong-sik/oas/commit/fe027bbe3ed500bc4e67d2599e1017a642e08942))

## [0.216.3](https://github.com/jeong-sik/oas/compare/v0.216.2...v0.216.3) (2026-07-18)


### Bug Fixes

* **ci:** run full CI matrix on stacked PRs ([#2656](https://github.com/jeong-sik/oas/issues/2656)) ([8410b87](https://github.com/jeong-sik/oas/commit/8410b87f66711a5586006f74185cebd610cb64fd))

## [0.216.2](https://github.com/jeong-sik/oas/compare/v0.216.1...v0.216.2) (2026-07-17)


### Bug Fixes

* **llm_provider:** promote empty-completion overflow in of_http_error ([#2659](https://github.com/jeong-sik/oas/issues/2659)) ([ded9bc7](https://github.com/jeong-sik/oas/commit/ded9bc7ec21e69e4627cdeb10cf758b32cefdd25))

## [0.216.1](https://github.com/jeong-sik/oas/compare/v0.216.0...v0.216.1) (2026-07-17)


### Features

* **llm_provider:** measure prepared completion requests ([#2647](https://github.com/jeong-sik/oas/issues/2647)) ([2fab2fa](https://github.com/jeong-sik/oas/commit/2fab2fa220ef6e1b6b172f12b04e341ac73cf2aa))


### Bug Fixes

* **execution:** align tool batch schedule semantics ([#2652](https://github.com/jeong-sik/oas/issues/2652)) ([0b21c5e](https://github.com/jeong-sik/oas/commit/0b21c5e141318e9b0f78e3c475b1ac392f8ce1ed))
* **execution:** preserve opaque provider tool ids ([#2648](https://github.com/jeong-sik/oas/issues/2648)) ([918899b](https://github.com/jeong-sik/oas/commit/918899bd2a0afb91bb9bfd232955035a59be6182))

## [0.216.0](https://github.com/jeong-sik/oas/compare/v0.215.0...v0.216.0) (2026-07-17)


### ⚠ BREAKING CHANGES

* **tool:** make invocation the lifecycle SSOT ([#2642](https://github.com/jeong-sik/oas/issues/2642))

### Features

* **llm_provider:** admit concurrent dispatches per endpoint identity ([#2641](https://github.com/jeong-sik/oas/issues/2641)) ([1bcc238](https://github.com/jeong-sik/oas/commit/1bcc2380f4877e70f0dd975f6a826f66efd6d68f))
* **tool:** make invocation the lifecycle SSOT ([#2642](https://github.com/jeong-sik/oas/issues/2642)) ([12d7366](https://github.com/jeong-sik/oas/commit/12d7366333574679f36418678e8e910cf185b255))


### Bug Fixes

* **llm_provider:** carry Retry-After and rate-limit prose through typed errors ([#2644](https://github.com/jeong-sik/oas/issues/2644)) ([f887c20](https://github.com/jeong-sik/oas/commit/f887c20f86ca0b3db40e09d7244169d0b8978336))

## [0.215.0](https://github.com/jeong-sik/oas/compare/v0.214.1...v0.215.0) (2026-07-17)


### ⚠ BREAKING CHANGES

* **tool:** Tool.handler_kind gains WithInvocation and invocation-aware handlers receive exact turn/index-scoped call metadata.

### Features

* **tool:** expose exact invocation occurrence ([#2631](https://github.com/jeong-sik/oas/issues/2631)) ([e67f550](https://github.com/jeong-sik/oas/commit/e67f550752b74ee04515a6f7e2329ec0688d4dfe))


### Bug Fixes

* **execution:** bind recursive work to exact tool attempts ([#2637](https://github.com/jeong-sik/oas/issues/2637)) ([ea70f5d](https://github.com/jeong-sik/oas/commit/ea70f5ded957fb3d5499a26f978b134b9a74c7ff))

## [0.214.1](https://github.com/jeong-sik/oas/compare/v0.214.0...v0.214.1) (2026-07-16)


### Bug Fixes

* **llm_provider:** surface silent capability drops and prove tools+schema coexistence ([#2636](https://github.com/jeong-sik/oas/issues/2636)) ([00d7bcb](https://github.com/jeong-sik/oas/commit/00d7bcb88c11083e191c753d4fb8afa9cd4b3d8a))
* **streaming:** total SSE decode boundary + shared Gemini Interactions envelope ([#2634](https://github.com/jeong-sik/oas/issues/2634)) ([1b108fe](https://github.com/jeong-sik/oas/commit/1b108fea6c3cae7d08bc6a1c382f052d279c9a77))

## [0.214.0](https://github.com/jeong-sik/oas/compare/v0.213.0...v0.214.0) (2026-07-16)


### ⚠ BREAKING CHANGES

* **runtime:** make_http_transport no longer accepts a construction-time stream idle timeout; callers must use the request/agent option. Provider timeout hint and turn-cap no-op APIs are removed.

### Features

* **audio:** add typed Gemini Interactions TTS ([#2615](https://github.com/jeong-sik/oas/issues/2615)) ([476bdc5](https://github.com/jeong-sik/oas/commit/476bdc5609d7857f23002c5981a0ddc27bc84cea))
* **audio:** add typed OpenAI speech generation ([#2629](https://github.com/jeong-sik/oas/issues/2629)) ([0e13bb0](https://github.com/jeong-sik/oas/commit/0e13bb0c5891299732955d5ba92873cce9a264f2))
* **execution:** add crash-durable journal store foundation ([#2611](https://github.com/jeong-sik/oas/issues/2611)) ([d912ab4](https://github.com/jeong-sik/oas/commit/d912ab44119ef4cbfc3e17d5f11410b2549c2559))
* **execution:** add private recursive journal foundation ([#2608](https://github.com/jeong-sik/oas/issues/2608)) ([10e8fef](https://github.com/jeong-sik/oas/commit/10e8fef6f2ec3f74d3810f155cc80e790c7ceae7))
* **execution:** add shared canonical codec executor ([#2622](https://github.com/jeong-sik/oas/issues/2622)) ([b9f0192](https://github.com/jeong-sik/oas/commit/b9f019210021fa93a38359128ee049bbedd5512e))
* **image:** add typed catalog-driven generation ([#2610](https://github.com/jeong-sik/oas/issues/2610)) ([245a725](https://github.com/jeong-sik/oas/commit/245a72567c8009c500d6132f55e907f842deae47))
* **image:** add typed Gemini Interactions generation ([#2612](https://github.com/jeong-sik/oas/issues/2612)) ([e11d18b](https://github.com/jeong-sik/oas/commit/e11d18b78f7ca011ac892c9a5877c055bbbf0756))
* **llm_provider:** add Anthropic input token count transport ([#2624](https://github.com/jeong-sik/oas/issues/2624)) ([845d9f9](https://github.com/jeong-sik/oas/commit/845d9f9529c9f0dabb4be40ef653d1ab8ccee7b7))
* **llm_provider:** add typed input token count contract ([#2623](https://github.com/jeong-sik/oas/issues/2623)) ([3a6c92c](https://github.com/jeong-sik/oas/commit/3a6c92c715dadf83a1f992f3d516f873aa84aac5))


### Performance Improvements

* **tls:** cache process-wide TLS client config ([#2626](https://github.com/jeong-sik/oas/issues/2626)) ([2dfccdf](https://github.com/jeong-sik/oas/commit/2dfccdf98ab1e43e3fa24cdb5e28b8380488bdf5))


### Code Refactoring

* **runtime:** hard-delete implicit execution limits ([#2589](https://github.com/jeong-sik/oas/issues/2589)) ([84f941c](https://github.com/jeong-sik/oas/commit/84f941c5a596866f48ac688615bb5680e52c026d))

## [0.213.0](https://github.com/jeong-sik/oas/compare/v0.212.1...v0.213.0) (2026-07-16)


### ⚠ BREAKING CHANGES

* **context:** purge retired reducer contracts ([#2603](https://github.com/jeong-sik/oas/issues/2603))

### Features

* **llm_provider:** add total JSON decode boundary to Json_util ([#2620](https://github.com/jeong-sik/oas/issues/2620)) ([aba2b59](https://github.com/jeong-sik/oas/commit/aba2b59190d8b798bdd2f34ded1c9fd6b90d70be))


### Bug Fixes

* **provider:** type empty-completion ContextWindowExceeded as Api ContextOverflow ([#2621](https://github.com/jeong-sik/oas/issues/2621)) ([98b1042](https://github.com/jeong-sik/oas/commit/98b104273524817b4621c8c07a02ffdea9f29172))


### Documentation

* **context:** purge retired reducer contracts ([#2603](https://github.com/jeong-sik/oas/issues/2603)) ([fb25e53](https://github.com/jeong-sik/oas/commit/fb25e53cbe6d75c71bfb6e60626cea6b5e542288))

## [0.212.1](https://github.com/jeong-sik/oas/compare/v0.212.0...v0.212.1) (2026-07-15)


### Features

* **catalog:** deployment overlay merge + alias-canonicalized provider lookup (RFC-OAS-036) ([#2604](https://github.com/jeong-sik/oas/issues/2604)) ([3624bca](https://github.com/jeong-sik/oas/commit/3624bca0c25763e7e94d352badfa6f8bbf7b16b0))


### Bug Fixes

* **agent-tool:** align declared and consumed inputs ([#2602](https://github.com/jeong-sik/oas/issues/2602)) ([92dbe27](https://github.com/jeong-sik/oas/commit/92dbe272e7d35e4294f8a40dd908f069bca8d63b))
* **provider:** keep one sync timeout boundary ([#2607](https://github.com/jeong-sik/oas/issues/2607)) ([fd9f460](https://github.com/jeong-sik/oas/commit/fd9f460ca200d01726303cf3862086cc8dea4374))

## [0.212.0](https://github.com/jeong-sik/oas/compare/v0.211.10...v0.212.0) (2026-07-14)


### ⚠ BREAKING CHANGES

* lifecycle caps, approval/governance APIs, automatic retries/context rewriting, tool disclosure/alias layers, runtime control messages, and ambient catalog bootstrap are removed.
* **catalog:** embed the OAS model catalog ([#2592](https://github.com/jeong-sik/oas/issues/2592))

### Bug Fixes

* preserve exact provider and pricing contracts ([#2596](https://github.com/jeong-sik/oas/issues/2596)) ([ac5fd31](https://github.com/jeong-sik/oas/commit/ac5fd31d640ca47961e14606ea67288f12e2579a))


### Code Refactoring

* **catalog:** embed the OAS model catalog ([#2592](https://github.com/jeong-sik/oas/issues/2592)) ([0025652](https://github.com/jeong-sik/oas/commit/002565272c2806a31883e47e0d1af94ed23449bc))
* hard-cut implicit agent governance ([#2590](https://github.com/jeong-sik/oas/issues/2590)) ([6f3648d](https://github.com/jeong-sik/oas/commit/6f3648d61a25181f1d53bcaaef9b96f7ec885178))

## [0.211.10](https://github.com/jeong-sik/oas/compare/v0.211.9...v0.211.10) (2026-07-13)


### Bug Fixes

* **agent:** migrate legacy recovery receipts ([#2584](https://github.com/jeong-sik/oas/issues/2584)) ([51481ef](https://github.com/jeong-sik/oas/commit/51481ef624960e6f501c39ac220e2973ffa2dfc5))
* treat typed media responses as deliverable ([#2588](https://github.com/jeong-sik/oas/issues/2588)) ([902c45d](https://github.com/jeong-sik/oas/commit/902c45d2f2a99bdef919b0afc3b0a13f1a494324))

## [0.211.9](https://github.com/jeong-sik/oas/compare/v0.211.8...v0.211.9) (2026-07-12)


### Bug Fixes

* **agent:** recover repeated failure groups without guessing ([#2582](https://github.com/jeong-sik/oas/issues/2582)) ([93004c9](https://github.com/jeong-sik/oas/commit/93004c96b4d816e1ea6c54fb16a25f022563fb48))

## [0.211.8](https://github.com/jeong-sik/oas/compare/v0.211.7...v0.211.8) (2026-07-12)


### Bug Fixes

* **agent:** preserve idle guard with recovery judge ([#2579](https://github.com/jeong-sik/oas/issues/2579)) ([33535c4](https://github.com/jeong-sik/oas/commit/33535c4c879f384d9d6dcfaaca7a3f945d56cb6b))
* **api:** preserve legacy error projections with typed evidence ([#2576](https://github.com/jeong-sik/oas/issues/2576)) ([85f69a1](https://github.com/jeong-sik/oas/commit/85f69a12d1e57da681a764ae3b2540b0cb5f7e31))
* **release:** reconcile API availability versions ([#2580](https://github.com/jeong-sik/oas/issues/2580)) ([0bdfee0](https://github.com/jeong-sik/oas/commit/0bdfee01cc9fb98e5855c29b99f0ba430f4db65a))

## [0.211.7](https://github.com/jeong-sik/oas/compare/v0.211.6...v0.211.7) (2026-07-12)


### Features

* **provider:** add closed failure attribution and binding identity ([#2572](https://github.com/jeong-sik/oas/issues/2572)) ([aa61ac8](https://github.com/jeong-sik/oas/commit/aa61ac8f65362554f1b9ec85d1be95b6e0154cb6))

## [0.211.6](https://github.com/jeong-sik/oas/compare/v0.211.5...v0.211.6) (2026-07-12)


### Bug Fixes

* **gemini:** validate exact replay payload schema ([#2569](https://github.com/jeong-sik/oas/issues/2569)) ([6544f05](https://github.com/jeong-sik/oas/commit/6544f054b0ba0699ca4188db0e4a11e3ac9f9d0c))

## [0.211.5](https://github.com/jeong-sik/oas/compare/v0.211.4...v0.211.5) (2026-07-12)


### Bug Fixes

* **fmt:** restore main formatting gate ([#2564](https://github.com/jeong-sik/oas/issues/2564)) ([bbdd8ea](https://github.com/jeong-sik/oas/commit/bbdd8eaacd2e78f6f6b836654dc5eac458455b8c))

## [0.211.4](https://github.com/jeong-sik/oas/compare/v0.211.3...v0.211.4) (2026-07-12)


### Bug Fixes

* **checkpoint:** reject duplicate recovery provenance ([#2558](https://github.com/jeong-sik/oas/issues/2558)) ([2432663](https://github.com/jeong-sik/oas/commit/2432663b3f544153ce9ed1c1e61ededcf2b27a69))
* **gemini:** harden thought-signature replay boundaries ([#2559](https://github.com/jeong-sik/oas/issues/2559)) ([b716f0c](https://github.com/jeong-sik/oas/commit/b716f0c5e3a710ee02da1baab9da0bba374e0686))
* **test:** correct List.nth argument order in gemini part assertion ([#2556](https://github.com/jeong-sik/oas/issues/2556)) ([a317895](https://github.com/jeong-sik/oas/commit/a317895d5112ed7d5bc1066a91c7424ca7989294))

## [0.211.3](https://github.com/jeong-sik/oas/compare/v0.211.2...v0.211.3) (2026-07-12)


### Features

* **llm_provider:** bind output-token receipts to request artifacts ([#2543](https://github.com/jeong-sik/oas/issues/2543)) ([da3cee6](https://github.com/jeong-sik/oas/commit/da3cee60dcbe5e79ce51bb97dc7b5d33ed23c38b))


### Bug Fixes

* **agent:** harden typed failure recovery resume ([#2547](https://github.com/jeong-sik/oas/issues/2547)) ([69647a3](https://github.com/jeong-sik/oas/commit/69647a30655cf550953ee535ef5e1b0f6e9b729a))
* **agent:** make typed recovery opt-in and authoritative ([#2551](https://github.com/jeong-sik/oas/issues/2551)) ([8738d1d](https://github.com/jeong-sik/oas/commit/8738d1d4d423b0588bc4fed3e51153f64cba4a9a))
* **agent:** type recovery receipt messages ([#2546](https://github.com/jeong-sik/oas/issues/2546)) ([d152464](https://github.com/jeong-sik/oas/commit/d15246468184736af3bb4885e4530b321f71ca6f))
* **gemini:** preserve textual thought signatures ([#2554](https://github.com/jeong-sik/oas/issues/2554)) ([0c6dabc](https://github.com/jeong-sik/oas/commit/0c6dabcfc80254e5a09fac314ea56c9fed765183))
* **test:** type recovery boundary fixture ([#2550](https://github.com/jeong-sik/oas/issues/2550)) ([fc40510](https://github.com/jeong-sik/oas/commit/fc405106e62dce43b57d08870ea6fbbff8422c93))

## [0.211.2](https://github.com/jeong-sik/oas/compare/v0.211.1...v0.211.2) (2026-07-11)


### Features

* **agent:** preserve typed tool failure provenance ([#2539](https://github.com/jeong-sik/oas/issues/2539)) ([972ea29](https://github.com/jeong-sik/oas/commit/972ea29b02594d11e8b84de628425b9fcf6f3b0a))


### Bug Fixes

* **provider:** align Kimi HTTP codec ([#2540](https://github.com/jeong-sik/oas/issues/2540)) ([0ed834a](https://github.com/jeong-sik/oas/commit/0ed834abbebe95001b301c66809a330ac2e3eb34))
* **provider:** make registry startup-safe ([#2538](https://github.com/jeong-sik/oas/issues/2538)) ([b8d8b51](https://github.com/jeong-sik/oas/commit/b8d8b516e9671fa179d7438a2b4af6671236ae94))
* **streaming:** stabilize id-less tool identities ([#2536](https://github.com/jeong-sik/oas/issues/2536)) ([a912fe4](https://github.com/jeong-sik/oas/commit/a912fe4487336aa41bc0352c7df59cd3f05ec854))

## [0.211.1](https://github.com/jeong-sik/oas/compare/v0.211.0...v0.211.1) (2026-07-11)


### Bug Fixes

* **reasoning:** capture qwen3.6 streamed thinking ([#2527](https://github.com/jeong-sik/oas/issues/2527)) ([01eefcc](https://github.com/jeong-sik/oas/commit/01eefcc841d36348396ec44b9190d1518f8fe376))
* **retry:** classify HTTP 403 as authorization failure ([#2520](https://github.com/jeong-sik/oas/issues/2520)) ([43498e9](https://github.com/jeong-sik/oas/commit/43498e93f908413a5139a4ace2c10f060747fb98))
* **streaming:** preserve authorization error parity ([#2524](https://github.com/jeong-sik/oas/issues/2524)) ([0c2aef9](https://github.com/jeong-sik/oas/commit/0c2aef991de2049c02de4188aafde1a5256f7a9a))

## [0.211.0](https://github.com/jeong-sik/oas/compare/v0.210.0...v0.211.0) (2026-07-11)


### ⚠ BREAKING CHANGES

* **llm_provider:** optional-envelope requests with caller None no longer carry max_tokens for catalog-declared models.

### Bug Fixes

* **llm_provider:** separate output ceiling from request default ([#2518](https://github.com/jeong-sik/oas/issues/2518)) ([8feb749](https://github.com/jeong-sik/oas/commit/8feb749e787dba40e1a6e0a034812f9a22ffbef7))

## [0.210.0](https://github.com/jeong-sik/oas/compare/v0.209.1...v0.210.0) (2026-07-11)


### ⚠ BREAKING CHANGES

* **llm_provider:** effective_max_output_tokens is int option; unknown-model requests no longer carry max_tokens.

### Features

* **llm_provider:** stop inventing max_tokens for catalog-silent models ([#2514](https://github.com/jeong-sik/oas/issues/2514)) ([351c962](https://github.com/jeong-sik/oas/commit/351c962606ddc0ac105efe98b43955a3cbd0054b))

## [0.209.1](https://github.com/jeong-sik/oas/compare/v0.209.0...v0.209.1) (2026-07-10)


### Bug Fixes

* **provider:** serialize tool_choice none for capable providers ([#2508](https://github.com/jeong-sik/oas/issues/2508)) ([90cd9b5](https://github.com/jeong-sik/oas/commit/90cd9b502ecfb0f93545cb1f0e84a9d610ad198c)), closes [#2505](https://github.com/jeong-sik/oas/issues/2505)
* **provider:** type documented terminal reasons ([#2506](https://github.com/jeong-sik/oas/issues/2506)) ([0837145](https://github.com/jeong-sik/oas/commit/0837145a440b0ee72a4aaabd9fc1a72587b000df))

## [0.209.0](https://github.com/jeong-sik/oas/compare/v0.208.22...v0.209.0) (2026-07-10)


### ⚠ BREAKING CHANGES

* **release:** OAS 0.209 is the supported compatibility floor for Hooks.Block and removes Agent_sdk.Context_intent.
* **ci:** restore Block ratchets and the 0.209 release gate ([#2495](https://github.com/jeong-sik/oas/issues/2495))

### Bug Fixes

* **ci:** restore Block ratchets and the 0.209 release gate ([#2495](https://github.com/jeong-sik/oas/issues/2495)) ([41eb848](https://github.com/jeong-sik/oas/commit/41eb84817823de894a289330b052d5ae40033ac9))
* **provider:** enforce typed empty completion boundaries ([#2498](https://github.com/jeong-sik/oas/issues/2498)) ([ec17f6a](https://github.com/jeong-sik/oas/commit/ec17f6a2f00ee858e368c31592bad65c74e911c4))
* **provider:** keep Ollama thinking default out of OpenAI requests ([#2494](https://github.com/jeong-sik/oas/issues/2494)) ([edab917](https://github.com/jeong-sik/oas/commit/edab91704a22135b06549705647ba7beb1946073))
* **release:** declare the 0.209 public API boundary ([#2497](https://github.com/jeong-sik/oas/issues/2497)) ([9ba0962](https://github.com/jeong-sik/oas/commit/9ba096275fb6ebdfeb42754e245c0a32566b1197))
* **streaming:** delete the thinking-only wall-clock cutoff ([#10](https://github.com/jeong-sik/oas/issues/10) campaign) ([#2501](https://github.com/jeong-sik/oas/issues/2501)) ([c2bcd8f](https://github.com/jeong-sik/oas/commit/c2bcd8f8579e671b5d0c5441e894e8b2c316c161))

## [0.208.22](https://github.com/jeong-sik/oas/compare/v0.208.21...v0.208.22) (2026-07-08)


### Bug Fixes

* **streaming:** fail closed on empty completion at the driver boundary (oas[#2483](https://github.com/jeong-sik/oas/issues/2483)) ([#2491](https://github.com/jeong-sik/oas/issues/2491)) ([a320b04](https://github.com/jeong-sik/oas/commit/a320b04f54dea4f3291a5c6d8c2b085501056455))

## [0.208.21](https://github.com/jeong-sik/oas/compare/v0.208.20...v0.208.21) (2026-07-08)


### Bug Fixes

* **openai-compat:** chat-template thinking token injection + empty-completion fail-close ([#2483](https://github.com/jeong-sik/oas/issues/2483)) ([#2488](https://github.com/jeong-sik/oas/issues/2488)) ([aad819b](https://github.com/jeong-sik/oas/commit/aad819bb1977c9668dbb87ac13b1ab7d50ac9edb))

## [0.208.20](https://github.com/jeong-sik/oas/compare/v0.208.19...v0.208.20) (2026-07-05)


### Features

* add local Gemma4 E2B Ollama catalog row ([#2477](https://github.com/jeong-sik/oas/issues/2477)) ([aa12f26](https://github.com/jeong-sik/oas/commit/aa12f26aece8c2b4d90f96ec4d8e4dc0aecc807e))

## [0.208.19](https://github.com/jeong-sik/oas/compare/v0.208.18...v0.208.19) (2026-07-04)


### Bug Fixes

* **provider:** release reasoning replay token waste fix ([#2473](https://github.com/jeong-sik/oas/issues/2473)) ([a33d6a0](https://github.com/jeong-sik/oas/commit/a33d6a0a0027830905993472805067dcdf2f1061))

## [0.208.18](https://github.com/jeong-sik/oas/compare/v0.208.17...v0.208.18) (2026-07-04)


### Bug Fixes

* **provider:** type suppressed sampling parameters ([#2467](https://github.com/jeong-sik/oas/issues/2467)) ([0aebb39](https://github.com/jeong-sik/oas/commit/0aebb39f34b0d18983444cee1db2e2d9fb089e17))

## [0.208.17](https://github.com/jeong-sik/oas/compare/v0.208.16...v0.208.17) (2026-07-04)


### Bug Fixes

* **llm_provider:** align kimi k2 thinking dialects ([#2465](https://github.com/jeong-sik/oas/issues/2465)) ([f637dfa](https://github.com/jeong-sik/oas/commit/f637dfac51f76528b921d08f2ddcbbe8698e2d90))
* **llm_provider:** align kimi sampling prompt strategy ([#2461](https://github.com/jeong-sik/oas/issues/2461)) ([ccdd0f5](https://github.com/jeong-sik/oas/commit/ccdd0f51e749ff6fa1c4bf99ae3f212aa9f4e39c))

## [0.208.16](https://github.com/jeong-sik/oas/compare/v0.208.15...v0.208.16) (2026-07-03)


### Bug Fixes

* **llm_provider:** offload wire capture I/O to a background fiber ([#2456](https://github.com/jeong-sik/oas/issues/2456)) ([3684c32](https://github.com/jeong-sik/oas/commit/3684c32fabab4daf74b6fc4eea6619b3fdf1a5c7))
* **provider_config:** replace fuzzy ollama host classifier with exact Uri.host equality ([#2458](https://github.com/jeong-sik/oas/issues/2458)) ([5c53517](https://github.com/jeong-sik/oas/commit/5c535170880091888ef552be9a212ac922259fdd))

## [0.208.15](https://github.com/jeong-sik/oas/compare/v0.208.14...v0.208.15) (2026-07-03)


### Bug Fixes

* **provider:** map api.kimi.com coding-plan host to kimi vendor identity ([#2454](https://github.com/jeong-sik/oas/issues/2454)) ([6c6d5ca](https://github.com/jeong-sik/oas/commit/6c6d5ca3971b82e3de746e70b1dac6f15842385d)), closes [#2452](https://github.com/jeong-sik/oas/issues/2452) [#2414](https://github.com/jeong-sik/oas/issues/2414)

## [0.208.14](https://github.com/jeong-sik/oas/compare/v0.208.13...v0.208.14) (2026-07-03)


### Bug Fixes

* **catalog:** validate base preset label at parse time, not silent default (RFC-OAS-034 :840) ([#2433](https://github.com/jeong-sik/oas/issues/2433)) ([ed4b30a](https://github.com/jeong-sik/oas/commit/ed4b30a13bee189f65a4dc1f08fc92414ac06684))
* **llm_provider:** harden redaction for large media payloads ([#2444](https://github.com/jeong-sik/oas/issues/2444)) ([8c8db16](https://github.com/jeong-sik/oas/commit/8c8db16c2d7ce703f9662f7353f7dc54e5111d68))
* **llm_provider:** use Eio.Mutex in wire_capture to avoid blocking fiber scheduling ([#2449](https://github.com/jeong-sik/oas/issues/2449)) ([815845b](https://github.com/jeong-sik/oas/commit/815845b23561a41430c8b28369e9760533410c9e))
* **provider:** honor per-model catalog rows on Custom_registered path ([#2447](https://github.com/jeong-sik/oas/issues/2447)) ([390008e](https://github.com/jeong-sik/oas/commit/390008e0bcec02b787a7b0e49adc48c7c7683154))
* **provider:** remove last model-id GLM classifier, gate GLM base entries by endpoint declaration ([#2446](https://github.com/jeong-sik/oas/issues/2446)) ([8bdf25d](https://github.com/jeong-sik/oas/commit/8bdf25d678f85f4c00893aa2f068bfb9edcf3ea7))

## [0.208.13](https://github.com/jeong-sik/oas/compare/v0.208.12...v0.208.13) (2026-07-02)


### Features

* **llm_provider:** expose packaged model catalog ([#2424](https://github.com/jeong-sik/oas/issues/2424)) ([9e4403c](https://github.com/jeong-sik/oas/commit/9e4403cb6fbe3ba132dcbd9cb0b16c1bbef1476c))
* **llm_provider:** raw stream wire capture 관측 하네스 (Phase O) ([#2435](https://github.com/jeong-sik/oas/issues/2435)) ([6ea88e6](https://github.com/jeong-sik/oas/commit/6ea88e6d54cc4eb6804d84b698805aebef6f4b50))
* **ratchet:** host/base_url fuzzy-classifier hardening metric (RFC-OAS-034 §5) ([#2419](https://github.com/jeong-sik/oas/issues/2419)) ([853e32b](https://github.com/jeong-sik/oas/commit/853e32b9e9bd3018a258f7f9f1afcd3298d31ff6))


### Bug Fixes

* **boundary:** remove coordinator-specific term from capabilities doc comment ([#2443](https://github.com/jeong-sik/oas/issues/2443)) ([7ac7ddc](https://github.com/jeong-sik/oas/commit/7ac7ddcf5f45c57086eec9144345859dedf1c52b))
* **boundary:** remove coordinator-specific term from wire_capture doc comment ([#2441](https://github.com/jeong-sik/oas/issues/2441)) ([42d44d8](https://github.com/jeong-sik/oas/commit/42d44d8bb143adf2a3bb548c5f48edc564c30bfb))
* **catalog:** add runpod gemma4 coder capabilities ([#2431](https://github.com/jeong-sik/oas/issues/2431)) ([56d7e48](https://github.com/jeong-sik/oas/commit/56d7e4850d695e430d93a8036b1b5b211243d7a4))
* **catalog:** reject unknown fields in model catalog entries, not silently drop (RFC-OAS-034) ([#2426](https://github.com/jeong-sik/oas/issues/2426)) ([3592c05](https://github.com/jeong-sik/oas/commit/3592c0553b940a5c7d193a9e94b61539ee0bff82))
* **provider:** defer 13 residual *_defaults BASE_URL env reads from module load to call time ([#2436](https://github.com/jeong-sik/oas/issues/2436)) ([b883c80](https://github.com/jeong-sik/oas/commit/b883c80ea87be0e12fcdf201cc467ea90e742bec))
* **provider:** match ollama cloud host by exact Uri.host, not URL prefix (RFC-OAS-034 B4) ([#2420](https://github.com/jeong-sik/oas/issues/2420)) ([84ef566](https://github.com/jeong-sik/oas/commit/84ef566e10b05035efdb267046c4e072623d642b))
* **provider:** Ollama Cloud /v1 does not guarantee structured output ([#2440](https://github.com/jeong-sik/oas/issues/2440)) ([2084e5f](https://github.com/jeong-sik/oas/commit/2084e5f7096688c123570aa39042d54597907b54))
* **provider:** recognize api.deepseek.com as deepseek vendor host (RFC-OAS-034) ([#2427](https://github.com/jeong-sik/oas/issues/2427)) ([b103e6b](https://github.com/jeong-sik/oas/commit/b103e6bcc729ccdd78620b262eb964268b30a3fb))
* **provider:** rename runpod_mtp namespace to host-agnostic vllm-qwen3-mtp (RFC-OAS-034 B1/B2) ([#2432](https://github.com/jeong-sik/oas/issues/2432)) ([b624354](https://github.com/jeong-sik/oas/commit/b62435409236925d49648ec2151bdefe4b0593e9))
* **provider:** single-source Responses builder policy with Chat builder ([#2437](https://github.com/jeong-sik/oas/issues/2437)) ([1b7da64](https://github.com/jeong-sik/oas/commit/1b7da64714824b585361207bba21b0041b5b128c))
* **ratchet:** host/base_url fuzzy-classifier detector precision + recall ([#2419](https://github.com/jeong-sik/oas/issues/2419) follow-up) ([#2430](https://github.com/jeong-sik/oas/issues/2430)) ([de66104](https://github.com/jeong-sik/oas/commit/de66104ffb3023705564f73131da114b0616fa24))
* **sampling:** do not default min_p from host locality for uncatalogued models (RFC-OAS-034 B7) ([#2425](https://github.com/jeong-sik/oas/issues/2425)) ([382bb2b](https://github.com/jeong-sik/oas/commit/382bb2b668cd83755faa5290d983a53bc0b6c608))
* **test:** list model catalog default test module ([#2429](https://github.com/jeong-sik/oas/issues/2429)) ([97076aa](https://github.com/jeong-sik/oas/commit/97076aa6dae6ee8ac14a1857a9232ea6373118f6))

## [0.208.12](https://github.com/jeong-sik/oas/compare/v0.208.11...v0.208.12) (2026-07-01)


### Bug Fixes

* accept declared provider-qualified compat models ([#2418](https://github.com/jeong-sik/oas/issues/2418)) ([0149c70](https://github.com/jeong-sik/oas/commit/0149c70e9a8719542011a8acb7f984f7e952b1bd))
* **agent:** release default unbounded turn budget ([#2422](https://github.com/jeong-sik/oas/issues/2422)) ([0a6d2cd](https://github.com/jeong-sik/oas/commit/0a6d2cd0c2834efd92fe60ac2bb9cfc2bd21acbf))

## [0.208.11](https://github.com/jeong-sik/oas/compare/v0.208.10...v0.208.11) (2026-07-01)


### Bug Fixes

* **provider:** resolve dot-qualified catalog models ([#2406](https://github.com/jeong-sik/oas/issues/2406)) ([ed7cd19](https://github.com/jeong-sik/oas/commit/ed7cd19313edfb5c37f832d189d64ec073c6feb1))
* **provider:** resolve local OpenAI-compat endpoints to neutral label, not vendor "nous" ([#2415](https://github.com/jeong-sik/oas/issues/2415)) ([b0dd6a0](https://github.com/jeong-sik/oas/commit/b0dd6a09545a6cee29cea87bcfeb9fe117ba2174))

## [0.208.10](https://github.com/jeong-sik/oas/compare/v0.208.9...v0.208.10) (2026-07-01)


### Bug Fixes

* let resume config override thinking policy ([#2412](https://github.com/jeong-sik/oas/issues/2412)) ([6543568](https://github.com/jeong-sik/oas/commit/65435688c4059563e6432800bdd1318acec03961))
* **provider:** revert Local dialect inference to fail-closed ([#2410](https://github.com/jeong-sik/oas/issues/2410)) ([2ea8be8](https://github.com/jeong-sik/oas/commit/2ea8be89eeb1734f37521d9951f5f3095ef2f403))
* **retry:** classify HTTP 402 as first-class PaymentRequired, not InvalidRequest ([#2407](https://github.com/jeong-sik/oas/issues/2407)) ([ff0d8f0](https://github.com/jeong-sik/oas/commit/ff0d8f02a2024e58a005ad00a29cf0922f16f4ed))

## [0.208.9](https://github.com/jeong-sik/oas/compare/v0.208.8...v0.208.9) (2026-07-01)


### Features

* **agent:** ensure_final_text convergence — one tool-withheld answer turn ([#2385](https://github.com/jeong-sik/oas/issues/2385)) ([287f0fe](https://github.com/jeong-sik/oas/commit/287f0fec7b2dcdb19eb74d55fc7c0df48acf7e00))
* **capabilities:** derive show+eq on thinking_control_format ([#2398](https://github.com/jeong-sik/oas/issues/2398)) ([96716ba](https://github.com/jeong-sik/oas/commit/96716bacdb0b0346c90cc32ff3ebb4c36bf7efe0))
* **provider:** parse catalog capability controls ([#2386](https://github.com/jeong-sik/oas/issues/2386)) ([2896068](https://github.com/jeong-sik/oas/commit/289606808a12b264057be08eb515ab5fdbb41250))
* **provider:** report tool pair repair drops ([#2389](https://github.com/jeong-sik/oas/issues/2389)) ([bc323fe](https://github.com/jeong-sik/oas/commit/bc323feca0a9ddd15e0809470db10d279eaf567d))
* **structured:** expose response JSON extractor ([#2379](https://github.com/jeong-sik/oas/issues/2379)) ([df8f473](https://github.com/jeong-sik/oas/commit/df8f473902d45373b1b8a7ce4a4ea2168d685b1c))


### Bug Fixes

* **canonical:** omit reasoning payloads from tool projection ([#2376](https://github.com/jeong-sik/oas/issues/2376)) ([fb9beed](https://github.com/jeong-sik/oas/commit/fb9beed6b763282680db2c74bc3eb3398b501b2d))
* **canonical:** use tool-only order index ([#2399](https://github.com/jeong-sik/oas/issues/2399)) ([f22ebbb](https://github.com/jeong-sik/oas/commit/f22ebbbce04e607aaa2b062d5541fd06753912d1))
* **provider:** keep local compat dialect generic ([#2402](https://github.com/jeong-sik/oas/issues/2402)) ([5ca29c9](https://github.com/jeong-sik/oas/commit/5ca29c96a2d0f7cf831330707cb69b3242f12343))
* **provider:** require endpoint declaration for compat dialects ([#2383](https://github.com/jeong-sik/oas/issues/2383)) ([898f26c](https://github.com/jeong-sik/oas/commit/898f26cbfebc61b0cd441693d7f834ab5858d537))
* **provider:** stop inferring identity from model id ([#2373](https://github.com/jeong-sik/oas/issues/2373)) ([120078f](https://github.com/jeong-sik/oas/commit/120078fe961334b285c3a09afa89b389707f0a0d))

## [0.208.8](https://github.com/jeong-sik/oas/compare/v0.208.7...v0.208.8) (2026-06-30)


### Bug Fixes

* **streaming:** fail closed on unnamed tool calls ([#2370](https://github.com/jeong-sik/oas/issues/2370)) ([bc9cc5d](https://github.com/jeong-sik/oas/commit/bc9cc5d63b0f5cc0a54c3650a45d925be3c14397))

## [0.208.7](https://github.com/jeong-sik/oas/compare/v0.208.6...v0.208.7) (2026-06-30)


### Features

* **types:** expose reasoning details text projection ([#2361](https://github.com/jeong-sik/oas/issues/2361)) ([17101f4](https://github.com/jeong-sik/oas/commit/17101f461e3d2873873b796e27c0169b86efa18e))


### Bug Fixes

* **streaming:** key tool-call blocks by id so parallel calls don't collapse ([#2363](https://github.com/jeong-sik/oas/issues/2363)) ([fab5fc3](https://github.com/jeong-sik/oas/commit/fab5fc3b61682324861419b3493cc8d4a3ef6360))

## [0.208.6](https://github.com/jeong-sik/oas/compare/v0.208.5...v0.208.6) (2026-06-30)


### Bug Fixes

* **mcp:** fail closed on unknown schema types ([#2343](https://github.com/jeong-sik/oas/issues/2343)) ([be716c3](https://github.com/jeong-sik/oas/commit/be716c3c21cd9900acbbf0a45c3b38b6d91303f4))
* **stream-acc:** fail closed on multi-object tool args; drop misdiagnosed re-emit guard ([#2354](https://github.com/jeong-sik/oas/issues/2354)) ([c080e3d](https://github.com/jeong-sik/oas/commit/c080e3d2c9a612f924285df546b00bb5230c27b0))
* **streaming:** emit ContentBlockStop for open blocks on OpenAI-compat finish ([#2356](https://github.com/jeong-sik/oas/issues/2356)) ([d8e5cff](https://github.com/jeong-sik/oas/commit/d8e5cff51ed0840dfd8d61f64b08686e1ac3791a))

## [0.208.5](https://github.com/jeong-sik/oas/compare/v0.208.4...v0.208.5) (2026-06-30)


### Bug Fixes

* **streaming:** avoid wildcard JSON success match ([#2352](https://github.com/jeong-sik/oas/issues/2352)) ([2def5f1](https://github.com/jeong-sik/oas/commit/2def5f11b4b6cbc562e6a8f85b51f6afc10ca701))

## [0.208.4](https://github.com/jeong-sik/oas/compare/v0.208.3...v0.208.4) (2026-06-30)


### Features

* **canonical-tool:** expose block tool call projection ([#2349](https://github.com/jeong-sik/oas/issues/2349)) ([191bc84](https://github.com/jeong-sik/oas/commit/191bc84a089db7f67818bd496294807ea368bedb))


### Bug Fixes

* **streaming:** preserve MiniMax split reasoning details ([#2347](https://github.com/jeong-sik/oas/issues/2347)) ([c60f544](https://github.com/jeong-sik/oas/commit/c60f544b6e3bfdd2d82ce152c82f699dc9468361))

## [0.208.3](https://github.com/jeong-sik/oas/compare/v0.208.2...v0.208.3) (2026-06-30)


### Bug Fixes

* **capabilities:** reject padded exact thinking tokens ([#2338](https://github.com/jeong-sik/oas/issues/2338)) ([dadc9a8](https://github.com/jeong-sik/oas/commit/dadc9a8b8eb5638d6460ac9b299f989605e859e4))
* **context:** preserve thinking skips summarization ([#2325](https://github.com/jeong-sik/oas/issues/2325)) ([8ab2ef1](https://github.com/jeong-sik/oas/commit/8ab2ef1d78a83109e2407f90408de5b2e500193d))
* **glm:** route thinking fields through shared builder ([#2309](https://github.com/jeong-sik/oas/issues/2309)) ([ae2f3ee](https://github.com/jeong-sik/oas/commit/ae2f3ee115e274c6a916b529a4d27b634f9049b2))
* **judge:** fail closed on invalid structured output ([#2342](https://github.com/jeong-sik/oas/issues/2342)) ([7137dd9](https://github.com/jeong-sik/oas/commit/7137dd960000f774a7c9b774fd4ad950ab18eb44))
* **ollama:** declare chat template thinking token ([#2332](https://github.com/jeong-sik/oas/issues/2332)) ([45a0ef4](https://github.com/jeong-sik/oas/commit/45a0ef44bc6356cfa26e3e7f7e144a4713b886fc))
* **responses:** centralize stop reason status mapping ([#2323](https://github.com/jeong-sik/oas/issues/2323)) ([9ee098f](https://github.com/jeong-sik/oas/commit/9ee098fc1a48e3e86f5f8c801e879de96b60dbb3))
* **stream-acc:** replace InputJsonDelta buffer on whole-value re-emit (malformed {}{}) ([#2344](https://github.com/jeong-sik/oas/issues/2344)) ([e4a128a](https://github.com/jeong-sik/oas/commit/e4a128a13777c6b9aa71b1c78bfb6aff232ac686))
* **streaming:** remove coordinator term from provider comments ([#2321](https://github.com/jeong-sik/oas/issues/2321)) ([15276bd](https://github.com/jeong-sik/oas/commit/15276bd18f66b2023565ae4489702b992cf7caec))
* **test:** avoid response helper shadowing ([#2340](https://github.com/jeong-sik/oas/issues/2340)) ([66553e2](https://github.com/jeong-sik/oas/commit/66553e2f28c89f4f995c63d6a465cc551b88cbb2))
* **test:** prefer the packaged model catalog in provider suites ([#2319](https://github.com/jeong-sik/oas/issues/2319)) ([41d64c6](https://github.com/jeong-sik/oas/commit/41d64c6bd3ec52f16f9a5cb32db3ec80cb3f141e))

## [0.208.2](https://github.com/jeong-sik/oas/compare/v0.208.1...v0.208.2) (2026-06-30)


### Bug Fixes

* harden thinking capability fallbacks ([#2313](https://github.com/jeong-sik/oas/issues/2313)) ([a7a153a](https://github.com/jeong-sik/oas/commit/a7a153a6ff9fe84f347d60457e662da37ae38724))
* **main:** restore CI broken by [#2232](https://github.com/jeong-sik/oas/issues/2232) stale visibility ref + format drift ([#2311](https://github.com/jeong-sik/oas/issues/2311)) ([2d89004](https://github.com/jeong-sik/oas/commit/2d8900499da19e43c8081cab9ae7a573e6a5dbed))
* **provider:** classify openai-compatible provider identity ([#2317](https://github.com/jeong-sik/oas/issues/2317)) ([f324a57](https://github.com/jeong-sik/oas/commit/f324a57f9f7de23a645f17ea8f6a5c840e4f90a8))
* **streaming:** preserve malformed tool-arg buffer for keeper-log diagnosis ([#2315](https://github.com/jeong-sik/oas/issues/2315)) ([ac32c79](https://github.com/jeong-sik/oas/commit/ac32c79bf5b294b3ccce6a739b5f5aa338f96eac))
* **streaming:** read reasoning deltas from dialect ([#2314](https://github.com/jeong-sik/oas/issues/2314)) ([1caeb75](https://github.com/jeong-sik/oas/commit/1caeb7583c468fa59b4d0e7e2e4714179137df5f))
* **test:** include model catalog in sandboxed provider suites ([#2318](https://github.com/jeong-sik/oas/issues/2318)) ([fd0731e](https://github.com/jeong-sik/oas/commit/fd0731ec3a77db9814cb3e8d3353c01b4cde9f9a))

## [0.208.1](https://github.com/jeong-sik/oas/compare/v0.208.0...v0.208.1) (2026-06-30)


### Features

* **rfc:** RFC-OAS-029 standard and enforcement coverage ([#2232](https://github.com/jeong-sik/oas/issues/2232)) ([e85d495](https://github.com/jeong-sik/oas/commit/e85d495764d2df94fa063bd25bcabaa4c87bfc3b))

## [0.208.0](https://github.com/jeong-sik/oas/compare/v0.207.28...v0.208.0) (2026-06-30)


### ⚠ BREAKING CHANGES

* **catalog:** provider API-key and thinking-budget env var names are renamed (e.g. PROVIDER_C_API_KEY -> KIMI_API_KEY). Deployment configs, .env files, and any masc OAS-spawn env must move to the brand names.
* **agent:** the public Tool_retry_policy module, the Error.ToolRetryExhausted variant, the agent options.tool_retry_policy field, and Builder.with_tool_retry_policy are removed. Consumers relying on a tool-validation retry cap must rely on the agent loop guard (max_turns / idle / token budget) instead.
* **pipeline:** Callers relying on automatic wrapper unwrap will now receive validation errors. The LLM must send parameters as flat JSON objects at the top level.
* Error.A2a and the a2a_* constructors are removed from the public sdk_error API. Consumers matching Error.A2a must drop that arm. masc-mcp consumes agent_sdk via a git pin; its ~20 Error.A2a match arms will be compiler-forced to update when it adopts the new commit (separate follow-up).
* removes the public Completion_contract, Completion_contract_id, and Completion_contract_violation_detail modules from agent_sdk, the CompletionContractViolation error variant (Error.sdk_error / Error_domain.sdk_error_poly), and the Agent builder function with_required_tool_satisfaction. Consumers that matched on these types or relied on the SDK raising CompletionContractViolation for a missing required tool must remove those matchers and detect the condition themselves (inspect the response for a ToolUse block).

### Features

* adversarial security / secrets hardening ([#2107](https://github.com/jeong-sik/oas/issues/2107)) ([fa51717](https://github.com/jeong-sik/oas/commit/fa517179c52f5eb0b95d878b46ececb69e610242))
* **agent:** accept multimodal user input blocks ([#2088](https://github.com/jeong-sik/oas/issues/2088)) ([36df900](https://github.com/jeong-sik/oas/commit/36df9004ae7b0d5fa6ae61e15d9a1b08ec474a59))
* **agent:** add missing tool name aliases for deprecated names ([#18922](https://github.com/jeong-sik/oas/issues/18922)) ([#1943](https://github.com/jeong-sik/oas/issues/1943)) ([95ccbbc](https://github.com/jeong-sik/oas/commit/95ccbbc139ab40797eb1bc6b18350d3e3c75951b))
* **agent:** generic tool alias registry, remove masc hardcoding ([#1999](https://github.com/jeong-sik/oas/issues/1999)) ([c8283ac](https://github.com/jeong-sik/oas/commit/c8283ac8a30d6807d48b28780ef2a7821f2471bb))
* **agent:** idle/progress-aware execution timeout ([#1823](https://github.com/jeong-sik/oas/issues/1823)) ([886c4d1](https://github.com/jeong-sik/oas/commit/886c4d1c8b5d03cab030266008fa5b28cdd5d847))
* **capabilities:** register Qwen_3 family in static model route ladder ([#1787](https://github.com/jeong-sik/oas/issues/1787)) ([c7f97cc](https://github.com/jeong-sik/oas/commit/c7f97cc827cf5034918ec939d0e105641b5c6b7e))
* **capability_manifest:** carry thinking_control_format (RFC-OAS-023) ([1bf68e5](https://github.com/jeong-sik/oas/commit/1bf68e54e08735e470f2a780aaa4fef1e9eb063a))
* **capability_manifest:** carry thinking_control_format (RFC-OAS-023) ([9a5d6c4](https://github.com/jeong-sik/oas/commit/9a5d6c4aaa57f917ed1c4f676f0a0082c0bacd4b))
* **event_bus:** add turn index to ToolCalled/ToolCompleted for downstream FSM correlation ([#2108](https://github.com/jeong-sik/oas/issues/2108)) ([89e979d](https://github.com/jeong-sik/oas/commit/89e979ddcc2c873a178121015075cd7da2f5238b))
* **event_bus:** carry provider tool_use_id on ToolCalled/ToolCompleted ([#2025](https://github.com/jeong-sik/oas/issues/2025)) ([4c6ec4c](https://github.com/jeong-sik/oas/commit/4c6ec4cedde339ee62a51265debca54127cf0506))
* extract agent_sdk.protocol sublibrary and resolve circular dependencies ([#1896](https://github.com/jeong-sik/oas/issues/1896)) ([de16a44](https://github.com/jeong-sik/oas/commit/de16a4497dd76ad3493608c110174f579a20dce8))
* **gemini:** surface unsupported disable_parallel_tool_use (WP9 gap) ([#1840](https://github.com/jeong-sik/oas/issues/1840)) ([7ba14b4](https://github.com/jeong-sik/oas/commit/7ba14b44da70a2fb714a6ac10ae2f27ffd5b2601))
* **http_client:** diagnose oversized request headers that CDN proxies reject ([#1819](https://github.com/jeong-sik/oas/issues/1819)) ([03a07b8](https://github.com/jeong-sik/oas/commit/03a07b8d6485f2e121868d8e4e0f938e1bb8987c))
* **llm_provider:** add ?getenv DI seam to Cli_common_env (RFC-OAS-024 Phase 0) ([#2226](https://github.com/jeong-sik/oas/issues/2226)) ([a8f5677](https://github.com/jeong-sik/oas/commit/a8f5677376a9e4a3d5710c2b6340d36b3e1f0913))
* **llm_provider:** allow json_schema response format for Ollama Cloud ([#2160](https://github.com/jeong-sik/oas/issues/2160)) ([36cea94](https://github.com/jeong-sik/oas/commit/36cea94216ec066ea582b256e37efe4f833d7da4))
* **llm_provider:** externalize all hardcoded model specifications to TOML catalog ([b056d26](https://github.com/jeong-sik/oas/commit/b056d261c416e51240fa4a54068a49f4c1b93e33))
* **llm_provider:** externalize all hardcoded model specifications to TOML catalog ([1f5dc59](https://github.com/jeong-sik/oas/commit/1f5dc591eed11477e01b21b68f1521c7e335fd30))
* **llm_provider:** reusable HTTP connection cache ([#2114](https://github.com/jeong-sik/oas/issues/2114)) ([260a261](https://github.com/jeong-sik/oas/commit/260a2612c13268402b9061a9d24c5ad0cdd5613c))
* **multimodal:** close media source kinds ([#2269](https://github.com/jeong-sik/oas/issues/2269)) ([35f5a06](https://github.com/jeong-sik/oas/commit/35f5a06ac6330d030067bfa863230e32bb6d6525))
* **oas:** adversarial hardening — eio-concurrency-core ([#2106](https://github.com/jeong-sik/oas/issues/2106)) ([4543cc9](https://github.com/jeong-sik/oas/commit/4543cc9e0f6cfcc236da2c6f097d8738f8435ecb))
* **oas:** adversarial hardening — legacy-purge-safe ([#2105](https://github.com/jeong-sik/oas/issues/2105)) ([e22a669](https://github.com/jeong-sik/oas/commit/e22a6697208bffb6dde3b410237c1f6933af6ed7))
* **observability:** default-on event bus + per-turn InferenceTelemetry producer ([#2252](https://github.com/jeong-sik/oas/issues/2252)) ([3c5a845](https://github.com/jeong-sik/oas/commit/3c5a8459ed2accacbf86ccfaea5c47880ac4a1b2))
* **ollama:** add native think dialect ([#2258](https://github.com/jeong-sik/oas/issues/2258)) ([841973c](https://github.com/jeong-sik/oas/commit/841973c2391d5a386cde97e1d344923ddbfcd117))
* **parse:** support catalog-scoped visible reasoning text ([#2217](https://github.com/jeong-sik/oas/issues/2217)) ([9cdc539](https://github.com/jeong-sik/oas/commit/9cdc539849a6a7bce6896bcbe56a17e847449c28))
* **pipeline:** remove forced-tool-use enforcement (RFC-OAS-025 Option A, stage 1) ([#1864](https://github.com/jeong-sik/oas/issues/1864)) ([81f97b8](https://github.com/jeong-sik/oas/commit/81f97b8441b807b78572fa219d0c935ee87e0f15))
* **provider:** canonical tool projection wired into turn pipeline (WP8 Inc1, RFC-OAS-024) ([#1846](https://github.com/jeong-sik/oas/issues/1846)) ([a04e0b4](https://github.com/jeong-sik/oas/commit/a04e0b45e13195cab4f59f11d22e0c2dcf31fdde))
* **provider:** per-function strict mode on tool_schema (WP2) ([#1837](https://github.com/jeong-sik/oas/issues/1837)) ([61755b2](https://github.com/jeong-sik/oas/commit/61755b286d356ff3ffb11a031c0ed27cb5d5e8d3))
* **provider:** structured tool_result content blocks (WP4) ([#1839](https://github.com/jeong-sik/oas/issues/1839)) ([95f74ec](https://github.com/jeong-sik/oas/commit/95f74ece5c7ed9c06b7231f2e6e6d208d91e3248))
* **provider:** tool calling 현대화 기반 — backend rename + stop_reason (WP0/WP1) ([#1835](https://github.com/jeong-sik/oas/issues/1835)) ([a1d6b4d](https://github.com/jeong-sik/oas/commit/a1d6b4db64a6e2c7890e5fcb67b9040fd68ff503))
* **reasoning:** typed reasoning_replay_override + Kimi K2 replay ([#2227](https://github.com/jeong-sik/oas/issues/2227)) ([35d9990](https://github.com/jeong-sik/oas/commit/35d99906ba57cbd497c2c1173ea7d67b48c1d171))
* remove dead A2a error variant from sdk_error ([#1903](https://github.com/jeong-sik/oas/issues/1903)) ([7edc393](https://github.com/jeong-sik/oas/commit/7edc39375d6260943c972bd510be4b51af9c4cc3))
* remove dead completion-contract machinery (RFC-OAS-025 Option A Stage 2) ([#1867](https://github.com/jeong-sik/oas/issues/1867)) ([a7d57d2](https://github.com/jeong-sik/oas/commit/a7d57d2765e80bf70f64b8b8e10265a9df2395aa))
* **sessions:** add participant_by_name accessor to Sessions facade ([#2168](https://github.com/jeong-sik/oas/issues/2168)) ([c75324c](https://github.com/jeong-sik/oas/commit/c75324c5ada01aeb92399cb06b9cc3d4a26bd814))
* **stream:** assemble multimodal image/document/audio blocks in the accumulator (RFC-OAS-029) ([#2246](https://github.com/jeong-sik/oas/issues/2246)) ([10a53be](https://github.com/jeong-sik/oas/commit/10a53be855966e14096a916f07cdc4633ff87c9b))
* **streaming:** add Connected and Timeout constructors to sse_event ([#1947](https://github.com/jeong-sik/oas/issues/1947)) ([e66bdcb](https://github.com/jeong-sik/oas/commit/e66bdcb9d9e35c9e9ad0758c3bc5a198873e14cf))
* **streaming:** propagate Connected and Timeout events down the callback line and clean dune-project ([#1945](https://github.com/jeong-sik/oas/issues/1945)) ([3555e34](https://github.com/jeong-sik/oas/commit/3555e342d990d8b8063e41b1fafbb6fb1272e361))
* support DeepSeek runtime API key env ([#2007](https://github.com/jeong-sik/oas/issues/2007)) ([fde579c](https://github.com/jeong-sik/oas/commit/fde579cdfe8c1af8eb6392448c6c317b25f19145))
* **tracing:** MASC↔OAS trace boundary linking (Phase 1-3) ([#2003](https://github.com/jeong-sik/oas/issues/2003)) ([f6ac0d0](https://github.com/jeong-sik/oas/commit/f6ac0d0eabe07a3e65f280c5d2d2e047265ff972))
* **transport:** carry stream_idle_timeout_s on completion_request (RFC-OAS-026, F1 step 1) ([e29c62b](https://github.com/jeong-sik/oas/commit/e29c62b92ab0087ddbadf718d7b38836638fc3af))
* **transport:** carry stream_idle_timeout_s on completion_request (RFC-OAS-026) ([95ba8a7](https://github.com/jeong-sik/oas/commit/95ba8a71c8a45bc4f588d9884d210a7cb4814aeb))
* **types:** expose summarize_blocks and total_tokens canonical projections ([#2249](https://github.com/jeong-sik/oas/issues/2249)) ([0fac2eb](https://github.com/jeong-sik/oas/commit/0fac2eba1a46f1d93752eb29e7e35a4c80f499a5))
* **types:** expose visible answer text projection ([#2306](https://github.com/jeong-sik/oas/issues/2306)) ([3a692b9](https://github.com/jeong-sik/oas/commit/3a692b9988ad72738cf22eb69296cd7452cfbd7d))


### Bug Fixes

* add call-time default model resolver ([#2213](https://github.com/jeong-sik/oas/issues/2213)) ([46684fa](https://github.com/jeong-sik/oas/commit/46684fa381d9ce38ee4e44c202d6bd32a6f78b88))
* address review follow-ups from [#2017](https://github.com/jeong-sik/oas/issues/2017) ([#2122](https://github.com/jeong-sik/oas/issues/2122)) ([d54eed6](https://github.com/jeong-sik/oas/commit/d54eed6e7ba807ae58791fb73d206aa64576cd41))
* address review follow-ups from [#2023](https://github.com/jeong-sik/oas/issues/2023) ([#2125](https://github.com/jeong-sik/oas/issues/2125)) ([2271978](https://github.com/jeong-sik/oas/commit/22719783317b3130bc121cae56eb5626e48ce69b))
* address review follow-ups from [#2028](https://github.com/jeong-sik/oas/issues/2028) ([#2124](https://github.com/jeong-sik/oas/issues/2124)) ([d58dc7d](https://github.com/jeong-sik/oas/commit/d58dc7d84aa01ca3a6be2e1d0a9a201589931a74))
* address review follow-ups from [#2096](https://github.com/jeong-sik/oas/issues/2096) ([#2123](https://github.com/jeong-sik/oas/issues/2123)) ([072f83c](https://github.com/jeong-sik/oas/commit/072f83ccf10d54224560338024fffee1a916dc1b))
* address review follow-ups from [#2098](https://github.com/jeong-sik/oas/issues/2098) ([#2127](https://github.com/jeong-sik/oas/issues/2127)) ([59170f9](https://github.com/jeong-sik/oas/commit/59170f942db9fb636b9aaa7f0dbcb4e18cc96529))
* **agent_registry:** protect hashtbl with mutex ([ac18990](https://github.com/jeong-sik/oas/commit/ac189904e0529a27f2e37af12558f833f1a517b1))
* **agent_tools:** preserve optional absence in correction ([#1789](https://github.com/jeong-sik/oas/issues/1789)) ([64773ea](https://github.com/jeong-sik/oas/commit/64773eabbed612dbf04a27d9a9b4b1e2d4061d69))
* **agent-tools:** purge retired native tool ids ([#1796](https://github.com/jeong-sik/oas/issues/1796)) ([d40180d](https://github.com/jeong-sik/oas/commit/d40180d963aefed06b72faac2a1a7e097591023e))
* **agent,responses:** address open Codex P2 findings (incomplete-before-tooluse + lifecycle ordering) ([#2073](https://github.com/jeong-sik/oas/issues/2073)) ([6563c4a](https://github.com/jeong-sik/oas/commit/6563c4ae6151c07b845d12033b5aa290c28b6fda))
* **agent:** complete reserved-exception filter and log illegal hook decision coercion ([#2057](https://github.com/jeong-sik/oas/issues/2057)) ([55547d3](https://github.com/jeong-sik/oas/commit/55547d36ae41fd457674a4d10926b9cd7d1ffce5))
* **agent:** export tool alias registry ([#2046](https://github.com/jeong-sik/oas/issues/2046)) ([4359533](https://github.com/jeong-sik/oas/commit/435953390ef27c82d7890445dc7952e25035dab9))
* **agent:** harden tool and reasoning loop handling ([#2048](https://github.com/jeong-sik/oas/issues/2048)) ([561f8b9](https://github.com/jeong-sik/oas/commit/561f8b95a2b6b8bc1621d78d2e174e816e87b5d9))
* **agent:** publish content replacement events by default ([#1767](https://github.com/jeong-sik/oas/issues/1767)) ([c23e8ba](https://github.com/jeong-sik/oas/commit/c23e8ba0efdd2fa9d7759d9cf263100d97386250))
* **agent:** remove built-in consumer tool aliases ([#2271](https://github.com/jeong-sik/oas/issues/2271)) ([8a69156](https://github.com/jeong-sik/oas/commit/8a6915612d1f91049c4ae3960139448986df12a6))
* **agent:** serialize tool-name alias registry ([#2053](https://github.com/jeong-sik/oas/issues/2053)) ([9702758](https://github.com/jeong-sik/oas/commit/97027583e4940aa6b2f61b1d9bab5c50750603e8))
* **agent:** serialize turn-budget history and idle-turn reads ([#2052](https://github.com/jeong-sik/oas/issues/2052)) ([dedc901](https://github.com/jeong-sik/oas/commit/dedc9015aa2e5204bbb6773ba77beb52b74808e7))
* **agent:** surface Agent.run execution timeouts ([#1792](https://github.com/jeong-sik/oas/issues/1792)) ([37a096d](https://github.com/jeong-sik/oas/commit/37a096de62354e4e5857434966b8e7420595ecf5))
* **anthropic:** gate adaptive effort on thinking being enabled (Codex P2 on [#2082](https://github.com/jeong-sik/oas/issues/2082)) ([#2087](https://github.com/jeong-sik/oas/issues/2087)) ([2737c0a](https://github.com/jeong-sik/oas/commit/2737c0adf857fd695b6f6dffd9f0873301252c57))
* **api:** centralize default inference telemetry ([#2180](https://github.com/jeong-sik/oas/issues/2180)) ([06f8a45](https://github.com/jeong-sik/oas/commit/06f8a45098f2feb942e93ae99a34c81ffce8430f))
* **api:** keep default_config as a value (non-breaking) — semver repair ([#2194](https://github.com/jeong-sik/oas/issues/2194)/[#2204](https://github.com/jeong-sik/oas/issues/2204)) ([#2207](https://github.com/jeong-sik/oas/issues/2207)) ([57eb200](https://github.com/jeong-sik/oas/commit/57eb200f33444db3016d669eb2e7bb02ea8d1a25))
* **async_agent:** eliminate cancel race and orphan fiber ([#2130](https://github.com/jeong-sik/oas/issues/2130)) ([dedc13a](https://github.com/jeong-sik/oas/commit/dedc13a975dcbe99502d0e7aaf933d9b5fb85960))
* **async_agent:** make cancel_fn atomic to avoid race and stale switch closure ([88435f8](https://github.com/jeong-sik/oas/commit/88435f8bba1ecc30ed9d011d783d629fefc86f3b))
* **backend_glm:** preserve Yojson parse error message for retry classification ([#2121](https://github.com/jeong-sik/oas/issues/2121)) ([7091d3d](https://github.com/jeong-sik/oas/commit/7091d3d57bbe1ea5f683bf18d71df83cfef3317a))
* **backend_glm:** restore GLM thinking overlay + dedup (un-break regression) ([d162563](https://github.com/jeong-sik/oas/commit/d1625639e87ad972e65139f5ccfc0e6add0377f6))
* **backend_glm:** use glm-5.1 instead of provider_k-5.1 in tests ([e44a452](https://github.com/jeong-sik/oas/commit/e44a4527fe1b57ce8313fe8accb26168f3d47d06))
* **build:** add missing open Request_priority + feat(otel): read OTEL_EXPORTER_OTLP_ENDPOINT from env ([#1941](https://github.com/jeong-sik/oas/issues/1941)) ([3dc60fe](https://github.com/jeong-sik/oas/commit/3dc60fe8089a2237448eb8097590bddfc41b9519))
* **builder:** log auto dump save failures ([#2197](https://github.com/jeong-sik/oas/issues/2197)) ([ed1deac](https://github.com/jeong-sik/oas/commit/ed1deac2ab9af03730af233f6d0d2eb4d3f119f0))
* **build:** unify mcp_protocol dependency names ([#2167](https://github.com/jeong-sik/oas/issues/2167)) ([f4d4b69](https://github.com/jeong-sik/oas/commit/f4d4b696f535f62416c58b44fdb732006de134e9))
* **capabilities:** change deepseek-v4 thinking control format to reasoning_effort ([e1efeee](https://github.com/jeong-sik/oas/commit/e1efeee6dfd0572a25ce2b6828f808ec22383c3b))
* **capabilities:** change deepseek-v4 thinking control format to reasoning_effort to resolve 500 error on ollama_cloud ([4e2f440](https://github.com/jeong-sik/oas/commit/4e2f440ab20ed0ca8138b47682b28cf9d454e2fd))
* **capabilities:** correct Qwen3 family specs to match official documentation ([cdc274c](https://github.com/jeong-sik/oas/commit/cdc274cb3c815e966fdbacc8cb5612033f80ef7f))
* **capabilities:** correct Qwen3 family specs to match official documentation ([a4bfdd2](https://github.com/jeong-sik/oas/commit/a4bfdd2c290b11dad43b08e321ff760af7589c56))
* **capabilities:** de-anonymize DeepSeek route + fix live model-id mismatch ([0a90990](https://github.com/jeong-sik/oas/commit/0a90990c543cf58558543725a8a4ef18ee94d01a))
* **capabilities:** Kimi rejects named forced tool_choice (auto-only API) ([#2298](https://github.com/jeong-sik/oas/issues/2298)) ([2871202](https://github.com/jeong-sik/oas/commit/2871202ad6a6c5663eb308ba77df2d08e4029a75))
* **capabilities:** restrict gemini minimal thinking level to flash-lite ([#2224](https://github.com/jeong-sik/oas/issues/2224)) ([4bd292c](https://github.com/jeong-sik/oas/commit/4bd292c0b4a0480a4811e70df267cad774f9511e))
* **capabilities:** RFC-OAS-023 de-anon increment 1 — DeepSeek route + live model-id fix ([2591770](https://github.com/jeong-sik/oas/commit/25917708fd5617a6851aa48f8d38f1f258f6ca28))
* **catalog:** DeepSeek V4 rejects named forced tool_choice (thinking-mode 400) ([#2299](https://github.com/jeong-sik/oas/issues/2299)) ([a8a668f](https://github.com/jeong-sik/oas/commit/a8a668fd1dc21a765a8987797913d746c46cdbfd))
* **catalog:** drop consumer-specific ~/.masc search path (SDK boundary) ([52f7b41](https://github.com/jeong-sik/oas/commit/52f7b41c3ef4bb7ef51803eba691c3f00eb64d75))
* **catalog:** drop consumer-specific ~/.masc search path (SDK boundary) ([19bc660](https://github.com/jeong-sik/oas/commit/19bc6608ab241366cb0564cc8283dcc0d63c1401))
* **catalog:** fail closed on policy string drift ([#2293](https://github.com/jeong-sik/oas/issues/2293)) ([e7a5e51](https://github.com/jeong-sik/oas/commit/e7a5e511dd9abf32005fe8540ce8ffb8cf3b7fe9))
* **ci:** align provider throttle timeout test ([f108350](https://github.com/jeong-sik/oas/commit/f1083506dc90986237067f9c497d347540aed18e))
* **ci:** align provider throttle timeout test ([16073fc](https://github.com/jeong-sik/oas/commit/16073fc6faae779378b6dc345a18b8a83c6d4126))
* **ci:** restore oas build formatting ([7341e7f](https://github.com/jeong-sik/oas/commit/7341e7ff6e495da552bf40a6b5ab93e456a05dc0))
* **ci:** restore oas main green after merge wave ([#2257](https://github.com/jeong-sik/oas/issues/2257)) ([0eb3971](https://github.com/jeong-sik/oas/commit/0eb3971122bf83488ef2db8b35224a37d8d6eee4))
* **ci:** scope legacy-stage lint to OCaml sources ([#2260](https://github.com/jeong-sik/oas/issues/2260)) ([55fe715](https://github.com/jeong-sik/oas/commit/55fe7154bbf4b3bc52eeebce2b24f17fc5b0671c))
* **complete:** measure latency with monotonic counters ([#2181](https://github.com/jeong-sik/oas/issues/2181)) ([9ab0301](https://github.com/jeong-sik/oas/commit/9ab030140a09791a7402cfb9209cc212889c0d7a))
* **complete:** measure sync latency with eio clock ([#2201](https://github.com/jeong-sik/oas/issues/2201)) ([bcb1ea5](https://github.com/jeong-sik/oas/commit/bcb1ea54d26f48f3a4142e0d0f9dac9d3bdd01e3))
* **config:** reject malformed agent list fields ([#2198](https://github.com/jeong-sik/oas/issues/2198)) ([e1c6b13](https://github.com/jeong-sik/oas/commit/e1c6b13247af69354bc3ab77a274ab52804c2aec))
* **constants:** resolve env defaults at call time ([#2185](https://github.com/jeong-sik/oas/issues/2185)) ([cc18b1b](https://github.com/jeong-sik/oas/commit/cc18b1bb8f15005d1bec1cacbe1429167bb7baec))
* **content_replacement_state:** protect hashtbl pair with mutex ([ddabc61](https://github.com/jeong-sik/oas/commit/ddabc61501fb1fb08c7b900be01b9d8e27e42477))
* **context:** make offload failures observable ([#2194](https://github.com/jeong-sik/oas/issues/2194)) ([6195c74](https://github.com/jeong-sik/oas/commit/6195c74298be812a5d68979b49a4d5b324820ce3))
* **defaults:** resolve fallback provider at call time ([#2189](https://github.com/jeong-sik/oas/issues/2189)) ([f6986af](https://github.com/jeong-sik/oas/commit/f6986af7a1eaf896702dc01f93ef0a7d23c361ef))
* **diag:** resolve debug env gates at call time ([#2191](https://github.com/jeong-sik/oas/issues/2191)) ([0c097a9](https://github.com/jeong-sik/oas/commit/0c097a91b4b719020044c38b87e9002d435b7cf6))
* **discovery:** correct de-anon leftover in contains_case_insensitive tests ([1186634](https://github.com/jeong-sik/oas/commit/1186634c0680b265dad00d1812c5155d483de35e))
* **discovery:** correct de-anon leftover in contains_case_insensitive tests ([f4e0ad2](https://github.com/jeong-sik/oas/commit/f4e0ad23ff32faebe8c5e46fc33ea8f64a910e32))
* **discovery:** warn on invalid port env tokens ([#2199](https://github.com/jeong-sik/oas/issues/2199)) ([1134964](https://github.com/jeong-sik/oas/commit/1134964c5ba864443972e6c2a5129ef67f712a1e))
* **durable_event:** correct FNV-1a operator precedence ([#2129](https://github.com/jeong-sik/oas/issues/2129)) ([545c23a](https://github.com/jeong-sik/oas/commit/545c23af938c2cf038705a2fb3236d9657645e14))
* **durable_event:** make journal append lock-free with Atomic.t pair ([45cfffd](https://github.com/jeong-sik/oas/commit/45cfffde8a7f16f37375997c358ac3a6d010ecca))
* **durable_event:** propagate reserved append callback exceptions ([#2071](https://github.com/jeong-sik/oas/issues/2071)) ([66982d2](https://github.com/jeong-sik/oas/commit/66982d22df858b0f61fd1ecb52842bd6b4776cde))
* **eval_collector:** make counter updates fiber-safe with atomics ([#2135](https://github.com/jeong-sik/oas/issues/2135)) ([dd3d647](https://github.com/jeong-sik/oas/commit/dd3d6470aea56f35e1254fd7becbb1fef627bd7d))
* **eval_collector:** unsubscribe before final drain ([#2148](https://github.com/jeong-sik/oas/issues/2148)) ([1cefcf3](https://github.com/jeong-sik/oas/commit/1cefcf31c0fff9a1b44930d61034dc0ed824272e))
* **event_bus:** remove subscriber_count race and prevent blocking on cancelled subscriptions ([#2136](https://github.com/jeong-sik/oas/issues/2136)) ([9374370](https://github.com/jeong-sik/oas/commit/9374370c0c6fcd3d4f87f02f54562d5bd8114071))
* **fs:** surface mkdir path failures ([#2196](https://github.com/jeong-sik/oas/issues/2196)) ([6453cd7](https://github.com/jeong-sik/oas/commit/6453cd72de2c6aa5d135a4f7de960d7e11fc32b4))
* **gemini:** serialize parallel-disable warning dedup table ([#2054](https://github.com/jeong-sik/oas/issues/2054)) ([0811ded](https://github.com/jeong-sik/oas/commit/0811ded725f8ab35a8feb67379bcb2b8795a4ec6))
* **glm:** gate native reasoning_content replay on Preserved Thinking ([#2238](https://github.com/jeong-sik/oas/issues/2238)) ([5997ddc](https://github.com/jeong-sik/oas/commit/5997ddcd804ac3bedb1f63cca75f32c731fadb65))
* **glm:** honor preserve thinking in ZAI requests ([#2023](https://github.com/jeong-sik/oas/issues/2023)) ([50d7726](https://github.com/jeong-sik/oas/commit/50d77261fd516a6471a2c8fdbd07748fcc9732bf))
* **glm:** reject forced tool_choice at typed boundary ([#2254](https://github.com/jeong-sik/oas/issues/2254)) ([b7f4947](https://github.com/jeong-sik/oas/commit/b7f4947cc6e6f89423059e311a2e732a373f51d6))
* **guardrail_tripwire:** avoid data race on shared violation ref ([#2133](https://github.com/jeong-sik/oas/issues/2133)) ([6dbe29f](https://github.com/jeong-sik/oas/commit/6dbe29ffe2bd58abb427de4a874febbf03fbface))
* **http_client:** propagate Eio.Cancel.Cancelled from drain_response_body ([#1871](https://github.com/jeong-sik/oas/issues/1871)) ([a141153](https://github.com/jeong-sik/oas/commit/a1411535ac6fc7db3d5a01840bbd60a2e3662b4a))
* **http_client:** replace pre-send header-size guard with 4xx response profiler ([#1820](https://github.com/jeong-sik/oas/issues/1820)) ([e44dee8](https://github.com/jeong-sik/oas/commit/e44dee8b91f3797436f3b7c4993a7b5497406ec6))
* **http_client:** spec-grammar SSE field parsing + fail-loud idle-without-clock ([ee945b4](https://github.com/jeong-sik/oas/commit/ee945b41cf3ef233b285f621a4bf8cc2ebb79a8f))
* **http_client:** spec-grammar SSE field parsing + fail-loud idle-without-clock ([06e32c8](https://github.com/jeong-sik/oas/commit/06e32c84714cee223abd129a66a0d444d8e901b6))
* **http:** classify Eio transport errors by type ([#2184](https://github.com/jeong-sik/oas/issues/2184)) ([25e0bcc](https://github.com/jeong-sik/oas/commit/25e0bcc911003bbd6ba26effe58d152689f96e8f))
* **http:** harden client error lifecycle ([#2176](https://github.com/jeong-sik/oas/issues/2176)) ([e818e66](https://github.com/jeong-sik/oas/commit/e818e66c196f6c66727f754025697578cd4cc2e7))
* implement complete_stream_with_retry to handle deepseek 500 errors ([e9f00f3](https://github.com/jeong-sik/oas/commit/e9f00f3be9760c0fc9b813c7510493a5dd0c2ac6))
* keep alias docs SDK-independent ([#2012](https://github.com/jeong-sik/oas/issues/2012)) ([05548e5](https://github.com/jeong-sik/oas/commit/05548e500c7157f170a844a9771279d30d89cbea))
* **llm_provider:** align Ollama streaming zero usage with non-streaming path ([#1848](https://github.com/jeong-sik/oas/issues/1848)) ([392902c](https://github.com/jeong-sik/oas/commit/392902c145cca0d8a481dccf0d05cd8e8c80e068))
* **llm_provider:** close [#2236](https://github.com/jeong-sik/oas/issues/2236) CoT re-injection loop, provider-agnostic ([#2304](https://github.com/jeong-sik/oas/issues/2304)) ([5eba83f](https://github.com/jeong-sik/oas/commit/5eba83f74b17956d96f8d993bee351100fff5c27))
* **llm_provider:** finish service-name migration, restore main green ([#1813](https://github.com/jeong-sik/oas/issues/1813)) ([b309bc1](https://github.com/jeong-sik/oas/commit/b309bc199f8a6f821dde5dca9379c0b8c22b86c6)), closes [#1811](https://github.com/jeong-sik/oas/issues/1811)
* **llm_provider:** Kimi backend mapping + capability rename to service names ([#1812](https://github.com/jeong-sik/oas/issues/1812)) ([27151c1](https://github.com/jeong-sik/oas/commit/27151c1c082467fb51cd7d1d77e192b0d4a87d03))
* **llm_provider:** make HTTP client tracked-transports list atomic ([#2060](https://github.com/jeong-sik/oas/issues/2060)) ([f2c89e8](https://github.com/jeong-sik/oas/commit/f2c89e84e513f1d857ca7684a672fcae8379d901))
* **llm_provider:** preserve timeout phase across retry path ([#2096](https://github.com/jeong-sik/oas/issues/2096)) ([82bcf18](https://github.com/jeong-sik/oas/commit/82bcf186d6e8d20864a374aeee2129e63fc44ca3))
* **llm_provider:** preserve typed provider errors across SSE stream finalize ([b4fe665](https://github.com/jeong-sik/oas/commit/b4fe66520f81d85c427a4fdc0d20d7880826e368))
* **llm_provider:** preserve typed provider errors across SSE stream finalize ([4d4e127](https://github.com/jeong-sik/oas/commit/4d4e12713c8c3f377f21d1882c9b0921324d7e94))
* **llm_provider:** reject unsatisfiable thinking-control instead of silent drop ([#2156](https://github.com/jeong-sik/oas/issues/2156)) ([8a30a9a](https://github.com/jeong-sik/oas/commit/8a30a9a25b536216352f2ef5e858da52bdcb5e65))
* **llm_provider:** separate timeout phase from catch scope, add Ollama prefill bounds ([#2093](https://github.com/jeong-sik/oas/issues/2093)) ([bef6395](https://github.com/jeong-sik/oas/commit/bef6395c26d441d31469b624a355a8e07788cd6f))
* **llm_provider:** StopToolUse requires a tool block — stop_reason SSOT (infinite Thinking P0) ([#2222](https://github.com/jeong-sik/oas/issues/2222)) ([d73191c](https://github.com/jeong-sik/oas/commit/d73191cf0f456a9719b0cba5e1b9b209195174bf))
* **llm_provider:** validate UTF-8 via Stdlib decoder, not byte-length ([#2301](https://github.com/jeong-sik/oas/issues/2301)) ([8e353b9](https://github.com/jeong-sik/oas/commit/8e353b97b64b423a26ef4a6ae68e9d3b1f570b4f))
* **mcp:** resolve http transport env at call time ([#2193](https://github.com/jeong-sik/oas/issues/2193)) ([ebed7ca](https://github.com/jeong-sik/oas/commit/ebed7ca35371425593d6a91ac5857165a753e008))
* **metrics:** preserve non-Eio aggregating snapshots ([#2072](https://github.com/jeong-sik/oas/issues/2072)) ([91c264a](https://github.com/jeong-sik/oas/commit/91c264ab6c97b8bd3c288e5390c109d42d4099fa))
* **metrics:** use Eio.Mutex in Aggregating to avoid scheduler yield issue ([2212235](https://github.com/jeong-sik/oas/commit/2212235ccc5dd129abc6bd793662fb09094040bf))
* **models:** register minimax-m3 capability entry (librarian thinking control) ([#2155](https://github.com/jeong-sik/oas/issues/2155)) ([7897d49](https://github.com/jeong-sik/oas/commit/7897d4998a101387412ba32beaf896b2a1863552))
* **multimodal:** close media source kinds ([#2283](https://github.com/jeong-sik/oas/issues/2283)) ([3860340](https://github.com/jeong-sik/oas/commit/38603406a8b679b8823ebbd57e188eef6b33fc5b))
* **oas:** concurrency safety, http client diagnostics, and pipeline SSOT ([#2174](https://github.com/jeong-sik/oas/issues/2174)) ([54507b2](https://github.com/jeong-sik/oas/commit/54507b26c920486588e8e36a7aa28ac125d75c9b))
* **oas:** correct tool retry policy classification + add LLM format recovery ([#1936](https://github.com/jeong-sik/oas/issues/1936)) ([22b268c](https://github.com/jeong-sik/oas/commit/22b268c68c1c793c26af62036244c521622b3b15))
* **oas:** remove streaming body timeout cap ([#1930](https://github.com/jeong-sik/oas/issues/1930)) ([3252c4f](https://github.com/jeong-sik/oas/commit/3252c4fe538b82c9de93e92d3491cf0f042b8e78))
* **oas:** repair main CI — ocamlformat + SDK independence ([#2111](https://github.com/jeong-sik/oas/issues/2111)) ([db7d3fb](https://github.com/jeong-sik/oas/commit/db7d3fbd77a6679b5439ba55e9ad446eaa96d327))
* **oas:** reset idle counter on non-tool-use turns and idle Skip ([#2190](https://github.com/jeong-sik/oas/issues/2190)) ([1998e7c](https://github.com/jeong-sik/oas/commit/1998e7cb02f1fdd1eac5fc031595ddddfa1ef007))
* ocamlformat drift and Dynamic selector API fallout on main ([#2119](https://github.com/jeong-sik/oas/issues/2119)) ([acf65e2](https://github.com/jeong-sik/oas/commit/acf65e2daeac0e4d719bfb896a62edb5c02ddaf0))
* **ollama:** native /api/chat multimodal serialization ([fdc35cc](https://github.com/jeong-sik/oas/commit/fdc35cccd2057d204f798293a928836a37589ddb))
* **openai:** model deepseek thinking control ([#2042](https://github.com/jeong-sik/oas/issues/2042)) ([2c41562](https://github.com/jeong-sik/oas/commit/2c415620475f2436b69141f709499e4e6c23e060))
* **openai:** omit disabled reasoning effort ([#2039](https://github.com/jeong-sik/oas/issues/2039)) ([b6159dc](https://github.com/jeong-sik/oas/commit/b6159dc3cf6a86b3fb408afa2b43b36832f05ae3))
* **otel_export:** propagate Eio.Cancel.Cancelled instead of retrying ([#2134](https://github.com/jeong-sik/oas/issues/2134)) ([e0fc325](https://github.com/jeong-sik/oas/commit/e0fc3254e7b044fa3c4916afcfaf95cbdf2beec3))
* **otel_tracer:** make global tracer fiber-safe and lazy ([#2141](https://github.com/jeong-sik/oas/issues/2141)) ([5d2cfb6](https://github.com/jeong-sik/oas/commit/5d2cfb61ec151a228fe5aa06fa8ba0b259c62028))
* **otel:** avoid module-load env capture ([#2200](https://github.com/jeong-sik/oas/issues/2200)) ([305e1a3](https://github.com/jeong-sik/oas/commit/305e1a34409120ae601ca0767a30661c5ea01dd6))
* **otel:** export native metrics ([28c8809](https://github.com/jeong-sik/oas/commit/28c88090c1f2064a378288656e8a8dec8aa05379))
* **otel:** export native metrics ([332c4cf](https://github.com/jeong-sik/oas/commit/332c4cf4f2f8864d31f055bedc8ccc4959764c70))
* **pipeline:** deliver idle nudge inside the tool-results message ([#2028](https://github.com/jeong-sik/oas/issues/2028)) ([071fd52](https://github.com/jeong-sik/oas/commit/071fd52d841285f6ce4c52f86761231880f2d52f))
* **pipeline:** keep tool results on tool role before nudges ([#2030](https://github.com/jeong-sik/oas/issues/2030)) ([3e56fcd](https://github.com/jeong-sik/oas/commit/3e56fcdb10b38f1451a7891ac73d72e516982fca))
* **pipeline:** make compaction watermark config-owned ([#2177](https://github.com/jeong-sik/oas/issues/2177)) ([0a018b7](https://github.com/jeong-sik/oas/commit/0a018b7210038d0c9c274d7d4f0658b6e672cced))
* **pipeline:** make hook decisions exhaustive ([#2179](https://github.com/jeong-sik/oas/issues/2179)) ([bd34a5e](https://github.com/jeong-sik/oas/commit/bd34a5eb3a665ae6be514d0aaf7af553edd070fc))
* **pipeline:** propagate Eio.Cancel.Cancelled from safe_publish ([#1881](https://github.com/jeong-sik/oas/issues/1881)) ([adc8312](https://github.com/jeong-sik/oas/commit/adc8312bc03e8fb76023df84d3558d3eb9d36fca))
* **pipeline:** purge ToolRetryExhausted — a tool failure is never turn-fatal ([3a5fea2](https://github.com/jeong-sik/oas/commit/3a5fea20f97c6db92d32ceaae4325e6ee98eeb6d))
* **pipeline:** purge ToolRetryExhausted — a tool failure is never turn-fatal ([f5d3345](https://github.com/jeong-sik/oas/commit/f5d3345e23c86fbf870cc9ee2aa53fedebb93370))
* **protocol:** include _meta in tool_result records for mcp_protocol 0.16 ([#2169](https://github.com/jeong-sik/oas/issues/2169)) ([0f44338](https://github.com/jeong-sik/oas/commit/0f44338adcb52d23be9a196115ab02fbe0a8ec18))
* **provider_intf:** propagate Provider.resolve errors from of_config ([#2139](https://github.com/jeong-sik/oas/issues/2139)) ([ea4e3bb](https://github.com/jeong-sik/oas/commit/ea4e3bb52411b26bd4abec0570453702d325be5d))
* **provider_registry:** protect entries hashtbl with mutex ([f3defdf](https://github.com/jeong-sik/oas/commit/f3defdf4809e976b31dce88fdd6619ed30f22110))
* **provider-catalog:** carry reasoning replay override ([#2290](https://github.com/jeong-sik/oas/issues/2290)) ([18611c0](https://github.com/jeong-sik/oas/commit/18611c0066c3f8a8d4d3639535f6022a756bc99b))
* **provider-catalog:** fail closed on enum field type drift ([#2292](https://github.com/jeong-sik/oas/issues/2292)) ([e2d634d](https://github.com/jeong-sik/oas/commit/e2d634d5b9ba4b273b947036d8f3f8b76e032961))
* **provider:** close tool message pairs before requests ([#2038](https://github.com/jeong-sik/oas/issues/2038)) ([b4478e0](https://github.com/jeong-sik/oas/commit/b4478e0cfa18501c1f4c8020889b7e07324ed077))
* **provider:** configurable connect/headers timeout override ([#2163](https://github.com/jeong-sik/oas/issues/2163)) ([#2186](https://github.com/jeong-sik/oas/issues/2186)) ([37f2084](https://github.com/jeong-sik/oas/commit/37f20842b0718f0fb2bb5e48f597d5319362a965))
* **provider:** derive auth headers without dummy config ([#2178](https://github.com/jeong-sik/oas/issues/2178)) ([48afaec](https://github.com/jeong-sik/oas/commit/48afaec325ab528c50be135e03933de4e4b20794))
* **provider:** honor parallel tool capability ([#2005](https://github.com/jeong-sik/oas/issues/2005)) ([86527d4](https://github.com/jeong-sik/oas/commit/86527d483e7f7f6a389af2b740d6e6f2172aba7b))
* **provider:** isolate assistant tool content capability ([#2244](https://github.com/jeong-sik/oas/issues/2244)) ([6aa5549](https://github.com/jeong-sik/oas/commit/6aa554971b0b33bbbdb74a55f276bb66fd75abab))
* **provider:** per-model tool-calling wire correctness (DeepSeek/Qwen/GLM) ([6596ded](https://github.com/jeong-sik/oas/commit/6596ded30a693f164faedb410cd42553951c9b2c))
* **provider:** remove api_key from Provider_config.t.headers ([#1817](https://github.com/jeong-sik/oas/issues/1817)) ([31b750c](https://github.com/jeong-sik/oas/commit/31b750ceec8993b06b740273e4609b68238fa474))
* **provider:** RFC-OAS-023 per-model wire correctness (DeepSeek [#20198](https://github.com/jeong-sik/oas/issues/20198) / Qwen3 thinking / GLM tool_stream) ([f665020](https://github.com/jeong-sik/oas/commit/f665020bdba682054fbeea7e3588df5a1590ad1d))
* **provider:** round-trip reasoning_content for DeepSeek models ([9ef2e19](https://github.com/jeong-sik/oas/commit/9ef2e19d44e8b4348d08e40581e6ce3e6b1e7c29))
* **provider:** round-trip reasoning_content for DeepSeek models ([1ce9ea6](https://github.com/jeong-sik/oas/commit/1ce9ea625cf549c0ad4efb62148f3305ed2b6f15))
* **provider:** type reasoning effort policy ([#2188](https://github.com/jeong-sik/oas/issues/2188)) ([1f7b2b4](https://github.com/jeong-sik/oas/commit/1f7b2b41801d3c7415674a18e058942e35aed525))
* **provider:** use provider-qualified model capabilities ([#2248](https://github.com/jeong-sik/oas/issues/2248)) ([01276bb](https://github.com/jeong-sik/oas/commit/01276bbe26c819d396965596135c0d6c9584eff1))
* **provider:** wire per-kind connect timeout in complete_sync post_sync ([#2099](https://github.com/jeong-sik/oas/issues/2099)) ([8b2ef22](https://github.com/jeong-sik/oas/commit/8b2ef22c503e04b062f645bb65482e37e047b4d4))
* **qwen:** preserve thinking controls ([#2014](https://github.com/jeong-sik/oas/issues/2014)) ([34f1588](https://github.com/jeong-sik/oas/commit/34f1588290a2e19cebff5d9a41e17727d9557d62))
* **reasoning_dialect:** align DashScope dialect + apply sampling drop on public path ([#2078](https://github.com/jeong-sik/oas/issues/2078) Codex P2) ([#2081](https://github.com/jeong-sik/oas/issues/2081)) ([3093300](https://github.com/jeong-sik/oas/commit/30933008e4c6bee3e9ed0870d839cefb507bf48c))
* **reasoning:** centralize budget effort thresholds ([#2297](https://github.com/jeong-sik/oas/issues/2297)) ([2139b10](https://github.com/jeong-sik/oas/commit/2139b101a8024897a183c13c15a34ff2f903a0c2))
* **reasoning:** preserve opaque thinking carriers for tool loops ([#2061](https://github.com/jeong-sik/oas/issues/2061)) ([d1d4e6e](https://github.com/jeong-sik/oas/commit/d1d4e6ebf482a723cfe9457312cbab8c2152d31c))
* reject removed provider catalog aliases ([#1822](https://github.com/jeong-sik/oas/issues/1822)) ([e725e2c](https://github.com/jeong-sik/oas/commit/e725e2ceaae87ab51d39c71287b65fd26b0b4ebb))
* remove masc reference from comment to pass SDK independence check ([#1805](https://github.com/jeong-sik/oas/issues/1805)) ([5f76987](https://github.com/jeong-sik/oas/commit/5f76987d25a24b18370f81efc4fdc79208a7e546)), closes [#1791](https://github.com/jeong-sik/oas/issues/1791)
* resolve discovery endpoints at call time ([#2214](https://github.com/jeong-sik/oas/issues/2214)) ([0364f27](https://github.com/jeong-sik/oas/commit/0364f2746d94f636e84d308741321eba441a3737))
* resolve SDK independence failure and apply code formatting ([4aebd4e](https://github.com/jeong-sik/oas/commit/4aebd4e1b441eef59838083c22c7e1e2d844a9e5))
* **responses:** drop partial tool blocks for all incomplete reasons, not just MaxTokens ([#2077](https://github.com/jeong-sik/oas/issues/2077)) ([d6f6ece](https://github.com/jeong-sik/oas/commit/d6f6ece4f1432f0cf4d36e4a0e3cc642de81cc40))
* **responses:** incomplete status wins over tool-use in streaming path ([#2073](https://github.com/jeong-sik/oas/issues/2073) follow-up) ([#2076](https://github.com/jeong-sik/oas/issues/2076)) ([e2a78f7](https://github.com/jeong-sik/oas/commit/e2a78f75e8dfc585078a88a2817bfffc9dad44f9))
* restore green main — SDK-independence ([#2080](https://github.com/jeong-sik/oas/issues/2080) doc+mli) + ocamlformat ([#2082](https://github.com/jeong-sik/oas/issues/2082) drift) ([#2084](https://github.com/jeong-sik/oas/issues/2084)) ([c10704e](https://github.com/jeong-sik/oas/commit/c10704e2f8ce271696eb0230da5bd283df63d477))
* restore green main (ocamlformat drift + SDK independence) ([#1852](https://github.com/jeong-sik/oas/issues/1852)) ([5a7ea9e](https://github.com/jeong-sik/oas/commit/5a7ea9e4d4e8dd9a1839143aad58a6a6d204c672))
* **runtime:** centralize provider identity resolution ([#1831](https://github.com/jeong-sik/oas/issues/1831)) ([c05e3bd](https://github.com/jeong-sik/oas/commit/c05e3bdaff51e5487054786cab5d3c358edafee5))
* **sessions_store:** return Error on malformed tool catalog instead of raising ([#1885](https://github.com/jeong-sik/oas/issues/1885)) ([cc30dea](https://github.com/jeong-sik/oas/commit/cc30deab29c7a1e65d20d6714649ec88b4bbbc34))
* **stream:** fail closed for unknown block kinds ([#2243](https://github.com/jeong-sik/oas/issues/2243)) ([b6149ac](https://github.com/jeong-sik/oas/commit/b6149ac63bc201c5385a4a47e95223f5036a9478))
* **streaming:** add auth header and usage options to OpenAI-compatible stream ([#2131](https://github.com/jeong-sik/oas/issues/2131)) ([04254a9](https://github.com/jeong-sik/oas/commit/04254a98ac0c05767ce0e4be2d99dfaae0b76602))
* **streaming:** bound thinking-only streams ([#2011](https://github.com/jeong-sik/oas/issues/2011)) ([0302112](https://github.com/jeong-sik/oas/commit/0302112fb763fe4688e5dc1cd385ab2392c5dbb0))
* **streaming:** correct inline test for fail-closed tool arguments ([#2265](https://github.com/jeong-sik/oas/issues/2265)) ([c741324](https://github.com/jeong-sik/oas/commit/c74132468414bf0663b32722be74c9c4acd7f8c1))
* **streaming:** default stream idle timeout to 60s and support clock ([0df3219](https://github.com/jeong-sik/oas/commit/0df32193d7c2d9499cbe9282d6c3d4d64b8595af))
* **streaming:** default stream idle timeout to 60s and support clock parameter ([e505e59](https://github.com/jeong-sik/oas/commit/e505e5987e5a58843129050a7226ce679f16d584))
* **streaming:** drive thinking-only cutoff from injected Eio clock ([#2056](https://github.com/jeong-sik/oas/issues/2056)) ([adaf147](https://github.com/jeong-sik/oas/commit/adaf147a5f7f3ff7ad4474ade0759d6e943a7c78))
* **streaming:** drop coordinator term from complete_stream comment ([#2284](https://github.com/jeong-sik/oas/issues/2284)) ([21ffac7](https://github.com/jeong-sik/oas/commit/21ffac7c491cba9b9c7d2973937358c280e115dc))
* **streaming:** drop empty-choices chunk without usage + repair fmt drift (main red after [#1866](https://github.com/jeong-sik/oas/issues/1866)) ([#1869](https://github.com/jeong-sik/oas/issues/1869)) ([91dcc47](https://github.com/jeong-sik/oas/commit/91dcc4761e0eb48d438ca64d030a1ed24dadb994))
* **streaming:** fail closed on malformed streamed tool arguments ([#2261](https://github.com/jeong-sik/oas/issues/2261)) ([500f0b3](https://github.com/jeong-sik/oas/commit/500f0b30eeb7a777ae73dbb06521dd955b5c4357))
* **streaming:** plug corner cases in streaming.ml duplicate accumulator ([942f1b2](https://github.com/jeong-sik/oas/commit/942f1b2d713d969d19dfc829ccc7e7c8e5c10b21))
* **streaming:** prevent phantom completion and preserve error state ([06f6f03](https://github.com/jeong-sik/oas/commit/06f6f0310d50408f5d41f86a4a262665c8ec77b4))
* **streaming:** prevent phantom completion and preserve HTTP error state ([4d6348e](https://github.com/jeong-sik/oas/commit/4d6348e9f6388da9b68f572b16969c131049f6ab))
* **streaming:** request + parse stream_options.include_usage so OpenAI-compatible streaming returns token usage ([#1866](https://github.com/jeong-sik/oas/issues/1866)) ([8f74ef1](https://github.com/jeong-sik/oas/commit/8f74ef155198f928572f15975b981bd8a8f39170))
* **streaming:** restore sdk-independent stream mirror ([#2285](https://github.com/jeong-sik/oas/issues/2285)) ([41d053a](https://github.com/jeong-sik/oas/commit/41d053a94faf1ef8f63b1e8d6463483fc0693d49))
* **streaming:** tool-call arguments 완성값 snapshot은 append 대신 replace (keeper transport_failure 근본 수정) ([#2296](https://github.com/jeong-sik/oas/issues/2296)) ([45a86f3](https://github.com/jeong-sik/oas/commit/45a86f328827665e91842640b3f0f3678c8b8a22))
* **streaming:** treat OpenAI-compat [DONE] sentinel as a clean stream close ([#2281](https://github.com/jeong-sik/oas/issues/2281)) ([fd25631](https://github.com/jeong-sik/oas/commit/fd2563124bbf80cc4bd018dd9424dfd2da7a7a88))
* **streaming:** use canonical stream accumulator ([#2279](https://github.com/jeong-sik/oas/issues/2279)) ([3d886a1](https://github.com/jeong-sik/oas/commit/3d886a1f4debe2cc1ddd04cd18cbbdb5dcfc1302))
* **stream:** replace block-kind string match with closed variant (RFC-OAS-029 S6.1/S8.3) ([#2237](https://github.com/jeong-sik/oas/issues/2237)) ([7015b85](https://github.com/jeong-sik/oas/commit/7015b85ec822467efda8f64327873c8744da33c5))
* support MiMo token plan endpoint ([#1803](https://github.com/jeong-sik/oas/issues/1803)) ([3265348](https://github.com/jeong-sik/oas/commit/3265348268f7f42c7041d5eb81f161fa8fac7bf2))
* **telemetry:** Event_bus.publish error handling + cache failure logging ([#1797](https://github.com/jeong-sik/oas/issues/1797)) ([b415057](https://github.com/jeong-sik/oas/commit/b415057bfd12b373e96de2cac361f922b5db2e4a))
* **telemetry:** propagate participant_name in Agent_output_delta, add structured logging ([#1794](https://github.com/jeong-sik/oas/issues/1794)) ([bab2c20](https://github.com/jeong-sik/oas/commit/bab2c2048a41eb8100ccfdd93166968fc4a4df58))
* **telemetry:** replace Eio.traceln with structured Log/Diag ([#1801](https://github.com/jeong-sik/oas/issues/1801)) ([a71c21b](https://github.com/jeong-sik/oas/commit/a71c21bcc91d18715277cc508a09ea5e438ac503))
* **telemetry:** wrap all Event_bus.publish in try/with + fix complete.ml Diag ([#1798](https://github.com/jeong-sik/oas/issues/1798)) ([0ce5b69](https://github.com/jeong-sik/oas/commit/0ce5b69104bb3687573f746c264f97861cdaafa3))
* **test:** format agent sdk alias assertion ([#2059](https://github.com/jeong-sik/oas/issues/2059)) ([cdcf6d5](https://github.com/jeong-sik/oas/commit/cdcf6d5ea0414b843fbc1b8f6bba51cba12d91fe))
* **test:** green oas main — preserved redacted-thinking synthetic events + fmt drift ([#2065](https://github.com/jeong-sik/oas/issues/2065)) ([70c320f](https://github.com/jeong-sik/oas/commit/70c320f21630abc5f9433910fbeee0b704f993e0))
* **test:** repair CLI Runtime purge residue to restore compilation ([#1815](https://github.com/jeong-sik/oas/issues/1815)) ([503439b](https://github.com/jeong-sik/oas/commit/503439bbb6e6cf59264b8f774a95466b138180d8))
* **test:** repair test/dune after provider de-anon renames (un-break main test build) ([ac2fe98](https://github.com/jeong-sik/oas/commit/ac2fe982db0bfcaf23f51761054a5bf74bc994a8))
* **test:** repair test/dune after provider de-anon renames (un-break main test build) ([148024d](https://github.com/jeong-sik/oas/commit/148024d98ea8fc46f28d0d300d1e8279b89db61a))
* **thinking:** centralize openai request controls ([#2282](https://github.com/jeong-sik/oas/issues/2282)) ([72c1595](https://github.com/jeong-sik/oas/commit/72c15951936c5dd1193c10f8660ee09dbbe586f4))
* **tool_selector:** fail explicitly on unimplemented Categorical LLM classifier ([#2138](https://github.com/jeong-sik/oas/issues/2138)) ([c904303](https://github.com/jeong-sik/oas/commit/c904303b6dd637396515ec52fd2cf6f1775dd4f0))
* **tool-choice:** fail closed on unsupported forced any ([#2295](https://github.com/jeong-sik/oas/issues/2295)) ([967c92c](https://github.com/jeong-sik/oas/commit/967c92c183c7008523ee3c6e807ca104ddd9d84c))
* **tool-choice:** reject unsupported named forcing ([#2272](https://github.com/jeong-sik/oas/issues/2272)) ([85ee86a](https://github.com/jeong-sik/oas/commit/85ee86a6cf429a759577625ba4e71f063244e0ac))
* **tool-harness:** treat reconciled Unknown stop as non-tool consistent ([#2276](https://github.com/jeong-sik/oas/issues/2276)) ([043ccc5](https://github.com/jeong-sik/oas/commit/043ccc5cf11e7c2be8b4a31ee4cee0c7e420184e)), closes [#2275](https://github.com/jeong-sik/oas/issues/2275)
* **tool-use:** gate strict text recovery by provider ([#2270](https://github.com/jeong-sik/oas/issues/2270)) ([74d32ec](https://github.com/jeong-sik/oas/commit/74d32eca13c49b4e6b0ca66639e1fc561885e502))
* **tool:** centralize mutation class concurrency policy ([#2187](https://github.com/jeong-sik/oas/issues/2187)) ([5f8aecf](https://github.com/jeong-sik/oas/commit/5f8aecfb3c5f217573f21a0f06e9aef490e52c7d))
* **tools:** input fail-closed + deterministic recovery ids (RFC-OAS-029 S8.1/S4.3/S10.1) ([#2234](https://github.com/jeong-sik/oas/issues/2234)) ([c021f11](https://github.com/jeong-sik/oas/commit/c021f113a7830601a6cb5386428b79f8e99d169f))
* **tools:** resolve legacy Read to visible ReadFile ([#1800](https://github.com/jeong-sik/oas/issues/1800)) ([17e1408](https://github.com/jeong-sik/oas/commit/17e1408c6849b46fd7139fb79dd28b470e84710a))
* **typed_tool:** improve result safety in lib/typed_tool.ml ([#2159](https://github.com/jeong-sik/oas/issues/2159)) ([022407e](https://github.com/jeong-sik/oas/commit/022407e712334e081e18a444e6d00c92d1284926))


### Performance Improvements

* **context_reducer:** memoize token estimates within a single reduce ([#2116](https://github.com/jeong-sik/oas/issues/2116)) ([3a17008](https://github.com/jeong-sik/oas/commit/3a170087a0555231e3a2528bbfe9fcbcab5528f9))
* **context:** diff sorted snapshots directly ([#2183](https://github.com/jeong-sik/oas/issues/2183)) ([fff74f6](https://github.com/jeong-sik/oas/commit/fff74f6bb0b4f1135e0048b658c266632cd37ead))
* **event_bus:** O(1) subscriber count and empty-bus publish fast path ([#2115](https://github.com/jeong-sik/oas/issues/2115)) ([eab37c4](https://github.com/jeong-sik/oas/commit/eab37c4a537d4ab0f93685e8dea4aae58e80c06e))
* **event_bus:** skip filter evaluation for accept_all subscribers ([#2117](https://github.com/jeong-sik/oas/issues/2117)) ([cc7d761](https://github.com/jeong-sik/oas/commit/cc7d761a3a94c1e1475b344fc06a44ad27c8a3e7))
* inject stream+options single pass + GLM parse-once + complete_stream timestamp reuse ([#2120](https://github.com/jeong-sik/oas/issues/2120)) ([cac5b3c](https://github.com/jeong-sik/oas/commit/cac5b3caa0e69f85f5f825c11263ba5b99670420))
* use Str literal search helpers ([#2212](https://github.com/jeong-sik/oas/issues/2212)) ([83d89cd](https://github.com/jeong-sik/oas/commit/83d89cda7907954e5adc980af69dd987a7145a9c))
* **util:** use Str literal search for ci substring ([#2209](https://github.com/jeong-sik/oas/issues/2209)) ([4ac2bec](https://github.com/jeong-sik/oas/commit/4ac2bec0d5603436f5435f4b9baf14e00bb74850))


### Code Refactoring

* **agent:** remove Tool_retry_policy; defer tool-retry to the loop guard ([bc54125](https://github.com/jeong-sik/oas/commit/bc54125f7ee1643a8f6b46ae6d89ae4a97a6216a))
* **catalog:** de-anonymize vendor-purge cipher to brand names ([#2100](https://github.com/jeong-sik/oas/issues/2100)) ([0ae9c32](https://github.com/jeong-sik/oas/commit/0ae9c323f141841504553364a29597341f6031c9))
* **pipeline:** remove llm_format_recovery_stage ([98e8cf7](https://github.com/jeong-sik/oas/commit/98e8cf7a09fe5a55f1a54128dd51c55e04755d8f))

## [0.207.28](https://github.com/jeong-sik/oas/compare/v0.207.27...v0.207.28) (2026-06-30)


### Features

* **types:** expose visible answer text projection ([#2306](https://github.com/jeong-sik/oas/issues/2306)) ([3a692b9](https://github.com/jeong-sik/oas/commit/3a692b9988ad72738cf22eb69296cd7452cfbd7d))

## [0.207.27](https://github.com/jeong-sik/oas/compare/v0.207.26...v0.207.27) (2026-06-30)


### Bug Fixes

* **capabilities:** Kimi rejects named forced tool_choice (auto-only API) ([#2298](https://github.com/jeong-sik/oas/issues/2298)) ([2871202](https://github.com/jeong-sik/oas/commit/2871202ad6a6c5663eb308ba77df2d08e4029a75))
* **catalog:** DeepSeek V4 rejects named forced tool_choice (thinking-mode 400) ([#2299](https://github.com/jeong-sik/oas/issues/2299)) ([a8a668f](https://github.com/jeong-sik/oas/commit/a8a668fd1dc21a765a8987797913d746c46cdbfd))
* **catalog:** fail closed on policy string drift ([#2293](https://github.com/jeong-sik/oas/issues/2293)) ([e7a5e51](https://github.com/jeong-sik/oas/commit/e7a5e511dd9abf32005fe8540ce8ffb8cf3b7fe9))
* **llm_provider:** validate UTF-8 via Stdlib decoder, not byte-length ([#2301](https://github.com/jeong-sik/oas/issues/2301)) ([8e353b9](https://github.com/jeong-sik/oas/commit/8e353b97b64b423a26ef4a6ae68e9d3b1f570b4f))
* **multimodal:** close media source kinds ([#2283](https://github.com/jeong-sik/oas/issues/2283)) ([3860340](https://github.com/jeong-sik/oas/commit/38603406a8b679b8823ebbd57e188eef6b33fc5b))
* **provider-catalog:** fail closed on enum field type drift ([#2292](https://github.com/jeong-sik/oas/issues/2292)) ([e2d634d](https://github.com/jeong-sik/oas/commit/e2d634d5b9ba4b273b947036d8f3f8b76e032961))
* **reasoning:** centralize budget effort thresholds ([#2297](https://github.com/jeong-sik/oas/issues/2297)) ([2139b10](https://github.com/jeong-sik/oas/commit/2139b101a8024897a183c13c15a34ff2f903a0c2))
* **streaming:** tool-call arguments 완성값 snapshot은 append 대신 replace (keeper transport_failure 근본 수정) ([#2296](https://github.com/jeong-sik/oas/issues/2296)) ([45a86f3](https://github.com/jeong-sik/oas/commit/45a86f328827665e91842640b3f0f3678c8b8a22))

## [0.207.26](https://github.com/jeong-sik/oas/compare/v0.207.25...v0.207.26) (2026-06-29)


### Bug Fixes

* **provider-catalog:** carry reasoning replay override ([#2290](https://github.com/jeong-sik/oas/issues/2290)) ([18611c0](https://github.com/jeong-sik/oas/commit/18611c0066c3f8a8d4d3639535f6022a756bc99b))
* **streaming:** drop coordinator term from complete_stream comment ([#2284](https://github.com/jeong-sik/oas/issues/2284)) ([21ffac7](https://github.com/jeong-sik/oas/commit/21ffac7c491cba9b9c7d2973937358c280e115dc))
* **streaming:** restore sdk-independent stream mirror ([#2285](https://github.com/jeong-sik/oas/issues/2285)) ([41d053a](https://github.com/jeong-sik/oas/commit/41d053a94faf1ef8f63b1e8d6463483fc0693d49))

## [0.207.25](https://github.com/jeong-sik/oas/compare/v0.207.24...v0.207.25) (2026-06-29)


### Bug Fixes

* **streaming:** treat OpenAI-compat [DONE] sentinel as a clean stream close ([#2281](https://github.com/jeong-sik/oas/issues/2281)) ([fd25631](https://github.com/jeong-sik/oas/commit/fd2563124bbf80cc4bd018dd9424dfd2da7a7a88))
* **streaming:** use canonical stream accumulator ([#2279](https://github.com/jeong-sik/oas/issues/2279)) ([3d886a1](https://github.com/jeong-sik/oas/commit/3d886a1f4debe2cc1ddd04cd18cbbdb5dcfc1302))
* **tool-choice:** reject unsupported named forcing ([#2272](https://github.com/jeong-sik/oas/issues/2272)) ([85ee86a](https://github.com/jeong-sik/oas/commit/85ee86a6cf429a759577625ba4e71f063244e0ac))

## [0.207.24](https://github.com/jeong-sik/oas/compare/v0.207.23...v0.207.24) (2026-06-29)


### Bug Fixes

* **tool-harness:** treat reconciled Unknown stop as non-tool consistent ([#2276](https://github.com/jeong-sik/oas/issues/2276)) ([043ccc5](https://github.com/jeong-sik/oas/commit/043ccc5cf11e7c2be8b4a31ee4cee0c7e420184e)), closes [#2275](https://github.com/jeong-sik/oas/issues/2275)

## [0.207.23](https://github.com/jeong-sik/oas/compare/v0.207.22...v0.207.23) (2026-06-29)


### Features

* **multimodal:** close media source kinds ([#2269](https://github.com/jeong-sik/oas/issues/2269)) ([35f5a06](https://github.com/jeong-sik/oas/commit/35f5a06ac6330d030067bfa863230e32bb6d6525))


### Bug Fixes

* **agent:** remove built-in consumer tool aliases ([#2271](https://github.com/jeong-sik/oas/issues/2271)) ([8a69156](https://github.com/jeong-sik/oas/commit/8a6915612d1f91049c4ae3960139448986df12a6))
* **ci:** scope legacy-stage lint to OCaml sources ([#2260](https://github.com/jeong-sik/oas/issues/2260)) ([55fe715](https://github.com/jeong-sik/oas/commit/55fe7154bbf4b3bc52eeebce2b24f17fc5b0671c))
* **streaming:** correct inline test for fail-closed tool arguments ([#2265](https://github.com/jeong-sik/oas/issues/2265)) ([c741324](https://github.com/jeong-sik/oas/commit/c74132468414bf0663b32722be74c9c4acd7f8c1))
* **streaming:** fail closed on malformed streamed tool arguments ([#2261](https://github.com/jeong-sik/oas/issues/2261)) ([500f0b3](https://github.com/jeong-sik/oas/commit/500f0b30eeb7a777ae73dbb06521dd955b5c4357))
* **tool-use:** gate strict text recovery by provider ([#2270](https://github.com/jeong-sik/oas/issues/2270)) ([74d32ec](https://github.com/jeong-sik/oas/commit/74d32eca13c49b4e6b0ca66639e1fc561885e502))

## [0.207.22](https://github.com/jeong-sik/oas/compare/v0.207.21...v0.207.22) (2026-06-29)


### Features

* **ollama:** add native think dialect ([#2258](https://github.com/jeong-sik/oas/issues/2258)) ([841973c](https://github.com/jeong-sik/oas/commit/841973c2391d5a386cde97e1d344923ddbfcd117))


### Bug Fixes

* **ci:** restore oas main green after merge wave ([#2257](https://github.com/jeong-sik/oas/issues/2257)) ([0eb3971](https://github.com/jeong-sik/oas/commit/0eb3971122bf83488ef2db8b35224a37d8d6eee4))

## [0.207.21](https://github.com/jeong-sik/oas/compare/v0.207.20...v0.207.21) (2026-06-29)


### Features

* **observability:** default-on event bus + per-turn InferenceTelemetry producer ([#2252](https://github.com/jeong-sik/oas/issues/2252)) ([3c5a845](https://github.com/jeong-sik/oas/commit/3c5a8459ed2accacbf86ccfaea5c47880ac4a1b2))
* **stream:** assemble multimodal image/document/audio blocks in the accumulator (RFC-OAS-029) ([#2246](https://github.com/jeong-sik/oas/issues/2246)) ([10a53be](https://github.com/jeong-sik/oas/commit/10a53be855966e14096a916f07cdc4633ff87c9b))


### Bug Fixes

* **glm:** reject forced tool_choice at typed boundary ([#2254](https://github.com/jeong-sik/oas/issues/2254)) ([b7f4947](https://github.com/jeong-sik/oas/commit/b7f4947cc6e6f89423059e311a2e732a373f51d6))
* **provider:** use provider-qualified model capabilities ([#2248](https://github.com/jeong-sik/oas/issues/2248)) ([01276bb](https://github.com/jeong-sik/oas/commit/01276bbe26c819d396965596135c0d6c9584eff1))
* **stream:** fail closed for unknown block kinds ([#2243](https://github.com/jeong-sik/oas/issues/2243)) ([b6149ac](https://github.com/jeong-sik/oas/commit/b6149ac63bc201c5385a4a47e95223f5036a9478))

## [0.207.20](https://github.com/jeong-sik/oas/compare/v0.207.19...v0.207.20) (2026-06-29)


### Bug Fixes

* **provider:** isolate assistant tool content capability ([#2244](https://github.com/jeong-sik/oas/issues/2244)) ([6aa5549](https://github.com/jeong-sik/oas/commit/6aa554971b0b33bbbdb74a55f276bb66fd75abab))

## [0.207.19](https://github.com/jeong-sik/oas/compare/v0.207.18...v0.207.19) (2026-06-29)


### Bug Fixes

* **glm:** gate native reasoning_content replay on Preserved Thinking ([#2238](https://github.com/jeong-sik/oas/issues/2238)) ([5997ddc](https://github.com/jeong-sik/oas/commit/5997ddcd804ac3bedb1f63cca75f32c731fadb65))
* **stream:** replace block-kind string match with closed variant (RFC-OAS-029 S6.1/S8.3) ([#2237](https://github.com/jeong-sik/oas/issues/2237)) ([7015b85](https://github.com/jeong-sik/oas/commit/7015b85ec822467efda8f64327873c8744da33c5))

## [0.207.18](https://github.com/jeong-sik/oas/compare/v0.207.17...v0.207.18) (2026-06-29)


### Bug Fixes

* **tools:** input fail-closed + deterministic recovery ids (RFC-OAS-029 S8.1/S4.3/S10.1) ([#2234](https://github.com/jeong-sik/oas/issues/2234)) ([c021f11](https://github.com/jeong-sik/oas/commit/c021f113a7830601a6cb5386428b79f8e99d169f))

## [0.207.17](https://github.com/jeong-sik/oas/compare/v0.207.16...v0.207.17) (2026-06-29)


### Features

* **reasoning:** typed reasoning_replay_override + Kimi K2 replay ([#2227](https://github.com/jeong-sik/oas/issues/2227)) ([35d9990](https://github.com/jeong-sik/oas/commit/35d99906ba57cbd497c2c1173ea7d67b48c1d171))


### Bug Fixes

* **capabilities:** restrict gemini minimal thinking level to flash-lite ([#2224](https://github.com/jeong-sik/oas/issues/2224)) ([4bd292c](https://github.com/jeong-sik/oas/commit/4bd292c0b4a0480a4811e70df267cad774f9511e))

## [0.207.16](https://github.com/jeong-sik/oas/compare/v0.207.15...v0.207.16) (2026-06-29)


### Features

* **llm_provider:** add ?getenv DI seam to Cli_common_env (RFC-OAS-024 Phase 0) ([#2226](https://github.com/jeong-sik/oas/issues/2226)) ([a8f5677](https://github.com/jeong-sik/oas/commit/a8f5677376a9e4a3d5710c2b6340d36b3e1f0913))

## [0.207.15](https://github.com/jeong-sik/oas/compare/v0.207.14...v0.207.15) (2026-06-28)


### Bug Fixes

* **llm_provider:** StopToolUse requires a tool block — stop_reason SSOT (infinite Thinking P0) ([#2222](https://github.com/jeong-sik/oas/issues/2222)) ([d73191c](https://github.com/jeong-sik/oas/commit/d73191cf0f456a9719b0cba5e1b9b209195174bf))

## [0.207.14](https://github.com/jeong-sik/oas/compare/v0.207.13...v0.207.14) (2026-06-28)


### Bug Fixes

* add call-time default model resolver ([#2213](https://github.com/jeong-sik/oas/issues/2213)) ([46684fa](https://github.com/jeong-sik/oas/commit/46684fa381d9ce38ee4e44c202d6bd32a6f78b88))

## [0.207.13](https://github.com/jeong-sik/oas/compare/v0.207.12...v0.207.13) (2026-06-28)


### Features

* **parse:** support catalog-scoped visible reasoning text ([#2217](https://github.com/jeong-sik/oas/issues/2217)) ([9cdc539](https://github.com/jeong-sik/oas/commit/9cdc539849a6a7bce6896bcbe56a17e847449c28))


### Performance Improvements

* use Str literal search helpers ([#2212](https://github.com/jeong-sik/oas/issues/2212)) ([83d89cd](https://github.com/jeong-sik/oas/commit/83d89cda7907954e5adc980af69dd987a7145a9c))

## [0.207.12](https://github.com/jeong-sik/oas/compare/v0.207.11...v0.207.12) (2026-06-28)


### Bug Fixes

* **api:** keep default_config as a value (non-breaking) — semver repair ([#2194](https://github.com/jeong-sik/oas/issues/2194)/[#2204](https://github.com/jeong-sik/oas/issues/2204)) ([#2207](https://github.com/jeong-sik/oas/issues/2207)) ([57eb200](https://github.com/jeong-sik/oas/commit/57eb200f33444db3016d669eb2e7bb02ea8d1a25))
* **defaults:** resolve fallback provider at call time ([#2189](https://github.com/jeong-sik/oas/issues/2189)) ([f6986af](https://github.com/jeong-sik/oas/commit/f6986af7a1eaf896702dc01f93ef0a7d23c361ef))
* **http:** harden client error lifecycle ([#2176](https://github.com/jeong-sik/oas/issues/2176)) ([e818e66](https://github.com/jeong-sik/oas/commit/e818e66c196f6c66727f754025697578cd4cc2e7))
* **otel:** avoid module-load env capture ([#2200](https://github.com/jeong-sik/oas/issues/2200)) ([305e1a3](https://github.com/jeong-sik/oas/commit/305e1a34409120ae601ca0767a30661c5ea01dd6))
* **tool:** centralize mutation class concurrency policy ([#2187](https://github.com/jeong-sik/oas/issues/2187)) ([5f8aecf](https://github.com/jeong-sik/oas/commit/5f8aecfb3c5f217573f21a0f06e9aef490e52c7d))


### Performance Improvements

* **util:** use Str literal search for ci substring ([#2209](https://github.com/jeong-sik/oas/issues/2209)) ([4ac2bec](https://github.com/jeong-sik/oas/commit/4ac2bec0d5603436f5435f4b9baf14e00bb74850))

## [0.207.11](https://github.com/jeong-sik/oas/compare/v0.207.10...v0.207.11) (2026-06-28)


### Bug Fixes

* **api:** centralize default inference telemetry ([#2180](https://github.com/jeong-sik/oas/issues/2180)) ([06f8a45](https://github.com/jeong-sik/oas/commit/06f8a45098f2feb942e93ae99a34c81ffce8430f))
* **complete:** measure sync latency with eio clock ([#2201](https://github.com/jeong-sik/oas/issues/2201)) ([bcb1ea5](https://github.com/jeong-sik/oas/commit/bcb1ea54d26f48f3a4142e0d0f9dac9d3bdd01e3))
* **constants:** resolve env defaults at call time ([#2185](https://github.com/jeong-sik/oas/issues/2185)) ([cc18b1b](https://github.com/jeong-sik/oas/commit/cc18b1bb8f15005d1bec1cacbe1429167bb7baec))
* **context:** make offload failures observable ([#2194](https://github.com/jeong-sik/oas/issues/2194)) ([6195c74](https://github.com/jeong-sik/oas/commit/6195c74298be812a5d68979b49a4d5b324820ce3))
* **diag:** resolve debug env gates at call time ([#2191](https://github.com/jeong-sik/oas/issues/2191)) ([0c097a9](https://github.com/jeong-sik/oas/commit/0c097a91b4b719020044c38b87e9002d435b7cf6))
* **fs:** surface mkdir path failures ([#2196](https://github.com/jeong-sik/oas/issues/2196)) ([6453cd7](https://github.com/jeong-sik/oas/commit/6453cd72de2c6aa5d135a4f7de960d7e11fc32b4))
* **http:** classify Eio transport errors by type ([#2184](https://github.com/jeong-sik/oas/issues/2184)) ([25e0bcc](https://github.com/jeong-sik/oas/commit/25e0bcc911003bbd6ba26effe58d152689f96e8f))
* **provider:** type reasoning effort policy ([#2188](https://github.com/jeong-sik/oas/issues/2188)) ([1f7b2b4](https://github.com/jeong-sik/oas/commit/1f7b2b41801d3c7415674a18e058942e35aed525))


### Performance Improvements

* **context:** diff sorted snapshots directly ([#2183](https://github.com/jeong-sik/oas/issues/2183)) ([fff74f6](https://github.com/jeong-sik/oas/commit/fff74f6bb0b4f1135e0048b658c266632cd37ead))

> **Post-release correction (0.207.12, #2207):** [#2194](https://github.com/jeong-sik/oas/issues/2194)
> also changed `Context_offload.default_config` and `Mcp_http.default_config` from
> values to `unit -> config` functions — a breaking API change that should have
> been a minor version bump. 0.207.12 reverts `default_config` to a value
> (captured at module init) and exposes the call-time capability as
> `make_default_config`. Downstream that migrated to `default_config ()` on
> 0.207.11 should revert to `default_config` or use `make_default_config ()`.

## [0.207.10](https://github.com/jeong-sik/oas/compare/v0.207.9...v0.207.10) (2026-06-27)


### Bug Fixes

* **builder:** log auto dump save failures ([#2197](https://github.com/jeong-sik/oas/issues/2197)) ([ed1deac](https://github.com/jeong-sik/oas/commit/ed1deac2ab9af03730af233f6d0d2eb4d3f119f0))
* **complete:** measure latency with monotonic counters ([#2181](https://github.com/jeong-sik/oas/issues/2181)) ([9ab0301](https://github.com/jeong-sik/oas/commit/9ab030140a09791a7402cfb9209cc212889c0d7a))
* **pipeline:** make compaction watermark config-owned ([#2177](https://github.com/jeong-sik/oas/issues/2177)) ([0a018b7](https://github.com/jeong-sik/oas/commit/0a018b7210038d0c9c274d7d4f0658b6e672cced))
* **provider:** derive auth headers without dummy config ([#2178](https://github.com/jeong-sik/oas/issues/2178)) ([48afaec](https://github.com/jeong-sik/oas/commit/48afaec325ab528c50be135e03933de4e4b20794))

## [0.207.9](https://github.com/jeong-sik/oas/compare/v0.207.8...v0.207.9) (2026-06-27)


### Bug Fixes

* **config:** reject malformed agent list fields ([#2198](https://github.com/jeong-sik/oas/issues/2198)) ([e1c6b13](https://github.com/jeong-sik/oas/commit/e1c6b13247af69354bc3ab77a274ab52804c2aec))
* **discovery:** warn on invalid port env tokens ([#2199](https://github.com/jeong-sik/oas/issues/2199)) ([1134964](https://github.com/jeong-sik/oas/commit/1134964c5ba864443972e6c2a5129ef67f712a1e))
* **mcp:** resolve http transport env at call time ([#2193](https://github.com/jeong-sik/oas/issues/2193)) ([ebed7ca](https://github.com/jeong-sik/oas/commit/ebed7ca35371425593d6a91ac5857165a753e008))
* **oas:** concurrency safety, http client diagnostics, and pipeline SSOT ([#2174](https://github.com/jeong-sik/oas/issues/2174)) ([54507b2](https://github.com/jeong-sik/oas/commit/54507b26c920486588e8e36a7aa28ac125d75c9b))
* **oas:** reset idle counter on non-tool-use turns and idle Skip ([#2190](https://github.com/jeong-sik/oas/issues/2190)) ([1998e7c](https://github.com/jeong-sik/oas/commit/1998e7cb02f1fdd1eac5fc031595ddddfa1ef007))
* **pipeline:** make hook decisions exhaustive ([#2179](https://github.com/jeong-sik/oas/issues/2179)) ([bd34a5e](https://github.com/jeong-sik/oas/commit/bd34a5eb3a665ae6be514d0aaf7af553edd070fc))
* **provider:** configurable connect/headers timeout override ([#2163](https://github.com/jeong-sik/oas/issues/2163)) ([#2186](https://github.com/jeong-sik/oas/issues/2186)) ([37f2084](https://github.com/jeong-sik/oas/commit/37f20842b0718f0fb2bb5e48f597d5319362a965))
## [0.207.8](https://github.com/jeong-sik/oas/compare/v0.207.7...v0.207.8) (2026-06-24)


### Bug Fixes

* **build:** unify mcp_protocol dependency names ([#2167](https://github.com/jeong-sik/oas/issues/2167)) ([f4d4b69](https://github.com/jeong-sik/oas/commit/f4d4b696f535f62416c58b44fdb732006de134e9))
* **protocol:** include _meta in tool_result records for mcp_protocol 0.16 ([#2169](https://github.com/jeong-sik/oas/issues/2169)) ([0f44338](https://github.com/jeong-sik/oas/commit/0f44338adcb52d23be9a196115ab02fbe0a8ec18))

## [0.207.7](https://github.com/jeong-sik/oas/compare/v0.207.6...v0.207.7) (2026-06-22)


### Bug Fixes

* **ollama:** native /api/chat multimodal serialization ([fdc35cc](https://github.com/jeong-sik/oas/commit/fdc35cccd2057d204f798293a928836a37589ddb))

## [0.207.6](https://github.com/jeong-sik/oas/compare/v0.207.5...v0.207.6) (2026-06-19)


### Features

* **llm_provider:** allow json_schema response format for Ollama Cloud ([#2160](https://github.com/jeong-sik/oas/issues/2160)) ([36cea94](https://github.com/jeong-sik/oas/commit/36cea94216ec066ea582b256e37efe4f833d7da4))


### Bug Fixes

* **eval_collector:** unsubscribe before final drain ([#2148](https://github.com/jeong-sik/oas/issues/2148)) ([1cefcf3](https://github.com/jeong-sik/oas/commit/1cefcf31c0fff9a1b44930d61034dc0ed824272e))
* **llm_provider:** reject unsatisfiable thinking-control instead of silent drop ([#2156](https://github.com/jeong-sik/oas/issues/2156)) ([8a30a9a](https://github.com/jeong-sik/oas/commit/8a30a9a25b536216352f2ef5e858da52bdcb5e65))
* **models:** register minimax-m3 capability entry (librarian thinking control) ([#2155](https://github.com/jeong-sik/oas/issues/2155)) ([7897d49](https://github.com/jeong-sik/oas/commit/7897d4998a101387412ba32beaf896b2a1863552))
* **typed_tool:** improve result safety in lib/typed_tool.ml ([#2159](https://github.com/jeong-sik/oas/issues/2159)) ([022407e](https://github.com/jeong-sik/oas/commit/022407e712334e081e18a444e6d00c92d1284926))

## [0.207.5](https://github.com/jeong-sik/oas/compare/v0.207.4...v0.207.5) (2026-06-19)


### Bug Fixes

* address review follow-ups from [#2023](https://github.com/jeong-sik/oas/issues/2023) ([#2125](https://github.com/jeong-sik/oas/issues/2125)) ([2271978](https://github.com/jeong-sik/oas/commit/22719783317b3130bc121cae56eb5626e48ce69b))
* **async_agent:** eliminate cancel race and orphan fiber ([#2130](https://github.com/jeong-sik/oas/issues/2130)) ([dedc13a](https://github.com/jeong-sik/oas/commit/dedc13a975dcbe99502d0e7aaf933d9b5fb85960))
* **durable_event:** correct FNV-1a operator precedence ([#2129](https://github.com/jeong-sik/oas/issues/2129)) ([545c23a](https://github.com/jeong-sik/oas/commit/545c23af938c2cf038705a2fb3236d9657645e14))
* **eval_collector:** make counter updates fiber-safe with atomics ([#2135](https://github.com/jeong-sik/oas/issues/2135)) ([dd3d647](https://github.com/jeong-sik/oas/commit/dd3d6470aea56f35e1254fd7becbb1fef627bd7d))
* **event_bus:** remove subscriber_count race and prevent blocking on cancelled subscriptions ([#2136](https://github.com/jeong-sik/oas/issues/2136)) ([9374370](https://github.com/jeong-sik/oas/commit/9374370c0c6fcd3d4f87f02f54562d5bd8114071))
* **guardrail_tripwire:** avoid data race on shared violation ref ([#2133](https://github.com/jeong-sik/oas/issues/2133)) ([6dbe29f](https://github.com/jeong-sik/oas/commit/6dbe29ffe2bd58abb427de4a874febbf03fbface))
* **otel_export:** propagate Eio.Cancel.Cancelled instead of retrying ([#2134](https://github.com/jeong-sik/oas/issues/2134)) ([e0fc325](https://github.com/jeong-sik/oas/commit/e0fc3254e7b044fa3c4916afcfaf95cbdf2beec3))
* **provider_intf:** propagate Provider.resolve errors from of_config ([#2139](https://github.com/jeong-sik/oas/issues/2139)) ([ea4e3bb](https://github.com/jeong-sik/oas/commit/ea4e3bb52411b26bd4abec0570453702d325be5d))
* **streaming:** add auth header and usage options to OpenAI-compatible stream ([#2131](https://github.com/jeong-sik/oas/issues/2131)) ([04254a9](https://github.com/jeong-sik/oas/commit/04254a98ac0c05767ce0e4be2d99dfaae0b76602))

## [0.207.4](https://github.com/jeong-sik/oas/compare/v0.207.3...v0.207.4) (2026-06-19)


### Bug Fixes

* address review follow-ups from [#2017](https://github.com/jeong-sik/oas/issues/2017) ([#2122](https://github.com/jeong-sik/oas/issues/2122)) ([d54eed6](https://github.com/jeong-sik/oas/commit/d54eed6e7ba807ae58791fb73d206aa64576cd41))
* address review follow-ups from [#2028](https://github.com/jeong-sik/oas/issues/2028) ([#2124](https://github.com/jeong-sik/oas/issues/2124)) ([d58dc7d](https://github.com/jeong-sik/oas/commit/d58dc7d84aa01ca3a6be2e1d0a9a201589931a74))
* address review follow-ups from [#2096](https://github.com/jeong-sik/oas/issues/2096) ([#2123](https://github.com/jeong-sik/oas/issues/2123)) ([072f83c](https://github.com/jeong-sik/oas/commit/072f83ccf10d54224560338024fffee1a916dc1b))
* address review follow-ups from [#2098](https://github.com/jeong-sik/oas/issues/2098) ([#2127](https://github.com/jeong-sik/oas/issues/2127)) ([59170f9](https://github.com/jeong-sik/oas/commit/59170f942db9fb636b9aaa7f0dbcb4e18cc96529))
* **backend_glm:** preserve Yojson parse error message for retry classification ([#2121](https://github.com/jeong-sik/oas/issues/2121)) ([7091d3d](https://github.com/jeong-sik/oas/commit/7091d3d57bbe1ea5f683bf18d71df83cfef3317a))

## [0.207.3](https://github.com/jeong-sik/oas/compare/v0.207.2...v0.207.3) (2026-06-17)


### Features

* **llm_provider:** reusable HTTP connection cache ([#2114](https://github.com/jeong-sik/oas/issues/2114)) ([260a261](https://github.com/jeong-sik/oas/commit/260a2612c13268402b9061a9d24c5ad0cdd5613c))


### Bug Fixes

* ocamlformat drift and Dynamic selector API fallout on main ([#2119](https://github.com/jeong-sik/oas/issues/2119)) ([acf65e2](https://github.com/jeong-sik/oas/commit/acf65e2daeac0e4d719bfb896a62edb5c02ddaf0))


### Performance Improvements

* **context_reducer:** memoize token estimates within a single reduce ([#2116](https://github.com/jeong-sik/oas/issues/2116)) ([3a17008](https://github.com/jeong-sik/oas/commit/3a170087a0555231e3a2528bbfe9fcbcab5528f9))
* **event_bus:** O(1) subscriber count and empty-bus publish fast path ([#2115](https://github.com/jeong-sik/oas/issues/2115)) ([eab37c4](https://github.com/jeong-sik/oas/commit/eab37c4a537d4ab0f93685e8dea4aae58e80c06e))
* **event_bus:** skip filter evaluation for accept_all subscribers ([#2117](https://github.com/jeong-sik/oas/issues/2117)) ([cc7d761](https://github.com/jeong-sik/oas/commit/cc7d761a3a94c1e1475b344fc06a44ad27c8a3e7))

## [0.207.2](https://github.com/jeong-sik/oas/compare/v0.207.1...v0.207.2) (2026-06-17)


### Bug Fixes

* **oas:** repair main CI — ocamlformat + SDK independence ([#2111](https://github.com/jeong-sik/oas/issues/2111)) ([db7d3fb](https://github.com/jeong-sik/oas/commit/db7d3fbd77a6679b5439ba55e9ad446eaa96d327))

## [0.207.1](https://github.com/jeong-sik/oas/compare/v0.207.0...v0.207.1) (2026-06-17)


### Features

* adversarial security / secrets hardening ([#2107](https://github.com/jeong-sik/oas/issues/2107)) ([fa51717](https://github.com/jeong-sik/oas/commit/fa517179c52f5eb0b95d878b46ececb69e610242))
* **event_bus:** add turn index to ToolCalled/ToolCompleted for downstream FSM correlation ([#2108](https://github.com/jeong-sik/oas/issues/2108)) ([89e979d](https://github.com/jeong-sik/oas/commit/89e979ddcc2c873a178121015075cd7da2f5238b))
* **oas:** adversarial hardening — eio-concurrency-core ([#2106](https://github.com/jeong-sik/oas/issues/2106)) ([4543cc9](https://github.com/jeong-sik/oas/commit/4543cc9e0f6cfcc236da2c6f097d8738f8435ecb))
* **oas:** adversarial hardening — legacy-purge-safe ([#2105](https://github.com/jeong-sik/oas/issues/2105)) ([e22a669](https://github.com/jeong-sik/oas/commit/e22a6697208bffb6dde3b410237c1f6933af6ed7))

## [0.207.0](https://github.com/jeong-sik/oas/compare/v0.206.14...v0.207.0) (2026-06-16)


### ⚠ BREAKING CHANGES

* **catalog:** provider API-key and thinking-budget env var names are renamed (e.g. PROVIDER_C_API_KEY -> KIMI_API_KEY). Deployment configs, .env files, and any masc OAS-spawn env must move to the brand names.

### Bug Fixes

* **provider:** wire per-kind connect timeout in complete_sync post_sync ([#2099](https://github.com/jeong-sik/oas/issues/2099)) ([8b2ef22](https://github.com/jeong-sik/oas/commit/8b2ef22c503e04b062f645bb65482e37e047b4d4))


### Code Refactoring

* **catalog:** de-anonymize vendor-purge cipher to brand names ([#2100](https://github.com/jeong-sik/oas/issues/2100)) ([0ae9c32](https://github.com/jeong-sik/oas/commit/0ae9c323f141841504553364a29597341f6031c9))

## [0.206.14](https://github.com/jeong-sik/oas/compare/v0.206.13...v0.206.14) (2026-06-15)


### Bug Fixes

* **llm_provider:** preserve timeout phase across retry path ([#2096](https://github.com/jeong-sik/oas/issues/2096)) ([82bcf18](https://github.com/jeong-sik/oas/commit/82bcf186d6e8d20864a374aeee2129e63fc44ca3))
* **llm_provider:** separate timeout phase from catch scope, add Ollama prefill bounds ([#2093](https://github.com/jeong-sik/oas/issues/2093)) ([bef6395](https://github.com/jeong-sik/oas/commit/bef6395c26d441d31469b624a355a8e07788cd6f))

## [0.206.13](https://github.com/jeong-sik/oas/compare/v0.206.12...v0.206.13) (2026-06-15)


### Features

* **agent:** accept multimodal user input blocks ([#2088](https://github.com/jeong-sik/oas/issues/2088)) ([36df900](https://github.com/jeong-sik/oas/commit/36df9004ae7b0d5fa6ae61e15d9a1b08ec474a59))

## [0.206.12](https://github.com/jeong-sik/oas/compare/v0.206.11...v0.206.12) (2026-06-14)


### Bug Fixes

* **anthropic:** gate adaptive effort on thinking being enabled (Codex P2 on [#2082](https://github.com/jeong-sik/oas/issues/2082)) ([#2087](https://github.com/jeong-sik/oas/issues/2087)) ([2737c0a](https://github.com/jeong-sik/oas/commit/2737c0adf857fd695b6f6dffd9f0873301252c57))
* restore green main — SDK-independence ([#2080](https://github.com/jeong-sik/oas/issues/2080) doc+mli) + ocamlformat ([#2082](https://github.com/jeong-sik/oas/issues/2082) drift) ([#2084](https://github.com/jeong-sik/oas/issues/2084)) ([c10704e](https://github.com/jeong-sik/oas/commit/c10704e2f8ce271696eb0230da5bd283df63d477))

## [0.206.11](https://github.com/jeong-sik/oas/compare/v0.206.10...v0.206.11) (2026-06-14)


### Bug Fixes

* **reasoning_dialect:** align DashScope dialect + apply sampling drop on public path ([#2078](https://github.com/jeong-sik/oas/issues/2078) Codex P2) ([#2081](https://github.com/jeong-sik/oas/issues/2081)) ([3093300](https://github.com/jeong-sik/oas/commit/30933008e4c6bee3e9ed0870d839cefb507bf48c))

## [0.206.10](https://github.com/jeong-sik/oas/compare/v0.206.9...v0.206.10) (2026-06-14)


### Bug Fixes

* **responses:** drop partial tool blocks for all incomplete reasons, not just MaxTokens ([#2077](https://github.com/jeong-sik/oas/issues/2077)) ([d6f6ece](https://github.com/jeong-sik/oas/commit/d6f6ece4f1432f0cf4d36e4a0e3cc642de81cc40))

## [0.206.9](https://github.com/jeong-sik/oas/compare/v0.206.8...v0.206.9) (2026-06-14)


### Bug Fixes

* **agent,responses:** address open Codex P2 findings (incomplete-before-tooluse + lifecycle ordering) ([#2073](https://github.com/jeong-sik/oas/issues/2073)) ([6563c4a](https://github.com/jeong-sik/oas/commit/6563c4ae6151c07b845d12033b5aa290c28b6fda))
* **responses:** incomplete status wins over tool-use in streaming path ([#2073](https://github.com/jeong-sik/oas/issues/2073) follow-up) ([#2076](https://github.com/jeong-sik/oas/issues/2076)) ([e2a78f7](https://github.com/jeong-sik/oas/commit/e2a78f75e8dfc585078a88a2817bfffc9dad44f9))

## [0.206.8](https://github.com/jeong-sik/oas/compare/v0.206.7...v0.206.8) (2026-06-14)


### Bug Fixes

* **agent_registry:** protect hashtbl with mutex ([ac18990](https://github.com/jeong-sik/oas/commit/ac189904e0529a27f2e37af12558f833f1a517b1))
* **agent:** complete reserved-exception filter and log illegal hook decision coercion ([#2057](https://github.com/jeong-sik/oas/issues/2057)) ([55547d3](https://github.com/jeong-sik/oas/commit/55547d36ae41fd457674a4d10926b9cd7d1ffce5))
* **agent:** harden tool and reasoning loop handling ([#2048](https://github.com/jeong-sik/oas/issues/2048)) ([561f8b9](https://github.com/jeong-sik/oas/commit/561f8b95a2b6b8bc1621d78d2e174e816e87b5d9))
* **agent:** serialize tool-name alias registry ([#2053](https://github.com/jeong-sik/oas/issues/2053)) ([9702758](https://github.com/jeong-sik/oas/commit/97027583e4940aa6b2f61b1d9bab5c50750603e8))
* **agent:** serialize turn-budget history and idle-turn reads ([#2052](https://github.com/jeong-sik/oas/issues/2052)) ([dedc901](https://github.com/jeong-sik/oas/commit/dedc9015aa2e5204bbb6773ba77beb52b74808e7))
* **async_agent:** make cancel_fn atomic to avoid race and stale switch closure ([88435f8](https://github.com/jeong-sik/oas/commit/88435f8bba1ecc30ed9d011d783d629fefc86f3b))
* **content_replacement_state:** protect hashtbl pair with mutex ([ddabc61](https://github.com/jeong-sik/oas/commit/ddabc61501fb1fb08c7b900be01b9d8e27e42477))
* **durable_event:** make journal append lock-free with Atomic.t pair ([45cfffd](https://github.com/jeong-sik/oas/commit/45cfffde8a7f16f37375997c358ac3a6d010ecca))
* **durable_event:** propagate reserved append callback exceptions ([#2071](https://github.com/jeong-sik/oas/issues/2071)) ([66982d2](https://github.com/jeong-sik/oas/commit/66982d22df858b0f61fd1ecb52842bd6b4776cde))
* **gemini:** serialize parallel-disable warning dedup table ([#2054](https://github.com/jeong-sik/oas/issues/2054)) ([0811ded](https://github.com/jeong-sik/oas/commit/0811ded725f8ab35a8feb67379bcb2b8795a4ec6))
* **llm_provider:** make HTTP client tracked-transports list atomic ([#2060](https://github.com/jeong-sik/oas/issues/2060)) ([f2c89e8](https://github.com/jeong-sik/oas/commit/f2c89e84e513f1d857ca7684a672fcae8379d901))
* **metrics:** use Eio.Mutex in Aggregating to avoid scheduler yield issue ([2212235](https://github.com/jeong-sik/oas/commit/2212235ccc5dd129abc6bd793662fb09094040bf))
* **provider_registry:** protect entries hashtbl with mutex ([f3defdf](https://github.com/jeong-sik/oas/commit/f3defdf4809e976b31dce88fdd6619ed30f22110))
* **reasoning:** preserve opaque thinking carriers for tool loops ([#2061](https://github.com/jeong-sik/oas/issues/2061)) ([d1d4e6e](https://github.com/jeong-sik/oas/commit/d1d4e6ebf482a723cfe9457312cbab8c2152d31c))
* **streaming:** drive thinking-only cutoff from injected Eio clock ([#2056](https://github.com/jeong-sik/oas/issues/2056)) ([adaf147](https://github.com/jeong-sik/oas/commit/adaf147a5f7f3ff7ad4474ade0759d6e943a7c78))
* **test:** format agent sdk alias assertion ([#2059](https://github.com/jeong-sik/oas/issues/2059)) ([cdcf6d5](https://github.com/jeong-sik/oas/commit/cdcf6d5ea0414b843fbc1b8f6bba51cba12d91fe))
* **test:** green oas main — preserved redacted-thinking synthetic events + fmt drift ([#2065](https://github.com/jeong-sik/oas/issues/2065)) ([70c320f](https://github.com/jeong-sik/oas/commit/70c320f21630abc5f9433910fbeee0b704f993e0))

## [0.206.7](https://github.com/jeong-sik/oas/compare/v0.206.6...v0.206.7) (2026-06-12)


### Bug Fixes

* **agent:** export tool alias registry ([#2046](https://github.com/jeong-sik/oas/issues/2046)) ([4359533](https://github.com/jeong-sik/oas/commit/435953390ef27c82d7890445dc7952e25035dab9))

## [0.206.6](https://github.com/jeong-sik/oas/compare/v0.206.5...v0.206.6) (2026-06-12)


### Bug Fixes

* **openai:** model deepseek thinking control ([#2042](https://github.com/jeong-sik/oas/issues/2042)) ([2c41562](https://github.com/jeong-sik/oas/commit/2c415620475f2436b69141f709499e4e6c23e060))

## [0.206.5](https://github.com/jeong-sik/oas/compare/v0.206.4...v0.206.5) (2026-06-12)


### Bug Fixes

* **openai:** omit disabled reasoning effort ([#2039](https://github.com/jeong-sik/oas/issues/2039)) ([b6159dc](https://github.com/jeong-sik/oas/commit/b6159dc3cf6a86b3fb408afa2b43b36832f05ae3))
* **provider:** close tool message pairs before requests ([#2038](https://github.com/jeong-sik/oas/issues/2038)) ([b4478e0](https://github.com/jeong-sik/oas/commit/b4478e0cfa18501c1f4c8020889b7e07324ed077))

## [0.206.4](https://github.com/jeong-sik/oas/compare/v0.206.3...v0.206.4) (2026-06-12)


### Bug Fixes

* **pipeline:** keep tool results on tool role before nudges ([#2030](https://github.com/jeong-sik/oas/issues/2030)) ([3e56fcd](https://github.com/jeong-sik/oas/commit/3e56fcdb10b38f1451a7891ac73d72e516982fca))

## [0.206.3](https://github.com/jeong-sik/oas/compare/v0.206.2...v0.206.3) (2026-06-12)


### Bug Fixes

* **pipeline:** deliver idle nudge inside the tool-results message ([#2028](https://github.com/jeong-sik/oas/issues/2028)) ([071fd52](https://github.com/jeong-sik/oas/commit/071fd52d841285f6ce4c52f86761231880f2d52f))

## [0.206.2](https://github.com/jeong-sik/oas/compare/v0.206.1...v0.206.2) (2026-06-12)


### Features

* **event_bus:** carry provider tool_use_id on ToolCalled/ToolCompleted ([#2025](https://github.com/jeong-sik/oas/issues/2025)) ([4c6ec4c](https://github.com/jeong-sik/oas/commit/4c6ec4cedde339ee62a51265debca54127cf0506))

## [0.206.1](https://github.com/jeong-sik/oas/compare/v0.206.0...v0.206.1) (2026-06-12)


### Bug Fixes

* **glm:** honor preserve thinking in ZAI requests ([#2023](https://github.com/jeong-sik/oas/issues/2023)) ([50d7726](https://github.com/jeong-sik/oas/commit/50d77261fd516a6471a2c8fdbd07748fcc9732bf))

## [0.206.0](https://github.com/jeong-sik/oas/compare/v0.205.15...v0.206.0) (2026-06-12)


### ⚠ BREAKING CHANGES

* **agent:** the public Tool_retry_policy module, the Error.ToolRetryExhausted variant, the agent options.tool_retry_policy field, and Builder.with_tool_retry_policy are removed. Consumers relying on a tool-validation retry cap must rely on the agent loop guard (max_turns / idle / token budget) instead.
* **pipeline:** Callers relying on automatic wrapper unwrap will now receive validation errors. The LLM must send parameters as flat JSON objects at the top level.
* Error.A2a and the a2a_* constructors are removed from the public sdk_error API. Consumers matching Error.A2a must drop that arm. masc-mcp consumes agent_sdk via a git pin; its ~20 Error.A2a match arms will be compiler-forced to update when it adopts the new commit (separate follow-up).
* removes the public Completion_contract, Completion_contract_id, and Completion_contract_violation_detail modules from agent_sdk, the CompletionContractViolation error variant (Error.sdk_error / Error_domain.sdk_error_poly), and the Agent builder function with_required_tool_satisfaction. Consumers that matched on these types or relied on the SDK raising CompletionContractViolation for a missing required tool must remove those matchers and detect the condition themselves (inspect the response for a ToolUse block).

### Features

* add runtime run window reads ([#1716](https://github.com/jeong-sik/oas/issues/1716)) ([c11b35b](https://github.com/jeong-sik/oas/commit/c11b35bb9142b5261d4b61daa324a8792fd85324))
* **agent_tool:** add typed child invocation ([#1744](https://github.com/jeong-sik/oas/issues/1744)) ([cbbd543](https://github.com/jeong-sik/oas/commit/cbbd5434cb92c97340bba4fd05ce2fe6c7f48310))
* **agent:** add missing tool name aliases for deprecated names ([#18922](https://github.com/jeong-sik/oas/issues/18922)) ([#1943](https://github.com/jeong-sik/oas/issues/1943)) ([95ccbbc](https://github.com/jeong-sik/oas/commit/95ccbbc139ab40797eb1bc6b18350d3e3c75951b))
* **agent:** add turn durability checkpoints ([#1550](https://github.com/jeong-sik/oas/issues/1550)) ([393ff0c](https://github.com/jeong-sik/oas/commit/393ff0c432734c6e2c471fd78b6ebba0040b48aa))
* **agent:** generic tool alias registry, remove masc hardcoding ([#1999](https://github.com/jeong-sik/oas/issues/1999)) ([c8283ac](https://github.com/jeong-sik/oas/commit/c8283ac8a30d6807d48b28780ef2a7821f2471bb))
* **agent:** idle/progress-aware execution timeout ([#1823](https://github.com/jeong-sik/oas/issues/1823)) ([886c4d1](https://github.com/jeong-sik/oas/commit/886c4d1c8b5d03cab030266008fa5b28cdd5d847))
* **agent:** index tool dispatch lookups ([#1557](https://github.com/jeong-sik/oas/issues/1557)) ([b7ea8e6](https://github.com/jeong-sik/oas/commit/b7ea8e6b00dd5ad1d3f4bbadeb26a071228c52f5))
* **agent:** pause on async elicitation ([#1722](https://github.com/jeong-sik/oas/issues/1722)) ([b40e955](https://github.com/jeong-sik/oas/commit/b40e9557ad3f404c692159d3fd018da368f9c63e))
* **bench:** TTFT distribution bench + SLO doc (RFC-OAS-020 PR-1b) ([#1625](https://github.com/jeong-sik/oas/issues/1625)) ([2ef4b25](https://github.com/jeong-sik/oas/commit/2ef4b25eade1d4fd6b6292e99842a97c8a78634b))
* bridge runtime windows to sync replay ([#1720](https://github.com/jeong-sik/oas/issues/1720)) ([1b98e4d](https://github.com/jeong-sik/oas/commit/1b98e4dcf6368fea5b452967df67eaa822969e5c))
* **capabilities:** register Qwen_3 family in static model route ladder ([#1787](https://github.com/jeong-sik/oas/issues/1787)) ([c7f97cc](https://github.com/jeong-sik/oas/commit/c7f97cc827cf5034918ec939d0e105641b5c6b7e))
* **capability_manifest:** carry thinking_control_format (RFC-OAS-023) ([1bf68e5](https://github.com/jeong-sik/oas/commit/1bf68e54e08735e470f2a780aaa4fef1e9eb063a))
* **capability_manifest:** carry thinking_control_format (RFC-OAS-023) ([9a5d6c4](https://github.com/jeong-sik/oas/commit/9a5d6c4aaa57f917ed1c4f676f0a0082c0bacd4b))
* **complete:** add body_timeout_s to non-streaming complete + complete_with_retry ([#1622](https://github.com/jeong-sik/oas/issues/1622)) ([79262f3](https://github.com/jeong-sik/oas/commit/79262f374d70798cc76dc43f1503c5f329dfe204))
* **completion-contract:** add typed violation_detail with satisfying_tools ([#1642](https://github.com/jeong-sik/oas/issues/1642)) ([42c125f](https://github.com/jeong-sik/oas/commit/42c125f6e31c422dcf387a3546a0ffdbcea1bde0))
* **error:** carry completion contract violation detail ([#1660](https://github.com/jeong-sik/oas/issues/1660)) ([609600d](https://github.com/jeong-sik/oas/commit/609600d896af320868b9578d278e5752f8f28075))
* **eval:** gate code snippet adoption criteria ([#1751](https://github.com/jeong-sik/oas/issues/1751)) ([2a3e688](https://github.com/jeong-sik/oas/commit/2a3e688bbc03785e2232447e4b88f3d6963b3dd4))
* extract agent_sdk.protocol sublibrary and resolve circular dependencies ([#1896](https://github.com/jeong-sik/oas/issues/1896)) ([de16a44](https://github.com/jeong-sik/oas/commit/de16a4497dd76ad3493608c110174f579a20dce8))
* **gemini:** surface unsupported disable_parallel_tool_use (WP9 gap) ([#1840](https://github.com/jeong-sik/oas/issues/1840)) ([7ba14b4](https://github.com/jeong-sik/oas/commit/7ba14b44da70a2fb714a6ac10ae2f27ffd5b2601))
* **http_client:** diagnose oversized request headers that CDN proxies reject ([#1819](https://github.com/jeong-sik/oas/issues/1819)) ([03a07b8](https://github.com/jeong-sik/oas/commit/03a07b8d6485f2e121868d8e4e0f938e1bb8987c))
* **llm_provider:** externalize all hardcoded model specifications to TOML catalog ([b056d26](https://github.com/jeong-sik/oas/commit/b056d261c416e51240fa4a54068a49f4c1b93e33))
* **llm_provider:** externalize all hardcoded model specifications to TOML catalog ([1f5dc59](https://github.com/jeong-sik/oas/commit/1f5dc591eed11477e01b21b68f1521c7e335fd30))
* **llm_provider:** Fd_throttle_hook injection point (RFC-0101 PR-3) ([#1618](https://github.com/jeong-sik/oas/issues/1618)) ([29cbbc5](https://github.com/jeong-sik/oas/commit/29cbbc5b1d1593ba77e9c9a6cccac716051f88c2))
* **llm_provider:** typed TTFT capture + prefill_ms field (RFC-OAS-020 PR-1a) ([#1620](https://github.com/jeong-sik/oas/issues/1620)) ([37b4a0c](https://github.com/jeong-sik/oas/commit/37b4a0cd2a0303282579641038858f222a115547))
* **memory:** expose typed long-term retrieve result ([#1627](https://github.com/jeong-sik/oas/issues/1627)) ([0be7c3c](https://github.com/jeong-sik/oas/commit/0be7c3c37fdbfcf69f8c93cdce0514fddedae7e3))
* **metrics:** add Prometheus text export ([#1556](https://github.com/jeong-sik/oas/issues/1556)) ([fc02639](https://github.com/jeong-sik/oas/commit/fc02639b940afe6714f207f08c41dc393e112260))
* **metrics:** emit cascade circuit state ([#1563](https://github.com/jeong-sik/oas/issues/1563)) ([1f69740](https://github.com/jeong-sik/oas/commit/1f69740fb423cc68c04b7d300597a9f164499c84))
* persist runtime input-required state ([#1714](https://github.com/jeong-sik/oas/issues/1714)) ([656ac61](https://github.com/jeong-sik/oas/commit/656ac61937810763a600a268bd671c7fe8beba30))
* **pipeline:** remove forced-tool-use enforcement (RFC-OAS-025 Option A, stage 1) ([#1864](https://github.com/jeong-sik/oas/issues/1864)) ([81f97b8](https://github.com/jeong-sik/oas/commit/81f97b8441b807b78572fa219d0c935ee87e0f15))
* preserve provider timeout evidence ([#1632](https://github.com/jeong-sik/oas/issues/1632)) ([5001b3b](https://github.com/jeong-sik/oas/commit/5001b3b866fce8a31dc5e6f78a654d8ae6e560e5))
* **provider:** add external provider catalog overlay ([35241e9](https://github.com/jeong-sik/oas/commit/35241e9a82ce30360449f19a115d6589041f8f79))
* **provider:** canonical tool projection wired into turn pipeline (WP8 Inc1, RFC-OAS-024) ([#1846](https://github.com/jeong-sik/oas/issues/1846)) ([a04e0b4](https://github.com/jeong-sik/oas/commit/a04e0b45e13195cab4f59f11d22e0c2dcf31fdde))
* **provider:** expose runtime bindings ([#1585](https://github.com/jeong-sik/oas/issues/1585)) ([dbabd5c](https://github.com/jeong-sik/oas/commit/dbabd5ca7daf3ab25a861973ba346faddd442201))
* **provider:** load external provider catalog ([a13a1d0](https://github.com/jeong-sik/oas/commit/a13a1d0caa6baf0eaf77cfaa1e0ebdbed380d490))
* **provider:** per-function strict mode on tool_schema (WP2) ([#1837](https://github.com/jeong-sik/oas/issues/1837)) ([61755b2](https://github.com/jeong-sik/oas/commit/61755b286d356ff3ffb11a031c0ed27cb5d5e8d3))
* **provider:** structured tool_result content blocks (WP4) ([#1839](https://github.com/jeong-sik/oas/issues/1839)) ([95f74ec](https://github.com/jeong-sik/oas/commit/95f74ece5c7ed9c06b7231f2e6e6d208d91e3248))
* **provider:** tool calling 현대화 기반 — backend rename + stop_reason (WP0/WP1) ([#1835](https://github.com/jeong-sik/oas/issues/1835)) ([a1d6b4d](https://github.com/jeong-sik/oas/commit/a1d6b4db64a6e2c7890e5fcb67b9040fd68ff503))
* **raw-trace:** add evidence role validation seam ([#1647](https://github.com/jeong-sik/oas/issues/1647)) ([f9f1c9f](https://github.com/jeong-sik/oas/commit/f9f1c9fad7c36eac04c95ac17fda0b001a58ff00))
* **raw-trace:** expose evidence role summaries ([#1653](https://github.com/jeong-sik/oas/issues/1653)) ([9d2b2e5](https://github.com/jeong-sik/oas/commit/9d2b2e5c2739135d73f7aecdbcf04ed8fceff4c3))
* **raw-trace:** expose validation evidence roles ([#1658](https://github.com/jeong-sik/oas/issues/1658)) ([6d79276](https://github.com/jeong-sik/oas/commit/6d79276611261d0c64a8beebdf2e673e38cba74e))
* remove dead A2a error variant from sdk_error ([#1903](https://github.com/jeong-sik/oas/issues/1903)) ([7edc393](https://github.com/jeong-sik/oas/commit/7edc39375d6260943c972bd510be4b51af9c4cc3))
* remove dead completion-contract machinery (RFC-OAS-025 Option A Stage 2) ([#1867](https://github.com/jeong-sik/oas/issues/1867)) ([a7d57d2](https://github.com/jeong-sik/oas/commit/a7d57d2765e80bf70f64b8b8e10265a9df2395aa))
* **runtime:** correlate output deltas with raw trace runs ([#1748](https://github.com/jeong-sik/oas/issues/1748)) ([b16fecc](https://github.com/jeong-sik/oas/commit/b16feccff374a84621ecd969e5e9026c64f6ec0f))
* **runtime:** project checkpoint deltas from replay windows ([#1738](https://github.com/jeong-sik/oas/issues/1738)) ([e0377ad](https://github.com/jeong-sik/oas/commit/e0377ad0e574366fe6c8511e70bbda03a23ff5e7))
* **runtime:** restore paused agent input ([#1746](https://github.com/jeong-sik/oas/issues/1746)) ([0550489](https://github.com/jeong-sik/oas/commit/055048954d75481221bea1eb78c0b526f311e97d))
* **runtime:** resume paused input agents ([#1724](https://github.com/jeong-sik/oas/issues/1724)) ([59a49d5](https://github.com/jeong-sik/oas/commit/59a49d5413a3ae9cb7ec708971f53e12dfe1cec0))
* **streaming:** add Connected and Timeout constructors to sse_event ([#1947](https://github.com/jeong-sik/oas/issues/1947)) ([e66bdcb](https://github.com/jeong-sik/oas/commit/e66bdcb9d9e35c9e9ad0758c3bc5a198873e14cf))
* **streaming:** propagate Connected and Timeout events down the callback line and clean dune-project ([#1945](https://github.com/jeong-sik/oas/issues/1945)) ([3555e34](https://github.com/jeong-sik/oas/commit/3555e342d990d8b8063e41b1fafbb6fb1272e361))
* support DeepSeek runtime API key env ([#2007](https://github.com/jeong-sik/oas/issues/2007)) ([fde579c](https://github.com/jeong-sik/oas/commit/fde579cdfe8c1af8eb6392448c6c317b25f19145))
* **telemetry:** RFC-OAS-019 Phase 1 — Streaming_summary at stream finalize ([#1578](https://github.com/jeong-sik/oas/issues/1578)) ([b26fed8](https://github.com/jeong-sik/oas/commit/b26fed80300016d987cbb5d0e9d817df9d02fe95))
* **timeout:** add provider timeout policy phases ([#1656](https://github.com/jeong-sik/oas/issues/1656)) ([540cb45](https://github.com/jeong-sik/oas/commit/540cb45918330e7ae274d2b919ef3c510425260d))
* **tracing:** MASC↔OAS trace boundary linking (Phase 1-3) ([#2003](https://github.com/jeong-sik/oas/issues/2003)) ([f6ac0d0](https://github.com/jeong-sik/oas/commit/f6ac0d0eabe07a3e65f280c5d2d2e047265ff972))
* **transport:** carry stream_idle_timeout_s on completion_request (RFC-OAS-026, F1 step 1) ([e29c62b](https://github.com/jeong-sik/oas/commit/e29c62b92ab0087ddbadf718d7b38836638fc3af))
* **transport:** carry stream_idle_timeout_s on completion_request (RFC-OAS-026) ([95ba8a7](https://github.com/jeong-sik/oas/commit/95ba8a71c8a45bc4f588d9884d210a7cb4814aeb))


### Bug Fixes

* add approval-required fail-closed policy ([#1630](https://github.com/jeong-sik/oas/issues/1630)) ([9f11c50](https://github.com/jeong-sik/oas/commit/9f11c506af1980554324e719427364a5b6461a42))
* add ollama cloud direct auth ([#1561](https://github.com/jeong-sik/oas/issues/1561)) ([9f265c1](https://github.com/jeong-sik/oas/commit/9f265c19fa477ab4810bff7ffca6083c652b8a95))
* **agent_tools:** preserve optional absence in correction ([#1789](https://github.com/jeong-sik/oas/issues/1789)) ([64773ea](https://github.com/jeong-sik/oas/commit/64773eabbed612dbf04a27d9a9b4b1e2d4061d69))
* **agent_tools:** restrict find_in_index fallback to non-User tool IDs ([#1568](https://github.com/jeong-sik/oas/issues/1568)) ([5e68d21](https://github.com/jeong-sik/oas/commit/5e68d21d4530af6c8991ff769921749f2287d6ab))
* **agent-tools:** purge retired native tool ids ([#1796](https://github.com/jeong-sik/oas/issues/1796)) ([d40180d](https://github.com/jeong-sik/oas/commit/d40180d963aefed06b72faac2a1a7e097591023e))
* **agent:** gate context overflow auto retry ([#1553](https://github.com/jeong-sik/oas/issues/1553)) ([8ed4183](https://github.com/jeong-sik/oas/commit/8ed4183fb20d97fe7b4dcb704b9a3d29d674ef4c))
* **agent:** hydrate relocated tool results on resume ([#1766](https://github.com/jeong-sik/oas/issues/1766)) ([8a80296](https://github.com/jeong-sik/oas/commit/8a80296c8372606f488e44c46b0faa97ccfb583e))
* **agent:** index tool lookup paths ([#1592](https://github.com/jeong-sik/oas/issues/1592)) ([31bda07](https://github.com/jeong-sik/oas/commit/31bda07bd54c4e902b35030ec4d71547718bd1ca))
* **agent:** narrow runtime mcp per turn ([#1596](https://github.com/jeong-sik/oas/issues/1596)) ([36f7b37](https://github.com/jeong-sik/oas/commit/36f7b3779b01c38f3d69e94374c6d0812cb96403))
* **agent:** order checkpoint completion effects ([#1552](https://github.com/jeong-sik/oas/issues/1552)) ([cfbdabd](https://github.com/jeong-sik/oas/commit/cfbdabdf1c40493b36b023a0a97248ff939d571a))
* **agent:** publish content replacement events by default ([#1767](https://github.com/jeong-sik/oas/issues/1767)) ([c23e8ba](https://github.com/jeong-sik/oas/commit/c23e8ba0efdd2fa9d7759d9cf263100d97386250))
* **agent:** route registry discovery through http client ([#1560](https://github.com/jeong-sik/oas/issues/1560)) ([c0ada64](https://github.com/jeong-sik/oas/commit/c0ada64d5b89196a06969f292b77268f36e03bab))
* **agent:** surface Agent.run execution timeouts ([#1792](https://github.com/jeong-sik/oas/issues/1792)) ([37a096d](https://github.com/jeong-sik/oas/commit/37a096de62354e4e5857434966b8e7420595ecf5))
* **api:** route legacy create_message through http client ([#1558](https://github.com/jeong-sik/oas/issues/1558)) ([a20ed9f](https://github.com/jeong-sik/oas/commit/a20ed9f812c30428e5168bc3aade3e1e86eceb92))
* **backend_glm:** restore GLM thinking overlay + dedup (un-break regression) ([d162563](https://github.com/jeong-sik/oas/commit/d1625639e87ad972e65139f5ccfc0e6add0377f6))
* **backend_glm:** use glm-5.1 instead of provider_k-5.1 in tests ([e44a452](https://github.com/jeong-sik/oas/commit/e44a4527fe1b57ce8313fe8accb26168f3d47d06))
* **build:** add missing open Request_priority + feat(otel): read OTEL_EXPORTER_OTLP_ENDPOINT from env ([#1941](https://github.com/jeong-sik/oas/issues/1941)) ([3dc60fe](https://github.com/jeong-sik/oas/commit/3dc60fe8089a2237448eb8097590bddfc41b9519))
* **build:** resolve main build/test failures ([3381d9a](https://github.com/jeong-sik/oas/commit/3381d9abe8b37030e35888c659f7f254331b3a32))
* **build:** resolve main CI failures post-0.193.6 ([1b0593f](https://github.com/jeong-sik/oas/commit/1b0593f101ccf70aa443b364fa8f5d5c4ea5f54e))
* **capabilities:** change deepseek-v4 thinking control format to reasoning_effort ([e1efeee](https://github.com/jeong-sik/oas/commit/e1efeee6dfd0572a25ce2b6828f808ec22383c3b))
* **capabilities:** change deepseek-v4 thinking control format to reasoning_effort to resolve 500 error on ollama_cloud ([4e2f440](https://github.com/jeong-sik/oas/commit/4e2f440ab20ed0ca8138b47682b28cf9d454e2fd))
* **capabilities:** correct Qwen3 family specs to match official documentation ([cdc274c](https://github.com/jeong-sik/oas/commit/cdc274cb3c815e966fdbacc8cb5612033f80ef7f))
* **capabilities:** correct Qwen3 family specs to match official documentation ([a4bfdd2](https://github.com/jeong-sik/oas/commit/a4bfdd2c290b11dad43b08e321ff760af7589c56))
* **capabilities:** de-anonymize DeepSeek route + fix live model-id mismatch ([0a90990](https://github.com/jeong-sik/oas/commit/0a90990c543cf58558543725a8a4ef18ee94d01a))
* **capabilities:** keep reasoning effort overlay conservative ([44ef91e](https://github.com/jeong-sik/oas/commit/44ef91e7822792986e73c6356fa481dd3c46c173))
* **capabilities:** RFC-OAS-023 de-anon increment 1 — DeepSeek route + live model-id fix ([2591770](https://github.com/jeong-sik/oas/commit/25917708fd5617a6851aa48f8d38f1f258f6ca28))
* **capabilities:** set Chat_template_kwargs for qwen3 ([#1614](https://github.com/jeong-sik/oas/issues/1614)) ([11181bb](https://github.com/jeong-sik/oas/commit/11181bb28147dc2b0e992885e9fabcba591f8b1c))
* **capability_manifest:** remove duplicate doc text, fix SDK gate, apply ocamlformat ([5f248c1](https://github.com/jeong-sik/oas/commit/5f248c1d6f331a7e671942fc17afe2b877b7910f))
* **cascade:** gate provider attempts with throttle ([#1595](https://github.com/jeong-sik/oas/issues/1595)) ([30dcc69](https://github.com/jeong-sik/oas/commit/30dcc690119238418ba54e524b1032705cc01333))
* **cascade:** stop on TLS and local resource failures ([#1607](https://github.com/jeong-sik/oas/issues/1607)) ([1599ee0](https://github.com/jeong-sik/oas/commit/1599ee03516446007d96426f304bde4c3b3086d2))
* **catalog:** drop consumer-specific ~/.masc search path (SDK boundary) ([52f7b41](https://github.com/jeong-sik/oas/commit/52f7b41c3ef4bb7ef51803eba691c3f00eb64d75))
* **catalog:** drop consumer-specific ~/.masc search path (SDK boundary) ([19bc660](https://github.com/jeong-sik/oas/commit/19bc6608ab241366cb0564cc8283dcc0d63c1401))
* **ci:** align provider throttle timeout test ([f108350](https://github.com/jeong-sik/oas/commit/f1083506dc90986237067f9c497d347540aed18e))
* **ci:** align provider throttle timeout test ([16073fc](https://github.com/jeong-sik/oas/commit/16073fc6faae779378b6dc345a18b8a83c6d4126))
* **ci:** fill checkpoint delta usage fixture ([4624cf9](https://github.com/jeong-sik/oas/commit/4624cf936f1641bf72ea84033c9bb7a84f6bb7bc))
* **ci:** repair post-merge OAS main checks ([#1648](https://github.com/jeong-sik/oas/issues/1648)) ([39c1e76](https://github.com/jeong-sik/oas/commit/39c1e76ad851fef3f263781cbb19cef2e9cef839))
* **ci:** restore main build after usage update ([36425dc](https://github.com/jeong-sik/oas/commit/36425dc4e7f9a5d8453c11dff7765b7e177f618d))
* **ci:** restore main build after usage update ([9d8b912](https://github.com/jeong-sik/oas/commit/9d8b912743aedb567a0f65317ce2f3eaada27144))
* **ci:** restore oas build formatting ([7341e7f](https://github.com/jeong-sik/oas/commit/7341e7ff6e495da552bf40a6b5ab93e456a05dc0))
* **completion:** lower tool-choice fallback log noise ([#1608](https://github.com/jeong-sik/oas/issues/1608)) ([f53a814](https://github.com/jeong-sik/oas/commit/f53a814a7c1afec9d686c7410282d94be9abae4b))
* **context:** surface reducer repair diagnostics ([#1611](https://github.com/jeong-sik/oas/issues/1611)) ([688ee48](https://github.com/jeong-sik/oas/commit/688ee48efb3ffe227305b9ba52c8a0393f4bba03))
* **cost:** address Copilot review findings on the fail-closed path ([85f0e1f](https://github.com/jeong-sik/oas/commit/85f0e1fdd63c73a9712b2078b587e3c72551ce79))
* **cost:** fail closed when max_cost_usd is set + a turn ran an unpriced model ([dfa9bf1](https://github.com/jeong-sik/oas/commit/dfa9bf1c0ac363c571a2c4bc8556b413de47d02c))
* **cost:** fail closed when max_cost_usd is set + unpriced model ([6ec5725](https://github.com/jeong-sik/oas/commit/6ec5725f4e73093b5a7149bc467293d95b9390eb))
* **discovery:** correct de-anon leftover in contains_case_insensitive tests ([1186634](https://github.com/jeong-sik/oas/commit/1186634c0680b265dad00d1812c5155d483de35e))
* **discovery:** correct de-anon leftover in contains_case_insensitive tests ([f4e0ad2](https://github.com/jeong-sik/oas/commit/f4e0ad23ff32faebe8c5e46fc33ea8f64a910e32))
* **discovery:** validate env scan ports ([e6553c7](https://github.com/jeong-sik/oas/commit/e6553c7a8f8a10ef16883b49c15042071b89bce3))
* **dune:** add blank line between stanzas for ocamlformat ([6577be3](https://github.com/jeong-sik/oas/commit/6577be34f22b5ea9d98c3444ab3dba851b6a2e86))
* **dune:** remove orphaned (rule stanza from dune file ([1dc7af9](https://github.com/jeong-sik/oas/commit/1dc7af940a1e8c0093ea934a54b4cad208e48d14))
* **dune:** remove trailing blank line ([4df5435](https://github.com/jeong-sik/oas/commit/4df54355c85a7a34dd47b94e59b953aaa3ea8d43))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([e92553e](https://github.com/jeong-sik/oas/commit/e92553ee4379b9b33277848bd0fdf1f95e743b8e))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([51692a5](https://github.com/jeong-sik/oas/commit/51692a51a1eeb85fa087d7cab5f04b1ae3544dc5))
* **http_client:** propagate Eio.Cancel.Cancelled from drain_response_body ([#1871](https://github.com/jeong-sik/oas/issues/1871)) ([a141153](https://github.com/jeong-sik/oas/commit/a1411535ac6fc7db3d5a01840bbd60a2e3662b4a))
* **http_client:** replace pre-send header-size guard with 4xx response profiler ([#1820](https://github.com/jeong-sik/oas/issues/1820)) ([e44dee8](https://github.com/jeong-sik/oas/commit/e44dee8b91f3797436f3b7c4993a7b5497406ec6))
* **http_client:** spec-grammar SSE field parsing + fail-loud idle-without-clock ([ee945b4](https://github.com/jeong-sik/oas/commit/ee945b41cf3ef233b285f621a4bf8cc2ebb79a8f))
* **http_client:** spec-grammar SSE field parsing + fail-loud idle-without-clock ([06e32c8](https://github.com/jeong-sik/oas/commit/06e32c84714cee223abd129a66a0d444d8e901b6))
* **http:** classify empty trust anchors as local resource ([#1610](https://github.com/jeong-sik/oas/issues/1610)) ([4e86499](https://github.com/jeong-sik/oas/commit/4e86499f4c84b8d7793ae8eea878a96ea7e98d63))
* implement complete_stream_with_retry to handle deepseek 500 errors ([e9f00f3](https://github.com/jeong-sik/oas/commit/e9f00f3be9760c0fc9b813c7510493a5dd0c2ac6))
* keep alias docs SDK-independent ([#2012](https://github.com/jeong-sik/oas/issues/2012)) ([05548e5](https://github.com/jeong-sik/oas/commit/05548e500c7157f170a844a9771279d30d89cbea))
* **llm_provider:** align Ollama streaming zero usage with non-streaming path ([#1848](https://github.com/jeong-sik/oas/issues/1848)) ([392902c](https://github.com/jeong-sik/oas/commit/392902c145cca0d8a481dccf0d05cd8e8c80e068))
* **llm_provider:** finish service-name migration, restore main green ([#1813](https://github.com/jeong-sik/oas/issues/1813)) ([b309bc1](https://github.com/jeong-sik/oas/commit/b309bc199f8a6f821dde5dca9379c0b8c22b86c6)), closes [#1811](https://github.com/jeong-sik/oas/issues/1811)
* **llm_provider:** Kimi backend mapping + capability rename to service names ([#1812](https://github.com/jeong-sik/oas/issues/1812)) ([27151c1](https://github.com/jeong-sik/oas/commit/27151c1c082467fb51cd7d1d77e192b0d4a87d03))
* **llm_provider:** preserve typed provider errors across SSE stream finalize ([b4fe665](https://github.com/jeong-sik/oas/commit/b4fe66520f81d85c427a4fdc0d20d7880826e368))
* **llm_provider:** preserve typed provider errors across SSE stream finalize ([4d4e127](https://github.com/jeong-sik/oas/commit/4d4e12713c8c3f377f21d1882c9b0921324d7e94))
* **llm:** lower confidence for fallback capability drift ([#1555](https://github.com/jeong-sik/oas/issues/1555)) ([26339df](https://github.com/jeong-sik/oas/commit/26339df8cacecb49cb33ddaf0ab88a56f85c9874))
* **memory:** persist episodic procedural backends ([#1594](https://github.com/jeong-sik/oas/issues/1594)) ([e87b73f](https://github.com/jeong-sik/oas/commit/e87b73fd90e83a79c66cf974e02002ec9a5eb9a2))
* **memory:** preserve long-term backend compatibility ([#1628](https://github.com/jeong-sik/oas/issues/1628)) ([2c046ee](https://github.com/jeong-sik/oas/commit/2c046ee883ef0df26a7f8acbf12cce22d8f4bc78))
* **metrics:** aggregate streaming latency samples ([#1577](https://github.com/jeong-sik/oas/issues/1577)) ([a33ac78](https://github.com/jeong-sik/oas/commit/a33ac78895a87db2ff824a4d394c3a108d7807ad))
* **metrics:** deduplicate histogram bucket bounds in prometheus export ([#1564](https://github.com/jeong-sik/oas/issues/1564)) ([b2e8403](https://github.com/jeong-sik/oas/commit/b2e8403897a43660f3ed6ca17529e9c4b7cdebdc))
* **metrics:** emit Circuit_open directly from open-skip branch ([#1566](https://github.com/jeong-sik/oas/issues/1566)) ([8969475](https://github.com/jeong-sik/oas/commit/8969475eb8323d17400a8ba53632961173d0cad3))
* **metrics:** persist provider snapshots as json ([#1573](https://github.com/jeong-sik/oas/issues/1573)) ([d5037d2](https://github.com/jeong-sik/oas/commit/d5037d2346e7e13f5488a13495e65722b0a0a268))
* **metrics:** reject duplicate histogram buckets at register time ([#1643](https://github.com/jeong-sik/oas/issues/1643)) ([2db3378](https://github.com/jeong-sik/oas/commit/2db337807cc71e7bed79accb6d69e82f38029057))
* **metrics:** reject normalized-name collisions at register time ([#1570](https://github.com/jeong-sik/oas/issues/1570)) ([54d4b71](https://github.com/jeong-sik/oas/commit/54d4b71246d382aa8b3561c1a473e8efd9c48d9f))
* **metrics:** reject open-circuit snapshots without failure timestamp ([#1575](https://github.com/jeong-sik/oas/issues/1575)) ([fedcd13](https://github.com/jeong-sik/oas/commit/fedcd13664e32edd03f47b2763ad131cb7d2184c))
* **metrics:** support labeled histograms ([#1572](https://github.com/jeong-sik/oas/issues/1572)) ([e9f5ac6](https://github.com/jeong-sik/oas/commit/e9f5ac6dad19d380e5cb068caafe16eed7800ed6))
* **oas:** correct tool retry policy classification + add LLM format recovery ([#1936](https://github.com/jeong-sik/oas/issues/1936)) ([22b268c](https://github.com/jeong-sik/oas/commit/22b268c68c1c793c26af62036244c521622b3b15))
* **oas:** remove streaming body timeout cap ([#1930](https://github.com/jeong-sik/oas/issues/1930)) ([3252c4f](https://github.com/jeong-sik/oas/commit/3252c4fe538b82c9de93e92d3491cf0f042b8e78))
* **ollama:** preserve tool calls and avoid hard timeouts ([#1609](https://github.com/jeong-sik/oas/issues/1609)) ([64ec834](https://github.com/jeong-sik/oas/commit/64ec834685faf8f3ecc58817d6020f4aa6ab3126))
* **otel:** export native metrics ([28c8809](https://github.com/jeong-sik/oas/commit/28c88090c1f2064a378288656e8a8dec8aa05379))
* **otel:** export native metrics ([332c4cf](https://github.com/jeong-sik/oas/commit/332c4cf4f2f8864d31f055bedc8ccc4959764c70))
* **otel:** propagate trace context to provider calls ([#1576](https://github.com/jeong-sik/oas/issues/1576)) ([4060baa](https://github.com/jeong-sik/oas/commit/4060baac4b8f83468091f66011492c5b4981c7ad))
* **paths:** replace assert false with invalid_arg, document MCP env var ([#1597](https://github.com/jeong-sik/oas/issues/1597)) ([9efc99d](https://github.com/jeong-sik/oas/commit/9efc99d9a91ed8b7b9658bcc34beb2cbba5d3db0))
* **pipeline:** count runtime MCP tools for tool_choice ([#1593](https://github.com/jeong-sik/oas/issues/1593)) ([f488eab](https://github.com/jeong-sik/oas/commit/f488eabf5d756ffb4a258465663aaf74ea295f42))
* **pipeline:** drop unused agent arg from turn_ready_tool_names callers ([#1599](https://github.com/jeong-sik/oas/issues/1599)) ([7489923](https://github.com/jeong-sik/oas/commit/748992379de975e3b7d705bd29dd6815864ea927))
* **pipeline:** propagate Eio.Cancel.Cancelled from safe_publish ([#1881](https://github.com/jeong-sik/oas/issues/1881)) ([adc8312](https://github.com/jeong-sik/oas/commit/adc8312bc03e8fb76023df84d3558d3eb9d36fca))
* **pipeline:** purge ToolRetryExhausted — a tool failure is never turn-fatal ([3a5fea2](https://github.com/jeong-sik/oas/commit/3a5fea20f97c6db92d32ceaae4325e6ee98eeb6d))
* **pipeline:** purge ToolRetryExhausted — a tool failure is never turn-fatal ([f5d3345](https://github.com/jeong-sik/oas/commit/f5d3345e23c86fbf870cc9ee2aa53fedebb93370))
* **pipeline:** reject invisible tool choice contracts ([#1579](https://github.com/jeong-sik/oas/issues/1579)) ([b33e626](https://github.com/jeong-sik/oas/commit/b33e6267b49913f7fd1b2c59253403d8bf3b24e5))
* **pipeline:** reuse accumulated usage in collect stage ([#1764](https://github.com/jeong-sik/oas/issues/1764)) ([fde41d7](https://github.com/jeong-sik/oas/commit/fde41d76d84ed01ff6a22598c2dd61fd5310d970))
* **provider_catalog:** fail-fast on unknown enum strings ([bb73cdc](https://github.com/jeong-sik/oas/commit/bb73cdc0d0db9afaae67c6d66a314d8169af7275))
* **provider_catalog:** fail-fast on unknown enum strings ([5a1cf67](https://github.com/jeong-sik/oas/commit/5a1cf674ff379871d20388b24f14fecc0e9b45d9))
* **provider:** apply ocamlformat to catalog overlay ([edb91b2](https://github.com/jeong-sik/oas/commit/edb91b29d35df8130d844e531a7492af89e3fefc))
* **provider:** apply ocamlformat to catalog overlay ([0b58dfe](https://github.com/jeong-sik/oas/commit/0b58dfecd53d0b5b7687051e3fcfea3588add8e1))
* **provider:** honor parallel tool capability ([#2005](https://github.com/jeong-sik/oas/issues/2005)) ([86527d4](https://github.com/jeong-sik/oas/commit/86527d483e7f7f6a389af2b740d6e6f2172aba7b))
* **provider:** include context for empty HTTP errors ([#1582](https://github.com/jeong-sik/oas/issues/1582)) ([3b49c50](https://github.com/jeong-sik/oas/commit/3b49c5049faee63b045f641bfd4fb0cde0f6ebcd))
* **provider:** per-model tool-calling wire correctness (DeepSeek/Qwen/GLM) ([6596ded](https://github.com/jeong-sik/oas/commit/6596ded30a693f164faedb410cd42553951c9b2c))
* **provider:** persist cascade health snapshots ([#1584](https://github.com/jeong-sik/oas/issues/1584)) ([4277673](https://github.com/jeong-sik/oas/commit/42776731e1ae0b6e505557c6912240f1550a3a3e))
* **provider:** remove api_key from Provider_config.t.headers ([#1817](https://github.com/jeong-sik/oas/issues/1817)) ([31b750c](https://github.com/jeong-sik/oas/commit/31b750ceec8993b06b740273e4609b68238fa474))
* **provider:** resolve runtime binding capabilities by config ([#1589](https://github.com/jeong-sik/oas/issues/1589)) ([da757ff](https://github.com/jeong-sik/oas/commit/da757ffc1ebc7a7c94c25370755b9a683b6ce412))
* **provider:** RFC-OAS-023 per-model wire correctness (DeepSeek [#20198](https://github.com/jeong-sik/oas/issues/20198) / Qwen3 thinking / GLM tool_stream) ([f665020](https://github.com/jeong-sik/oas/commit/f665020bdba682054fbeea7e3588df5a1590ad1d))
* **provider:** round-trip reasoning_content for DeepSeek models ([9ef2e19](https://github.com/jeong-sik/oas/commit/9ef2e19d44e8b4348d08e40581e6ce3e6b1e7c29))
* **provider:** round-trip reasoning_content for DeepSeek models ([1ce9ea6](https://github.com/jeong-sik/oas/commit/1ce9ea625cf549c0ad4efb62148f3305ed2b6f15))
* **provider:** route provider intf through http client ([#1559](https://github.com/jeong-sik/oas/issues/1559)) ([b249b58](https://github.com/jeong-sik/oas/commit/b249b5887064e8da87b04697521742279103b72f))
* **provider:** surface OpenAI harness parse errors ([#1581](https://github.com/jeong-sik/oas/issues/1581)) ([42273ee](https://github.com/jeong-sik/oas/commit/42273ee4a4daf9a68aa5f3aa68b2c553be3cd05e))
* **qwen:** preserve thinking controls ([#2014](https://github.com/jeong-sik/oas/issues/2014)) ([34f1588](https://github.com/jeong-sik/oas/commit/34f1588290a2e19cebff5d9a41e17727d9557d62))
* **raw-trace:** require explicit evidence roles ([#1650](https://github.com/jeong-sik/oas/issues/1650)) ([0f4ff62](https://github.com/jeong-sik/oas/commit/0f4ff62afe0ef23895c02ecbf1cbf882709439e3))
* recognize bare GLM model ids in capabilities ([#1763](https://github.com/jeong-sik/oas/issues/1763)) ([44b5ff9](https://github.com/jeong-sik/oas/commit/44b5ff94c719bf03de03d48b6ace82b4289b613e))
* reject removed provider catalog aliases ([#1822](https://github.com/jeong-sik/oas/issues/1822)) ([e725e2c](https://github.com/jeong-sik/oas/commit/e725e2ceaae87ab51d39c71287b65fd26b0b4ebb))
* **release:** automate agent_sdk.opam sync inside release-please workflow ([#1604](https://github.com/jeong-sik/oas/issues/1604)) ([4b00bdf](https://github.com/jeong-sik/oas/commit/4b00bdff217e6233ed15bcc722d9aed410c36eba))
* remove coordinator-specific OAS hardcoding ([#1639](https://github.com/jeong-sik/oas/issues/1639)) ([16f0075](https://github.com/jeong-sik/oas/commit/16f0075f5106c8013fc9305ded2d4a59e1ee1557))
* remove masc reference from comment to pass SDK independence check ([#1805](https://github.com/jeong-sik/oas/issues/1805)) ([5f76987](https://github.com/jeong-sik/oas/commit/5f76987d25a24b18370f81efc4fdc79208a7e546)), closes [#1791](https://github.com/jeong-sik/oas/issues/1791)
* remove mutable anti-patterns — O(n) append, dead mutable, debug printf ([#1619](https://github.com/jeong-sik/oas/issues/1619)) ([5f8e07b](https://github.com/jeong-sik/oas/commit/5f8e07b777285f59c111b1a866166604d5bc4a1a))
* resolve SDK independence failure and apply code formatting ([4aebd4e](https://github.com/jeong-sik/oas/commit/4aebd4e1b441eef59838083c22c7e1e2d844a9e5))
* restore green main (ocamlformat drift + SDK independence) ([#1852](https://github.com/jeong-sik/oas/issues/1852)) ([5a7ea9e](https://github.com/jeong-sik/oas/commit/5a7ea9e4d4e8dd9a1839143aad58a6a6d204c672))
* **review:** harden recent OAS follow-ups ([66cff92](https://github.com/jeong-sik/oas/commit/66cff92c1987db2f9f69141d8ca736f91f8c11be))
* **runtime:** centralize provider identity resolution ([#1831](https://github.com/jeong-sik/oas/issues/1831)) ([c05e3bd](https://github.com/jeong-sik/oas/commit/c05e3bdaff51e5487054786cab5d3c358edafee5))
* **sessions_store:** return Error on malformed tool catalog instead of raising ([#1885](https://github.com/jeong-sik/oas/issues/1885)) ([cc30dea](https://github.com/jeong-sik/oas/commit/cc30deab29c7a1e65d20d6714649ec88b4bbbc34))
* **sessions:** drop stale parser helper signature ([#1670](https://github.com/jeong-sik/oas/issues/1670)) ([c701d0f](https://github.com/jeong-sik/oas/commit/c701d0f2de0ae01e91b83bea1e1f6491d4877603))
* **spec:** include input-required runtime phase ([#1769](https://github.com/jeong-sik/oas/issues/1769)) ([a341140](https://github.com/jeong-sik/oas/commit/a341140be322059c065b7f967924f33c2ec8ba49))
* **streaming:** bound thinking-only streams ([#2011](https://github.com/jeong-sik/oas/issues/2011)) ([0302112](https://github.com/jeong-sik/oas/commit/0302112fb763fe4688e5dc1cd385ab2392c5dbb0))
* **streaming:** default stream idle timeout to 60s and support clock ([0df3219](https://github.com/jeong-sik/oas/commit/0df32193d7c2d9499cbe9282d6c3d4d64b8595af))
* **streaming:** default stream idle timeout to 60s and support clock parameter ([e505e59](https://github.com/jeong-sik/oas/commit/e505e5987e5a58843129050a7226ce679f16d584))
* **streaming:** drop empty-choices chunk without usage + repair fmt drift (main red after [#1866](https://github.com/jeong-sik/oas/issues/1866)) ([#1869](https://github.com/jeong-sik/oas/issues/1869)) ([91dcc47](https://github.com/jeong-sik/oas/commit/91dcc4761e0eb48d438ca64d030a1ed24dadb994))
* **streaming:** plug corner cases in streaming.ml duplicate accumulator ([942f1b2](https://github.com/jeong-sik/oas/commit/942f1b2d713d969d19dfc829ccc7e7c8e5c10b21))
* **streaming:** prevent phantom completion and preserve error state ([06f6f03](https://github.com/jeong-sik/oas/commit/06f6f0310d50408f5d41f86a4a262665c8ec77b4))
* **streaming:** prevent phantom completion and preserve HTTP error state ([4d6348e](https://github.com/jeong-sik/oas/commit/4d6348e9f6388da9b68f572b16969c131049f6ab))
* **streaming:** request + parse stream_options.include_usage so OpenAI-compatible streaming returns token usage ([#1866](https://github.com/jeong-sik/oas/issues/1866)) ([8f74ef1](https://github.com/jeong-sik/oas/commit/8f74ef155198f928572f15975b981bd8a8f39170))
* support MiMo token plan endpoint ([#1803](https://github.com/jeong-sik/oas/issues/1803)) ([3265348](https://github.com/jeong-sik/oas/commit/3265348268f7f42c7041d5eb81f161fa8fac7bf2))
* **telemetry:** emit context window usage ([#1583](https://github.com/jeong-sik/oas/issues/1583)) ([070b9d4](https://github.com/jeong-sik/oas/commit/070b9d46d764d45d56b506d7edd51188a529a779))
* **telemetry:** Event_bus.publish error handling + cache failure logging ([#1797](https://github.com/jeong-sik/oas/issues/1797)) ([b415057](https://github.com/jeong-sik/oas/commit/b415057bfd12b373e96de2cac361f922b5db2e4a))
* **telemetry:** propagate participant_name in Agent_output_delta, add structured logging ([#1794](https://github.com/jeong-sik/oas/issues/1794)) ([bab2c20](https://github.com/jeong-sik/oas/commit/bab2c2048a41eb8100ccfdd93166968fc4a4df58))
* **telemetry:** replace Eio.traceln with structured Log/Diag ([#1801](https://github.com/jeong-sik/oas/issues/1801)) ([a71c21b](https://github.com/jeong-sik/oas/commit/a71c21bcc91d18715277cc508a09ea5e438ac503))
* **telemetry:** wrap all Event_bus.publish in try/with + fix complete.ml Diag ([#1798](https://github.com/jeong-sik/oas/issues/1798)) ([0ce5b69](https://github.com/jeong-sik/oas/commit/0ce5b69104bb3687573f746c264f97861cdaafa3))
* **test:** make telemetry SCA repo-root discovery fail fast ([b9d4f57](https://github.com/jeong-sik/oas/commit/b9d4f57e21904658f7163e6fcfe52f0fb18b6072))
* **test:** remove duplicate test_telemetry_sca — superseded by test/telemetry_sca/ ([4bab73f](https://github.com/jeong-sik/oas/commit/4bab73fa6236b4e4b8fac6c3d027a206780b217a))
* **test:** repair CLI Runtime purge residue to restore compilation ([#1815](https://github.com/jeong-sik/oas/issues/1815)) ([503439b](https://github.com/jeong-sik/oas/commit/503439bbb6e6cf59264b8f774a95466b138180d8))
* **test:** repair test/dune after provider de-anon renames (un-break main test build) ([ac2fe98](https://github.com/jeong-sik/oas/commit/ac2fe982db0bfcaf23f51761054a5bf74bc994a8))
* **test:** repair test/dune after provider de-anon renames (un-break main test build) ([148024d](https://github.com/jeong-sik/oas/commit/148024d98ea8fc46f28d0d300d1e8279b89db61a))
* tolerate release version markers ([#1708](https://github.com/jeong-sik/oas/issues/1708)) ([a5cd80f](https://github.com/jeong-sik/oas/commit/a5cd80fd1ffbc12ef3f5188d9c754ebd114958be))
* **tools:** enforce shell descriptor constraints ([#1602](https://github.com/jeong-sik/oas/issues/1602)) ([ce90f5d](https://github.com/jeong-sik/oas/commit/ce90f5d2575d54ec339bdfd2744c019a8849414f))
* **tools:** resolve legacy Read to visible ReadFile ([#1800](https://github.com/jeong-sik/oas/issues/1800)) ([17e1408](https://github.com/jeong-sik/oas/commit/17e1408c6849b46fd7139fb79dd28b470e84710a))
* type provider reasoning controls ([#1709](https://github.com/jeong-sik/oas/issues/1709)) ([a2bf6e1](https://github.com/jeong-sik/oas/commit/a2bf6e1c192f59717fe47f7f57f74458e3ffbcaa))


### Performance Improvements

* **completion_contract:** build tool-lookup index lazily ([#1600](https://github.com/jeong-sik/oas/issues/1600)) ([e605a13](https://github.com/jeong-sik/oas/commit/e605a133d798a1e1e308727643b59692a5c2bc25))


### Code Refactoring

* **agent:** remove Tool_retry_policy; defer tool-retry to the loop guard ([bc54125](https://github.com/jeong-sik/oas/commit/bc54125f7ee1643a8f6b46ae6d89ae4a97a6216a))
* **pipeline:** remove llm_format_recovery_stage ([98e8cf7](https://github.com/jeong-sik/oas/commit/98e8cf7a09fe5a55f1a54128dd51c55e04755d8f))

## [0.205.15](https://github.com/jeong-sik/oas/compare/v0.205.14...v0.205.15) (2026-06-12)


### Bug Fixes

* **ollama:** support Gemma 4 QAT thinking control token ([#2016](https://github.com/jeong-sik/oas/issues/2016)) ([4ab99a1](https://github.com/jeong-sik/oas/commit/4ab99a1c5d1aaadb0cef8f21cad087413ea9798e))

## [0.205.14](https://github.com/jeong-sik/oas/compare/v0.205.13...v0.205.14) (2026-06-11)


### Bug Fixes

* **qwen:** preserve thinking controls ([#2014](https://github.com/jeong-sik/oas/issues/2014)) ([34f1588](https://github.com/jeong-sik/oas/commit/34f1588290a2e19cebff5d9a41e17727d9557d62))

## [0.205.13](https://github.com/jeong-sik/oas/compare/v0.205.12...v0.205.13) (2026-06-11)


### Bug Fixes

* keep alias docs SDK-independent ([#2012](https://github.com/jeong-sik/oas/issues/2012)) ([05548e5](https://github.com/jeong-sik/oas/commit/05548e500c7157f170a844a9771279d30d89cbea))

## [0.205.12](https://github.com/jeong-sik/oas/compare/v0.205.11...v0.205.12) (2026-06-11)


### Features

* support DeepSeek runtime API key env ([#2007](https://github.com/jeong-sik/oas/issues/2007)) ([fde579c](https://github.com/jeong-sik/oas/commit/fde579cdfe8c1af8eb6392448c6c317b25f19145))


### Bug Fixes

* **streaming:** bound thinking-only streams ([#2011](https://github.com/jeong-sik/oas/issues/2011)) ([0302112](https://github.com/jeong-sik/oas/commit/0302112fb763fe4688e5dc1cd385ab2392c5dbb0))

## [0.205.11](https://github.com/jeong-sik/oas/compare/v0.205.10...v0.205.11) (2026-06-11)


### Bug Fixes

* **provider:** honor parallel tool capability ([#2005](https://github.com/jeong-sik/oas/issues/2005)) ([86527d4](https://github.com/jeong-sik/oas/commit/86527d483e7f7f6a389af2b740d6e6f2172aba7b))

## [0.205.10](https://github.com/jeong-sik/oas/compare/v0.205.9...v0.205.10) (2026-06-11)


### Features

* **tracing:** MASC↔OAS trace boundary linking (Phase 1-3) ([#2003](https://github.com/jeong-sik/oas/issues/2003)) ([f6ac0d0](https://github.com/jeong-sik/oas/commit/f6ac0d0eabe07a3e65f280c5d2d2e047265ff972))

## [0.205.9](https://github.com/jeong-sik/oas/compare/v0.205.8...v0.205.9) (2026-06-11)


### Features

* **agent:** generic tool alias registry, remove masc hardcoding ([#1999](https://github.com/jeong-sik/oas/issues/1999)) ([c8283ac](https://github.com/jeong-sik/oas/commit/c8283ac8a30d6807d48b28780ef2a7821f2471bb))

## [0.205.8](https://github.com/jeong-sik/oas/compare/v0.205.7...v0.205.8) (2026-06-10)


### Bug Fixes

* **ci:** align provider throttle timeout test ([f108350](https://github.com/jeong-sik/oas/commit/f1083506dc90986237067f9c497d347540aed18e))
* **ci:** align provider throttle timeout test ([16073fc](https://github.com/jeong-sik/oas/commit/16073fc6faae779378b6dc345a18b8a83c6d4126))

## [0.205.7](https://github.com/jeong-sik/oas/compare/v0.205.6...v0.205.7) (2026-06-10)


### Bug Fixes

* **ci:** restore oas build formatting ([7341e7f](https://github.com/jeong-sik/oas/commit/7341e7ff6e495da552bf40a6b5ab93e456a05dc0))
* **otel:** export native metrics ([28c8809](https://github.com/jeong-sik/oas/commit/28c88090c1f2064a378288656e8a8dec8aa05379))
* **otel:** export native metrics ([332c4cf](https://github.com/jeong-sik/oas/commit/332c4cf4f2f8864d31f055bedc8ccc4959764c70))

## [0.205.6](https://github.com/jeong-sik/oas/compare/v0.205.5...v0.205.6) (2026-06-10)


### Bug Fixes

* **http_client:** spec-grammar SSE field parsing + fail-loud idle-without-clock ([ee945b4](https://github.com/jeong-sik/oas/commit/ee945b41cf3ef233b285f621a4bf8cc2ebb79a8f))
* **http_client:** spec-grammar SSE field parsing + fail-loud idle-without-clock ([06e32c8](https://github.com/jeong-sik/oas/commit/06e32c84714cee223abd129a66a0d444d8e901b6))

## [0.205.5](https://github.com/jeong-sik/oas/compare/v0.205.4...v0.205.5) (2026-06-10)


### Bug Fixes

* **catalog:** drop consumer-specific ~/.masc search path (SDK boundary) ([52f7b41](https://github.com/jeong-sik/oas/commit/52f7b41c3ef4bb7ef51803eba691c3f00eb64d75))
* **catalog:** drop consumer-specific ~/.masc search path (SDK boundary) ([19bc660](https://github.com/jeong-sik/oas/commit/19bc6608ab241366cb0564cc8283dcc0d63c1401))

## [0.205.4](https://github.com/jeong-sik/oas/compare/v0.205.3...v0.205.4) (2026-06-09)


### Bug Fixes

* **provider:** round-trip reasoning_content for DeepSeek models ([9ef2e19](https://github.com/jeong-sik/oas/commit/9ef2e19d44e8b4348d08e40581e6ce3e6b1e7c29))
* **provider:** round-trip reasoning_content for DeepSeek models ([1ce9ea6](https://github.com/jeong-sik/oas/commit/1ce9ea625cf549c0ad4efb62148f3305ed2b6f15))

## [0.205.3](https://github.com/jeong-sik/oas/compare/v0.205.2...v0.205.3) (2026-06-09)


### Features

* **llm_provider:** externalize all hardcoded model specifications to TOML catalog ([b056d26](https://github.com/jeong-sik/oas/commit/b056d261c416e51240fa4a54068a49f4c1b93e33))
* **llm_provider:** externalize all hardcoded model specifications to TOML catalog ([1f5dc59](https://github.com/jeong-sik/oas/commit/1f5dc591eed11477e01b21b68f1521c7e335fd30))

## [0.205.2](https://github.com/jeong-sik/oas/compare/v0.205.1...v0.205.2) (2026-06-09)


### Bug Fixes

* **streaming:** default stream idle timeout to 60s and support clock ([0df3219](https://github.com/jeong-sik/oas/commit/0df32193d7c2d9499cbe9282d6c3d4d64b8595af))
* **streaming:** default stream idle timeout to 60s and support clock parameter ([e505e59](https://github.com/jeong-sik/oas/commit/e505e5987e5a58843129050a7226ce679f16d584))

## [0.205.1](https://github.com/jeong-sik/oas/compare/v0.205.0...v0.205.1) (2026-06-09)


### Bug Fixes

* **capabilities:** correct Qwen3 family specs to match official documentation ([cdc274c](https://github.com/jeong-sik/oas/commit/cdc274cb3c815e966fdbacc8cb5612033f80ef7f))
* **capabilities:** correct Qwen3 family specs to match official documentation ([a4bfdd2](https://github.com/jeong-sik/oas/commit/a4bfdd2c290b11dad43b08e321ff760af7589c56))

## [0.205.0](https://github.com/jeong-sik/oas/compare/v0.204.11...v0.205.0) (2026-06-09)


### ⚠ BREAKING CHANGES

* **agent:** the public Tool_retry_policy module, the Error.ToolRetryExhausted variant, the agent options.tool_retry_policy field, and Builder.with_tool_retry_policy are removed. Consumers relying on a tool-validation retry cap must rely on the agent loop guard (max_turns / idle / token budget) instead.

### Bug Fixes

* implement complete_stream_with_retry to handle deepseek 500 errors ([e9f00f3](https://github.com/jeong-sik/oas/commit/e9f00f3be9760c0fc9b813c7510493a5dd0c2ac6))
* **pipeline:** purge ToolRetryExhausted — a tool failure is never turn-fatal ([3a5fea2](https://github.com/jeong-sik/oas/commit/3a5fea20f97c6db92d32ceaae4325e6ee98eeb6d))
* **pipeline:** purge ToolRetryExhausted — a tool failure is never turn-fatal ([f5d3345](https://github.com/jeong-sik/oas/commit/f5d3345e23c86fbf870cc9ee2aa53fedebb93370))
* resolve SDK independence failure and apply code formatting ([4aebd4e](https://github.com/jeong-sik/oas/commit/4aebd4e1b441eef59838083c22c7e1e2d844a9e5))


### Code Refactoring

* **agent:** remove Tool_retry_policy; defer tool-retry to the loop guard ([bc54125](https://github.com/jeong-sik/oas/commit/bc54125f7ee1643a8f6b46ae6d89ae4a97a6216a))

## [0.204.11](https://github.com/jeong-sik/oas/compare/v0.204.10...v0.204.11) (2026-06-09)


### Features

* **capability_manifest:** carry thinking_control_format (RFC-OAS-023) ([1bf68e5](https://github.com/jeong-sik/oas/commit/1bf68e54e08735e470f2a780aaa4fef1e9eb063a))
* **capability_manifest:** carry thinking_control_format (RFC-OAS-023) ([9a5d6c4](https://github.com/jeong-sik/oas/commit/9a5d6c4aaa57f917ed1c4f676f0a0082c0bacd4b))

## [0.204.10](https://github.com/jeong-sik/oas/compare/v0.204.9...v0.204.10) (2026-06-09)


### Bug Fixes

* **discovery:** correct de-anon leftover in contains_case_insensitive tests ([1186634](https://github.com/jeong-sik/oas/commit/1186634c0680b265dad00d1812c5155d483de35e))

## [0.204.9](https://github.com/jeong-sik/oas/compare/v0.204.8...v0.204.9) (2026-06-09)


### Bug Fixes

* **backend_glm:** restore GLM thinking overlay + dedup (un-break regression) ([d162563](https://github.com/jeong-sik/oas/commit/d1625639e87ad972e65139f5ccfc0e6add0377f6))
* **backend_glm:** use glm-5.1 instead of provider_k-5.1 in tests ([e44a452](https://github.com/jeong-sik/oas/commit/e44a4527fe1b57ce8313fe8accb26168f3d47d06))
* **provider:** RFC-OAS-023 per-model wire correctness (DeepSeek [#20198](https://github.com/jeong-sik/oas/issues/20198) / Qwen3 thinking / GLM tool_stream) ([f665020](https://github.com/jeong-sik/oas/commit/f665020bdba682054fbeea7e3588df5a1590ad1d))
* **streaming:** plug corner cases in streaming.ml duplicate accumulator ([942f1b2](https://github.com/jeong-sik/oas/commit/942f1b2d713d969d19dfc829ccc7e7c8e5c10b21))
* **streaming:** prevent phantom completion and preserve error state ([06f6f03](https://github.com/jeong-sik/oas/commit/06f6f0310d50408f5d41f86a4a262665c8ec77b4))
* **streaming:** prevent phantom completion and preserve HTTP error state ([4d6348e](https://github.com/jeong-sik/oas/commit/4d6348e9f6388da9b68f572b16969c131049f6ab))
* **test:** repair test/dune after provider de-anon renames (un-break main test build) ([ac2fe98](https://github.com/jeong-sik/oas/commit/ac2fe982db0bfcaf23f51761054a5bf74bc994a8))
* **test:** repair test/dune after provider de-anon renames (un-break main test build) ([148024d](https://github.com/jeong-sik/oas/commit/148024d98ea8fc46f28d0d300d1e8279b89db61a))

## [0.204.8](https://github.com/jeong-sik/oas/compare/v0.204.7...v0.204.8) (2026-06-09)


### Bug Fixes

* **llm_provider:** preserve typed provider errors across SSE stream finalize ([b4fe665](https://github.com/jeong-sik/oas/commit/b4fe66520f81d85c427a4fdc0d20d7880826e368))
* **llm_provider:** preserve typed provider errors across SSE stream finalize ([4d4e127](https://github.com/jeong-sik/oas/commit/4d4e12713c8c3f377f21d1882c9b0921324d7e94))

## [0.204.7](https://github.com/jeong-sik/oas/compare/v0.204.6...v0.204.7) (2026-06-09)


### Bug Fixes

* **capabilities:** de-anonymize DeepSeek route + fix live model-id mismatch ([0a90990](https://github.com/jeong-sik/oas/commit/0a90990c543cf58558543725a8a4ef18ee94d01a))
* **capabilities:** RFC-OAS-023 de-anon increment 1 — DeepSeek route + live model-id fix ([2591770](https://github.com/jeong-sik/oas/commit/25917708fd5617a6851aa48f8d38f1f258f6ca28))

## [0.204.6](https://github.com/jeong-sik/oas/compare/v0.204.5...v0.204.6) (2026-06-09)


### Features

* **transport:** carry stream_idle_timeout_s on completion_request (RFC-OAS-026, F1 step 1) ([e29c62b](https://github.com/jeong-sik/oas/commit/e29c62b92ab0087ddbadf718d7b38836638fc3af))
* **transport:** carry stream_idle_timeout_s on completion_request (RFC-OAS-026) ([95ba8a7](https://github.com/jeong-sik/oas/commit/95ba8a71c8a45bc4f588d9884d210a7cb4814aeb))

## [0.204.5](https://github.com/jeong-sik/oas/compare/v0.204.4...v0.204.5) (2026-06-08)


### Features

* **streaming:** add Connected and Timeout constructors to sse_event ([#1947](https://github.com/jeong-sik/oas/issues/1947)) ([e66bdcb](https://github.com/jeong-sik/oas/commit/e66bdcb9d9e35c9e9ad0758c3bc5a198873e14cf))

## [0.204.4](https://github.com/jeong-sik/oas/compare/v0.204.3...v0.204.4) (2026-06-08)


### Features

* **streaming:** propagate Connected and Timeout events down the callback line and clean dune-project ([#1945](https://github.com/jeong-sik/oas/issues/1945)) ([3555e34](https://github.com/jeong-sik/oas/commit/3555e342d990d8b8063e41b1fafbb6fb1272e361))

## [0.204.3](https://github.com/jeong-sik/oas/compare/v0.204.2...v0.204.3) (2026-06-08)


### Features

* **agent:** add missing tool name aliases for deprecated names ([#18922](https://github.com/jeong-sik/oas/issues/18922)) ([#1943](https://github.com/jeong-sik/oas/issues/1943)) ([95ccbbc](https://github.com/jeong-sik/oas/commit/95ccbbc139ab40797eb1bc6b18350d3e3c75951b))

## [0.204.2](https://github.com/jeong-sik/oas/compare/v0.204.1...v0.204.2) (2026-06-08)


### Bug Fixes

* **build:** add missing open Request_priority + feat(otel): read OTEL_EXPORTER_OTLP_ENDPOINT from env ([#1941](https://github.com/jeong-sik/oas/issues/1941)) ([3dc60fe](https://github.com/jeong-sik/oas/commit/3dc60fe8089a2237448eb8097590bddfc41b9519))

## [0.204.1](https://github.com/jeong-sik/oas/compare/v0.204.0...v0.204.1) (2026-06-07)


### Bug Fixes

* **oas:** correct tool retry policy classification + add LLM format recovery ([#1936](https://github.com/jeong-sik/oas/issues/1936)) ([22b268c](https://github.com/jeong-sik/oas/commit/22b268c68c1c793c26af62036244c521622b3b15))

## [0.204.0](https://github.com/jeong-sik/oas/compare/v0.203.2...v0.204.0) (2026-06-06)


### ⚠ BREAKING CHANGES

* Error.A2a and the a2a_* constructors are removed from the public sdk_error API. Consumers matching Error.A2a must drop that arm. masc-mcp consumes agent_sdk via a git pin; its ~20 Error.A2a match arms will be compiler-forced to update when it adopts the new commit (separate follow-up).
* removes the public Completion_contract, Completion_contract_id, and Completion_contract_violation_detail modules from agent_sdk, the CompletionContractViolation error variant (Error.sdk_error / Error_domain.sdk_error_poly), and the Agent builder function with_required_tool_satisfaction. Consumers that matched on these types or relied on the SDK raising CompletionContractViolation for a missing required tool must remove those matchers and detect the condition themselves (inspect the response for a ToolUse block).
* remove migrated CDAL modules + façade re-exports (RFC-OAS-011 OAS-E PR-6)

### Features

* add runtime run window reads ([#1716](https://github.com/jeong-sik/oas/issues/1716)) ([c11b35b](https://github.com/jeong-sik/oas/commit/c11b35bb9142b5261d4b61daa324a8792fd85324))
* **agent_tool:** add typed child invocation ([#1744](https://github.com/jeong-sik/oas/issues/1744)) ([cbbd543](https://github.com/jeong-sik/oas/commit/cbbd5434cb92c97340bba4fd05ce2fe6c7f48310))
* **agent_tools:** remove CDAL builtin_descriptor fallback (RFC-OAS-009 v2 PR-B) ([39082f6](https://github.com/jeong-sik/oas/commit/39082f6005888209a5b16c6aaa0b60bd25df050f))
* **agent_tools:** remove CDAL builtin_descriptor fallback (RFC-OAS-009 v2 PR-B) ([41d0144](https://github.com/jeong-sik/oas/commit/41d0144f22fbfc36ea0da2c92487caff638bf807))
* **agent:** add disclosure_level for tool schema serialization ([#1508](https://github.com/jeong-sik/oas/issues/1508)) ([f48ccec](https://github.com/jeong-sik/oas/commit/f48ccec3d1f6045627bb51c913944b7b879baf4d))
* **agent:** add disclosure_resolver for per-turn adaptive disclosure ([#1511](https://github.com/jeong-sik/oas/issues/1511)) ([7ed9c05](https://github.com/jeong-sik/oas/commit/7ed9c05260dce7b813bfaf524a2799573eb6479d))
* **agent:** add turn durability checkpoints ([#1550](https://github.com/jeong-sik/oas/issues/1550)) ([393ff0c](https://github.com/jeong-sik/oas/commit/393ff0c432734c6e2c471fd78b6ebba0040b48aa))
* **agent:** idle/progress-aware execution timeout ([#1823](https://github.com/jeong-sik/oas/issues/1823)) ([886c4d1](https://github.com/jeong-sik/oas/commit/886c4d1c8b5d03cab030266008fa5b28cdd5d847))
* **agent:** index tool dispatch lookups ([#1557](https://github.com/jeong-sik/oas/issues/1557)) ([b7ea8e6](https://github.com/jeong-sik/oas/commit/b7ea8e6b00dd5ad1d3f4bbadeb26a071228c52f5))
* **agent:** pause on async elicitation ([#1722](https://github.com/jeong-sik/oas/issues/1722)) ([b40e955](https://github.com/jeong-sik/oas/commit/b40e9557ad3f404c692159d3fd018da368f9c63e))
* **base:** Tool_id closed Variant identifier (RFC-OAS-008 PR-2/5) ([3c67d1e](https://github.com/jeong-sik/oas/commit/3c67d1e510fca49692937effd08cefc89aebd079))
* **base:** Tool_id closed Variant identifier (RFC-OAS-008 PR-2/5) ([8f413f8](https://github.com/jeong-sik/oas/commit/8f413f8a063273524f4fd2a22d14e69b1934709e))
* **bench:** TTFT distribution bench + SLO doc (RFC-OAS-020 PR-1b) ([#1625](https://github.com/jeong-sik/oas/issues/1625)) ([2ef4b25](https://github.com/jeong-sik/oas/commit/2ef4b25eade1d4fd6b6292e99842a97c8a78634b))
* bridge runtime windows to sync replay ([#1720](https://github.com/jeong-sik/oas/issues/1720)) ([1b98e4d](https://github.com/jeong-sik/oas/commit/1b98e4dcf6368fea5b452967df67eaa822969e5c))
* **capabilities:** register Qwen_3 family in static model route ladder ([#1787](https://github.com/jeong-sik/oas/issues/1787)) ([c7f97cc](https://github.com/jeong-sik/oas/commit/c7f97cc827cf5034918ec939d0e105641b5c6b7e))
* **capability_manifest:** add set_global / clear_global runtime override ([#1516](https://github.com/jeong-sik/oas/issues/1516)) ([c3a786f](https://github.com/jeong-sik/oas/commit/c3a786f36f6fc37306c1f8932267b9f684180ed5))
* **ci:** boundary-lint for core→CDAL zero dependency (RFC-OAS-009 v2 PR-D) ([b0c7a44](https://github.com/jeong-sik/oas/commit/b0c7a4484fe1a6514c1a308e9ce01581e356c81a))
* **ci:** boundary-lint for core→CDAL zero dependency (RFC-OAS-009 v2 PR-D) ([f53a3f5](https://github.com/jeong-sik/oas/commit/f53a3f550a9b27848cc58e52ed024036cb86f281))
* **ci:** expand boundary-lint to 20 CDAL prefixes (RFC-OAS-011 OAS-E PR-1) ([0a306ce](https://github.com/jeong-sik/oas/commit/0a306ce0f30e28d44e780eedb68551d2ded634a3))
* **ci:** expand boundary-lint to 20 CDAL prefixes (RFC-OAS-011 OAS-E PR-1) ([e189ed7](https://github.com/jeong-sik/oas/commit/e189ed75b1d25b97a6bf9c4d8536d7c5b79188bc))
* **complete:** add body_timeout_s to non-streaming complete + complete_with_retry ([#1622](https://github.com/jeong-sik/oas/issues/1622)) ([79262f3](https://github.com/jeong-sik/oas/commit/79262f374d70798cc76dc43f1503c5f329dfe204))
* **completion-contract:** add typed violation_detail with satisfying_tools ([#1642](https://github.com/jeong-sik/oas/issues/1642)) ([42c125f](https://github.com/jeong-sik/oas/commit/42c125f6e31c422dcf387a3546a0ffdbcea1bde0))
* **error:** carry completion contract violation detail ([#1660](https://github.com/jeong-sik/oas/issues/1660)) ([609600d](https://github.com/jeong-sik/oas/commit/609600d896af320868b9578d278e5752f8f28075))
* **eval:** gate code snippet adoption criteria ([#1751](https://github.com/jeong-sik/oas/issues/1751)) ([2a3e688](https://github.com/jeong-sik/oas/commit/2a3e688bbc03785e2232447e4b88f3d6963b3dd4))
* extract agent_sdk.protocol sublibrary and resolve circular dependencies ([#1896](https://github.com/jeong-sik/oas/issues/1896)) ([de16a44](https://github.com/jeong-sik/oas/commit/de16a4497dd76ad3493608c110174f579a20dce8))
* **gemini:** surface unsupported disable_parallel_tool_use (WP9 gap) ([#1840](https://github.com/jeong-sik/oas/issues/1840)) ([7ba14b4](https://github.com/jeong-sik/oas/commit/7ba14b44da70a2fb714a6ac10ae2f27ffd5b2601))
* **http_client:** diagnose oversized request headers that CDN proxies reject ([#1819](https://github.com/jeong-sik/oas/issues/1819)) ([03a07b8](https://github.com/jeong-sik/oas/commit/03a07b8d6485f2e121868d8e4e0f938e1bb8987c))
* **lib:** add Cognitive_event typed schema (RFC-0036 PR-B) ([#1451](https://github.com/jeong-sik/oas/issues/1451)) ([f848e75](https://github.com/jeong-sik/oas/commit/f848e75a298827722d5f6cff8162f954ae20f974))
* **llm_provider:** Fd_throttle_hook injection point (RFC-0101 PR-3) ([#1618](https://github.com/jeong-sik/oas/issues/1618)) ([29cbbc5](https://github.com/jeong-sik/oas/commit/29cbbc5b1d1593ba77e9c9a6cccac716051f88c2))
* **llm_provider:** RFC-0058 Phase B — CLI transport factory ([#1520](https://github.com/jeong-sik/oas/issues/1520)) ([41e87e0](https://github.com/jeong-sik/oas/commit/41e87e0cd1fe4d57c4f627958b34fcf419839745))
* **llm_provider:** typed TTFT capture + prefill_ms field (RFC-OAS-020 PR-1a) ([#1620](https://github.com/jeong-sik/oas/issues/1620)) ([37b4a0c](https://github.com/jeong-sik/oas/commit/37b4a0cd2a0303282579641038858f222a115547))
* **llm_provider:** Visual_first modality ordering for Gemma 4 ([cf94ce9](https://github.com/jeong-sik/oas/commit/cf94ce9a95deaa34270f3f3c1cb75347ba5ea59d))
* **llm_provider:** Visual_first modality ordering for Gemma 4 ([791eee8](https://github.com/jeong-sik/oas/commit/791eee8b6266fe91d762f76544ae525bb4992f7c))
* **llm_provider:** wire ttfrc_ms and prefill_ms into inference_telemetry ([809b63a](https://github.com/jeong-sik/oas/commit/809b63a5c4dfbeed427d660295de26df3ed928eb))
* **mcp_schema:** remove descriptor_for_builtin_tool alias (RFC-OAS-009 v2 PR-C) ([ffb8aff](https://github.com/jeong-sik/oas/commit/ffb8aff3a3bac4bdfce823fe41ca176226ba2f13))
* **mcp_schema:** remove descriptor_for_builtin_tool alias (RFC-OAS-009 v2 PR-C) ([2c41611](https://github.com/jeong-sik/oas/commit/2c416118433aa703f97f1e891b5671e9f67bb931))
* **memory:** expose typed long-term retrieve result ([#1627](https://github.com/jeong-sik/oas/issues/1627)) ([0be7c3c](https://github.com/jeong-sik/oas/commit/0be7c3c37fdbfcf69f8c93cdce0514fddedae7e3))
* **metrics:** add Prometheus text export ([#1556](https://github.com/jeong-sik/oas/issues/1556)) ([fc02639](https://github.com/jeong-sik/oas/commit/fc02639b940afe6714f207f08c41dc393e112260))
* **metrics:** emit cascade circuit state ([#1563](https://github.com/jeong-sik/oas/issues/1563)) ([1f69740](https://github.com/jeong-sik/oas/commit/1f69740fb423cc68c04b7d300597a9f164499c84))
* **oas:** TLA+ CI gate + AgentCancellation spec + lifecycle_status yojson ([#1467](https://github.com/jeong-sik/oas/issues/1467)) ([7cd282f](https://github.com/jeong-sik/oas/commit/7cd282fed27ef6aa0637a6a12ca9356621619039))
* persist runtime input-required state ([#1714](https://github.com/jeong-sik/oas/issues/1714)) ([656ac61](https://github.com/jeong-sik/oas/commit/656ac61937810763a600a268bd671c7fe8beba30))
* **pipeline:** remove forced-tool-use enforcement (RFC-OAS-025 Option A, stage 1) ([#1864](https://github.com/jeong-sik/oas/issues/1864)) ([81f97b8](https://github.com/jeong-sik/oas/commit/81f97b8441b807b78572fa219d0c935ee87e0f15))
* preserve provider timeout evidence ([#1632](https://github.com/jeong-sik/oas/issues/1632)) ([5001b3b](https://github.com/jeong-sik/oas/commit/5001b3b866fce8a31dc5e6f78a654d8ae6e560e5))
* **provider:** add external provider catalog overlay ([35241e9](https://github.com/jeong-sik/oas/commit/35241e9a82ce30360449f19a115d6589041f8f79))
* **provider:** canonical tool projection wired into turn pipeline (WP8 Inc1, RFC-OAS-024) ([#1846](https://github.com/jeong-sik/oas/issues/1846)) ([a04e0b4](https://github.com/jeong-sik/oas/commit/a04e0b45e13195cab4f59f11d22e0c2dcf31fdde))
* **provider:** expose runtime bindings ([#1585](https://github.com/jeong-sik/oas/issues/1585)) ([dbabd5c](https://github.com/jeong-sik/oas/commit/dbabd5ca7daf3ab25a861973ba346faddd442201))
* **provider:** load external provider catalog ([a13a1d0](https://github.com/jeong-sik/oas/commit/a13a1d0caa6baf0eaf77cfaa1e0ebdbed380d490))
* **provider:** map transport errors to typed provider errors ([#1448](https://github.com/jeong-sik/oas/issues/1448)) ([e804755](https://github.com/jeong-sik/oas/commit/e804755e3fb4ce81c33cd2b32880b206c588c28a))
* **provider:** per-function strict mode on tool_schema (WP2) ([#1837](https://github.com/jeong-sik/oas/issues/1837)) ([61755b2](https://github.com/jeong-sik/oas/commit/61755b286d356ff3ffb11a031c0ed27cb5d5e8d3))
* **provider:** structured tool_result content blocks (WP4) ([#1839](https://github.com/jeong-sik/oas/issues/1839)) ([95f74ec](https://github.com/jeong-sik/oas/commit/95f74ece5c7ed9c06b7231f2e6e6d208d91e3248))
* **provider:** tool calling 현대화 기반 — backend rename + stop_reason (WP0/WP1) ([#1835](https://github.com/jeong-sik/oas/issues/1835)) ([a1d6b4d](https://github.com/jeong-sik/oas/commit/a1d6b4db64a6e2c7890e5fcb67b9040fd68ff503))
* **raw-trace:** add evidence role validation seam ([#1647](https://github.com/jeong-sik/oas/issues/1647)) ([f9f1c9f](https://github.com/jeong-sik/oas/commit/f9f1c9fad7c36eac04c95ac17fda0b001a58ff00))
* **raw-trace:** expose evidence role summaries ([#1653](https://github.com/jeong-sik/oas/issues/1653)) ([9d2b2e5](https://github.com/jeong-sik/oas/commit/9d2b2e5c2739135d73f7aecdbcf04ed8fceff4c3))
* **raw-trace:** expose validation evidence roles ([#1658](https://github.com/jeong-sik/oas/issues/1658)) ([6d79276](https://github.com/jeong-sik/oas/commit/6d79276611261d0c64a8beebdf2e673e38cba74e))
* **release:** adopt release-please for version + CHANGELOG automation ([fd9931d](https://github.com/jeong-sik/oas/commit/fd9931d7f60f3b966140fdc700fd29c982ac5ea5))
* **release:** adopt release-please for version + CHANGELOG automation ([058ea4b](https://github.com/jeong-sik/oas/commit/058ea4bea2205b21854960f7cd4cb885043a9de8))
* remove dead A2a error variant from sdk_error ([#1903](https://github.com/jeong-sik/oas/issues/1903)) ([7edc393](https://github.com/jeong-sik/oas/commit/7edc39375d6260943c972bd510be4b51af9c4cc3))
* remove dead completion-contract machinery (RFC-OAS-025 Option A Stage 2) ([#1867](https://github.com/jeong-sik/oas/issues/1867)) ([a7d57d2](https://github.com/jeong-sik/oas/commit/a7d57d2765e80bf70f64b8b8e10265a9df2395aa))
* **runtime:** correlate output deltas with raw trace runs ([#1748](https://github.com/jeong-sik/oas/issues/1748)) ([b16fecc](https://github.com/jeong-sik/oas/commit/b16feccff374a84621ecd969e5e9026c64f6ec0f))
* **runtime:** project checkpoint deltas from replay windows ([#1738](https://github.com/jeong-sik/oas/issues/1738)) ([e0377ad](https://github.com/jeong-sik/oas/commit/e0377ad0e574366fe6c8511e70bbda03a23ff5e7))
* **runtime:** restore paused agent input ([#1746](https://github.com/jeong-sik/oas/issues/1746)) ([0550489](https://github.com/jeong-sik/oas/commit/055048954d75481221bea1eb78c0b526f311e97d))
* **runtime:** resume paused input agents ([#1724](https://github.com/jeong-sik/oas/issues/1724)) ([59a49d5](https://github.com/jeong-sik/oas/commit/59a49d5413a3ae9cb7ec708971f53e12dfe1cec0))
* **telemetry:** add SCA registry and audit tests for signal producer coverage ([1f57f3e](https://github.com/jeong-sik/oas/commit/1f57f3ebd1f2e678f638bcffe0ac0ebf87a61321))
* **telemetry:** per-turn typed telemetry events and bus ([7396ed6](https://github.com/jeong-sik/oas/commit/7396ed645cfb33a7f92df49f8c49806779044791))
* **telemetry:** RFC-OAS-019 Phase 1 — Streaming_summary at stream finalize ([#1578](https://github.com/jeong-sik/oas/issues/1578)) ([b26fed8](https://github.com/jeong-sik/oas/commit/b26fed80300016d987cbb5d0e9d817df9d02fe95))
* **telemetry:** wire ttfrc_ms and prefill_ms through patch_telemetry ([39f15ea](https://github.com/jeong-sik/oas/commit/39f15ea25dfa980375253af8f9b1c50815b17165))
* **telemetry:** wire ttfrc_ms and prefill_ms through patch_telemetry ([ef4ef9e](https://github.com/jeong-sik/oas/commit/ef4ef9e51d87411ec5a680a14385fcd613729974))
* **telemetry:** wire ttfrc_ms and prefill_ms to inference_telemetry ([98d5335](https://github.com/jeong-sik/oas/commit/98d5335fa0198e271dae98a420521f396af4934c))
* **timeout:** add provider timeout policy phases ([#1656](https://github.com/jeong-sik/oas/issues/1656)) ([540cb45](https://github.com/jeong-sik/oas/commit/540cb45918330e7ae274d2b919ef3c510425260d))
* **transport_claude_code:** expose stdout_idle_timeout_s on config ([#1459](https://github.com/jeong-sik/oas/issues/1459)) ([564e1e7](https://github.com/jeong-sik/oas/commit/564e1e71df332c159dccc5e8280c391e5053af94))
* **transport_codex_cli:** expose stdout_idle_timeout_s on config ([#1458](https://github.com/jeong-sik/oas/issues/1458)) ([64d3e1a](https://github.com/jeong-sik/oas/commit/64d3e1a90eb55f03f251d1b85a0dabe8b6aa2064))
* **transport_gemini_cli:** expose stdout_idle_timeout_s on config ([#1461](https://github.com/jeong-sik/oas/issues/1461)) ([5240005](https://github.com/jeong-sik/oas/commit/5240005c444adbec870ae032882d495af03674ca))
* **transport_kimi_cli:** expose stdout_idle_timeout_s on config ([#1460](https://github.com/jeong-sik/oas/issues/1460)) ([cbfd139](https://github.com/jeong-sik/oas/commit/cbfd139a90baadde01f9940e71b8ac2a8f706547))


### Bug Fixes

* add approval-required fail-closed policy ([#1630](https://github.com/jeong-sik/oas/issues/1630)) ([9f11c50](https://github.com/jeong-sik/oas/commit/9f11c506af1980554324e719427364a5b6461a42))
* add ollama cloud direct auth ([#1561](https://github.com/jeong-sik/oas/issues/1561)) ([9f265c1](https://github.com/jeong-sik/oas/commit/9f265c19fa477ab4810bff7ffca6083c652b8a95))
* **agent_tools:** preserve optional absence in correction ([#1789](https://github.com/jeong-sik/oas/issues/1789)) ([64773ea](https://github.com/jeong-sik/oas/commit/64773eabbed612dbf04a27d9a9b4b1e2d4061d69))
* **agent_tools:** restrict find_in_index fallback to non-User tool IDs ([#1568](https://github.com/jeong-sik/oas/issues/1568)) ([5e68d21](https://github.com/jeong-sik/oas/commit/5e68d21d4530af6c8991ff769921749f2287d6ab))
* **agent_turn:** make reserve_strategy_budget strategy match exhaustive ([#1522](https://github.com/jeong-sik/oas/issues/1522)) ([c6428ae](https://github.com/jeong-sik/oas/commit/c6428ae937bd378ff72228671adcb9d328495dc7))
* **agent-tools:** purge retired native tool ids ([#1796](https://github.com/jeong-sik/oas/issues/1796)) ([d40180d](https://github.com/jeong-sik/oas/commit/d40180d963aefed06b72faac2a1a7e097591023e))
* **agent:** gate context overflow auto retry ([#1553](https://github.com/jeong-sik/oas/issues/1553)) ([8ed4183](https://github.com/jeong-sik/oas/commit/8ed4183fb20d97fe7b4dcb704b9a3d29d674ef4c))
* **agent:** hydrate relocated tool results on resume ([#1766](https://github.com/jeong-sik/oas/issues/1766)) ([8a80296](https://github.com/jeong-sik/oas/commit/8a80296c8372606f488e44c46b0faa97ccfb583e))
* **agent:** index tool lookup paths ([#1592](https://github.com/jeong-sik/oas/issues/1592)) ([31bda07](https://github.com/jeong-sik/oas/commit/31bda07bd54c4e902b35030ec4d71547718bd1ca))
* **agent:** narrow runtime mcp per turn ([#1596](https://github.com/jeong-sik/oas/issues/1596)) ([36f7b37](https://github.com/jeong-sik/oas/commit/36f7b3779b01c38f3d69e94374c6d0812cb96403))
* **agent:** order checkpoint completion effects ([#1552](https://github.com/jeong-sik/oas/issues/1552)) ([cfbdabd](https://github.com/jeong-sik/oas/commit/cfbdabdf1c40493b36b023a0a97248ff939d571a))
* **agent:** publish content replacement events by default ([#1767](https://github.com/jeong-sik/oas/issues/1767)) ([c23e8ba](https://github.com/jeong-sik/oas/commit/c23e8ba0efdd2fa9d7759d9cf263100d97386250))
* **agent:** route registry discovery through http client ([#1560](https://github.com/jeong-sik/oas/issues/1560)) ([c0ada64](https://github.com/jeong-sik/oas/commit/c0ada64d5b89196a06969f292b77268f36e03bab))
* **agent:** stop periodic callbacks on cancellation ([#1447](https://github.com/jeong-sik/oas/issues/1447)) ([217ed2a](https://github.com/jeong-sik/oas/commit/217ed2a1833118dbf4dfb7ba7d1d25f92fbbb3f2))
* **agent:** surface Agent.run execution timeouts ([#1792](https://github.com/jeong-sik/oas/issues/1792)) ([37a096d](https://github.com/jeong-sik/oas/commit/37a096de62354e4e5857434966b8e7420595ecf5))
* **api_openai:** make is_zai_provider_config Provider.config match exhaustive ([#1523](https://github.com/jeong-sik/oas/issues/1523)) ([98814d1](https://github.com/jeong-sik/oas/commit/98814d1c56f151ca9b32b46d5e5639e09ab0869a))
* **api:** route legacy create_message through http client ([#1558](https://github.com/jeong-sik/oas/issues/1558)) ([a20ed9f](https://github.com/jeong-sik/oas/commit/a20ed9f812c30428e5168bc3aade3e1e86eceb92))
* **backend_gemini:** make has_tool_use content_block match exhaustive (N-of-M followup to [#1519](https://github.com/jeong-sik/oas/issues/1519)/[#1521](https://github.com/jeong-sik/oas/issues/1521)) ([#1525](https://github.com/jeong-sik/oas/issues/1525)) ([01d3276](https://github.com/jeong-sik/oas/commit/01d3276dcc48b37a9ee9ea42f1eee95c4b486e10))
* **backend_openai:** make Thinking-detection content_block matches exhaustive (2 sites, N-of-M followup) ([#1526](https://github.com/jeong-sik/oas/issues/1526)) ([591c961](https://github.com/jeong-sik/oas/commit/591c961fb8f14eb5f45c061774e0ba8fe465685b))
* **build:** resolve main build/test failures ([3381d9a](https://github.com/jeong-sik/oas/commit/3381d9abe8b37030e35888c659f7f254331b3a32))
* **build:** resolve main CI failures post-0.193.6 ([1b0593f](https://github.com/jeong-sik/oas/commit/1b0593f101ccf70aa443b364fa8f5d5c4ea5f54e))
* **capabilities:** keep reasoning effort overlay conservative ([44ef91e](https://github.com/jeong-sik/oas/commit/44ef91e7822792986e73c6356fa481dd3c46c173))
* **capabilities:** set Chat_template_kwargs for qwen3 ([#1614](https://github.com/jeong-sik/oas/issues/1614)) ([11181bb](https://github.com/jeong-sik/oas/commit/11181bb28147dc2b0e992885e9fabcba591f8b1c))
* **capability_manifest:** post-merge follow-up to [#1516](https://github.com/jeong-sik/oas/issues/1516) — Atomic.t + docstrings + test title ([#1529](https://github.com/jeong-sik/oas/issues/1529)) ([ea0023e](https://github.com/jeong-sik/oas/commit/ea0023ece0d9812995ebe8854bcfa1e8aa67f934))
* **capability_manifest:** remove duplicate doc text, fix SDK gate, apply ocamlformat ([5f248c1](https://github.com/jeong-sik/oas/commit/5f248c1d6f331a7e671942fc17afe2b877b7910f))
* **cascade:** gate provider attempts with throttle ([#1595](https://github.com/jeong-sik/oas/issues/1595)) ([30dcc69](https://github.com/jeong-sik/oas/commit/30dcc690119238418ba54e524b1032705cc01333))
* **cascade:** stop on TLS and local resource failures ([#1607](https://github.com/jeong-sik/oas/issues/1607)) ([1599ee0](https://github.com/jeong-sik/oas/commit/1599ee03516446007d96426f304bde4c3b3086d2))
* **cascade:** stop provider terminal fallthrough ([#1454](https://github.com/jeong-sik/oas/issues/1454)) ([15f3f0d](https://github.com/jeong-sik/oas/commit/15f3f0d9480d6d39df72f0c67403b590a1f17a97))
* **cascade:** use Eio mutex for provider health ([#1435](https://github.com/jeong-sik/oas/issues/1435)) ([a041368](https://github.com/jeong-sik/oas/commit/a04136828a78d45d2d6ecfed9563254b0bdbc170))
* **ci:** fill checkpoint delta usage fixture ([4624cf9](https://github.com/jeong-sik/oas/commit/4624cf936f1641bf72ea84033c9bb7a84f6bb7bc))
* **ci:** repair post-merge OAS main checks ([#1648](https://github.com/jeong-sik/oas/issues/1648)) ([39c1e76](https://github.com/jeong-sik/oas/commit/39c1e76ad851fef3f263781cbb19cef2e9cef839))
* **ci:** restore main build after usage update ([36425dc](https://github.com/jeong-sik/oas/commit/36425dc4e7f9a5d8453c11dff7765b7e177f618d))
* **ci:** restore main build after usage update ([9d8b912](https://github.com/jeong-sik/oas/commit/9d8b912743aedb567a0f65317ce2f3eaada27144))
* **collaboration:** make is_claimable claim_phase match exhaustive ([#1524](https://github.com/jeong-sik/oas/issues/1524)) ([a09983d](https://github.com/jeong-sik/oas/commit/a09983dd1c5006c764c9230d5a29ca5200bbfb00))
* **completion:** lower tool-choice fallback log noise ([#1608](https://github.com/jeong-sik/oas/issues/1608)) ([f53a814](https://github.com/jeong-sik/oas/commit/f53a814a7c1afec9d686c7410282d94be9abae4b))
* **content_block:** close 7 catch-all sites across pipeline + context_reducer + tool_use_recovery ([#1519](https://github.com/jeong-sik/oas/issues/1519)) ([c52b945](https://github.com/jeong-sik/oas/commit/c52b9451b6214a3fad94df79a61f1287505b446e))
* **context_reducer:** close 9 content_block catch-all sites in apply ([#1521](https://github.com/jeong-sik/oas/issues/1521)) ([92590ae](https://github.com/jeong-sik/oas/commit/92590ae10e99bbb929ad45705058964729555309))
* **context:** surface reducer repair diagnostics ([#1611](https://github.com/jeong-sik/oas/issues/1611)) ([688ee48](https://github.com/jeong-sik/oas/commit/688ee48efb3ffe227305b9ba52c8a0393f4bba03))
* **cost:** address Copilot review findings on the fail-closed path ([85f0e1f](https://github.com/jeong-sik/oas/commit/85f0e1fdd63c73a9712b2078b587e3c72551ce79))
* **cost:** fail closed when max_cost_usd is set + a turn ran an unpriced model ([dfa9bf1](https://github.com/jeong-sik/oas/commit/dfa9bf1c0ac363c571a2c4bc8556b413de47d02c))
* **cost:** fail closed when max_cost_usd is set + unpriced model ([6ec5725](https://github.com/jeong-sik/oas/commit/6ec5725f4e73093b5a7149bc467293d95b9390eb))
* **discovery:** validate env scan ports ([e6553c7](https://github.com/jeong-sik/oas/commit/e6553c7a8f8a10ef16883b49c15042071b89bce3))
* **dune:** add blank line between stanzas for ocamlformat ([6577be3](https://github.com/jeong-sik/oas/commit/6577be34f22b5ea9d98c3444ab3dba851b6a2e86))
* **dune:** remove orphaned (rule stanza from dune file ([1dc7af9](https://github.com/jeong-sik/oas/commit/1dc7af940a1e8c0093ea934a54b4cad208e48d14))
* **dune:** remove trailing blank line ([4df5435](https://github.com/jeong-sik/oas/commit/4df54355c85a7a34dd47b94e59b953aaa3ea8d43))
* **eval:** tag otel metric json exports ([#1423](https://github.com/jeong-sik/oas/issues/1423)) ([d610422](https://github.com/jeong-sik/oas/commit/d610422aec346db7df4b6da16da450ff50d578a2))
* expose cli stdout recovery metadata ([#1457](https://github.com/jeong-sik/oas/issues/1457)) ([31abd8e](https://github.com/jeong-sik/oas/commit/31abd8e84f790e8a0d4a30a66cffce11e8ba4526))
* harden exhaustive matches on closed variants (capabilities/streaming/agent) ([#1517](https://github.com/jeong-sik/oas/issues/1517)) ([1cd5d5a](https://github.com/jeong-sik/oas/commit/1cd5d5a9926a2010ca990f66739823e536a5f83d))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([e92553e](https://github.com/jeong-sik/oas/commit/e92553ee4379b9b33277848bd0fdf1f95e743b8e))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([51692a5](https://github.com/jeong-sik/oas/commit/51692a51a1eeb85fa087d7cab5f04b1ae3544dc5))
* **http_client:** propagate Eio.Cancel.Cancelled from drain_response_body ([#1871](https://github.com/jeong-sik/oas/issues/1871)) ([a141153](https://github.com/jeong-sik/oas/commit/a1411535ac6fc7db3d5a01840bbd60a2e3662b4a))
* **http_client:** replace pre-send header-size guard with 4xx response profiler ([#1820](https://github.com/jeong-sik/oas/issues/1820)) ([e44dee8](https://github.com/jeong-sik/oas/commit/e44dee8b91f3797436f3b7c4993a7b5497406ec6))
* **http:** classify empty trust anchors as local resource ([#1610](https://github.com/jeong-sik/oas/issues/1610)) ([4e86499](https://github.com/jeong-sik/oas/commit/4e86499f4c84b8d7793ae8eea878a96ea7e98d63))
* **llm_provider:** align Ollama streaming zero usage with non-streaming path ([#1848](https://github.com/jeong-sik/oas/issues/1848)) ([392902c](https://github.com/jeong-sik/oas/commit/392902c145cca0d8a481dccf0d05cd8e8c80e068))
* **llm_provider:** finish service-name migration, restore main green ([#1813](https://github.com/jeong-sik/oas/issues/1813)) ([b309bc1](https://github.com/jeong-sik/oas/commit/b309bc199f8a6f821dde5dca9379c0b8c22b86c6)), closes [#1811](https://github.com/jeong-sik/oas/issues/1811)
* **llm_provider:** Kimi backend mapping + capability rename to service names ([#1812](https://github.com/jeong-sik/oas/issues/1812)) ([27151c1](https://github.com/jeong-sik/oas/commit/27151c1c082467fb51cd7d1d77e192b0d4a87d03))
* **llm:** expose optional transport latency ([#1463](https://github.com/jeong-sik/oas/issues/1463)) ([eed15b4](https://github.com/jeong-sik/oas/commit/eed15b4cf3bbfc2d050b68188a6870af34766436))
* **llm:** lower confidence for fallback capability drift ([#1555](https://github.com/jeong-sik/oas/issues/1555)) ([26339df](https://github.com/jeong-sik/oas/commit/26339df8cacecb49cb33ddaf0ab88a56f85c9874))
* **main:** unblock 3 CI categories after [#1469](https://github.com/jeong-sik/oas/issues/1469)-[#1471](https://github.com/jeong-sik/oas/issues/1471) cascade ([ebfc95d](https://github.com/jeong-sik/oas/commit/ebfc95d6fb94c4e5c2a1c47af1380aa3f78fdbff))
* **main:** unblock 3 CI categories after [#1469](https://github.com/jeong-sik/oas/issues/1469)-[#1471](https://github.com/jeong-sik/oas/issues/1471) merge cascade ([73d727b](https://github.com/jeong-sik/oas/commit/73d727b45fa283bd2bda693678c6bf32687c010d))
* **mcp:** preserve builtin tool permissions ([#1438](https://github.com/jeong-sik/oas/issues/1438)) ([f568a07](https://github.com/jeong-sik/oas/commit/f568a07b653870984dc38722bb2c436c74b78693))
* **memory:** persist episodic procedural backends ([#1594](https://github.com/jeong-sik/oas/issues/1594)) ([e87b73f](https://github.com/jeong-sik/oas/commit/e87b73fd90e83a79c66cf974e02002ec9a5eb9a2))
* **memory:** preserve long-term backend compatibility ([#1628](https://github.com/jeong-sik/oas/issues/1628)) ([2c046ee](https://github.com/jeong-sik/oas/commit/2c046ee883ef0df26a7f8acbf12cce22d8f4bc78))
* **metrics:** aggregate streaming latency samples ([#1577](https://github.com/jeong-sik/oas/issues/1577)) ([a33ac78](https://github.com/jeong-sik/oas/commit/a33ac78895a87db2ff824a4d394c3a108d7807ad))
* **metrics:** deduplicate histogram bucket bounds in prometheus export ([#1564](https://github.com/jeong-sik/oas/issues/1564)) ([b2e8403](https://github.com/jeong-sik/oas/commit/b2e8403897a43660f3ed6ca17529e9c4b7cdebdc))
* **metrics:** emit Circuit_open directly from open-skip branch ([#1566](https://github.com/jeong-sik/oas/issues/1566)) ([8969475](https://github.com/jeong-sik/oas/commit/8969475eb8323d17400a8ba53632961173d0cad3))
* **metrics:** persist provider snapshots as json ([#1573](https://github.com/jeong-sik/oas/issues/1573)) ([d5037d2](https://github.com/jeong-sik/oas/commit/d5037d2346e7e13f5488a13495e65722b0a0a268))
* **metrics:** reject duplicate histogram buckets at register time ([#1643](https://github.com/jeong-sik/oas/issues/1643)) ([2db3378](https://github.com/jeong-sik/oas/commit/2db337807cc71e7bed79accb6d69e82f38029057))
* **metrics:** reject normalized-name collisions at register time ([#1570](https://github.com/jeong-sik/oas/issues/1570)) ([54d4b71](https://github.com/jeong-sik/oas/commit/54d4b71246d382aa8b3561c1a473e8efd9c48d9f))
* **metrics:** reject open-circuit snapshots without failure timestamp ([#1575](https://github.com/jeong-sik/oas/issues/1575)) ([fedcd13](https://github.com/jeong-sik/oas/commit/fedcd13664e32edd03f47b2763ad131cb7d2184c))
* **metrics:** support labeled histograms ([#1572](https://github.com/jeong-sik/oas/issues/1572)) ([e9f5ac6](https://github.com/jeong-sik/oas/commit/e9f5ac6dad19d380e5cb068caafe16eed7800ed6))
* **oas:** remove streaming body timeout cap ([#1930](https://github.com/jeong-sik/oas/issues/1930)) ([3252c4f](https://github.com/jeong-sik/oas/commit/3252c4fe538b82c9de93e92d3491cf0f042b8e78))
* **ollama:** preserve tool calls and avoid hard timeouts ([#1609](https://github.com/jeong-sik/oas/issues/1609)) ([64ec834](https://github.com/jeong-sik/oas/commit/64ec834685faf8f3ecc58817d6020f4aa6ab3126))
* **otel:** propagate trace context to provider calls ([#1576](https://github.com/jeong-sik/oas/issues/1576)) ([4060baa](https://github.com/jeong-sik/oas/commit/4060baac4b8f83468091f66011492c5b4981c7ad))
* **paths:** replace assert false with invalid_arg, document MCP env var ([#1597](https://github.com/jeong-sik/oas/issues/1597)) ([9efc99d](https://github.com/jeong-sik/oas/commit/9efc99d9a91ed8b7b9658bcc34beb2cbba5d3db0))
* **pipeline:** count runtime MCP tools for tool_choice ([#1593](https://github.com/jeong-sik/oas/issues/1593)) ([f488eab](https://github.com/jeong-sik/oas/commit/f488eabf5d756ffb4a258465663aaf74ea295f42))
* **pipeline:** drop unused agent arg from turn_ready_tool_names callers ([#1599](https://github.com/jeong-sik/oas/issues/1599)) ([7489923](https://github.com/jeong-sik/oas/commit/748992379de975e3b7d705bd29dd6815864ea927))
* **pipeline:** propagate Eio.Cancel.Cancelled from safe_publish ([#1881](https://github.com/jeong-sik/oas/issues/1881)) ([adc8312](https://github.com/jeong-sik/oas/commit/adc8312bc03e8fb76023df84d3558d3eb9d36fca))
* **pipeline:** reject invisible tool choice contracts ([#1579](https://github.com/jeong-sik/oas/issues/1579)) ([b33e626](https://github.com/jeong-sik/oas/commit/b33e6267b49913f7fd1b2c59253403d8bf3b24e5))
* **pipeline:** reuse accumulated usage in collect stage ([#1764](https://github.com/jeong-sik/oas/issues/1764)) ([fde41d7](https://github.com/jeong-sik/oas/commit/fde41d76d84ed01ff6a22598c2dd61fd5310d970))
* **plan:** make progress + is_done variant matches exhaustive ([#1518](https://github.com/jeong-sik/oas/issues/1518)) ([fd82743](https://github.com/jeong-sik/oas/commit/fd827431dc98a0f41fcf3dc7409f6c5bdc35e103))
* **provider_catalog:** fail-fast on unknown enum strings ([bb73cdc](https://github.com/jeong-sik/oas/commit/bb73cdc0d0db9afaae67c6d66a314d8169af7275))
* **provider_catalog:** fail-fast on unknown enum strings ([5a1cf67](https://github.com/jeong-sik/oas/commit/5a1cf674ff379871d20388b24f14fecc0e9b45d9))
* **provider:** apply ocamlformat to catalog overlay ([edb91b2](https://github.com/jeong-sik/oas/commit/edb91b29d35df8130d844e531a7492af89e3fefc))
* **provider:** apply ocamlformat to catalog overlay ([0b58dfe](https://github.com/jeong-sik/oas/commit/0b58dfecd53d0b5b7687051e3fcfea3588add8e1))
* **provider:** include context for empty HTTP errors ([#1582](https://github.com/jeong-sik/oas/issues/1582)) ([3b49c50](https://github.com/jeong-sik/oas/commit/3b49c5049faee63b045f641bfd4fb0cde0f6ebcd))
* **provider:** persist cascade health snapshots ([#1584](https://github.com/jeong-sik/oas/issues/1584)) ([4277673](https://github.com/jeong-sik/oas/commit/42776731e1ae0b6e505557c6912240f1550a3a3e))
* **provider:** remove api_key from Provider_config.t.headers ([#1817](https://github.com/jeong-sik/oas/issues/1817)) ([31b750c](https://github.com/jeong-sik/oas/commit/31b750ceec8993b06b740273e4609b68238fa474))
* **provider:** resolve runtime binding capabilities by config ([#1589](https://github.com/jeong-sik/oas/issues/1589)) ([da757ff](https://github.com/jeong-sik/oas/commit/da757ffc1ebc7a7c94c25370755b9a683b6ce412))
* **provider:** route provider intf through http client ([#1559](https://github.com/jeong-sik/oas/issues/1559)) ([b249b58](https://github.com/jeong-sik/oas/commit/b249b5887064e8da87b04697521742279103b72f))
* **provider:** surface OpenAI harness parse errors ([#1581](https://github.com/jeong-sik/oas/issues/1581)) ([42273ee](https://github.com/jeong-sik/oas/commit/42273ee4a4daf9a68aa5f3aa68b2c553be3cd05e))
* **raw-trace:** require explicit evidence roles ([#1650](https://github.com/jeong-sik/oas/issues/1650)) ([0f4ff62](https://github.com/jeong-sik/oas/commit/0f4ff62afe0ef23895c02ecbf1cbf882709439e3))
* recognize bare GLM model ids in capabilities ([#1763](https://github.com/jeong-sik/oas/issues/1763)) ([44b5ff9](https://github.com/jeong-sik/oas/commit/44b5ff94c719bf03de03d48b6ace82b4289b613e))
* reject removed provider catalog aliases ([#1822](https://github.com/jeong-sik/oas/issues/1822)) ([e725e2c](https://github.com/jeong-sik/oas/commit/e725e2ceaae87ab51d39c71287b65fd26b0b4ebb))
* **release:** automate agent_sdk.opam sync inside release-please workflow ([#1604](https://github.com/jeong-sik/oas/issues/1604)) ([4b00bdf](https://github.com/jeong-sik/oas/commit/4b00bdff217e6233ed15bcc722d9aed410c36eba))
* remove coordinator-specific OAS hardcoding ([#1639](https://github.com/jeong-sik/oas/issues/1639)) ([16f0075](https://github.com/jeong-sik/oas/commit/16f0075f5106c8013fc9305ded2d4a59e1ee1557))
* remove masc reference from comment to pass SDK independence check ([#1805](https://github.com/jeong-sik/oas/issues/1805)) ([5f76987](https://github.com/jeong-sik/oas/commit/5f76987d25a24b18370f81efc4fdc79208a7e546)), closes [#1791](https://github.com/jeong-sik/oas/issues/1791)
* remove mutable anti-patterns — O(n) append, dead mutable, debug printf ([#1619](https://github.com/jeong-sik/oas/issues/1619)) ([5f8e07b](https://github.com/jeong-sik/oas/commit/5f8e07b777285f59c111b1a866166604d5bc4a1a))
* resolve main build failures after release 0.193.6 ([#1532](https://github.com/jeong-sik/oas/issues/1532)) ([04447d4](https://github.com/jeong-sik/oas/commit/04447d4e1ded4ccc49bc101a209d404b206e1a10))
* restore green main (ocamlformat drift + SDK independence) ([#1852](https://github.com/jeong-sik/oas/issues/1852)) ([5a7ea9e](https://github.com/jeong-sik/oas/commit/5a7ea9e4d4e8dd9a1839143aad58a6a6d204c672))
* **retry:** stop cascade on account usage limit ([#1428](https://github.com/jeong-sik/oas/issues/1428)) ([5ead30d](https://github.com/jeong-sik/oas/commit/5ead30d0c0ca7b72de32b8767bcea411a844eaed))
* **review:** harden recent OAS follow-ups ([66cff92](https://github.com/jeong-sik/oas/commit/66cff92c1987db2f9f69141d8ca736f91f8c11be))
* **runtime:** absorb runtime_server_worker into runtime_server, restore runtime_evidence ([b09ace3](https://github.com/jeong-sik/oas/commit/b09ace33a5b19934aa5057a6e6955ad7c9c16609))
* **runtime:** absorb runtime_server_worker, restore runtime_evidence ([692a4c2](https://github.com/jeong-sik/oas/commit/692a4c2348d1240ed50fc9102c28c9081e61c2f1))
* **runtime:** centralize provider identity resolution ([#1831](https://github.com/jeong-sik/oas/issues/1831)) ([c05e3bd](https://github.com/jeong-sik/oas/commit/c05e3bdaff51e5487054786cab5d3c358edafee5))
* **scripts:** recognize release-please CHANGELOG header format ([#1513](https://github.com/jeong-sik/oas/issues/1513)) ([188efa6](https://github.com/jeong-sik/oas/commit/188efa67bdb95de6888f0c7660d236e3cc9de2df))
* **sessions_store:** return Error on malformed tool catalog instead of raising ([#1885](https://github.com/jeong-sik/oas/issues/1885)) ([cc30dea](https://github.com/jeong-sik/oas/commit/cc30deab29c7a1e65d20d6714649ec88b4bbbc34))
* **sessions:** drop stale parser helper signature ([#1670](https://github.com/jeong-sik/oas/issues/1670)) ([c701d0f](https://github.com/jeong-sik/oas/commit/c701d0f2de0ae01e91b83bea1e1f6491d4877603))
* **spec:** include input-required runtime phase ([#1769](https://github.com/jeong-sik/oas/issues/1769)) ([a341140](https://github.com/jeong-sik/oas/commit/a341140be322059c065b7f967924f33c2ec8ba49))
* **streaming:** drop empty-choices chunk without usage + repair fmt drift (main red after [#1866](https://github.com/jeong-sik/oas/issues/1866)) ([#1869](https://github.com/jeong-sik/oas/issues/1869)) ([91dcc47](https://github.com/jeong-sik/oas/commit/91dcc4761e0eb48d438ca64d030a1ed24dadb994))
* **streaming:** request + parse stream_options.include_usage so OpenAI-compatible streaming returns token usage ([#1866](https://github.com/jeong-sik/oas/issues/1866)) ([8f74ef1](https://github.com/jeong-sik/oas/commit/8f74ef155198f928572f15975b981bd8a8f39170))
* support MiMo token plan endpoint ([#1803](https://github.com/jeong-sik/oas/issues/1803)) ([3265348](https://github.com/jeong-sik/oas/commit/3265348268f7f42c7041d5eb81f161fa8fac7bf2))
* **telemetry:** emit context window usage ([#1583](https://github.com/jeong-sik/oas/issues/1583)) ([070b9d4](https://github.com/jeong-sik/oas/commit/070b9d46d764d45d56b506d7edd51188a529a779))
* **telemetry:** Event_bus.publish error handling + cache failure logging ([#1797](https://github.com/jeong-sik/oas/issues/1797)) ([b415057](https://github.com/jeong-sik/oas/commit/b415057bfd12b373e96de2cac361f922b5db2e4a))
* **telemetry:** propagate participant_name in Agent_output_delta, add structured logging ([#1794](https://github.com/jeong-sik/oas/issues/1794)) ([bab2c20](https://github.com/jeong-sik/oas/commit/bab2c2048a41eb8100ccfdd93166968fc4a4df58))
* **telemetry:** replace Eio.traceln with structured Log/Diag ([#1801](https://github.com/jeong-sik/oas/issues/1801)) ([a71c21b](https://github.com/jeong-sik/oas/commit/a71c21bcc91d18715277cc508a09ea5e438ac503))
* **telemetry:** wrap all Event_bus.publish in try/with + fix complete.ml Diag ([#1798](https://github.com/jeong-sik/oas/issues/1798)) ([0ce5b69](https://github.com/jeong-sik/oas/commit/0ce5b69104bb3687573f746c264f97861cdaafa3))
* **test:** make telemetry SCA repo-root discovery fail fast ([b9d4f57](https://github.com/jeong-sik/oas/commit/b9d4f57e21904658f7163e6fcfe52f0fb18b6072))
* **test:** remove duplicate test_telemetry_sca — superseded by test/telemetry_sca/ ([4bab73f](https://github.com/jeong-sik/oas/commit/4bab73fa6236b4e4b8fac6c3d027a206780b217a))
* **test:** repair CLI Runtime purge residue to restore compilation ([#1815](https://github.com/jeong-sik/oas/issues/1815)) ([503439b](https://github.com/jeong-sik/oas/commit/503439bbb6e6cf59264b8f774a95466b138180d8))
* tolerate release version markers ([#1708](https://github.com/jeong-sik/oas/issues/1708)) ([a5cd80f](https://github.com/jeong-sik/oas/commit/a5cd80fd1ffbc12ef3f5188d9c754ebd114958be))
* **tool_selector:** replace failwith with empty list for unimplemented LLM categorical classifier ([#1455](https://github.com/jeong-sik/oas/issues/1455)) ([496c329](https://github.com/jeong-sik/oas/commit/496c329bc4423fb1ddbe61507bbc6b5df1ba23a9))
* **tools:** enforce shell descriptor constraints ([#1602](https://github.com/jeong-sik/oas/issues/1602)) ([ce90f5d](https://github.com/jeong-sik/oas/commit/ce90f5d2575d54ec339bdfd2744c019a8849414f))
* **tools:** resolve legacy Read to visible ReadFile ([#1800](https://github.com/jeong-sik/oas/issues/1800)) ([17e1408](https://github.com/jeong-sik/oas/commit/17e1408c6849b46fd7139fb79dd28b470e84710a))
* type provider reasoning controls ([#1709](https://github.com/jeong-sik/oas/issues/1709)) ([a2bf6e1](https://github.com/jeong-sik/oas/commit/a2bf6e1c192f59717fe47f7f57f74458e3ffbcaa))
* **types:** preserve missing response usage ([#1449](https://github.com/jeong-sik/oas/issues/1449)) ([9639c92](https://github.com/jeong-sik/oas/commit/9639c9204c75c17d5c4e260111b8cb1be5ea257c))
* warn on invalid cli integer env ([#1456](https://github.com/jeong-sik/oas/issues/1456)) ([21dea98](https://github.com/jeong-sik/oas/commit/21dea9862fab506eb8983740c9c12951b32dbe94))
* **zai_catalog:** remove unsupported glm-5-code from coding auto-models ([92f108c](https://github.com/jeong-sik/oas/commit/92f108c6045b1e0065504ab059ac85a144db7f39))
* **zai_catalog:** remove unsupported glm-5-code from coding auto-models ([186e51c](https://github.com/jeong-sik/oas/commit/186e51c24e0e1eadc50840073396630cdb6b74b9))


### Performance Improvements

* **completion_contract:** build tool-lookup index lazily ([#1600](https://github.com/jeong-sik/oas/issues/1600)) ([e605a13](https://github.com/jeong-sik/oas/commit/e605a133d798a1e1e308727643b59692a5c2bc25))


### Code Refactoring

* remove migrated CDAL modules + façade re-exports (RFC-OAS-011 OAS-E PR-6) ([c5b120d](https://github.com/jeong-sik/oas/commit/c5b120d6f04eb8ea203dec2d1ffc5f8920656cdf))

## [0.203.2](https://github.com/jeong-sik/oas/compare/v0.203.1...v0.203.2) (2026-06-06)


### Miscellaneous Chores

* **oas:** format streaming timeout tests ([#1932](https://github.com/jeong-sik/oas/issues/1932)) ([4041753](https://github.com/jeong-sik/oas/commit/4041753b8f5c26b9013c4b7dec9435eea450fdc8))

## [0.203.1](https://github.com/jeong-sik/oas/compare/v0.203.0...v0.203.1) (2026-06-06)


### Bug Fixes

* **oas:** remove streaming body timeout cap ([#1930](https://github.com/jeong-sik/oas/issues/1930)) ([3252c4f](https://github.com/jeong-sik/oas/commit/3252c4fe538b82c9de93e92d3491cf0f042b8e78))

## [0.203.0](https://github.com/jeong-sik/oas/compare/v0.202.0...v0.203.0) (2026-06-04)


### ⚠ BREAKING CHANGES

* Error.A2a and the a2a_* constructors are removed from the public sdk_error API. Consumers matching Error.A2a must drop that arm. masc-mcp consumes agent_sdk via a git pin; its ~20 Error.A2a match arms will be compiler-forced to update when it adopts the new commit (separate follow-up).
* removes the public Completion_contract, Completion_contract_id, and Completion_contract_violation_detail modules from agent_sdk, the CompletionContractViolation error variant (Error.sdk_error / Error_domain.sdk_error_poly), and the Agent builder function with_required_tool_satisfaction. Consumers that matched on these types or relied on the SDK raising CompletionContractViolation for a missing required tool must remove those matchers and detect the condition themselves (inspect the response for a ToolUse block).
* remove migrated CDAL modules + façade re-exports (RFC-OAS-011 OAS-E PR-6)

### Features

* add runtime run window reads ([#1716](https://github.com/jeong-sik/oas/issues/1716)) ([c11b35b](https://github.com/jeong-sik/oas/commit/c11b35bb9142b5261d4b61daa324a8792fd85324))
* **agent_tool:** add typed child invocation ([#1744](https://github.com/jeong-sik/oas/issues/1744)) ([cbbd543](https://github.com/jeong-sik/oas/commit/cbbd5434cb92c97340bba4fd05ce2fe6c7f48310))
* **agent_tools:** remove CDAL builtin_descriptor fallback (RFC-OAS-009 v2 PR-B) ([39082f6](https://github.com/jeong-sik/oas/commit/39082f6005888209a5b16c6aaa0b60bd25df050f))
* **agent_tools:** remove CDAL builtin_descriptor fallback (RFC-OAS-009 v2 PR-B) ([41d0144](https://github.com/jeong-sik/oas/commit/41d0144f22fbfc36ea0da2c92487caff638bf807))
* **agent:** add disclosure_level for tool schema serialization ([#1508](https://github.com/jeong-sik/oas/issues/1508)) ([f48ccec](https://github.com/jeong-sik/oas/commit/f48ccec3d1f6045627bb51c913944b7b879baf4d))
* **agent:** add disclosure_resolver for per-turn adaptive disclosure ([#1511](https://github.com/jeong-sik/oas/issues/1511)) ([7ed9c05](https://github.com/jeong-sik/oas/commit/7ed9c05260dce7b813bfaf524a2799573eb6479d))
* **agent:** add turn durability checkpoints ([#1550](https://github.com/jeong-sik/oas/issues/1550)) ([393ff0c](https://github.com/jeong-sik/oas/commit/393ff0c432734c6e2c471fd78b6ebba0040b48aa))
* **agent:** idle/progress-aware execution timeout ([#1823](https://github.com/jeong-sik/oas/issues/1823)) ([886c4d1](https://github.com/jeong-sik/oas/commit/886c4d1c8b5d03cab030266008fa5b28cdd5d847))
* **agent:** index tool dispatch lookups ([#1557](https://github.com/jeong-sik/oas/issues/1557)) ([b7ea8e6](https://github.com/jeong-sik/oas/commit/b7ea8e6b00dd5ad1d3f4bbadeb26a071228c52f5))
* **agent:** pause on async elicitation ([#1722](https://github.com/jeong-sik/oas/issues/1722)) ([b40e955](https://github.com/jeong-sik/oas/commit/b40e9557ad3f404c692159d3fd018da368f9c63e))
* **base:** Tool_id closed Variant identifier (RFC-OAS-008 PR-2/5) ([3c67d1e](https://github.com/jeong-sik/oas/commit/3c67d1e510fca49692937effd08cefc89aebd079))
* **base:** Tool_id closed Variant identifier (RFC-OAS-008 PR-2/5) ([8f413f8](https://github.com/jeong-sik/oas/commit/8f413f8a063273524f4fd2a22d14e69b1934709e))
* **bench:** TTFT distribution bench + SLO doc (RFC-OAS-020 PR-1b) ([#1625](https://github.com/jeong-sik/oas/issues/1625)) ([2ef4b25](https://github.com/jeong-sik/oas/commit/2ef4b25eade1d4fd6b6292e99842a97c8a78634b))
* bridge runtime windows to sync replay ([#1720](https://github.com/jeong-sik/oas/issues/1720)) ([1b98e4d](https://github.com/jeong-sik/oas/commit/1b98e4dcf6368fea5b452967df67eaa822969e5c))
* **capabilities:** register Qwen_3 family in static model route ladder ([#1787](https://github.com/jeong-sik/oas/issues/1787)) ([c7f97cc](https://github.com/jeong-sik/oas/commit/c7f97cc827cf5034918ec939d0e105641b5c6b7e))
* **capability_manifest:** add set_global / clear_global runtime override ([#1516](https://github.com/jeong-sik/oas/issues/1516)) ([c3a786f](https://github.com/jeong-sik/oas/commit/c3a786f36f6fc37306c1f8932267b9f684180ed5))
* **ci:** boundary-lint for core→CDAL zero dependency (RFC-OAS-009 v2 PR-D) ([b0c7a44](https://github.com/jeong-sik/oas/commit/b0c7a4484fe1a6514c1a308e9ce01581e356c81a))
* **ci:** boundary-lint for core→CDAL zero dependency (RFC-OAS-009 v2 PR-D) ([f53a3f5](https://github.com/jeong-sik/oas/commit/f53a3f550a9b27848cc58e52ed024036cb86f281))
* **ci:** expand boundary-lint to 20 CDAL prefixes (RFC-OAS-011 OAS-E PR-1) ([0a306ce](https://github.com/jeong-sik/oas/commit/0a306ce0f30e28d44e780eedb68551d2ded634a3))
* **ci:** expand boundary-lint to 20 CDAL prefixes (RFC-OAS-011 OAS-E PR-1) ([e189ed7](https://github.com/jeong-sik/oas/commit/e189ed75b1d25b97a6bf9c4d8536d7c5b79188bc))
* **complete:** add body_timeout_s to non-streaming complete + complete_with_retry ([#1622](https://github.com/jeong-sik/oas/issues/1622)) ([79262f3](https://github.com/jeong-sik/oas/commit/79262f374d70798cc76dc43f1503c5f329dfe204))
* **completion-contract:** add typed violation_detail with satisfying_tools ([#1642](https://github.com/jeong-sik/oas/issues/1642)) ([42c125f](https://github.com/jeong-sik/oas/commit/42c125f6e31c422dcf387a3546a0ffdbcea1bde0))
* **error:** carry completion contract violation detail ([#1660](https://github.com/jeong-sik/oas/issues/1660)) ([609600d](https://github.com/jeong-sik/oas/commit/609600d896af320868b9578d278e5752f8f28075))
* **eval:** gate code snippet adoption criteria ([#1751](https://github.com/jeong-sik/oas/issues/1751)) ([2a3e688](https://github.com/jeong-sik/oas/commit/2a3e688bbc03785e2232447e4b88f3d6963b3dd4))
* extract agent_sdk.protocol sublibrary and resolve circular dependencies ([#1896](https://github.com/jeong-sik/oas/issues/1896)) ([de16a44](https://github.com/jeong-sik/oas/commit/de16a4497dd76ad3493608c110174f579a20dce8))
* **gemini:** surface unsupported disable_parallel_tool_use (WP9 gap) ([#1840](https://github.com/jeong-sik/oas/issues/1840)) ([7ba14b4](https://github.com/jeong-sik/oas/commit/7ba14b44da70a2fb714a6ac10ae2f27ffd5b2601))
* **http_client:** diagnose oversized request headers that CDN proxies reject ([#1819](https://github.com/jeong-sik/oas/issues/1819)) ([03a07b8](https://github.com/jeong-sik/oas/commit/03a07b8d6485f2e121868d8e4e0f938e1bb8987c))
* **lib:** add Cognitive_event typed schema (RFC-0036 PR-B) ([#1451](https://github.com/jeong-sik/oas/issues/1451)) ([f848e75](https://github.com/jeong-sik/oas/commit/f848e75a298827722d5f6cff8162f954ae20f974))
* **llm_provider:** Fd_throttle_hook injection point (RFC-0101 PR-3) ([#1618](https://github.com/jeong-sik/oas/issues/1618)) ([29cbbc5](https://github.com/jeong-sik/oas/commit/29cbbc5b1d1593ba77e9c9a6cccac716051f88c2))
* **llm_provider:** RFC-0058 Phase B — CLI transport factory ([#1520](https://github.com/jeong-sik/oas/issues/1520)) ([41e87e0](https://github.com/jeong-sik/oas/commit/41e87e0cd1fe4d57c4f627958b34fcf419839745))
* **llm_provider:** typed TTFT capture + prefill_ms field (RFC-OAS-020 PR-1a) ([#1620](https://github.com/jeong-sik/oas/issues/1620)) ([37b4a0c](https://github.com/jeong-sik/oas/commit/37b4a0cd2a0303282579641038858f222a115547))
* **llm_provider:** Visual_first modality ordering for Gemma 4 ([cf94ce9](https://github.com/jeong-sik/oas/commit/cf94ce9a95deaa34270f3f3c1cb75347ba5ea59d))
* **llm_provider:** Visual_first modality ordering for Gemma 4 ([791eee8](https://github.com/jeong-sik/oas/commit/791eee8b6266fe91d762f76544ae525bb4992f7c))
* **llm_provider:** wire ttfrc_ms and prefill_ms into inference_telemetry ([809b63a](https://github.com/jeong-sik/oas/commit/809b63a5c4dfbeed427d660295de26df3ed928eb))
* **mcp_schema:** remove descriptor_for_builtin_tool alias (RFC-OAS-009 v2 PR-C) ([ffb8aff](https://github.com/jeong-sik/oas/commit/ffb8aff3a3bac4bdfce823fe41ca176226ba2f13))
* **mcp_schema:** remove descriptor_for_builtin_tool alias (RFC-OAS-009 v2 PR-C) ([2c41611](https://github.com/jeong-sik/oas/commit/2c416118433aa703f97f1e891b5671e9f67bb931))
* **memory:** expose typed long-term retrieve result ([#1627](https://github.com/jeong-sik/oas/issues/1627)) ([0be7c3c](https://github.com/jeong-sik/oas/commit/0be7c3c37fdbfcf69f8c93cdce0514fddedae7e3))
* **metrics:** add Prometheus text export ([#1556](https://github.com/jeong-sik/oas/issues/1556)) ([fc02639](https://github.com/jeong-sik/oas/commit/fc02639b940afe6714f207f08c41dc393e112260))
* **metrics:** emit cascade circuit state ([#1563](https://github.com/jeong-sik/oas/issues/1563)) ([1f69740](https://github.com/jeong-sik/oas/commit/1f69740fb423cc68c04b7d300597a9f164499c84))
* **oas:** TLA+ CI gate + AgentCancellation spec + lifecycle_status yojson ([#1467](https://github.com/jeong-sik/oas/issues/1467)) ([7cd282f](https://github.com/jeong-sik/oas/commit/7cd282fed27ef6aa0637a6a12ca9356621619039))
* persist runtime input-required state ([#1714](https://github.com/jeong-sik/oas/issues/1714)) ([656ac61](https://github.com/jeong-sik/oas/commit/656ac61937810763a600a268bd671c7fe8beba30))
* **pipeline:** remove forced-tool-use enforcement (RFC-OAS-025 Option A, stage 1) ([#1864](https://github.com/jeong-sik/oas/issues/1864)) ([81f97b8](https://github.com/jeong-sik/oas/commit/81f97b8441b807b78572fa219d0c935ee87e0f15))
* preserve provider timeout evidence ([#1632](https://github.com/jeong-sik/oas/issues/1632)) ([5001b3b](https://github.com/jeong-sik/oas/commit/5001b3b866fce8a31dc5e6f78a654d8ae6e560e5))
* **provider:** add external provider catalog overlay ([35241e9](https://github.com/jeong-sik/oas/commit/35241e9a82ce30360449f19a115d6589041f8f79))
* **provider:** canonical tool projection wired into turn pipeline (WP8 Inc1, RFC-OAS-024) ([#1846](https://github.com/jeong-sik/oas/issues/1846)) ([a04e0b4](https://github.com/jeong-sik/oas/commit/a04e0b45e13195cab4f59f11d22e0c2dcf31fdde))
* **provider:** expose runtime bindings ([#1585](https://github.com/jeong-sik/oas/issues/1585)) ([dbabd5c](https://github.com/jeong-sik/oas/commit/dbabd5ca7daf3ab25a861973ba346faddd442201))
* **provider:** load external provider catalog ([a13a1d0](https://github.com/jeong-sik/oas/commit/a13a1d0caa6baf0eaf77cfaa1e0ebdbed380d490))
* **provider:** map transport errors to typed provider errors ([#1448](https://github.com/jeong-sik/oas/issues/1448)) ([e804755](https://github.com/jeong-sik/oas/commit/e804755e3fb4ce81c33cd2b32880b206c588c28a))
* **provider:** per-function strict mode on tool_schema (WP2) ([#1837](https://github.com/jeong-sik/oas/issues/1837)) ([61755b2](https://github.com/jeong-sik/oas/commit/61755b286d356ff3ffb11a031c0ed27cb5d5e8d3))
* **provider:** structured tool_result content blocks (WP4) ([#1839](https://github.com/jeong-sik/oas/issues/1839)) ([95f74ec](https://github.com/jeong-sik/oas/commit/95f74ece5c7ed9c06b7231f2e6e6d208d91e3248))
* **provider:** tool calling 현대화 기반 — backend rename + stop_reason (WP0/WP1) ([#1835](https://github.com/jeong-sik/oas/issues/1835)) ([a1d6b4d](https://github.com/jeong-sik/oas/commit/a1d6b4db64a6e2c7890e5fcb67b9040fd68ff503))
* **raw-trace:** add evidence role validation seam ([#1647](https://github.com/jeong-sik/oas/issues/1647)) ([f9f1c9f](https://github.com/jeong-sik/oas/commit/f9f1c9fad7c36eac04c95ac17fda0b001a58ff00))
* **raw-trace:** expose evidence role summaries ([#1653](https://github.com/jeong-sik/oas/issues/1653)) ([9d2b2e5](https://github.com/jeong-sik/oas/commit/9d2b2e5c2739135d73f7aecdbcf04ed8fceff4c3))
* **raw-trace:** expose validation evidence roles ([#1658](https://github.com/jeong-sik/oas/issues/1658)) ([6d79276](https://github.com/jeong-sik/oas/commit/6d79276611261d0c64a8beebdf2e673e38cba74e))
* **release:** adopt release-please for version + CHANGELOG automation ([fd9931d](https://github.com/jeong-sik/oas/commit/fd9931d7f60f3b966140fdc700fd29c982ac5ea5))
* **release:** adopt release-please for version + CHANGELOG automation ([058ea4b](https://github.com/jeong-sik/oas/commit/058ea4bea2205b21854960f7cd4cb885043a9de8))
* remove dead A2a error variant from sdk_error ([#1903](https://github.com/jeong-sik/oas/issues/1903)) ([7edc393](https://github.com/jeong-sik/oas/commit/7edc39375d6260943c972bd510be4b51af9c4cc3))
* remove dead completion-contract machinery (RFC-OAS-025 Option A Stage 2) ([#1867](https://github.com/jeong-sik/oas/issues/1867)) ([a7d57d2](https://github.com/jeong-sik/oas/commit/a7d57d2765e80bf70f64b8b8e10265a9df2395aa))
* **runtime:** correlate output deltas with raw trace runs ([#1748](https://github.com/jeong-sik/oas/issues/1748)) ([b16fecc](https://github.com/jeong-sik/oas/commit/b16feccff374a84621ecd969e5e9026c64f6ec0f))
* **runtime:** project checkpoint deltas from replay windows ([#1738](https://github.com/jeong-sik/oas/issues/1738)) ([e0377ad](https://github.com/jeong-sik/oas/commit/e0377ad0e574366fe6c8511e70bbda03a23ff5e7))
* **runtime:** restore paused agent input ([#1746](https://github.com/jeong-sik/oas/issues/1746)) ([0550489](https://github.com/jeong-sik/oas/commit/055048954d75481221bea1eb78c0b526f311e97d))
* **runtime:** resume paused input agents ([#1724](https://github.com/jeong-sik/oas/issues/1724)) ([59a49d5](https://github.com/jeong-sik/oas/commit/59a49d5413a3ae9cb7ec708971f53e12dfe1cec0))
* **telemetry:** add SCA registry and audit tests for signal producer coverage ([1f57f3e](https://github.com/jeong-sik/oas/commit/1f57f3ebd1f2e678f638bcffe0ac0ebf87a61321))
* **telemetry:** per-turn typed telemetry events and bus ([7396ed6](https://github.com/jeong-sik/oas/commit/7396ed645cfb33a7f92df49f8c49806779044791))
* **telemetry:** RFC-OAS-019 Phase 1 — Streaming_summary at stream finalize ([#1578](https://github.com/jeong-sik/oas/issues/1578)) ([b26fed8](https://github.com/jeong-sik/oas/commit/b26fed80300016d987cbb5d0e9d817df9d02fe95))
* **telemetry:** wire ttfrc_ms and prefill_ms through patch_telemetry ([39f15ea](https://github.com/jeong-sik/oas/commit/39f15ea25dfa980375253af8f9b1c50815b17165))
* **telemetry:** wire ttfrc_ms and prefill_ms through patch_telemetry ([ef4ef9e](https://github.com/jeong-sik/oas/commit/ef4ef9e51d87411ec5a680a14385fcd613729974))
* **telemetry:** wire ttfrc_ms and prefill_ms to inference_telemetry ([98d5335](https://github.com/jeong-sik/oas/commit/98d5335fa0198e271dae98a420521f396af4934c))
* **timeout:** add provider timeout policy phases ([#1656](https://github.com/jeong-sik/oas/issues/1656)) ([540cb45](https://github.com/jeong-sik/oas/commit/540cb45918330e7ae274d2b919ef3c510425260d))
* **transport_claude_code:** expose stdout_idle_timeout_s on config ([#1459](https://github.com/jeong-sik/oas/issues/1459)) ([564e1e7](https://github.com/jeong-sik/oas/commit/564e1e71df332c159dccc5e8280c391e5053af94))
* **transport_codex_cli:** expose stdout_idle_timeout_s on config ([#1458](https://github.com/jeong-sik/oas/issues/1458)) ([64d3e1a](https://github.com/jeong-sik/oas/commit/64d3e1a90eb55f03f251d1b85a0dabe8b6aa2064))
* **transport_gemini_cli:** expose stdout_idle_timeout_s on config ([#1461](https://github.com/jeong-sik/oas/issues/1461)) ([5240005](https://github.com/jeong-sik/oas/commit/5240005c444adbec870ae032882d495af03674ca))
* **transport_kimi_cli:** expose stdout_idle_timeout_s on config ([#1460](https://github.com/jeong-sik/oas/issues/1460)) ([cbfd139](https://github.com/jeong-sik/oas/commit/cbfd139a90baadde01f9940e71b8ac2a8f706547))


### Bug Fixes

* add approval-required fail-closed policy ([#1630](https://github.com/jeong-sik/oas/issues/1630)) ([9f11c50](https://github.com/jeong-sik/oas/commit/9f11c506af1980554324e719427364a5b6461a42))
* add ollama cloud direct auth ([#1561](https://github.com/jeong-sik/oas/issues/1561)) ([9f265c1](https://github.com/jeong-sik/oas/commit/9f265c19fa477ab4810bff7ffca6083c652b8a95))
* **agent_tools:** preserve optional absence in correction ([#1789](https://github.com/jeong-sik/oas/issues/1789)) ([64773ea](https://github.com/jeong-sik/oas/commit/64773eabbed612dbf04a27d9a9b4b1e2d4061d69))
* **agent_tools:** restrict find_in_index fallback to non-User tool IDs ([#1568](https://github.com/jeong-sik/oas/issues/1568)) ([5e68d21](https://github.com/jeong-sik/oas/commit/5e68d21d4530af6c8991ff769921749f2287d6ab))
* **agent_turn:** make reserve_strategy_budget strategy match exhaustive ([#1522](https://github.com/jeong-sik/oas/issues/1522)) ([c6428ae](https://github.com/jeong-sik/oas/commit/c6428ae937bd378ff72228671adcb9d328495dc7))
* **agent-tools:** purge retired native tool ids ([#1796](https://github.com/jeong-sik/oas/issues/1796)) ([d40180d](https://github.com/jeong-sik/oas/commit/d40180d963aefed06b72faac2a1a7e097591023e))
* **agent:** gate context overflow auto retry ([#1553](https://github.com/jeong-sik/oas/issues/1553)) ([8ed4183](https://github.com/jeong-sik/oas/commit/8ed4183fb20d97fe7b4dcb704b9a3d29d674ef4c))
* **agent:** hydrate relocated tool results on resume ([#1766](https://github.com/jeong-sik/oas/issues/1766)) ([8a80296](https://github.com/jeong-sik/oas/commit/8a80296c8372606f488e44c46b0faa97ccfb583e))
* **agent:** index tool lookup paths ([#1592](https://github.com/jeong-sik/oas/issues/1592)) ([31bda07](https://github.com/jeong-sik/oas/commit/31bda07bd54c4e902b35030ec4d71547718bd1ca))
* **agent:** narrow runtime mcp per turn ([#1596](https://github.com/jeong-sik/oas/issues/1596)) ([36f7b37](https://github.com/jeong-sik/oas/commit/36f7b3779b01c38f3d69e94374c6d0812cb96403))
* **agent:** order checkpoint completion effects ([#1552](https://github.com/jeong-sik/oas/issues/1552)) ([cfbdabd](https://github.com/jeong-sik/oas/commit/cfbdabdf1c40493b36b023a0a97248ff939d571a))
* **agent:** publish content replacement events by default ([#1767](https://github.com/jeong-sik/oas/issues/1767)) ([c23e8ba](https://github.com/jeong-sik/oas/commit/c23e8ba0efdd2fa9d7759d9cf263100d97386250))
* **agent:** route registry discovery through http client ([#1560](https://github.com/jeong-sik/oas/issues/1560)) ([c0ada64](https://github.com/jeong-sik/oas/commit/c0ada64d5b89196a06969f292b77268f36e03bab))
* **agent:** stop periodic callbacks on cancellation ([#1447](https://github.com/jeong-sik/oas/issues/1447)) ([217ed2a](https://github.com/jeong-sik/oas/commit/217ed2a1833118dbf4dfb7ba7d1d25f92fbbb3f2))
* **agent:** surface Agent.run execution timeouts ([#1792](https://github.com/jeong-sik/oas/issues/1792)) ([37a096d](https://github.com/jeong-sik/oas/commit/37a096de62354e4e5857434966b8e7420595ecf5))
* **api_openai:** make is_zai_provider_config Provider.config match exhaustive ([#1523](https://github.com/jeong-sik/oas/issues/1523)) ([98814d1](https://github.com/jeong-sik/oas/commit/98814d1c56f151ca9b32b46d5e5639e09ab0869a))
* **api:** route legacy create_message through http client ([#1558](https://github.com/jeong-sik/oas/issues/1558)) ([a20ed9f](https://github.com/jeong-sik/oas/commit/a20ed9f812c30428e5168bc3aade3e1e86eceb92))
* **backend_gemini:** make has_tool_use content_block match exhaustive (N-of-M followup to [#1519](https://github.com/jeong-sik/oas/issues/1519)/[#1521](https://github.com/jeong-sik/oas/issues/1521)) ([#1525](https://github.com/jeong-sik/oas/issues/1525)) ([01d3276](https://github.com/jeong-sik/oas/commit/01d3276dcc48b37a9ee9ea42f1eee95c4b486e10))
* **backend_openai:** make Thinking-detection content_block matches exhaustive (2 sites, N-of-M followup) ([#1526](https://github.com/jeong-sik/oas/issues/1526)) ([591c961](https://github.com/jeong-sik/oas/commit/591c961fb8f14eb5f45c061774e0ba8fe465685b))
* **build:** resolve main build/test failures ([3381d9a](https://github.com/jeong-sik/oas/commit/3381d9abe8b37030e35888c659f7f254331b3a32))
* **build:** resolve main CI failures post-0.193.6 ([1b0593f](https://github.com/jeong-sik/oas/commit/1b0593f101ccf70aa443b364fa8f5d5c4ea5f54e))
* **capabilities:** keep reasoning effort overlay conservative ([44ef91e](https://github.com/jeong-sik/oas/commit/44ef91e7822792986e73c6356fa481dd3c46c173))
* **capabilities:** set Chat_template_kwargs for qwen3 ([#1614](https://github.com/jeong-sik/oas/issues/1614)) ([11181bb](https://github.com/jeong-sik/oas/commit/11181bb28147dc2b0e992885e9fabcba591f8b1c))
* **capability_manifest:** post-merge follow-up to [#1516](https://github.com/jeong-sik/oas/issues/1516) — Atomic.t + docstrings + test title ([#1529](https://github.com/jeong-sik/oas/issues/1529)) ([ea0023e](https://github.com/jeong-sik/oas/commit/ea0023ece0d9812995ebe8854bcfa1e8aa67f934))
* **capability_manifest:** remove duplicate doc text, fix SDK gate, apply ocamlformat ([5f248c1](https://github.com/jeong-sik/oas/commit/5f248c1d6f331a7e671942fc17afe2b877b7910f))
* **cascade:** gate provider attempts with throttle ([#1595](https://github.com/jeong-sik/oas/issues/1595)) ([30dcc69](https://github.com/jeong-sik/oas/commit/30dcc690119238418ba54e524b1032705cc01333))
* **cascade:** stop on TLS and local resource failures ([#1607](https://github.com/jeong-sik/oas/issues/1607)) ([1599ee0](https://github.com/jeong-sik/oas/commit/1599ee03516446007d96426f304bde4c3b3086d2))
* **cascade:** stop provider terminal fallthrough ([#1454](https://github.com/jeong-sik/oas/issues/1454)) ([15f3f0d](https://github.com/jeong-sik/oas/commit/15f3f0d9480d6d39df72f0c67403b590a1f17a97))
* **cascade:** use Eio mutex for provider health ([#1435](https://github.com/jeong-sik/oas/issues/1435)) ([a041368](https://github.com/jeong-sik/oas/commit/a04136828a78d45d2d6ecfed9563254b0bdbc170))
* **ci:** fill checkpoint delta usage fixture ([4624cf9](https://github.com/jeong-sik/oas/commit/4624cf936f1641bf72ea84033c9bb7a84f6bb7bc))
* **ci:** repair post-merge OAS main checks ([#1648](https://github.com/jeong-sik/oas/issues/1648)) ([39c1e76](https://github.com/jeong-sik/oas/commit/39c1e76ad851fef3f263781cbb19cef2e9cef839))
* **ci:** restore main build after usage update ([36425dc](https://github.com/jeong-sik/oas/commit/36425dc4e7f9a5d8453c11dff7765b7e177f618d))
* **ci:** restore main build after usage update ([9d8b912](https://github.com/jeong-sik/oas/commit/9d8b912743aedb567a0f65317ce2f3eaada27144))
* **collaboration:** make is_claimable claim_phase match exhaustive ([#1524](https://github.com/jeong-sik/oas/issues/1524)) ([a09983d](https://github.com/jeong-sik/oas/commit/a09983dd1c5006c764c9230d5a29ca5200bbfb00))
* **completion:** lower tool-choice fallback log noise ([#1608](https://github.com/jeong-sik/oas/issues/1608)) ([f53a814](https://github.com/jeong-sik/oas/commit/f53a814a7c1afec9d686c7410282d94be9abae4b))
* **content_block:** close 7 catch-all sites across pipeline + context_reducer + tool_use_recovery ([#1519](https://github.com/jeong-sik/oas/issues/1519)) ([c52b945](https://github.com/jeong-sik/oas/commit/c52b9451b6214a3fad94df79a61f1287505b446e))
* **context_reducer:** close 9 content_block catch-all sites in apply ([#1521](https://github.com/jeong-sik/oas/issues/1521)) ([92590ae](https://github.com/jeong-sik/oas/commit/92590ae10e99bbb929ad45705058964729555309))
* **context:** surface reducer repair diagnostics ([#1611](https://github.com/jeong-sik/oas/issues/1611)) ([688ee48](https://github.com/jeong-sik/oas/commit/688ee48efb3ffe227305b9ba52c8a0393f4bba03))
* **cost:** address Copilot review findings on the fail-closed path ([85f0e1f](https://github.com/jeong-sik/oas/commit/85f0e1fdd63c73a9712b2078b587e3c72551ce79))
* **cost:** fail closed when max_cost_usd is set + a turn ran an unpriced model ([dfa9bf1](https://github.com/jeong-sik/oas/commit/dfa9bf1c0ac363c571a2c4bc8556b413de47d02c))
* **cost:** fail closed when max_cost_usd is set + unpriced model ([6ec5725](https://github.com/jeong-sik/oas/commit/6ec5725f4e73093b5a7149bc467293d95b9390eb))
* **discovery:** validate env scan ports ([e6553c7](https://github.com/jeong-sik/oas/commit/e6553c7a8f8a10ef16883b49c15042071b89bce3))
* **dune:** add blank line between stanzas for ocamlformat ([6577be3](https://github.com/jeong-sik/oas/commit/6577be34f22b5ea9d98c3444ab3dba851b6a2e86))
* **dune:** remove orphaned (rule stanza from dune file ([1dc7af9](https://github.com/jeong-sik/oas/commit/1dc7af940a1e8c0093ea934a54b4cad208e48d14))
* **dune:** remove trailing blank line ([4df5435](https://github.com/jeong-sik/oas/commit/4df54355c85a7a34dd47b94e59b953aaa3ea8d43))
* **eval:** tag otel metric json exports ([#1423](https://github.com/jeong-sik/oas/issues/1423)) ([d610422](https://github.com/jeong-sik/oas/commit/d610422aec346db7df4b6da16da450ff50d578a2))
* expose cli stdout recovery metadata ([#1457](https://github.com/jeong-sik/oas/issues/1457)) ([31abd8e](https://github.com/jeong-sik/oas/commit/31abd8e84f790e8a0d4a30a66cffce11e8ba4526))
* harden exhaustive matches on closed variants (capabilities/streaming/agent) ([#1517](https://github.com/jeong-sik/oas/issues/1517)) ([1cd5d5a](https://github.com/jeong-sik/oas/commit/1cd5d5a9926a2010ca990f66739823e536a5f83d))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([e92553e](https://github.com/jeong-sik/oas/commit/e92553ee4379b9b33277848bd0fdf1f95e743b8e))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([51692a5](https://github.com/jeong-sik/oas/commit/51692a51a1eeb85fa087d7cab5f04b1ae3544dc5))
* **http_client:** propagate Eio.Cancel.Cancelled from drain_response_body ([#1871](https://github.com/jeong-sik/oas/issues/1871)) ([a141153](https://github.com/jeong-sik/oas/commit/a1411535ac6fc7db3d5a01840bbd60a2e3662b4a))
* **http_client:** replace pre-send header-size guard with 4xx response profiler ([#1820](https://github.com/jeong-sik/oas/issues/1820)) ([e44dee8](https://github.com/jeong-sik/oas/commit/e44dee8b91f3797436f3b7c4993a7b5497406ec6))
* **http:** classify empty trust anchors as local resource ([#1610](https://github.com/jeong-sik/oas/issues/1610)) ([4e86499](https://github.com/jeong-sik/oas/commit/4e86499f4c84b8d7793ae8eea878a96ea7e98d63))
* **llm_provider:** align Ollama streaming zero usage with non-streaming path ([#1848](https://github.com/jeong-sik/oas/issues/1848)) ([392902c](https://github.com/jeong-sik/oas/commit/392902c145cca0d8a481dccf0d05cd8e8c80e068))
* **llm_provider:** finish service-name migration, restore main green ([#1813](https://github.com/jeong-sik/oas/issues/1813)) ([b309bc1](https://github.com/jeong-sik/oas/commit/b309bc199f8a6f821dde5dca9379c0b8c22b86c6)), closes [#1811](https://github.com/jeong-sik/oas/issues/1811)
* **llm_provider:** Kimi backend mapping + capability rename to service names ([#1812](https://github.com/jeong-sik/oas/issues/1812)) ([27151c1](https://github.com/jeong-sik/oas/commit/27151c1c082467fb51cd7d1d77e192b0d4a87d03))
* **llm:** expose optional transport latency ([#1463](https://github.com/jeong-sik/oas/issues/1463)) ([eed15b4](https://github.com/jeong-sik/oas/commit/eed15b4cf3bbfc2d050b68188a6870af34766436))
* **llm:** lower confidence for fallback capability drift ([#1555](https://github.com/jeong-sik/oas/issues/1555)) ([26339df](https://github.com/jeong-sik/oas/commit/26339df8cacecb49cb33ddaf0ab88a56f85c9874))
* **main:** unblock 3 CI categories after [#1469](https://github.com/jeong-sik/oas/issues/1469)-[#1471](https://github.com/jeong-sik/oas/issues/1471) cascade ([ebfc95d](https://github.com/jeong-sik/oas/commit/ebfc95d6fb94c4e5c2a1c47af1380aa3f78fdbff))
* **main:** unblock 3 CI categories after [#1469](https://github.com/jeong-sik/oas/issues/1469)-[#1471](https://github.com/jeong-sik/oas/issues/1471) merge cascade ([73d727b](https://github.com/jeong-sik/oas/commit/73d727b45fa283bd2bda693678c6bf32687c010d))
* **mcp:** preserve builtin tool permissions ([#1438](https://github.com/jeong-sik/oas/issues/1438)) ([f568a07](https://github.com/jeong-sik/oas/commit/f568a07b653870984dc38722bb2c436c74b78693))
* **memory:** persist episodic procedural backends ([#1594](https://github.com/jeong-sik/oas/issues/1594)) ([e87b73f](https://github.com/jeong-sik/oas/commit/e87b73fd90e83a79c66cf974e02002ec9a5eb9a2))
* **memory:** preserve long-term backend compatibility ([#1628](https://github.com/jeong-sik/oas/issues/1628)) ([2c046ee](https://github.com/jeong-sik/oas/commit/2c046ee883ef0df26a7f8acbf12cce22d8f4bc78))
* **metrics:** aggregate streaming latency samples ([#1577](https://github.com/jeong-sik/oas/issues/1577)) ([a33ac78](https://github.com/jeong-sik/oas/commit/a33ac78895a87db2ff824a4d394c3a108d7807ad))
* **metrics:** deduplicate histogram bucket bounds in prometheus export ([#1564](https://github.com/jeong-sik/oas/issues/1564)) ([b2e8403](https://github.com/jeong-sik/oas/commit/b2e8403897a43660f3ed6ca17529e9c4b7cdebdc))
* **metrics:** emit Circuit_open directly from open-skip branch ([#1566](https://github.com/jeong-sik/oas/issues/1566)) ([8969475](https://github.com/jeong-sik/oas/commit/8969475eb8323d17400a8ba53632961173d0cad3))
* **metrics:** persist provider snapshots as json ([#1573](https://github.com/jeong-sik/oas/issues/1573)) ([d5037d2](https://github.com/jeong-sik/oas/commit/d5037d2346e7e13f5488a13495e65722b0a0a268))
* **metrics:** reject duplicate histogram buckets at register time ([#1643](https://github.com/jeong-sik/oas/issues/1643)) ([2db3378](https://github.com/jeong-sik/oas/commit/2db337807cc71e7bed79accb6d69e82f38029057))
* **metrics:** reject normalized-name collisions at register time ([#1570](https://github.com/jeong-sik/oas/issues/1570)) ([54d4b71](https://github.com/jeong-sik/oas/commit/54d4b71246d382aa8b3561c1a473e8efd9c48d9f))
* **metrics:** reject open-circuit snapshots without failure timestamp ([#1575](https://github.com/jeong-sik/oas/issues/1575)) ([fedcd13](https://github.com/jeong-sik/oas/commit/fedcd13664e32edd03f47b2763ad131cb7d2184c))
* **metrics:** support labeled histograms ([#1572](https://github.com/jeong-sik/oas/issues/1572)) ([e9f5ac6](https://github.com/jeong-sik/oas/commit/e9f5ac6dad19d380e5cb068caafe16eed7800ed6))
* **ollama:** preserve tool calls and avoid hard timeouts ([#1609](https://github.com/jeong-sik/oas/issues/1609)) ([64ec834](https://github.com/jeong-sik/oas/commit/64ec834685faf8f3ecc58817d6020f4aa6ab3126))
* **otel:** propagate trace context to provider calls ([#1576](https://github.com/jeong-sik/oas/issues/1576)) ([4060baa](https://github.com/jeong-sik/oas/commit/4060baac4b8f83468091f66011492c5b4981c7ad))
* **paths:** replace assert false with invalid_arg, document MCP env var ([#1597](https://github.com/jeong-sik/oas/issues/1597)) ([9efc99d](https://github.com/jeong-sik/oas/commit/9efc99d9a91ed8b7b9658bcc34beb2cbba5d3db0))
* **pipeline:** count runtime MCP tools for tool_choice ([#1593](https://github.com/jeong-sik/oas/issues/1593)) ([f488eab](https://github.com/jeong-sik/oas/commit/f488eabf5d756ffb4a258465663aaf74ea295f42))
* **pipeline:** drop unused agent arg from turn_ready_tool_names callers ([#1599](https://github.com/jeong-sik/oas/issues/1599)) ([7489923](https://github.com/jeong-sik/oas/commit/748992379de975e3b7d705bd29dd6815864ea927))
* **pipeline:** propagate Eio.Cancel.Cancelled from safe_publish ([#1881](https://github.com/jeong-sik/oas/issues/1881)) ([adc8312](https://github.com/jeong-sik/oas/commit/adc8312bc03e8fb76023df84d3558d3eb9d36fca))
* **pipeline:** reject invisible tool choice contracts ([#1579](https://github.com/jeong-sik/oas/issues/1579)) ([b33e626](https://github.com/jeong-sik/oas/commit/b33e6267b49913f7fd1b2c59253403d8bf3b24e5))
* **pipeline:** reuse accumulated usage in collect stage ([#1764](https://github.com/jeong-sik/oas/issues/1764)) ([fde41d7](https://github.com/jeong-sik/oas/commit/fde41d76d84ed01ff6a22598c2dd61fd5310d970))
* **plan:** make progress + is_done variant matches exhaustive ([#1518](https://github.com/jeong-sik/oas/issues/1518)) ([fd82743](https://github.com/jeong-sik/oas/commit/fd827431dc98a0f41fcf3dc7409f6c5bdc35e103))
* **provider_catalog:** fail-fast on unknown enum strings ([bb73cdc](https://github.com/jeong-sik/oas/commit/bb73cdc0d0db9afaae67c6d66a314d8169af7275))
* **provider_catalog:** fail-fast on unknown enum strings ([5a1cf67](https://github.com/jeong-sik/oas/commit/5a1cf674ff379871d20388b24f14fecc0e9b45d9))
* **provider:** apply ocamlformat to catalog overlay ([edb91b2](https://github.com/jeong-sik/oas/commit/edb91b29d35df8130d844e531a7492af89e3fefc))
* **provider:** apply ocamlformat to catalog overlay ([0b58dfe](https://github.com/jeong-sik/oas/commit/0b58dfecd53d0b5b7687051e3fcfea3588add8e1))
* **provider:** include context for empty HTTP errors ([#1582](https://github.com/jeong-sik/oas/issues/1582)) ([3b49c50](https://github.com/jeong-sik/oas/commit/3b49c5049faee63b045f641bfd4fb0cde0f6ebcd))
* **provider:** persist cascade health snapshots ([#1584](https://github.com/jeong-sik/oas/issues/1584)) ([4277673](https://github.com/jeong-sik/oas/commit/42776731e1ae0b6e505557c6912240f1550a3a3e))
* **provider:** remove api_key from Provider_config.t.headers ([#1817](https://github.com/jeong-sik/oas/issues/1817)) ([31b750c](https://github.com/jeong-sik/oas/commit/31b750ceec8993b06b740273e4609b68238fa474))
* **provider:** resolve runtime binding capabilities by config ([#1589](https://github.com/jeong-sik/oas/issues/1589)) ([da757ff](https://github.com/jeong-sik/oas/commit/da757ffc1ebc7a7c94c25370755b9a683b6ce412))
* **provider:** route provider intf through http client ([#1559](https://github.com/jeong-sik/oas/issues/1559)) ([b249b58](https://github.com/jeong-sik/oas/commit/b249b5887064e8da87b04697521742279103b72f))
* **provider:** surface OpenAI harness parse errors ([#1581](https://github.com/jeong-sik/oas/issues/1581)) ([42273ee](https://github.com/jeong-sik/oas/commit/42273ee4a4daf9a68aa5f3aa68b2c553be3cd05e))
* **raw-trace:** require explicit evidence roles ([#1650](https://github.com/jeong-sik/oas/issues/1650)) ([0f4ff62](https://github.com/jeong-sik/oas/commit/0f4ff62afe0ef23895c02ecbf1cbf882709439e3))
* recognize bare GLM model ids in capabilities ([#1763](https://github.com/jeong-sik/oas/issues/1763)) ([44b5ff9](https://github.com/jeong-sik/oas/commit/44b5ff94c719bf03de03d48b6ace82b4289b613e))
* reject removed provider catalog aliases ([#1822](https://github.com/jeong-sik/oas/issues/1822)) ([e725e2c](https://github.com/jeong-sik/oas/commit/e725e2ceaae87ab51d39c71287b65fd26b0b4ebb))
* **release:** automate agent_sdk.opam sync inside release-please workflow ([#1604](https://github.com/jeong-sik/oas/issues/1604)) ([4b00bdf](https://github.com/jeong-sik/oas/commit/4b00bdff217e6233ed15bcc722d9aed410c36eba))
* remove coordinator-specific OAS hardcoding ([#1639](https://github.com/jeong-sik/oas/issues/1639)) ([16f0075](https://github.com/jeong-sik/oas/commit/16f0075f5106c8013fc9305ded2d4a59e1ee1557))
* remove masc reference from comment to pass SDK independence check ([#1805](https://github.com/jeong-sik/oas/issues/1805)) ([5f76987](https://github.com/jeong-sik/oas/commit/5f76987d25a24b18370f81efc4fdc79208a7e546)), closes [#1791](https://github.com/jeong-sik/oas/issues/1791)
* remove mutable anti-patterns — O(n) append, dead mutable, debug printf ([#1619](https://github.com/jeong-sik/oas/issues/1619)) ([5f8e07b](https://github.com/jeong-sik/oas/commit/5f8e07b777285f59c111b1a866166604d5bc4a1a))
* resolve main build failures after release 0.193.6 ([#1532](https://github.com/jeong-sik/oas/issues/1532)) ([04447d4](https://github.com/jeong-sik/oas/commit/04447d4e1ded4ccc49bc101a209d404b206e1a10))
* restore green main (ocamlformat drift + SDK independence) ([#1852](https://github.com/jeong-sik/oas/issues/1852)) ([5a7ea9e](https://github.com/jeong-sik/oas/commit/5a7ea9e4d4e8dd9a1839143aad58a6a6d204c672))
* **retry:** stop cascade on account usage limit ([#1428](https://github.com/jeong-sik/oas/issues/1428)) ([5ead30d](https://github.com/jeong-sik/oas/commit/5ead30d0c0ca7b72de32b8767bcea411a844eaed))
* **review:** harden recent OAS follow-ups ([66cff92](https://github.com/jeong-sik/oas/commit/66cff92c1987db2f9f69141d8ca736f91f8c11be))
* **runtime:** absorb runtime_server_worker into runtime_server, restore runtime_evidence ([b09ace3](https://github.com/jeong-sik/oas/commit/b09ace33a5b19934aa5057a6e6955ad7c9c16609))
* **runtime:** absorb runtime_server_worker, restore runtime_evidence ([692a4c2](https://github.com/jeong-sik/oas/commit/692a4c2348d1240ed50fc9102c28c9081e61c2f1))
* **runtime:** centralize provider identity resolution ([#1831](https://github.com/jeong-sik/oas/issues/1831)) ([c05e3bd](https://github.com/jeong-sik/oas/commit/c05e3bdaff51e5487054786cab5d3c358edafee5))
* **scripts:** recognize release-please CHANGELOG header format ([#1513](https://github.com/jeong-sik/oas/issues/1513)) ([188efa6](https://github.com/jeong-sik/oas/commit/188efa67bdb95de6888f0c7660d236e3cc9de2df))
* **sessions_store:** return Error on malformed tool catalog instead of raising ([#1885](https://github.com/jeong-sik/oas/issues/1885)) ([cc30dea](https://github.com/jeong-sik/oas/commit/cc30deab29c7a1e65d20d6714649ec88b4bbbc34))
* **sessions:** drop stale parser helper signature ([#1670](https://github.com/jeong-sik/oas/issues/1670)) ([c701d0f](https://github.com/jeong-sik/oas/commit/c701d0f2de0ae01e91b83bea1e1f6491d4877603))
* **spec:** include input-required runtime phase ([#1769](https://github.com/jeong-sik/oas/issues/1769)) ([a341140](https://github.com/jeong-sik/oas/commit/a341140be322059c065b7f967924f33c2ec8ba49))
* **streaming:** drop empty-choices chunk without usage + repair fmt drift (main red after [#1866](https://github.com/jeong-sik/oas/issues/1866)) ([#1869](https://github.com/jeong-sik/oas/issues/1869)) ([91dcc47](https://github.com/jeong-sik/oas/commit/91dcc4761e0eb48d438ca64d030a1ed24dadb994))
* **streaming:** request + parse stream_options.include_usage so OpenAI-compatible streaming returns token usage ([#1866](https://github.com/jeong-sik/oas/issues/1866)) ([8f74ef1](https://github.com/jeong-sik/oas/commit/8f74ef155198f928572f15975b981bd8a8f39170))
* support MiMo token plan endpoint ([#1803](https://github.com/jeong-sik/oas/issues/1803)) ([3265348](https://github.com/jeong-sik/oas/commit/3265348268f7f42c7041d5eb81f161fa8fac7bf2))
* **telemetry:** emit context window usage ([#1583](https://github.com/jeong-sik/oas/issues/1583)) ([070b9d4](https://github.com/jeong-sik/oas/commit/070b9d46d764d45d56b506d7edd51188a529a779))
* **telemetry:** Event_bus.publish error handling + cache failure logging ([#1797](https://github.com/jeong-sik/oas/issues/1797)) ([b415057](https://github.com/jeong-sik/oas/commit/b415057bfd12b373e96de2cac361f922b5db2e4a))
* **telemetry:** propagate participant_name in Agent_output_delta, add structured logging ([#1794](https://github.com/jeong-sik/oas/issues/1794)) ([bab2c20](https://github.com/jeong-sik/oas/commit/bab2c2048a41eb8100ccfdd93166968fc4a4df58))
* **telemetry:** replace Eio.traceln with structured Log/Diag ([#1801](https://github.com/jeong-sik/oas/issues/1801)) ([a71c21b](https://github.com/jeong-sik/oas/commit/a71c21bcc91d18715277cc508a09ea5e438ac503))
* **telemetry:** wrap all Event_bus.publish in try/with + fix complete.ml Diag ([#1798](https://github.com/jeong-sik/oas/issues/1798)) ([0ce5b69](https://github.com/jeong-sik/oas/commit/0ce5b69104bb3687573f746c264f97861cdaafa3))
* **test:** make telemetry SCA repo-root discovery fail fast ([b9d4f57](https://github.com/jeong-sik/oas/commit/b9d4f57e21904658f7163e6fcfe52f0fb18b6072))
* **test:** remove duplicate test_telemetry_sca — superseded by test/telemetry_sca/ ([4bab73f](https://github.com/jeong-sik/oas/commit/4bab73fa6236b4e4b8fac6c3d027a206780b217a))
* **test:** repair CLI Runtime purge residue to restore compilation ([#1815](https://github.com/jeong-sik/oas/issues/1815)) ([503439b](https://github.com/jeong-sik/oas/commit/503439bbb6e6cf59264b8f774a95466b138180d8))
* tolerate release version markers ([#1708](https://github.com/jeong-sik/oas/issues/1708)) ([a5cd80f](https://github.com/jeong-sik/oas/commit/a5cd80fd1ffbc12ef3f5188d9c754ebd114958be))
* **tool_selector:** replace failwith with empty list for unimplemented LLM categorical classifier ([#1455](https://github.com/jeong-sik/oas/issues/1455)) ([496c329](https://github.com/jeong-sik/oas/commit/496c329bc4423fb1ddbe61507bbc6b5df1ba23a9))
* **tools:** enforce shell descriptor constraints ([#1602](https://github.com/jeong-sik/oas/issues/1602)) ([ce90f5d](https://github.com/jeong-sik/oas/commit/ce90f5d2575d54ec339bdfd2744c019a8849414f))
* **tools:** resolve legacy Read to visible ReadFile ([#1800](https://github.com/jeong-sik/oas/issues/1800)) ([17e1408](https://github.com/jeong-sik/oas/commit/17e1408c6849b46fd7139fb79dd28b470e84710a))
* type provider reasoning controls ([#1709](https://github.com/jeong-sik/oas/issues/1709)) ([a2bf6e1](https://github.com/jeong-sik/oas/commit/a2bf6e1c192f59717fe47f7f57f74458e3ffbcaa))
* **types:** preserve missing response usage ([#1449](https://github.com/jeong-sik/oas/issues/1449)) ([9639c92](https://github.com/jeong-sik/oas/commit/9639c9204c75c17d5c4e260111b8cb1be5ea257c))
* warn on invalid cli integer env ([#1456](https://github.com/jeong-sik/oas/issues/1456)) ([21dea98](https://github.com/jeong-sik/oas/commit/21dea9862fab506eb8983740c9c12951b32dbe94))
* **zai_catalog:** remove unsupported glm-5-code from coding auto-models ([92f108c](https://github.com/jeong-sik/oas/commit/92f108c6045b1e0065504ab059ac85a144db7f39))
* **zai_catalog:** remove unsupported glm-5-code from coding auto-models ([186e51c](https://github.com/jeong-sik/oas/commit/186e51c24e0e1eadc50840073396630cdb6b74b9))


### Performance Improvements

* **completion_contract:** build tool-lookup index lazily ([#1600](https://github.com/jeong-sik/oas/issues/1600)) ([e605a13](https://github.com/jeong-sik/oas/commit/e605a133d798a1e1e308727643b59692a5c2bc25))


### Code Refactoring

* remove migrated CDAL modules + façade re-exports (RFC-OAS-011 OAS-E PR-6) ([c5b120d](https://github.com/jeong-sik/oas/commit/c5b120d6f04eb8ea203dec2d1ffc5f8920656cdf))

## [0.202.0](https://github.com/jeong-sik/oas/compare/v0.201.0...v0.202.0) (2026-06-04)


### ⚠ BREAKING CHANGES

* Memory, lesson-memory, and memory-tool modules are removed from the public SDK surface. Host applications that need durable memory should own it outside `agent_sdk` and project only the data they need into OAS turns.

### Features

* remove memory API surface ([#1926](https://github.com/jeong-sik/oas/issues/1926)) ([e705946](https://github.com/jeong-sik/oas/commit/e7059466a07a017472208c75b8a72257f5863871))

## [0.201.0](https://github.com/jeong-sik/oas/compare/v0.200.19...v0.201.0) (2026-06-04)


### ⚠ BREAKING CHANGES

* Error.A2a and the a2a_* constructors are removed from the public sdk_error API. Consumers matching Error.A2a must drop that arm. masc-mcp consumes agent_sdk via a git pin; its ~20 Error.A2a match arms will be compiler-forced to update when it adopts the new commit (separate follow-up).

### Features

* remove dead A2a error variant from sdk_error ([#1903](https://github.com/jeong-sik/oas/issues/1903)) ([7edc393](https://github.com/jeong-sik/oas/commit/7edc39375d6260943c972bd510be4b51af9c4cc3))

## [0.200.19](https://github.com/jeong-sik/oas/compare/v0.200.18...v0.200.19) (2026-06-04)


### Features

* extract agent_sdk.protocol sublibrary and resolve circular dependencies ([#1896](https://github.com/jeong-sik/oas/issues/1896)) ([de16a44](https://github.com/jeong-sik/oas/commit/de16a4497dd76ad3493608c110174f579a20dce8))

## [0.200.18](https://github.com/jeong-sik/oas/compare/v0.200.17...v0.200.18) (2026-06-04)


### Bug Fixes

* **pipeline:** propagate Eio.Cancel.Cancelled from safe_publish ([#1881](https://github.com/jeong-sik/oas/issues/1881)) ([adc8312](https://github.com/jeong-sik/oas/commit/adc8312bc03e8fb76023df84d3558d3eb9d36fca))

## [0.200.17](https://github.com/jeong-sik/oas/compare/v0.200.16...v0.200.17) (2026-06-03)


### Bug Fixes

* **http_client:** propagate Eio.Cancel.Cancelled from drain_response_body ([#1871](https://github.com/jeong-sik/oas/issues/1871)) ([a141153](https://github.com/jeong-sik/oas/commit/a1411535ac6fc7db3d5a01840bbd60a2e3662b4a))

## [0.200.16](https://github.com/jeong-sik/oas/compare/v0.200.15...v0.200.16) (2026-06-03)


### Bug Fixes

* **streaming:** drop empty-choices chunk without usage + repair fmt drift (main red after [#1866](https://github.com/jeong-sik/oas/issues/1866)) ([#1869](https://github.com/jeong-sik/oas/issues/1869)) ([91dcc47](https://github.com/jeong-sik/oas/commit/91dcc4761e0eb48d438ca64d030a1ed24dadb994))

## [0.200.15](https://github.com/jeong-sik/oas/compare/v0.200.14...v0.200.15) (2026-06-03)


### Bug Fixes

* **streaming:** request + parse stream_options.include_usage so OpenAI-compatible streaming returns token usage ([#1866](https://github.com/jeong-sik/oas/issues/1866)) ([8f74ef1](https://github.com/jeong-sik/oas/commit/8f74ef155198f928572f15975b981bd8a8f39170))

## [0.200.14](https://github.com/jeong-sik/oas/compare/v0.200.13...v0.200.14) (2026-06-03)


### Features

* **pipeline:** remove forced-tool-use enforcement (RFC-OAS-025 Option A, stage 1) ([#1864](https://github.com/jeong-sik/oas/issues/1864)) ([81f97b8](https://github.com/jeong-sik/oas/commit/81f97b8441b807b78572fa219d0c935ee87e0f15))

## [0.200.13](https://github.com/jeong-sik/oas/compare/v0.200.12...v0.200.13) (2026-06-03)


### Bug Fixes

* restore green main (ocamlformat drift + SDK independence) ([#1852](https://github.com/jeong-sik/oas/issues/1852)) ([5a7ea9e](https://github.com/jeong-sik/oas/commit/5a7ea9e4d4e8dd9a1839143aad58a6a6d204c672))

## [0.200.12](https://github.com/jeong-sik/oas/compare/v0.200.11...v0.200.12) (2026-06-03)


### Bug Fixes

* **llm_provider:** align Ollama streaming zero usage with non-streaming path ([#1848](https://github.com/jeong-sik/oas/issues/1848)) ([392902c](https://github.com/jeong-sik/oas/commit/392902c145cca0d8a481dccf0d05cd8e8c80e068))

## [0.200.11](https://github.com/jeong-sik/oas/compare/v0.200.10...v0.200.11) (2026-06-03)


### Features

* **provider:** canonical tool projection wired into turn pipeline (WP8 Inc1, RFC-OAS-024) ([#1846](https://github.com/jeong-sik/oas/issues/1846)) ([a04e0b4](https://github.com/jeong-sik/oas/commit/a04e0b45e13195cab4f59f11d22e0c2dcf31fdde))

## [0.200.10](https://github.com/jeong-sik/oas/compare/v0.200.9...v0.200.10) (2026-06-03)


### Features

* **gemini:** surface unsupported disable_parallel_tool_use (WP9 gap) ([#1840](https://github.com/jeong-sik/oas/issues/1840)) ([7ba14b4](https://github.com/jeong-sik/oas/commit/7ba14b44da70a2fb714a6ac10ae2f27ffd5b2601))
* **provider:** per-function strict mode on tool_schema (WP2) ([#1837](https://github.com/jeong-sik/oas/issues/1837)) ([61755b2](https://github.com/jeong-sik/oas/commit/61755b286d356ff3ffb11a031c0ed27cb5d5e8d3))
* **provider:** structured tool_result content blocks (WP4) ([#1839](https://github.com/jeong-sik/oas/issues/1839)) ([95f74ec](https://github.com/jeong-sik/oas/commit/95f74ece5c7ed9c06b7231f2e6e6d208d91e3248))
* **provider:** tool calling 현대화 기반 — backend rename + stop_reason (WP0/WP1) ([#1835](https://github.com/jeong-sik/oas/issues/1835)) ([a1d6b4d](https://github.com/jeong-sik/oas/commit/a1d6b4db64a6e2c7890e5fcb67b9040fd68ff503))

## [0.200.9](https://github.com/jeong-sik/oas/compare/v0.200.8...v0.200.9) (2026-06-02)


### Bug Fixes

* **runtime:** centralize provider identity resolution ([#1831](https://github.com/jeong-sik/oas/issues/1831)) ([c05e3bd](https://github.com/jeong-sik/oas/commit/c05e3bdaff51e5487054786cab5d3c358edafee5))

## [0.200.8](https://github.com/jeong-sik/oas/compare/v0.200.7...v0.200.8) (2026-06-01)


### Features

* **agent:** idle/progress-aware execution timeout ([#1823](https://github.com/jeong-sik/oas/issues/1823)) ([886c4d1](https://github.com/jeong-sik/oas/commit/886c4d1c8b5d03cab030266008fa5b28cdd5d847))
* **http_client:** diagnose oversized request headers that CDN proxies reject ([#1819](https://github.com/jeong-sik/oas/issues/1819)) ([03a07b8](https://github.com/jeong-sik/oas/commit/03a07b8d6485f2e121868d8e4e0f938e1bb8987c))


### Bug Fixes

* **http_client:** replace pre-send header-size guard with 4xx response profiler ([#1820](https://github.com/jeong-sik/oas/issues/1820)) ([e44dee8](https://github.com/jeong-sik/oas/commit/e44dee8b91f3797436f3b7c4993a7b5497406ec6))
* **llm_provider:** finish service-name migration, restore main green ([#1813](https://github.com/jeong-sik/oas/issues/1813)) ([b309bc1](https://github.com/jeong-sik/oas/commit/b309bc199f8a6f821dde5dca9379c0b8c22b86c6)), closes [#1811](https://github.com/jeong-sik/oas/issues/1811)
* **llm_provider:** Kimi backend mapping + capability rename to service names ([#1812](https://github.com/jeong-sik/oas/issues/1812)) ([27151c1](https://github.com/jeong-sik/oas/commit/27151c1c082467fb51cd7d1d77e192b0d4a87d03))
* **provider:** remove api_key from Provider_config.t.headers ([#1817](https://github.com/jeong-sik/oas/issues/1817)) ([31b750c](https://github.com/jeong-sik/oas/commit/31b750ceec8993b06b740273e4609b68238fa474))
* reject removed provider catalog aliases ([#1822](https://github.com/jeong-sik/oas/issues/1822)) ([e725e2c](https://github.com/jeong-sik/oas/commit/e725e2ceaae87ab51d39c71287b65fd26b0b4ebb))
* **test:** repair CLI Runtime purge residue to restore compilation ([#1815](https://github.com/jeong-sik/oas/issues/1815)) ([503439b](https://github.com/jeong-sik/oas/commit/503439bbb6e6cf59264b8f774a95466b138180d8))

## [0.200.7](https://github.com/jeong-sik/oas/compare/v0.200.6...v0.200.7) (2026-06-01)


### Features

* **http_client:** diagnose oversized request headers that CDN proxies reject ([#1819](https://github.com/jeong-sik/oas/issues/1819)) ([03a07b8](https://github.com/jeong-sik/oas/commit/03a07b8d6485f2e121868d8e4e0f938e1bb8987c))


### Bug Fixes

* **http_client:** replace pre-send header-size guard with 4xx response profiler ([#1820](https://github.com/jeong-sik/oas/issues/1820)) ([e44dee8](https://github.com/jeong-sik/oas/commit/e44dee8b91f3797436f3b7c4993a7b5497406ec6))
* **llm_provider:** finish service-name migration, restore main green ([#1813](https://github.com/jeong-sik/oas/issues/1813)) ([b309bc1](https://github.com/jeong-sik/oas/commit/b309bc199f8a6f821dde5dca9379c0b8c22b86c6)), closes [#1811](https://github.com/jeong-sik/oas/issues/1811)
* **llm_provider:** Kimi backend mapping + capability rename to service names ([#1812](https://github.com/jeong-sik/oas/issues/1812)) ([27151c1](https://github.com/jeong-sik/oas/commit/27151c1c082467fb51cd7d1d77e192b0d4a87d03))
* **provider:** remove api_key from Provider_config.t.headers ([#1817](https://github.com/jeong-sik/oas/issues/1817)) ([31b750c](https://github.com/jeong-sik/oas/commit/31b750ceec8993b06b740273e4609b68238fa474))
* reject removed provider catalog aliases ([#1822](https://github.com/jeong-sik/oas/issues/1822)) ([e725e2c](https://github.com/jeong-sik/oas/commit/e725e2ceaae87ab51d39c71287b65fd26b0b4ebb))
* remove masc reference from comment to pass SDK independence check ([#1805](https://github.com/jeong-sik/oas/issues/1805)) ([5f76987](https://github.com/jeong-sik/oas/commit/5f76987d25a24b18370f81efc4fdc79208a7e546)), closes [#1791](https://github.com/jeong-sik/oas/issues/1791)
* **test:** repair CLI Runtime purge residue to restore compilation ([#1815](https://github.com/jeong-sik/oas/issues/1815)) ([503439b](https://github.com/jeong-sik/oas/commit/503439bbb6e6cf59264b8f774a95466b138180d8))

## [0.200.7](https://github.com/jeong-sik/oas/compare/v0.200.6...v0.200.7) (2026-05-28)

### Documentation

* **issue-consolidation:** finalize plan HTML with executive summary, dark mode, responsive design, accessibility (skip-link, aria-label, scope, focus-visible, time elements), and 51 clickable GitHub links ([#1804](https://github.com/jeong-sik/oas/pull/1804))

### Bug Fixes

* **sdk-independence:** reword comment in capabilities.ml to remove `\bmasc\b` pattern match ([#1805](https://github.com/jeong-sik/oas/pull/1805), closes [#1791](https://github.com/jeong-sik/oas/issues/1791))

### Documentation

* **capability-manifest:** add `docs/example-capability-manifest.json` — RFC-OAS-023 §5.3 Phase 5 catalog draft applied as runtime manifest. 12 model entries covering cascade.toml api-name surface (kimi-k2.6, gpt-5.3-codex-spark, gpt-4.1, glm-5.1/5-turbo/5, gemma4, qwen3.5/qwen/qwen-local-35b-a3b, deepseek-v4-pro/flash). Load with `Capability_manifest.load_file` and install with `Capability_manifest.set_global` to resolve the §5.1 0/13 catalog miss + 16:42 runtime drift WARN. WORKAROUND: cipher catalog plane still in place via `base_label: provider_d_chat`; removal target = Phase 1 sweep completion (variant + file rename) per RFC §6.1.

## [0.200.6](https://github.com/jeong-sik/oas/compare/v0.200.5...v0.200.6) (2026-05-27)


### Bug Fixes

* **telemetry:** replace Eio.traceln with structured Log/Diag ([#1801](https://github.com/jeong-sik/oas/issues/1801)) ([a71c21b](https://github.com/jeong-sik/oas/commit/a71c21bcc91d18715277cc508a09ea5e438ac503))

## [0.200.5](https://github.com/jeong-sik/oas/compare/v0.200.4...v0.200.5) (2026-05-27)


### Bug Fixes

* **telemetry:** wrap all Event_bus.publish in try/with + fix complete.ml Diag ([#1798](https://github.com/jeong-sik/oas/issues/1798)) ([0ce5b69](https://github.com/jeong-sik/oas/commit/0ce5b69104bb3687573f746c264f97861cdaafa3))

## [0.200.4](https://github.com/jeong-sik/oas/compare/v0.200.3...v0.200.4) (2026-05-27)


### Bug Fixes

* **agent-tools:** purge retired native tool ids ([#1796](https://github.com/jeong-sik/oas/issues/1796)) ([d40180d](https://github.com/jeong-sik/oas/commit/d40180d963aefed06b72faac2a1a7e097591023e))
* **telemetry:** Event_bus.publish error handling + cache failure logging ([#1797](https://github.com/jeong-sik/oas/issues/1797)) ([b415057](https://github.com/jeong-sik/oas/commit/b415057bfd12b373e96de2cac361f922b5db2e4a))
* **telemetry:** propagate participant_name in Agent_output_delta, add structured logging ([#1794](https://github.com/jeong-sik/oas/issues/1794)) ([bab2c20](https://github.com/jeong-sik/oas/commit/bab2c2048a41eb8100ccfdd93166968fc4a4df58))

## [0.200.3](https://github.com/jeong-sik/oas/compare/v0.200.2...v0.200.3) (2026-05-27)


### Bug Fixes

* **agent:** surface Agent.run execution timeouts ([#1792](https://github.com/jeong-sik/oas/issues/1792)) ([37a096d](https://github.com/jeong-sik/oas/commit/37a096de62354e4e5857434966b8e7420595ecf5))

## [0.200.2](https://github.com/jeong-sik/oas/compare/v0.200.1...v0.200.2) (2026-05-27)


### Bug Fixes

* **agent_tools:** preserve optional absence in correction ([#1789](https://github.com/jeong-sik/oas/issues/1789)) ([64773ea](https://github.com/jeong-sik/oas/commit/64773eabbed612dbf04a27d9a9b4b1e2d4061d69))

## [0.200.1](https://github.com/jeong-sik/oas/compare/v0.200.0...v0.200.1) (2026-05-26)


### Features

* **capabilities:** register Qwen_3 family in static model route ladder ([#1787](https://github.com/jeong-sik/oas/issues/1787)) ([c7f97cc](https://github.com/jeong-sik/oas/commit/c7f97cc827cf5034918ec939d0e105641b5c6b7e))

## [0.200.0](https://github.com/jeong-sik/oas/compare/v0.199.0...v0.200.0) (2026-05-26)


### ⚠ BREAKING CHANGES

* remove migrated CDAL modules + façade re-exports (RFC-OAS-011 OAS-E PR-6)

### Features

* add ppx_let support with Let_syntax in Result_syntax ([#1353](https://github.com/jeong-sik/oas/issues/1353)) ([9aeb72c](https://github.com/jeong-sik/oas/commit/9aeb72cb33e845fe99cf8e5983cf957a7022de84))
* add runtime run window reads ([#1716](https://github.com/jeong-sik/oas/issues/1716)) ([c11b35b](https://github.com/jeong-sik/oas/commit/c11b35bb9142b5261d4b61daa324a8792fd85324))
* **agent_tool:** add typed child invocation ([#1744](https://github.com/jeong-sik/oas/issues/1744)) ([cbbd543](https://github.com/jeong-sik/oas/commit/cbbd5434cb92c97340bba4fd05ce2fe6c7f48310))
* **agent_tools:** remove CDAL builtin_descriptor fallback (RFC-OAS-009 v2 PR-B) ([39082f6](https://github.com/jeong-sik/oas/commit/39082f6005888209a5b16c6aaa0b60bd25df050f))
* **agent_tools:** remove CDAL builtin_descriptor fallback (RFC-OAS-009 v2 PR-B) ([41d0144](https://github.com/jeong-sik/oas/commit/41d0144f22fbfc36ea0da2c92487caff638bf807))
* **agent:** add disclosure_level for tool schema serialization ([#1508](https://github.com/jeong-sik/oas/issues/1508)) ([f48ccec](https://github.com/jeong-sik/oas/commit/f48ccec3d1f6045627bb51c913944b7b879baf4d))
* **agent:** add disclosure_resolver for per-turn adaptive disclosure ([#1511](https://github.com/jeong-sik/oas/issues/1511)) ([7ed9c05](https://github.com/jeong-sik/oas/commit/7ed9c05260dce7b813bfaf524a2799573eb6479d))
* **agent:** add turn durability checkpoints ([#1550](https://github.com/jeong-sik/oas/issues/1550)) ([393ff0c](https://github.com/jeong-sik/oas/commit/393ff0c432734c6e2c471fd78b6ebba0040b48aa))
* **agent:** index tool dispatch lookups ([#1557](https://github.com/jeong-sik/oas/issues/1557)) ([b7ea8e6](https://github.com/jeong-sik/oas/commit/b7ea8e6b00dd5ad1d3f4bbadeb26a071228c52f5))
* **agent:** pause on async elicitation ([#1722](https://github.com/jeong-sik/oas/issues/1722)) ([b40e955](https://github.com/jeong-sik/oas/commit/b40e9557ad3f404c692159d3fd018da368f9c63e))
* **arch:** decouple OAS from MASC by purging A2A and Handoff ([#1322](https://github.com/jeong-sik/oas/issues/1322)) ([d98e00e](https://github.com/jeong-sik/oas/commit/d98e00e43c405850d2fc80e7f52a93ac03c37bcf))
* **base:** Tool_id closed Variant identifier (RFC-OAS-008 PR-2/5) ([3c67d1e](https://github.com/jeong-sik/oas/commit/3c67d1e510fca49692937effd08cefc89aebd079))
* **base:** Tool_id closed Variant identifier (RFC-OAS-008 PR-2/5) ([8f413f8](https://github.com/jeong-sik/oas/commit/8f413f8a063273524f4fd2a22d14e69b1934709e))
* **bench:** TTFT distribution bench + SLO doc (RFC-OAS-020 PR-1b) ([#1625](https://github.com/jeong-sik/oas/issues/1625)) ([2ef4b25](https://github.com/jeong-sik/oas/commit/2ef4b25eade1d4fd6b6292e99842a97c8a78634b))
* bridge runtime windows to sync replay ([#1720](https://github.com/jeong-sik/oas/issues/1720)) ([1b98e4d](https://github.com/jeong-sik/oas/commit/1b98e4dcf6368fea5b452967df67eaa822969e5c))
* **capabilities:** add prefix-match ordering regression test for for_model_id (M01) ([#1361](https://github.com/jeong-sik/oas/issues/1361)) ([711e5a0](https://github.com/jeong-sik/oas/commit/711e5a0164081ab1a91745d5d5e3afbe4e1aaa4d))
* **capabilities:** add thinking_control_format and structured capability_drop metrics ([b596d78](https://github.com/jeong-sik/oas/commit/b596d7896daf8b8b488acc3e116843437de2ad93))
* **capabilities:** add thinking_control_format and structured capability_drop metrics ([bff40ae](https://github.com/jeong-sik/oas/commit/bff40aed2578a5b138050dd35b2352488773b9b1))
* **capabilities:** Ollama dynamic capability discovery via /api/show (M03) ([#1362](https://github.com/jeong-sik/oas/issues/1362)) ([eca778b](https://github.com/jeong-sik/oas/commit/eca778bc1e7f6b79ab7c5c734f63da857bd438e7))
* **capabilities:** runtime model capability manifest (H12) ([#1347](https://github.com/jeong-sik/oas/issues/1347)) ([1299541](https://github.com/jeong-sik/oas/commit/1299541bbd5ed25646c69637c4080efa6bfd6cd0))
* **capability_manifest:** add set_global / clear_global runtime override ([#1516](https://github.com/jeong-sik/oas/issues/1516)) ([c3a786f](https://github.com/jeong-sik/oas/commit/c3a786f36f6fc37306c1f8932267b9f684180ed5))
* **ci:** boundary-lint for core→CDAL zero dependency (RFC-OAS-009 v2 PR-D) ([b0c7a44](https://github.com/jeong-sik/oas/commit/b0c7a4484fe1a6514c1a308e9ce01581e356c81a))
* **ci:** boundary-lint for core→CDAL zero dependency (RFC-OAS-009 v2 PR-D) ([f53a3f5](https://github.com/jeong-sik/oas/commit/f53a3f550a9b27848cc58e52ed024036cb86f281))
* **ci:** expand boundary-lint to 20 CDAL prefixes (RFC-OAS-011 OAS-E PR-1) ([0a306ce](https://github.com/jeong-sik/oas/commit/0a306ce0f30e28d44e780eedb68551d2ded634a3))
* **ci:** expand boundary-lint to 20 CDAL prefixes (RFC-OAS-011 OAS-E PR-1) ([e189ed7](https://github.com/jeong-sik/oas/commit/e189ed75b1d25b97a6bf9c4d8536d7c5b79188bc))
* **complete:** add body_timeout_s to non-streaming complete + complete_with_retry ([#1622](https://github.com/jeong-sik/oas/issues/1622)) ([79262f3](https://github.com/jeong-sik/oas/commit/79262f374d70798cc76dc43f1503c5f329dfe204))
* **completion-contract:** add typed violation_detail with satisfying_tools ([#1642](https://github.com/jeong-sik/oas/issues/1642)) ([42c125f](https://github.com/jeong-sik/oas/commit/42c125f6e31c422dcf387a3546a0ffdbcea1bde0))
* **context:** dynamic prompt cache alignment & budget compaction ([49823a6](https://github.com/jeong-sik/oas/commit/49823a614296289568e040ec197473e626031a2f))
* **context:** dynamic prompt cache alignment & budget compaction ([dd6f37e](https://github.com/jeong-sik/oas/commit/dd6f37ea70563c971b08103138fee80444aead55))
* **error:** carry completion contract violation detail ([#1660](https://github.com/jeong-sik/oas/issues/1660)) ([609600d](https://github.com/jeong-sik/oas/commit/609600d896af320868b9578d278e5752f8f28075))
* **eval:** gate code snippet adoption criteria ([#1751](https://github.com/jeong-sik/oas/issues/1751)) ([2a3e688](https://github.com/jeong-sik/oas/commit/2a3e688bbc03785e2232447e4b88f3d6963b3dd4))
* GLM-5-Code models and Kimi CLI model restrictions ([#1334](https://github.com/jeong-sik/oas/issues/1334)) ([6be9be9](https://github.com/jeong-sik/oas/commit/6be9be9be1b601cc797a3e3fbbda8524c95da4f3))
* **guardrails_async:** add per-validator deadline to prevent silent stall ([#1368](https://github.com/jeong-sik/oas/issues/1368)) ([b9e5f09](https://github.com/jeong-sik/oas/commit/b9e5f09791c7ef0f608f1dcc512dadc9368fdeb2))
* **guardrails:** tighten default tool_filter to DenyList + cap ([#1370](https://github.com/jeong-sik/oas/issues/1370)) ([7fa5cdc](https://github.com/jeong-sik/oas/commit/7fa5cdc9a264ef634c1069702dbfc4d90114c064))
* **lib:** add Cognitive_event typed schema (RFC-0036 PR-B) ([#1451](https://github.com/jeong-sik/oas/issues/1451)) ([f848e75](https://github.com/jeong-sik/oas/commit/f848e75a298827722d5f6cff8162f954ae20f974))
* **llm_provider:** Fd_throttle_hook injection point (RFC-0101 PR-3) ([#1618](https://github.com/jeong-sik/oas/issues/1618)) ([29cbbc5](https://github.com/jeong-sik/oas/commit/29cbbc5b1d1593ba77e9c9a6cccac716051f88c2))
* **llm_provider:** implement usage token restoration for CLI wrappers (P7) ([#1342](https://github.com/jeong-sik/oas/issues/1342)) ([53c921a](https://github.com/jeong-sik/oas/commit/53c921a47635c4bc03c42ad33f95dc3f3ebea429))
* **llm_provider:** RFC-0058 Phase B — CLI transport factory ([#1520](https://github.com/jeong-sik/oas/issues/1520)) ([41e87e0](https://github.com/jeong-sik/oas/commit/41e87e0cd1fe4d57c4f627958b34fcf419839745))
* **llm_provider:** typed TTFT capture + prefill_ms field (RFC-OAS-020 PR-1a) ([#1620](https://github.com/jeong-sik/oas/issues/1620)) ([37b4a0c](https://github.com/jeong-sik/oas/commit/37b4a0cd2a0303282579641038858f222a115547))
* **llm_provider:** Visual_first modality ordering for Gemma 4 ([cf94ce9](https://github.com/jeong-sik/oas/commit/cf94ce9a95deaa34270f3f3c1cb75347ba5ea59d))
* **llm_provider:** Visual_first modality ordering for Gemma 4 ([791eee8](https://github.com/jeong-sik/oas/commit/791eee8b6266fe91d762f76544ae525bb4992f7c))
* **llm_provider:** wire ttfrc_ms and prefill_ms into inference_telemetry ([809b63a](https://github.com/jeong-sik/oas/commit/809b63a5c4dfbeed427d660295de26df3ed928eb))
* **log:** count records dropped without sinks ([#1402](https://github.com/jeong-sik/oas/issues/1402)) ([d039517](https://github.com/jeong-sik/oas/commit/d039517fef5daa0a740545bb1b99661decfa1185))
* **manifest:** carry provider health evidence ([#1398](https://github.com/jeong-sik/oas/issues/1398)) ([07a06e4](https://github.com/jeong-sik/oas/commit/07a06e49e313294a3d3d721dd8d8f2e1badbb39b))
* **mcp_schema:** remove descriptor_for_builtin_tool alias (RFC-OAS-009 v2 PR-C) ([ffb8aff](https://github.com/jeong-sik/oas/commit/ffb8aff3a3bac4bdfce823fe41ca176226ba2f13))
* **mcp_schema:** remove descriptor_for_builtin_tool alias (RFC-OAS-009 v2 PR-C) ([2c41611](https://github.com/jeong-sik/oas/commit/2c416118433aa703f97f1e891b5671e9f67bb931))
* **mcp:** cli provider integration and ollama dynamic capabilities ([8c460d0](https://github.com/jeong-sik/oas/commit/8c460d011b1aed997b106765f48f567a69e6eefd))
* **mcp:** cli provider integration and ollama dynamic capabilities ([230773e](https://github.com/jeong-sik/oas/commit/230773ee8642e44d928a539215e04401957a1cb1))
* **memory:** expose typed long-term retrieve result ([#1627](https://github.com/jeong-sik/oas/issues/1627)) ([0be7c3c](https://github.com/jeong-sik/oas/commit/0be7c3c37fdbfcf69f8c93cdce0514fddedae7e3))
* **metrics:** add Prometheus text export ([#1556](https://github.com/jeong-sik/oas/issues/1556)) ([fc02639](https://github.com/jeong-sik/oas/commit/fc02639b940afe6714f207f08c41dc393e112260))
* **metrics:** emit cascade circuit state ([#1563](https://github.com/jeong-sik/oas/issues/1563)) ([1f69740](https://github.com/jeong-sik/oas/commit/1f69740fb423cc68c04b7d300597a9f164499c84))
* OAS Execution Manifest 고도화 및 Rate Limit Quota (P0~P1) ([44d8c84](https://github.com/jeong-sik/oas/commit/44d8c84676152ffb5eafb24da1ebb01db2d41ddd))
* **oas:** TLA+ CI gate + AgentCancellation spec + lifecycle_status yojson ([#1467](https://github.com/jeong-sik/oas/issues/1467)) ([7cd282f](https://github.com/jeong-sik/oas/commit/7cd282fed27ef6aa0637a6a12ca9356621619039))
* P0-P3 goals implementation (Rate limit quota, cascade config) ([1e58068](https://github.com/jeong-sik/oas/commit/1e580685527369f582836bd7aa6afedc59f1f4de))
* persist runtime input-required state ([#1714](https://github.com/jeong-sik/oas/issues/1714)) ([656ac61](https://github.com/jeong-sik/oas/commit/656ac61937810763a600a268bd671c7fe8beba30))
* preserve provider timeout evidence ([#1632](https://github.com/jeong-sik/oas/issues/1632)) ([5001b3b](https://github.com/jeong-sik/oas/commit/5001b3b866fce8a31dc5e6f78a654d8ae6e560e5))
* **pricing:** dynamic model pricing lookup via env vars (H11) ([#1348](https://github.com/jeong-sik/oas/issues/1348)) ([3017770](https://github.com/jeong-sik/oas/commit/301777035fe23868e27d4d3fa7544f7f3e534fc6))
* provider cascade routing + agent_sdk.base extraction (B→B+) ([#1346](https://github.com/jeong-sik/oas/issues/1346)) ([ac2e6e0](https://github.com/jeong-sik/oas/commit/ac2e6e04f155f687936ac41a55daaf003c3d0655))
* **provider:** add external provider catalog overlay ([35241e9](https://github.com/jeong-sik/oas/commit/35241e9a82ce30360449f19a115d6589041f8f79))
* **provider:** expose runtime bindings ([#1585](https://github.com/jeong-sik/oas/issues/1585)) ([dbabd5c](https://github.com/jeong-sik/oas/commit/dbabd5ca7daf3ab25a861973ba346faddd442201))
* **provider:** load external provider catalog ([a13a1d0](https://github.com/jeong-sik/oas/commit/a13a1d0caa6baf0eaf77cfaa1e0ebdbed380d490))
* **provider:** map transport errors to typed provider errors ([#1448](https://github.com/jeong-sik/oas/issues/1448)) ([e804755](https://github.com/jeong-sik/oas/commit/e804755e3fb4ce81c33cd2b32880b206c588c28a))
* **provider:** P0-P7 LLM provider improvement plan implementation ([#1337](https://github.com/jeong-sik/oas/issues/1337)) ([8fbd8ac](https://github.com/jeong-sik/oas/commit/8fbd8ac7a9570ac2311c0fdeb158c7efd3ff0360))
* **raw-trace:** add evidence role validation seam ([#1647](https://github.com/jeong-sik/oas/issues/1647)) ([f9f1c9f](https://github.com/jeong-sik/oas/commit/f9f1c9fad7c36eac04c95ac17fda0b001a58ff00))
* **raw-trace:** expose evidence role summaries ([#1653](https://github.com/jeong-sik/oas/issues/1653)) ([9d2b2e5](https://github.com/jeong-sik/oas/commit/9d2b2e5c2739135d73f7aecdbcf04ed8fceff4c3))
* **raw-trace:** expose validation evidence roles ([#1658](https://github.com/jeong-sik/oas/issues/1658)) ([6d79276](https://github.com/jeong-sik/oas/commit/6d79276611261d0c64a8beebdf2e673e38cba74e))
* **release:** adopt release-please for version + CHANGELOG automation ([fd9931d](https://github.com/jeong-sik/oas/commit/fd9931d7f60f3b966140fdc700fd29c982ac5ea5))
* **release:** adopt release-please for version + CHANGELOG automation ([058ea4b](https://github.com/jeong-sik/oas/commit/058ea4bea2205b21854960f7cd4cb885043a9de8))
* **runtime:** add durable relay delivery primitive ([#1383](https://github.com/jeong-sik/oas/issues/1383)) ([b056099](https://github.com/jeong-sik/oas/commit/b056099b5de703da53d6b2f774db9847f5a18b7c))
* **runtime:** correlate output deltas with raw trace runs ([#1748](https://github.com/jeong-sik/oas/issues/1748)) ([b16fecc](https://github.com/jeong-sik/oas/commit/b16feccff374a84621ecd969e5e9026c64f6ec0f))
* **runtime:** project checkpoint deltas from replay windows ([#1738](https://github.com/jeong-sik/oas/issues/1738)) ([e0377ad](https://github.com/jeong-sik/oas/commit/e0377ad0e574366fe6c8511e70bbda03a23ff5e7))
* **runtime:** restore paused agent input ([#1746](https://github.com/jeong-sik/oas/issues/1746)) ([0550489](https://github.com/jeong-sik/oas/commit/055048954d75481221bea1eb78c0b526f311e97d))
* **runtime:** resume paused input agents ([#1724](https://github.com/jeong-sik/oas/issues/1724)) ([59a49d5](https://github.com/jeong-sik/oas/commit/59a49d5413a3ae9cb7ec708971f53e12dfe1cec0))
* **structured:** expose schema extractors ([#1405](https://github.com/jeong-sik/oas/issues/1405)) ([08eed88](https://github.com/jeong-sik/oas/commit/08eed88c21e8146854f8199946bc87faf5a29544))
* **telemetry:** add SCA registry and audit tests for signal producer coverage ([1f57f3e](https://github.com/jeong-sik/oas/commit/1f57f3ebd1f2e678f638bcffe0ac0ebf87a61321))
* **telemetry:** per-turn typed telemetry events and bus ([7396ed6](https://github.com/jeong-sik/oas/commit/7396ed645cfb33a7f92df49f8c49806779044791))
* **telemetry:** RFC-OAS-019 Phase 1 — Streaming_summary at stream finalize ([#1578](https://github.com/jeong-sik/oas/issues/1578)) ([b26fed8](https://github.com/jeong-sik/oas/commit/b26fed80300016d987cbb5d0e9d817df9d02fe95))
* **telemetry:** wire ttfrc_ms and prefill_ms through patch_telemetry ([39f15ea](https://github.com/jeong-sik/oas/commit/39f15ea25dfa980375253af8f9b1c50815b17165))
* **telemetry:** wire ttfrc_ms and prefill_ms through patch_telemetry ([ef4ef9e](https://github.com/jeong-sik/oas/commit/ef4ef9e51d87411ec5a680a14385fcd613729974))
* **telemetry:** wire ttfrc_ms and prefill_ms to inference_telemetry ([98d5335](https://github.com/jeong-sik/oas/commit/98d5335fa0198e271dae98a420521f396af4934c))
* **timeout:** add provider timeout policy phases ([#1656](https://github.com/jeong-sik/oas/issues/1656)) ([540cb45](https://github.com/jeong-sik/oas/commit/540cb45918330e7ae274d2b919ef3c510425260d))
* **transport_claude_code:** expose stdout_idle_timeout_s on config ([#1459](https://github.com/jeong-sik/oas/issues/1459)) ([564e1e7](https://github.com/jeong-sik/oas/commit/564e1e71df332c159dccc5e8280c391e5053af94))
* **transport_codex_cli:** expose stdout_idle_timeout_s on config ([#1458](https://github.com/jeong-sik/oas/issues/1458)) ([64d3e1a](https://github.com/jeong-sik/oas/commit/64d3e1a90eb55f03f251d1b85a0dabe8b6aa2064))
* **transport_gemini_cli:** expose stdout_idle_timeout_s on config ([#1461](https://github.com/jeong-sik/oas/issues/1461)) ([5240005](https://github.com/jeong-sik/oas/commit/5240005c444adbec870ae032882d495af03674ca))
* **transport_kimi_cli:** expose stdout_idle_timeout_s on config ([#1460](https://github.com/jeong-sik/oas/issues/1460)) ([cbfd139](https://github.com/jeong-sik/oas/commit/cbfd139a90baadde01f9940e71b8ac2a8f706547))


### Bug Fixes

* add approval-required fail-closed policy ([#1630](https://github.com/jeong-sik/oas/issues/1630)) ([9f11c50](https://github.com/jeong-sik/oas/commit/9f11c506af1980554324e719427364a5b6461a42))
* add ollama cloud direct auth ([#1561](https://github.com/jeong-sik/oas/issues/1561)) ([9f265c1](https://github.com/jeong-sik/oas/commit/9f265c19fa477ab4810bff7ffca6083c652b8a95))
* **agent_sdk:** qualify base reexports ([#1389](https://github.com/jeong-sik/oas/issues/1389)) ([c310b2d](https://github.com/jeong-sik/oas/commit/c310b2d2fc31db2f83ce2fa447376be4df21f9c8))
* **agent_tools:** restrict find_in_index fallback to non-User tool IDs ([#1568](https://github.com/jeong-sik/oas/issues/1568)) ([5e68d21](https://github.com/jeong-sik/oas/commit/5e68d21d4530af6c8991ff769921749f2287d6ab))
* **agent_turn:** make reserve_strategy_budget strategy match exhaustive ([#1522](https://github.com/jeong-sik/oas/issues/1522)) ([c6428ae](https://github.com/jeong-sik/oas/commit/c6428ae937bd378ff72228671adcb9d328495dc7))
* **agent:** gate context overflow auto retry ([#1553](https://github.com/jeong-sik/oas/issues/1553)) ([8ed4183](https://github.com/jeong-sik/oas/commit/8ed4183fb20d97fe7b4dcb704b9a3d29d674ef4c))
* **agent:** hydrate relocated tool results on resume ([#1766](https://github.com/jeong-sik/oas/issues/1766)) ([8a80296](https://github.com/jeong-sik/oas/commit/8a80296c8372606f488e44c46b0faa97ccfb583e))
* **agent:** index tool lookup paths ([#1592](https://github.com/jeong-sik/oas/issues/1592)) ([31bda07](https://github.com/jeong-sik/oas/commit/31bda07bd54c4e902b35030ec4d71547718bd1ca))
* **agent:** narrow runtime mcp per turn ([#1596](https://github.com/jeong-sik/oas/issues/1596)) ([36f7b37](https://github.com/jeong-sik/oas/commit/36f7b3779b01c38f3d69e94374c6d0812cb96403))
* **agent:** order checkpoint completion effects ([#1552](https://github.com/jeong-sik/oas/issues/1552)) ([cfbdabd](https://github.com/jeong-sik/oas/commit/cfbdabdf1c40493b36b023a0a97248ff939d571a))
* **agent:** publish content replacement events by default ([#1767](https://github.com/jeong-sik/oas/issues/1767)) ([c23e8ba](https://github.com/jeong-sik/oas/commit/c23e8ba0efdd2fa9d7759d9cf263100d97386250))
* **agent:** route registry discovery through http client ([#1560](https://github.com/jeong-sik/oas/issues/1560)) ([c0ada64](https://github.com/jeong-sik/oas/commit/c0ada64d5b89196a06969f292b77268f36e03bab))
* **agent:** stop periodic callbacks on cancellation ([#1447](https://github.com/jeong-sik/oas/issues/1447)) ([217ed2a](https://github.com/jeong-sik/oas/commit/217ed2a1833118dbf4dfb7ba7d1d25f92fbbb3f2))
* **api_openai:** make is_zai_provider_config Provider.config match exhaustive ([#1523](https://github.com/jeong-sik/oas/issues/1523)) ([98814d1](https://github.com/jeong-sik/oas/commit/98814d1c56f151ca9b32b46d5e5639e09ab0869a))
* **api:** route legacy create_message through http client ([#1558](https://github.com/jeong-sik/oas/issues/1558)) ([a20ed9f](https://github.com/jeong-sik/oas/commit/a20ed9f812c30428e5168bc3aade3e1e86eceb92))
* **backend_gemini:** make has_tool_use content_block match exhaustive (N-of-M followup to [#1519](https://github.com/jeong-sik/oas/issues/1519)/[#1521](https://github.com/jeong-sik/oas/issues/1521)) ([#1525](https://github.com/jeong-sik/oas/issues/1525)) ([01d3276](https://github.com/jeong-sik/oas/commit/01d3276dcc48b37a9ee9ea42f1eee95c4b486e10))
* **backend_openai:** make Thinking-detection content_block matches exhaustive (2 sites, N-of-M followup) ([#1526](https://github.com/jeong-sik/oas/issues/1526)) ([591c961](https://github.com/jeong-sik/oas/commit/591c961fb8f14eb5f45c061774e0ba8fe465685b))
* bound cascade provider attempts ([#1375](https://github.com/jeong-sik/oas/issues/1375)) ([cafb7c0](https://github.com/jeong-sik/oas/commit/cafb7c00674dedc23328a5caa2294a584cfef114))
* **build:** resolve main build/test failures ([3381d9a](https://github.com/jeong-sik/oas/commit/3381d9abe8b37030e35888c659f7f254331b3a32))
* **build:** resolve main CI failures post-0.193.6 ([1b0593f](https://github.com/jeong-sik/oas/commit/1b0593f101ccf70aa443b364fa8f5d5c4ea5f54e))
* **capabilities:** keep reasoning effort overlay conservative ([44ef91e](https://github.com/jeong-sik/oas/commit/44ef91e7822792986e73c6356fa481dd3c46c173))
* **capabilities:** set Chat_template_kwargs for qwen3 ([#1614](https://github.com/jeong-sik/oas/issues/1614)) ([11181bb](https://github.com/jeong-sik/oas/commit/11181bb28147dc2b0e992885e9fabcba591f8b1c))
* **capabilities:** surface manifest load diagnostics ([#1381](https://github.com/jeong-sik/oas/issues/1381)) ([7afb3b0](https://github.com/jeong-sik/oas/commit/7afb3b0457f5b47c54231a3b20b3a7dac15f080b))
* **capability_manifest:** post-merge follow-up to [#1516](https://github.com/jeong-sik/oas/issues/1516) — Atomic.t + docstrings + test title ([#1529](https://github.com/jeong-sik/oas/issues/1529)) ([ea0023e](https://github.com/jeong-sik/oas/commit/ea0023ece0d9812995ebe8854bcfa1e8aa67f934))
* **capability_manifest:** remove duplicate doc text, fix SDK gate, apply ocamlformat ([5f248c1](https://github.com/jeong-sik/oas/commit/5f248c1d6f331a7e671942fc17afe2b877b7910f))
* **cascade:** gate provider attempts with throttle ([#1595](https://github.com/jeong-sik/oas/issues/1595)) ([30dcc69](https://github.com/jeong-sik/oas/commit/30dcc690119238418ba54e524b1032705cc01333))
* **cascade:** stop on TLS and local resource failures ([#1607](https://github.com/jeong-sik/oas/issues/1607)) ([1599ee0](https://github.com/jeong-sik/oas/commit/1599ee03516446007d96426f304bde4c3b3086d2))
* **cascade:** stop provider terminal fallthrough ([#1454](https://github.com/jeong-sik/oas/issues/1454)) ([15f3f0d](https://github.com/jeong-sik/oas/commit/15f3f0d9480d6d39df72f0c67403b590a1f17a97))
* **cascade:** use Eio mutex for provider health ([#1435](https://github.com/jeong-sik/oas/issues/1435)) ([a041368](https://github.com/jeong-sik/oas/commit/a04136828a78d45d2d6ecfed9563254b0bdbc170))
* **ci:** fill checkpoint delta usage fixture ([4624cf9](https://github.com/jeong-sik/oas/commit/4624cf936f1641bf72ea84033c9bb7a84f6bb7bc))
* **ci:** repair post-merge OAS main checks ([#1648](https://github.com/jeong-sik/oas/issues/1648)) ([39c1e76](https://github.com/jeong-sik/oas/commit/39c1e76ad851fef3f263781cbb19cef2e9cef839))
* **ci:** restore main build after usage update ([36425dc](https://github.com/jeong-sik/oas/commit/36425dc4e7f9a5d8453c11dff7765b7e177f618d))
* **ci:** restore main build after usage update ([9d8b912](https://github.com/jeong-sik/oas/commit/9d8b912743aedb567a0f65317ce2f3eaada27144))
* **collaboration:** make is_claimable claim_phase match exhaustive ([#1524](https://github.com/jeong-sik/oas/issues/1524)) ([a09983d](https://github.com/jeong-sik/oas/commit/a09983dd1c5006c764c9230d5a29ca5200bbfb00))
* **completion:** lower tool-choice fallback log noise ([#1608](https://github.com/jeong-sik/oas/issues/1608)) ([f53a814](https://github.com/jeong-sik/oas/commit/f53a814a7c1afec9d686c7410282d94be9abae4b))
* **content_block:** close 7 catch-all sites across pipeline + context_reducer + tool_use_recovery ([#1519](https://github.com/jeong-sik/oas/issues/1519)) ([c52b945](https://github.com/jeong-sik/oas/commit/c52b9451b6214a3fad94df79a61f1287505b446e))
* **context_reducer:** close 9 content_block catch-all sites in apply ([#1521](https://github.com/jeong-sik/oas/issues/1521)) ([92590ae](https://github.com/jeong-sik/oas/commit/92590ae10e99bbb929ad45705058964729555309))
* **context:** surface reducer repair diagnostics ([#1611](https://github.com/jeong-sik/oas/issues/1611)) ([688ee48](https://github.com/jeong-sik/oas/commit/688ee48efb3ffe227305b9ba52c8a0393f4bba03))
* **cost:** address Copilot review findings on the fail-closed path ([85f0e1f](https://github.com/jeong-sik/oas/commit/85f0e1fdd63c73a9712b2078b587e3c72551ce79))
* **cost:** fail closed when max_cost_usd is set + a turn ran an unpriced model ([dfa9bf1](https://github.com/jeong-sik/oas/commit/dfa9bf1c0ac363c571a2c4bc8556b413de47d02c))
* **cost:** fail closed when max_cost_usd is set + unpriced model ([6ec5725](https://github.com/jeong-sik/oas/commit/6ec5725f4e73093b5a7149bc467293d95b9390eb))
* **discovery:** validate env scan ports ([e6553c7](https://github.com/jeong-sik/oas/commit/e6553c7a8f8a10ef16883b49c15042071b89bce3))
* **dune:** add blank line between stanzas for ocamlformat ([6577be3](https://github.com/jeong-sik/oas/commit/6577be34f22b5ea9d98c3444ab3dba851b6a2e86))
* **dune:** remove orphaned (rule stanza from dune file ([1dc7af9](https://github.com/jeong-sik/oas/commit/1dc7af940a1e8c0093ea934a54b4cad208e48d14))
* **dune:** remove trailing blank line ([4df5435](https://github.com/jeong-sik/oas/commit/4df54355c85a7a34dd47b94e59b953aaa3ea8d43))
* **eval:** tag otel metric json exports ([#1423](https://github.com/jeong-sik/oas/issues/1423)) ([d610422](https://github.com/jeong-sik/oas/commit/d610422aec346db7df4b6da16da450ff50d578a2))
* expose cli stdout recovery metadata ([#1457](https://github.com/jeong-sik/oas/issues/1457)) ([31abd8e](https://github.com/jeong-sik/oas/commit/31abd8e84f790e8a0d4a30a66cffce11e8ba4526))
* **fmt:** join cons operator for Chat_template_kwargs ([#1329](https://github.com/jeong-sik/oas/issues/1329)) ([56931f1](https://github.com/jeong-sik/oas/commit/56931f1c44138a487fa7f51527e626f8f84b77ea))
* **fmt:** ocamlformat compliance followup for [#1324](https://github.com/jeong-sik/oas/issues/1324) ([118db54](https://github.com/jeong-sik/oas/commit/118db5437287f2d5c4124e2f0f23b0c9117b2650))
* **fmt:** ocamlformat compliance for thinking-control match and doc comments ([a671a12](https://github.com/jeong-sik/oas/commit/a671a1233db169cda0898fed810a2870d3330fe1))
* harden exhaustive matches on closed variants (capabilities/streaming/agent) ([#1517](https://github.com/jeong-sik/oas/issues/1517)) ([1cd5d5a](https://github.com/jeong-sik/oas/commit/1cd5d5a9926a2010ca990f66739823e536a5f83d))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([e92553e](https://github.com/jeong-sik/oas/commit/e92553ee4379b9b33277848bd0fdf1f95e743b8e))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([51692a5](https://github.com/jeong-sik/oas/commit/51692a51a1eeb85fa087d7cab5f04b1ae3544dc5))
* **http:** classify empty trust anchors as local resource ([#1610](https://github.com/jeong-sik/oas/issues/1610)) ([4e86499](https://github.com/jeong-sik/oas/commit/4e86499f4c84b8d7793ae8eea878a96ea7e98d63))
* **llm_provider:** extract hardcoded max_tokens 4096 fallback to Constants (S08) ([#1331](https://github.com/jeong-sik/oas/issues/1331)) ([89c9e12](https://github.com/jeong-sik/oas/commit/89c9e12d74d2b6fad58084e9a076300a7aab69b8))
* **llm_provider:** remove anti-patterns in thinking, error classification, and Gemini/GLM backends ([#1326](https://github.com/jeong-sik/oas/issues/1326)) ([df249b6](https://github.com/jeong-sik/oas/commit/df249b650e8456e588ec1a3bbd2f109bc882d6b8))
* **llm_provider:** replace Eio.traceln with Diag.warn in CLI transports (F02) ([#1333](https://github.com/jeong-sik/oas/issues/1333)) ([9756e7e](https://github.com/jeong-sik/oas/commit/9756e7e6ff79ffd94cb637d6cb9c8607552ceeaf))
* **llm:** expose optional transport latency ([#1463](https://github.com/jeong-sik/oas/issues/1463)) ([eed15b4](https://github.com/jeong-sik/oas/commit/eed15b4cf3bbfc2d050b68188a6870af34766436))
* **llm:** lower confidence for fallback capability drift ([#1555](https://github.com/jeong-sik/oas/issues/1555)) ([26339df](https://github.com/jeong-sik/oas/commit/26339df8cacecb49cb33ddaf0ab88a56f85c9874))
* **main:** unblock 3 CI categories after [#1469](https://github.com/jeong-sik/oas/issues/1469)-[#1471](https://github.com/jeong-sik/oas/issues/1471) cascade ([ebfc95d](https://github.com/jeong-sik/oas/commit/ebfc95d6fb94c4e5c2a1c47af1380aa3f78fdbff))
* **main:** unblock 3 CI categories after [#1469](https://github.com/jeong-sik/oas/issues/1469)-[#1471](https://github.com/jeong-sik/oas/issues/1471) merge cascade ([73d727b](https://github.com/jeong-sik/oas/commit/73d727b45fa283bd2bda693678c6bf32687c010d))
* **mcp:** preserve builtin tool permissions ([#1438](https://github.com/jeong-sik/oas/issues/1438)) ([f568a07](https://github.com/jeong-sik/oas/commit/f568a07b653870984dc38722bb2c436c74b78693))
* **memory:** persist episodic procedural backends ([#1594](https://github.com/jeong-sik/oas/issues/1594)) ([e87b73f](https://github.com/jeong-sik/oas/commit/e87b73fd90e83a79c66cf974e02002ec9a5eb9a2))
* **memory:** preserve long-term backend compatibility ([#1628](https://github.com/jeong-sik/oas/issues/1628)) ([2c046ee](https://github.com/jeong-sik/oas/commit/2c046ee883ef0df26a7f8acbf12cce22d8f4bc78))
* **metrics:** aggregate streaming latency samples ([#1577](https://github.com/jeong-sik/oas/issues/1577)) ([a33ac78](https://github.com/jeong-sik/oas/commit/a33ac78895a87db2ff824a4d394c3a108d7807ad))
* **metrics:** deduplicate histogram bucket bounds in prometheus export ([#1564](https://github.com/jeong-sik/oas/issues/1564)) ([b2e8403](https://github.com/jeong-sik/oas/commit/b2e8403897a43660f3ed6ca17529e9c4b7cdebdc))
* **metrics:** emit Circuit_open directly from open-skip branch ([#1566](https://github.com/jeong-sik/oas/issues/1566)) ([8969475](https://github.com/jeong-sik/oas/commit/8969475eb8323d17400a8ba53632961173d0cad3))
* **metrics:** persist provider snapshots as json ([#1573](https://github.com/jeong-sik/oas/issues/1573)) ([d5037d2](https://github.com/jeong-sik/oas/commit/d5037d2346e7e13f5488a13495e65722b0a0a268))
* **metrics:** reject duplicate histogram buckets at register time ([#1643](https://github.com/jeong-sik/oas/issues/1643)) ([2db3378](https://github.com/jeong-sik/oas/commit/2db337807cc71e7bed79accb6d69e82f38029057))
* **metrics:** reject normalized-name collisions at register time ([#1570](https://github.com/jeong-sik/oas/issues/1570)) ([54d4b71](https://github.com/jeong-sik/oas/commit/54d4b71246d382aa8b3561c1a473e8efd9c48d9f))
* **metrics:** reject open-circuit snapshots without failure timestamp ([#1575](https://github.com/jeong-sik/oas/issues/1575)) ([fedcd13](https://github.com/jeong-sik/oas/commit/fedcd13664e32edd03f47b2763ad131cb7d2184c))
* **metrics:** support labeled histograms ([#1572](https://github.com/jeong-sik/oas/issues/1572)) ([e9f5ac6](https://github.com/jeong-sik/oas/commit/e9f5ac6dad19d380e5cb068caafe16eed7800ed6))
* **ollama:** preserve tool calls and avoid hard timeouts ([#1609](https://github.com/jeong-sik/oas/issues/1609)) ([64ec834](https://github.com/jeong-sik/oas/commit/64ec834685faf8f3ecc58817d6020f4aa6ab3126))
* **otel:** propagate trace context to provider calls ([#1576](https://github.com/jeong-sik/oas/issues/1576)) ([4060baa](https://github.com/jeong-sik/oas/commit/4060baac4b8f83468091f66011492c5b4981c7ad))
* **paths:** replace assert false with invalid_arg, document MCP env var ([#1597](https://github.com/jeong-sik/oas/issues/1597)) ([9efc99d](https://github.com/jeong-sik/oas/commit/9efc99d9a91ed8b7b9658bcc34beb2cbba5d3db0))
* **pipeline:** count runtime MCP tools for tool_choice ([#1593](https://github.com/jeong-sik/oas/issues/1593)) ([f488eab](https://github.com/jeong-sik/oas/commit/f488eabf5d756ffb4a258465663aaf74ea295f42))
* **pipeline:** drop unused agent arg from turn_ready_tool_names callers ([#1599](https://github.com/jeong-sik/oas/issues/1599)) ([7489923](https://github.com/jeong-sik/oas/commit/748992379de975e3b7d705bd29dd6815864ea927))
* **pipeline:** reject invisible tool choice contracts ([#1579](https://github.com/jeong-sik/oas/issues/1579)) ([b33e626](https://github.com/jeong-sik/oas/commit/b33e6267b49913f7fd1b2c59253403d8bf3b24e5))
* **pipeline:** reuse accumulated usage in collect stage ([#1764](https://github.com/jeong-sik/oas/issues/1764)) ([fde41d7](https://github.com/jeong-sik/oas/commit/fde41d76d84ed01ff6a22598c2dd61fd5310d970))
* **plan:** make progress + is_done variant matches exhaustive ([#1518](https://github.com/jeong-sik/oas/issues/1518)) ([fd82743](https://github.com/jeong-sik/oas/commit/fd827431dc98a0f41fcf3dc7409f6c5bdc35e103))
* propagate provider clocks to completions ([#1319](https://github.com/jeong-sik/oas/issues/1319)) ([6a7b4d1](https://github.com/jeong-sik/oas/commit/6a7b4d1b23216b98dd5a6957dfb19c9d00220410))
* **provider_catalog:** fail-fast on unknown enum strings ([bb73cdc](https://github.com/jeong-sik/oas/commit/bb73cdc0d0db9afaae67c6d66a314d8169af7275))
* **provider_catalog:** fail-fast on unknown enum strings ([5a1cf67](https://github.com/jeong-sik/oas/commit/5a1cf674ff379871d20388b24f14fecc0e9b45d9))
* **provider:** apply ocamlformat to catalog overlay ([edb91b2](https://github.com/jeong-sik/oas/commit/edb91b29d35df8130d844e531a7492af89e3fefc))
* **provider:** apply ocamlformat to catalog overlay ([0b58dfe](https://github.com/jeong-sik/oas/commit/0b58dfecd53d0b5b7687051e3fcfea3588add8e1))
* **provider:** include context for empty HTTP errors ([#1582](https://github.com/jeong-sik/oas/issues/1582)) ([3b49c50](https://github.com/jeong-sik/oas/commit/3b49c5049faee63b045f641bfd4fb0cde0f6ebcd))
* **provider:** persist cascade health snapshots ([#1584](https://github.com/jeong-sik/oas/issues/1584)) ([4277673](https://github.com/jeong-sik/oas/commit/42776731e1ae0b6e505557c6912240f1550a3a3e))
* **provider:** remove GLM tool_choice coerce anti-pattern ([#1351](https://github.com/jeong-sik/oas/issues/1351)) ([7132e1f](https://github.com/jeong-sik/oas/commit/7132e1f178599db7d66503518c5abfd6ce1c7c56))
* **provider:** resolve runtime binding capabilities by config ([#1589](https://github.com/jeong-sik/oas/issues/1589)) ([da757ff](https://github.com/jeong-sik/oas/commit/da757ffc1ebc7a7c94c25370755b9a683b6ce412))
* **provider:** route provider intf through http client ([#1559](https://github.com/jeong-sik/oas/issues/1559)) ([b249b58](https://github.com/jeong-sik/oas/commit/b249b5887064e8da87b04697521742279103b72f))
* **provider:** surface OpenAI harness parse errors ([#1581](https://github.com/jeong-sik/oas/issues/1581)) ([42273ee](https://github.com/jeong-sik/oas/commit/42273ee4a4daf9a68aa5f3aa68b2c553be3cd05e))
* **raw-trace:** require explicit evidence roles ([#1650](https://github.com/jeong-sik/oas/issues/1650)) ([0f4ff62](https://github.com/jeong-sik/oas/commit/0f4ff62afe0ef23895c02ecbf1cbf882709439e3))
* recognize bare GLM model ids in capabilities ([#1763](https://github.com/jeong-sik/oas/issues/1763)) ([44b5ff9](https://github.com/jeong-sik/oas/commit/44b5ff94c719bf03de03d48b6ace82b4289b613e))
* **release:** automate agent_sdk.opam sync inside release-please workflow ([#1604](https://github.com/jeong-sik/oas/issues/1604)) ([4b00bdf](https://github.com/jeong-sik/oas/commit/4b00bdff217e6233ed15bcc722d9aed410c36eba))
* remove coordinator-specific OAS hardcoding ([#1639](https://github.com/jeong-sik/oas/issues/1639)) ([16f0075](https://github.com/jeong-sik/oas/commit/16f0075f5106c8013fc9305ded2d4a59e1ee1557))
* remove mutable anti-patterns — O(n) append, dead mutable, debug printf ([#1619](https://github.com/jeong-sik/oas/issues/1619)) ([5f8e07b](https://github.com/jeong-sik/oas/commit/5f8e07b777285f59c111b1a866166604d5bc4a1a))
* resolve CI failures (coverage, syntax error, sdk gate) ([90303e0](https://github.com/jeong-sik/oas/commit/90303e03addfa5cee334806c8c864c9faff47a91))
* resolve main build failures after release 0.193.6 ([#1532](https://github.com/jeong-sik/oas/issues/1532)) ([04447d4](https://github.com/jeong-sik/oas/commit/04447d4e1ded4ccc49bc101a209d404b206e1a10))
* **retry:** classify admin-disabled and account-suspended 429s as hard quota ([#1358](https://github.com/jeong-sik/oas/issues/1358)) ([45b6af2](https://github.com/jeong-sik/oas/commit/45b6af2f3c3fc59d03a018f727878e5999d417f6))
* **retry:** stop cascade on account usage limit ([#1428](https://github.com/jeong-sik/oas/issues/1428)) ([5ead30d](https://github.com/jeong-sik/oas/commit/5ead30d0c0ca7b72de32b8767bcea411a844eaed))
* **review:** harden recent OAS follow-ups ([66cff92](https://github.com/jeong-sik/oas/commit/66cff92c1987db2f9f69141d8ca736f91f8c11be))
* **runtime:** absorb runtime_server_worker into runtime_server, restore runtime_evidence ([b09ace3](https://github.com/jeong-sik/oas/commit/b09ace33a5b19934aa5057a6e6955ad7c9c16609))
* **runtime:** absorb runtime_server_worker, restore runtime_evidence ([692a4c2](https://github.com/jeong-sik/oas/commit/692a4c2348d1240ed50fc9102c28c9081e61c2f1))
* **scripts:** recognize release-please CHANGELOG header format ([#1513](https://github.com/jeong-sik/oas/issues/1513)) ([188efa6](https://github.com/jeong-sik/oas/commit/188efa67bdb95de6888f0c7660d236e3cc9de2df))
* **sessions:** drop stale parser helper signature ([#1670](https://github.com/jeong-sik/oas/issues/1670)) ([c701d0f](https://github.com/jeong-sik/oas/commit/c701d0f2de0ae01e91b83bea1e1f6491d4877603))
* **spec:** include input-required runtime phase ([#1769](https://github.com/jeong-sik/oas/issues/1769)) ([a341140](https://github.com/jeong-sik/oas/commit/a341140be322059c065b7f967924f33c2ec8ba49))
* **streaming:** surface SSE parse failures instead of silent discard ([#1357](https://github.com/jeong-sik/oas/issues/1357)) ([83e40ea](https://github.com/jeong-sik/oas/commit/83e40ea8263a3ef101426b8e9e395e69d510c954))
* **telemetry:** emit context window usage ([#1583](https://github.com/jeong-sik/oas/issues/1583)) ([070b9d4](https://github.com/jeong-sik/oas/commit/070b9d46d764d45d56b506d7edd51188a529a779))
* **test:** make telemetry SCA repo-root discovery fail fast ([b9d4f57](https://github.com/jeong-sik/oas/commit/b9d4f57e21904658f7163e6fcfe52f0fb18b6072))
* **test:** remove duplicate test_telemetry_sca — superseded by test/telemetry_sca/ ([4bab73f](https://github.com/jeong-sik/oas/commit/4bab73fa6236b4e4b8fac6c3d027a206780b217a))
* **test:** rescue test_discovery orphan (record field supports_tools) ([#1392](https://github.com/jeong-sik/oas/issues/1392)) ([720305e](https://github.com/jeong-sik/oas/commit/720305e75c1187fff939507bcbc45a56931b01db))
* **test:** rescue test_pipeline_deep orphan (record field enable_thinking) ([#1394](https://github.com/jeong-sik/oas/issues/1394)) ([5613191](https://github.com/jeong-sik/oas/commit/5613191bd681d10012fde7a24dd9b4211059f45b))
* **test:** rescue test_provider_config orphan (record field reasoning_tokens_estimated) ([#1388](https://github.com/jeong-sik/oas/issues/1388)) ([2724b1f](https://github.com/jeong-sik/oas/commit/2724b1fa67e299f768a99ecd8370be274c4e2582))
* tolerate release version markers ([#1708](https://github.com/jeong-sik/oas/issues/1708)) ([a5cd80f](https://github.com/jeong-sik/oas/commit/a5cd80fd1ffbc12ef3f5188d9c754ebd114958be))
* **tool_selector:** replace failwith with empty list for unimplemented LLM categorical classifier ([#1455](https://github.com/jeong-sik/oas/issues/1455)) ([496c329](https://github.com/jeong-sik/oas/commit/496c329bc4423fb1ddbe61507bbc6b5df1ba23a9))
* **tools:** enforce shell descriptor constraints ([#1602](https://github.com/jeong-sik/oas/issues/1602)) ([ce90f5d](https://github.com/jeong-sik/oas/commit/ce90f5d2575d54ec339bdfd2744c019a8849414f))
* type provider reasoning controls ([#1709](https://github.com/jeong-sik/oas/issues/1709)) ([a2bf6e1](https://github.com/jeong-sik/oas/commit/a2bf6e1c192f59717fe47f7f57f74458e3ffbcaa))
* **types:** preserve missing response usage ([#1449](https://github.com/jeong-sik/oas/issues/1449)) ([9639c92](https://github.com/jeong-sik/oas/commit/9639c9204c75c17d5c4e260111b8cb1be5ea257c))
* warn on invalid cli integer env ([#1456](https://github.com/jeong-sik/oas/issues/1456)) ([21dea98](https://github.com/jeong-sik/oas/commit/21dea9862fab506eb8983740c9c12951b32dbe94))
* wrap agent_sdk base library ([c7fc03b](https://github.com/jeong-sik/oas/commit/c7fc03b19085e8acf8d647f4ea99838d89e539bd))
* **zai_catalog:** remove unsupported glm-5-code from coding auto-models ([92f108c](https://github.com/jeong-sik/oas/commit/92f108c6045b1e0065504ab059ac85a144db7f39))
* **zai_catalog:** remove unsupported glm-5-code from coding auto-models ([186e51c](https://github.com/jeong-sik/oas/commit/186e51c24e0e1eadc50840073396630cdb6b74b9))


### Performance Improvements

* **completion_contract:** build tool-lookup index lazily ([#1600](https://github.com/jeong-sik/oas/issues/1600)) ([e605a13](https://github.com/jeong-sik/oas/commit/e605a133d798a1e1e308727643b59692a5c2bc25))


### Code Refactoring

* remove migrated CDAL modules + façade re-exports (RFC-OAS-011 OAS-E PR-6) ([c5b120d](https://github.com/jeong-sik/oas/commit/c5b120d6f04eb8ea203dec2d1ffc5f8920656cdf))

## [0.199.0](https://github.com/jeong-sik/oas/compare/v0.198.5...v0.199.0) (2026-05-26)

### ⚠ BREAKING CHANGES

* **runtime:** remove retired domain projection event types, schema catalog entry, and projection helpers from `Runtime` / `Runtime_projection`

### Features

* **agent_tool:** add typed child-agent invocation wrapper for agent-as-tool parity
* **raw-trace:** include typed evidence role summaries in validation results

### Documentation

* **rfc:** RFC-OAS-023 capability axis reshape (model × transport) — hybrid naming + two-record capability composition. supersedes RFC-0001 naming policy. supplements RFC-OAS-018 catalog externalization. 0/13 cascade × OAS audit + 16:42 runtime drift WARN evidence. Phase 1 sweep follow-up (variant + file rename, ~140-150 files) planned for next release.
* **rfc:** RFC-0001 status Draft → Withdrawn (superseded by RFC-OAS-023). vendor brand cipher substitution self-critique per `feedback_vendor_brand_substitution_is_encryption_not_abstraction` (2026-05-24).

## [0.198.5](https://github.com/jeong-sik/oas/compare/v0.198.4...v0.198.5) (2026-05-26)


### Bug Fixes

* **agent:** hydrate relocated tool results on resume ([#1766](https://github.com/jeong-sik/oas/issues/1766)) ([8a80296](https://github.com/jeong-sik/oas/commit/8a80296c8372606f488e44c46b0faa97ccfb583e))
* **pipeline:** reuse accumulated usage in collect stage ([#1764](https://github.com/jeong-sik/oas/issues/1764)) ([fde41d7](https://github.com/jeong-sik/oas/commit/fde41d76d84ed01ff6a22598c2dd61fd5310d970))
* recognize bare GLM model ids in capabilities ([#1763](https://github.com/jeong-sik/oas/issues/1763)) ([44b5ff9](https://github.com/jeong-sik/oas/commit/44b5ff94c719bf03de03d48b6ace82b4289b613e))
* **spec:** include input-required runtime phase ([#1769](https://github.com/jeong-sik/oas/issues/1769)) ([a341140](https://github.com/jeong-sik/oas/commit/a341140be322059c065b7f967924f33c2ec8ba49))

## [0.198.4](https://github.com/jeong-sik/oas/compare/v0.198.3...v0.198.4) (2026-05-24)


### Features

* **eval:** gate code snippet adoption criteria ([#1751](https://github.com/jeong-sik/oas/issues/1751)) ([2a3e688](https://github.com/jeong-sik/oas/commit/2a3e688bbc03785e2232447e4b88f3d6963b3dd4))

## [0.198.3](https://github.com/jeong-sik/oas/compare/v0.198.2...v0.198.3) (2026-05-24)


### Features

* **runtime:** correlate output deltas with raw trace runs ([#1748](https://github.com/jeong-sik/oas/issues/1748)) ([b16fecc](https://github.com/jeong-sik/oas/commit/b16feccff374a84621ecd969e5e9026c64f6ec0f))

## [0.198.2](https://github.com/jeong-sik/oas/compare/v0.198.1...v0.198.2) (2026-05-24)


### Features

* **runtime:** restore paused agent input ([#1746](https://github.com/jeong-sik/oas/issues/1746)) ([0550489](https://github.com/jeong-sik/oas/commit/055048954d75481221bea1eb78c0b526f311e97d))

## [0.198.1](https://github.com/jeong-sik/oas/compare/v0.198.0...v0.198.1) (2026-05-24)


### Features

* **agent_tool:** add typed child invocation ([#1744](https://github.com/jeong-sik/oas/issues/1744)) ([cbbd543](https://github.com/jeong-sik/oas/commit/cbbd5434cb92c97340bba4fd05ce2fe6c7f48310))

## [0.198.0](https://github.com/jeong-sik/oas/compare/v0.197.0...v0.198.0) (2026-05-24)


### ⚠ BREAKING CHANGES

* remove migrated CDAL modules + façade re-exports (RFC-OAS-011 OAS-E PR-6)

### Features

* add ppx_let support with Let_syntax in Result_syntax ([#1353](https://github.com/jeong-sik/oas/issues/1353)) ([9aeb72c](https://github.com/jeong-sik/oas/commit/9aeb72cb33e845fe99cf8e5983cf957a7022de84))
* add runtime run window reads ([#1716](https://github.com/jeong-sik/oas/issues/1716)) ([c11b35b](https://github.com/jeong-sik/oas/commit/c11b35bb9142b5261d4b61daa324a8792fd85324))
* **agent_tools:** remove CDAL builtin_descriptor fallback (RFC-OAS-009 v2 PR-B) ([39082f6](https://github.com/jeong-sik/oas/commit/39082f6005888209a5b16c6aaa0b60bd25df050f))
* **agent_tools:** remove CDAL builtin_descriptor fallback (RFC-OAS-009 v2 PR-B) ([41d0144](https://github.com/jeong-sik/oas/commit/41d0144f22fbfc36ea0da2c92487caff638bf807))
* **agent:** add disclosure_level for tool schema serialization ([#1508](https://github.com/jeong-sik/oas/issues/1508)) ([f48ccec](https://github.com/jeong-sik/oas/commit/f48ccec3d1f6045627bb51c913944b7b879baf4d))
* **agent:** add disclosure_resolver for per-turn adaptive disclosure ([#1511](https://github.com/jeong-sik/oas/issues/1511)) ([7ed9c05](https://github.com/jeong-sik/oas/commit/7ed9c05260dce7b813bfaf524a2799573eb6479d))
* **agent:** add turn durability checkpoints ([#1550](https://github.com/jeong-sik/oas/issues/1550)) ([393ff0c](https://github.com/jeong-sik/oas/commit/393ff0c432734c6e2c471fd78b6ebba0040b48aa))
* **agent:** index tool dispatch lookups ([#1557](https://github.com/jeong-sik/oas/issues/1557)) ([b7ea8e6](https://github.com/jeong-sik/oas/commit/b7ea8e6b00dd5ad1d3f4bbadeb26a071228c52f5))
* **agent:** pause on async elicitation ([#1722](https://github.com/jeong-sik/oas/issues/1722)) ([b40e955](https://github.com/jeong-sik/oas/commit/b40e9557ad3f404c692159d3fd018da368f9c63e))
* **arch:** decouple OAS from MASC by purging A2A and Handoff ([#1322](https://github.com/jeong-sik/oas/issues/1322)) ([d98e00e](https://github.com/jeong-sik/oas/commit/d98e00e43c405850d2fc80e7f52a93ac03c37bcf))
* **base:** Tool_id closed Variant identifier (RFC-OAS-008 PR-2/5) ([3c67d1e](https://github.com/jeong-sik/oas/commit/3c67d1e510fca49692937effd08cefc89aebd079))
* **base:** Tool_id closed Variant identifier (RFC-OAS-008 PR-2/5) ([8f413f8](https://github.com/jeong-sik/oas/commit/8f413f8a063273524f4fd2a22d14e69b1934709e))
* **bench:** TTFT distribution bench + SLO doc (RFC-OAS-020 PR-1b) ([#1625](https://github.com/jeong-sik/oas/issues/1625)) ([2ef4b25](https://github.com/jeong-sik/oas/commit/2ef4b25eade1d4fd6b6292e99842a97c8a78634b))
* bridge runtime windows to sync replay ([#1720](https://github.com/jeong-sik/oas/issues/1720)) ([1b98e4d](https://github.com/jeong-sik/oas/commit/1b98e4dcf6368fea5b452967df67eaa822969e5c))
* **capabilities:** add prefix-match ordering regression test for for_model_id (M01) ([#1361](https://github.com/jeong-sik/oas/issues/1361)) ([711e5a0](https://github.com/jeong-sik/oas/commit/711e5a0164081ab1a91745d5d5e3afbe4e1aaa4d))
* **capabilities:** add thinking_control_format and structured capability_drop metrics ([b596d78](https://github.com/jeong-sik/oas/commit/b596d7896daf8b8b488acc3e116843437de2ad93))
* **capabilities:** add thinking_control_format and structured capability_drop metrics ([bff40ae](https://github.com/jeong-sik/oas/commit/bff40aed2578a5b138050dd35b2352488773b9b1))
* **capabilities:** Ollama dynamic capability discovery via /api/show (M03) ([#1362](https://github.com/jeong-sik/oas/issues/1362)) ([eca778b](https://github.com/jeong-sik/oas/commit/eca778bc1e7f6b79ab7c5c734f63da857bd438e7))
* **capabilities:** runtime model capability manifest (H12) ([#1347](https://github.com/jeong-sik/oas/issues/1347)) ([1299541](https://github.com/jeong-sik/oas/commit/1299541bbd5ed25646c69637c4080efa6bfd6cd0))
* **capability_manifest:** add set_global / clear_global runtime override ([#1516](https://github.com/jeong-sik/oas/issues/1516)) ([c3a786f](https://github.com/jeong-sik/oas/commit/c3a786f36f6fc37306c1f8932267b9f684180ed5))
* **ci:** boundary-lint for core→CDAL zero dependency (RFC-OAS-009 v2 PR-D) ([b0c7a44](https://github.com/jeong-sik/oas/commit/b0c7a4484fe1a6514c1a308e9ce01581e356c81a))
* **ci:** boundary-lint for core→CDAL zero dependency (RFC-OAS-009 v2 PR-D) ([f53a3f5](https://github.com/jeong-sik/oas/commit/f53a3f550a9b27848cc58e52ed024036cb86f281))
* **ci:** expand boundary-lint to 20 CDAL prefixes (RFC-OAS-011 OAS-E PR-1) ([0a306ce](https://github.com/jeong-sik/oas/commit/0a306ce0f30e28d44e780eedb68551d2ded634a3))
* **ci:** expand boundary-lint to 20 CDAL prefixes (RFC-OAS-011 OAS-E PR-1) ([e189ed7](https://github.com/jeong-sik/oas/commit/e189ed75b1d25b97a6bf9c4d8536d7c5b79188bc))
* **complete:** add body_timeout_s to non-streaming complete + complete_with_retry ([#1622](https://github.com/jeong-sik/oas/issues/1622)) ([79262f3](https://github.com/jeong-sik/oas/commit/79262f374d70798cc76dc43f1503c5f329dfe204))
* **completion-contract:** add typed violation_detail with satisfying_tools ([#1642](https://github.com/jeong-sik/oas/issues/1642)) ([42c125f](https://github.com/jeong-sik/oas/commit/42c125f6e31c422dcf387a3546a0ffdbcea1bde0))
* **context:** dynamic prompt cache alignment & budget compaction ([49823a6](https://github.com/jeong-sik/oas/commit/49823a614296289568e040ec197473e626031a2f))
* **context:** dynamic prompt cache alignment & budget compaction ([dd6f37e](https://github.com/jeong-sik/oas/commit/dd6f37ea70563c971b08103138fee80444aead55))
* **error:** carry completion contract violation detail ([#1660](https://github.com/jeong-sik/oas/issues/1660)) ([609600d](https://github.com/jeong-sik/oas/commit/609600d896af320868b9578d278e5752f8f28075))
* GLM-5-Code models and Kimi CLI model restrictions ([#1334](https://github.com/jeong-sik/oas/issues/1334)) ([6be9be9](https://github.com/jeong-sik/oas/commit/6be9be9be1b601cc797a3e3fbbda8524c95da4f3))
* **guardrails_async:** add per-validator deadline to prevent silent stall ([#1368](https://github.com/jeong-sik/oas/issues/1368)) ([b9e5f09](https://github.com/jeong-sik/oas/commit/b9e5f09791c7ef0f608f1dcc512dadc9368fdeb2))
* **guardrails:** tighten default tool_filter to DenyList + cap ([#1370](https://github.com/jeong-sik/oas/issues/1370)) ([7fa5cdc](https://github.com/jeong-sik/oas/commit/7fa5cdc9a264ef634c1069702dbfc4d90114c064))
* **lib:** add Cognitive_event typed schema (RFC-0036 PR-B) ([#1451](https://github.com/jeong-sik/oas/issues/1451)) ([f848e75](https://github.com/jeong-sik/oas/commit/f848e75a298827722d5f6cff8162f954ae20f974))
* **llm_provider:** Fd_throttle_hook injection point (RFC-0101 PR-3) ([#1618](https://github.com/jeong-sik/oas/issues/1618)) ([29cbbc5](https://github.com/jeong-sik/oas/commit/29cbbc5b1d1593ba77e9c9a6cccac716051f88c2))
* **llm_provider:** implement usage token restoration for CLI wrappers (P7) ([#1342](https://github.com/jeong-sik/oas/issues/1342)) ([53c921a](https://github.com/jeong-sik/oas/commit/53c921a47635c4bc03c42ad33f95dc3f3ebea429))
* **llm_provider:** RFC-0058 Phase B — CLI transport factory ([#1520](https://github.com/jeong-sik/oas/issues/1520)) ([41e87e0](https://github.com/jeong-sik/oas/commit/41e87e0cd1fe4d57c4f627958b34fcf419839745))
* **llm_provider:** typed TTFT capture + prefill_ms field (RFC-OAS-020 PR-1a) ([#1620](https://github.com/jeong-sik/oas/issues/1620)) ([37b4a0c](https://github.com/jeong-sik/oas/commit/37b4a0cd2a0303282579641038858f222a115547))
* **llm_provider:** Visual_first modality ordering for Gemma 4 ([cf94ce9](https://github.com/jeong-sik/oas/commit/cf94ce9a95deaa34270f3f3c1cb75347ba5ea59d))
* **llm_provider:** Visual_first modality ordering for Gemma 4 ([791eee8](https://github.com/jeong-sik/oas/commit/791eee8b6266fe91d762f76544ae525bb4992f7c))
* **llm_provider:** wire ttfrc_ms and prefill_ms into inference_telemetry ([809b63a](https://github.com/jeong-sik/oas/commit/809b63a5c4dfbeed427d660295de26df3ed928eb))
* **log:** count records dropped without sinks ([#1402](https://github.com/jeong-sik/oas/issues/1402)) ([d039517](https://github.com/jeong-sik/oas/commit/d039517fef5daa0a740545bb1b99661decfa1185))
* **manifest:** carry provider health evidence ([#1398](https://github.com/jeong-sik/oas/issues/1398)) ([07a06e4](https://github.com/jeong-sik/oas/commit/07a06e49e313294a3d3d721dd8d8f2e1badbb39b))
* **mcp_schema:** remove descriptor_for_builtin_tool alias (RFC-OAS-009 v2 PR-C) ([ffb8aff](https://github.com/jeong-sik/oas/commit/ffb8aff3a3bac4bdfce823fe41ca176226ba2f13))
* **mcp_schema:** remove descriptor_for_builtin_tool alias (RFC-OAS-009 v2 PR-C) ([2c41611](https://github.com/jeong-sik/oas/commit/2c416118433aa703f97f1e891b5671e9f67bb931))
* **mcp:** cli provider integration and ollama dynamic capabilities ([8c460d0](https://github.com/jeong-sik/oas/commit/8c460d011b1aed997b106765f48f567a69e6eefd))
* **mcp:** cli provider integration and ollama dynamic capabilities ([230773e](https://github.com/jeong-sik/oas/commit/230773ee8642e44d928a539215e04401957a1cb1))
* **memory:** expose typed long-term retrieve result ([#1627](https://github.com/jeong-sik/oas/issues/1627)) ([0be7c3c](https://github.com/jeong-sik/oas/commit/0be7c3c37fdbfcf69f8c93cdce0514fddedae7e3))
* **metrics:** add Prometheus text export ([#1556](https://github.com/jeong-sik/oas/issues/1556)) ([fc02639](https://github.com/jeong-sik/oas/commit/fc02639b940afe6714f207f08c41dc393e112260))
* **metrics:** emit cascade circuit state ([#1563](https://github.com/jeong-sik/oas/issues/1563)) ([1f69740](https://github.com/jeong-sik/oas/commit/1f69740fb423cc68c04b7d300597a9f164499c84))
* OAS Execution Manifest 고도화 및 Rate Limit Quota (P0~P1) ([44d8c84](https://github.com/jeong-sik/oas/commit/44d8c84676152ffb5eafb24da1ebb01db2d41ddd))
* **oas:** TLA+ CI gate + AgentCancellation spec + lifecycle_status yojson ([#1467](https://github.com/jeong-sik/oas/issues/1467)) ([7cd282f](https://github.com/jeong-sik/oas/commit/7cd282fed27ef6aa0637a6a12ca9356621619039))
* P0-P3 goals implementation (Rate limit quota, cascade config) ([1e58068](https://github.com/jeong-sik/oas/commit/1e580685527369f582836bd7aa6afedc59f1f4de))
* persist runtime input-required state ([#1714](https://github.com/jeong-sik/oas/issues/1714)) ([656ac61](https://github.com/jeong-sik/oas/commit/656ac61937810763a600a268bd671c7fe8beba30))
* preserve provider timeout evidence ([#1632](https://github.com/jeong-sik/oas/issues/1632)) ([5001b3b](https://github.com/jeong-sik/oas/commit/5001b3b866fce8a31dc5e6f78a654d8ae6e560e5))
* **pricing:** dynamic model pricing lookup via env vars (H11) ([#1348](https://github.com/jeong-sik/oas/issues/1348)) ([3017770](https://github.com/jeong-sik/oas/commit/301777035fe23868e27d4d3fa7544f7f3e534fc6))
* provider cascade routing + agent_sdk.base extraction (B→B+) ([#1346](https://github.com/jeong-sik/oas/issues/1346)) ([ac2e6e0](https://github.com/jeong-sik/oas/commit/ac2e6e04f155f687936ac41a55daaf003c3d0655))
* **provider:** add external provider catalog overlay ([35241e9](https://github.com/jeong-sik/oas/commit/35241e9a82ce30360449f19a115d6589041f8f79))
* **provider:** expose runtime bindings ([#1585](https://github.com/jeong-sik/oas/issues/1585)) ([dbabd5c](https://github.com/jeong-sik/oas/commit/dbabd5ca7daf3ab25a861973ba346faddd442201))
* **provider:** load external provider catalog ([a13a1d0](https://github.com/jeong-sik/oas/commit/a13a1d0caa6baf0eaf77cfaa1e0ebdbed380d490))
* **provider:** map transport errors to typed provider errors ([#1448](https://github.com/jeong-sik/oas/issues/1448)) ([e804755](https://github.com/jeong-sik/oas/commit/e804755e3fb4ce81c33cd2b32880b206c588c28a))
* **provider:** P0-P7 LLM provider improvement plan implementation ([#1337](https://github.com/jeong-sik/oas/issues/1337)) ([8fbd8ac](https://github.com/jeong-sik/oas/commit/8fbd8ac7a9570ac2311c0fdeb158c7efd3ff0360))
* **raw-trace:** add evidence role validation seam ([#1647](https://github.com/jeong-sik/oas/issues/1647)) ([f9f1c9f](https://github.com/jeong-sik/oas/commit/f9f1c9fad7c36eac04c95ac17fda0b001a58ff00))
* **raw-trace:** expose evidence role summaries ([#1653](https://github.com/jeong-sik/oas/issues/1653)) ([9d2b2e5](https://github.com/jeong-sik/oas/commit/9d2b2e5c2739135d73f7aecdbcf04ed8fceff4c3))
* **raw-trace:** expose validation evidence roles ([#1658](https://github.com/jeong-sik/oas/issues/1658)) ([6d79276](https://github.com/jeong-sik/oas/commit/6d79276611261d0c64a8beebdf2e673e38cba74e))
* **release:** adopt release-please for version + CHANGELOG automation ([fd9931d](https://github.com/jeong-sik/oas/commit/fd9931d7f60f3b966140fdc700fd29c982ac5ea5))
* **release:** adopt release-please for version + CHANGELOG automation ([058ea4b](https://github.com/jeong-sik/oas/commit/058ea4bea2205b21854960f7cd4cb885043a9de8))
* **runtime:** add collaboration projection contract ([#1260](https://github.com/jeong-sik/oas/issues/1260)) ([189a91c](https://github.com/jeong-sik/oas/commit/189a91c4d72fc33add247cb2f2e21cc058ee3149))
* **runtime:** add durable relay delivery primitive ([#1383](https://github.com/jeong-sik/oas/issues/1383)) ([b056099](https://github.com/jeong-sik/oas/commit/b056099b5de703da53d6b2f774db9847f5a18b7c))
* **runtime:** project checkpoint deltas from replay windows ([#1738](https://github.com/jeong-sik/oas/issues/1738)) ([e0377ad](https://github.com/jeong-sik/oas/commit/e0377ad0e574366fe6c8511e70bbda03a23ff5e7))
* **runtime:** resume paused input agents ([#1724](https://github.com/jeong-sik/oas/issues/1724)) ([59a49d5](https://github.com/jeong-sik/oas/commit/59a49d5413a3ae9cb7ec708971f53e12dfe1cec0))
* **structured:** expose schema extractors ([#1405](https://github.com/jeong-sik/oas/issues/1405)) ([08eed88](https://github.com/jeong-sik/oas/commit/08eed88c21e8146854f8199946bc87faf5a29544))
* **telemetry:** add SCA registry and audit tests for signal producer coverage ([1f57f3e](https://github.com/jeong-sik/oas/commit/1f57f3ebd1f2e678f638bcffe0ac0ebf87a61321))
* **telemetry:** per-turn typed telemetry events and bus ([7396ed6](https://github.com/jeong-sik/oas/commit/7396ed645cfb33a7f92df49f8c49806779044791))
* **telemetry:** RFC-OAS-019 Phase 1 — Streaming_summary at stream finalize ([#1578](https://github.com/jeong-sik/oas/issues/1578)) ([b26fed8](https://github.com/jeong-sik/oas/commit/b26fed80300016d987cbb5d0e9d817df9d02fe95))
* **telemetry:** wire ttfrc_ms and prefill_ms through patch_telemetry ([39f15ea](https://github.com/jeong-sik/oas/commit/39f15ea25dfa980375253af8f9b1c50815b17165))
* **telemetry:** wire ttfrc_ms and prefill_ms through patch_telemetry ([ef4ef9e](https://github.com/jeong-sik/oas/commit/ef4ef9e51d87411ec5a680a14385fcd613729974))
* **telemetry:** wire ttfrc_ms and prefill_ms to inference_telemetry ([98d5335](https://github.com/jeong-sik/oas/commit/98d5335fa0198e271dae98a420521f396af4934c))
* **timeout:** add provider timeout policy phases ([#1656](https://github.com/jeong-sik/oas/issues/1656)) ([540cb45](https://github.com/jeong-sik/oas/commit/540cb45918330e7ae274d2b919ef3c510425260d))
* **transport_claude_code:** expose stdout_idle_timeout_s on config ([#1459](https://github.com/jeong-sik/oas/issues/1459)) ([564e1e7](https://github.com/jeong-sik/oas/commit/564e1e71df332c159dccc5e8280c391e5053af94))
* **transport_codex_cli:** expose stdout_idle_timeout_s on config ([#1458](https://github.com/jeong-sik/oas/issues/1458)) ([64d3e1a](https://github.com/jeong-sik/oas/commit/64d3e1a90eb55f03f251d1b85a0dabe8b6aa2064))
* **transport_gemini_cli:** expose stdout_idle_timeout_s on config ([#1461](https://github.com/jeong-sik/oas/issues/1461)) ([5240005](https://github.com/jeong-sik/oas/commit/5240005c444adbec870ae032882d495af03674ca))
* **transport_kimi_cli:** expose stdout_idle_timeout_s on config ([#1460](https://github.com/jeong-sik/oas/issues/1460)) ([cbfd139](https://github.com/jeong-sik/oas/commit/cbfd139a90baadde01f9940e71b8ac2a8f706547))


### Bug Fixes

* add approval-required fail-closed policy ([#1630](https://github.com/jeong-sik/oas/issues/1630)) ([9f11c50](https://github.com/jeong-sik/oas/commit/9f11c506af1980554324e719427364a5b6461a42))
* add ollama cloud direct auth ([#1561](https://github.com/jeong-sik/oas/issues/1561)) ([9f265c1](https://github.com/jeong-sik/oas/commit/9f265c19fa477ab4810bff7ffca6083c652b8a95))
* **agent_sdk:** qualify base reexports ([#1389](https://github.com/jeong-sik/oas/issues/1389)) ([c310b2d](https://github.com/jeong-sik/oas/commit/c310b2d2fc31db2f83ce2fa447376be4df21f9c8))
* **agent_tools:** restrict find_in_index fallback to non-User tool IDs ([#1568](https://github.com/jeong-sik/oas/issues/1568)) ([5e68d21](https://github.com/jeong-sik/oas/commit/5e68d21d4530af6c8991ff769921749f2287d6ab))
* **agent_turn:** make reserve_strategy_budget strategy match exhaustive ([#1522](https://github.com/jeong-sik/oas/issues/1522)) ([c6428ae](https://github.com/jeong-sik/oas/commit/c6428ae937bd378ff72228671adcb9d328495dc7))
* **agent:** gate context overflow auto retry ([#1553](https://github.com/jeong-sik/oas/issues/1553)) ([8ed4183](https://github.com/jeong-sik/oas/commit/8ed4183fb20d97fe7b4dcb704b9a3d29d674ef4c))
* **agent:** index tool lookup paths ([#1592](https://github.com/jeong-sik/oas/issues/1592)) ([31bda07](https://github.com/jeong-sik/oas/commit/31bda07bd54c4e902b35030ec4d71547718bd1ca))
* **agent:** narrow runtime mcp per turn ([#1596](https://github.com/jeong-sik/oas/issues/1596)) ([36f7b37](https://github.com/jeong-sik/oas/commit/36f7b3779b01c38f3d69e94374c6d0812cb96403))
* **agent:** order checkpoint completion effects ([#1552](https://github.com/jeong-sik/oas/issues/1552)) ([cfbdabd](https://github.com/jeong-sik/oas/commit/cfbdabdf1c40493b36b023a0a97248ff939d571a))
* **agent:** route registry discovery through http client ([#1560](https://github.com/jeong-sik/oas/issues/1560)) ([c0ada64](https://github.com/jeong-sik/oas/commit/c0ada64d5b89196a06969f292b77268f36e03bab))
* **agent:** stop periodic callbacks on cancellation ([#1447](https://github.com/jeong-sik/oas/issues/1447)) ([217ed2a](https://github.com/jeong-sik/oas/commit/217ed2a1833118dbf4dfb7ba7d1d25f92fbbb3f2))
* align agent sdk version metadata ([#1288](https://github.com/jeong-sik/oas/issues/1288)) ([5063db8](https://github.com/jeong-sik/oas/commit/5063db8ce4ff85cc8a583e53639a1e070465d656))
* **api_openai:** make is_zai_provider_config Provider.config match exhaustive ([#1523](https://github.com/jeong-sik/oas/issues/1523)) ([98814d1](https://github.com/jeong-sik/oas/commit/98814d1c56f151ca9b32b46d5e5639e09ab0869a))
* **api:** route legacy create_message through http client ([#1558](https://github.com/jeong-sik/oas/issues/1558)) ([a20ed9f](https://github.com/jeong-sik/oas/commit/a20ed9f812c30428e5168bc3aade3e1e86eceb92))
* **backend_gemini:** make has_tool_use content_block match exhaustive (N-of-M followup to [#1519](https://github.com/jeong-sik/oas/issues/1519)/[#1521](https://github.com/jeong-sik/oas/issues/1521)) ([#1525](https://github.com/jeong-sik/oas/issues/1525)) ([01d3276](https://github.com/jeong-sik/oas/commit/01d3276dcc48b37a9ee9ea42f1eee95c4b486e10))
* **backend_openai:** make Thinking-detection content_block matches exhaustive (2 sites, N-of-M followup) ([#1526](https://github.com/jeong-sik/oas/issues/1526)) ([591c961](https://github.com/jeong-sik/oas/commit/591c961fb8f14eb5f45c061774e0ba8fe465685b))
* bound cascade provider attempts ([#1375](https://github.com/jeong-sik/oas/issues/1375)) ([cafb7c0](https://github.com/jeong-sik/oas/commit/cafb7c00674dedc23328a5caa2294a584cfef114))
* **build:** resolve main build/test failures ([3381d9a](https://github.com/jeong-sik/oas/commit/3381d9abe8b37030e35888c659f7f254331b3a32))
* **build:** resolve main CI failures post-0.193.6 ([1b0593f](https://github.com/jeong-sik/oas/commit/1b0593f101ccf70aa443b364fa8f5d5c4ea5f54e))
* **capabilities:** keep reasoning effort overlay conservative ([44ef91e](https://github.com/jeong-sik/oas/commit/44ef91e7822792986e73c6356fa481dd3c46c173))
* **capabilities:** set Chat_template_kwargs for qwen3 ([#1614](https://github.com/jeong-sik/oas/issues/1614)) ([11181bb](https://github.com/jeong-sik/oas/commit/11181bb28147dc2b0e992885e9fabcba591f8b1c))
* **capabilities:** surface manifest load diagnostics ([#1381](https://github.com/jeong-sik/oas/issues/1381)) ([7afb3b0](https://github.com/jeong-sik/oas/commit/7afb3b0457f5b47c54231a3b20b3a7dac15f080b))
* **capability_manifest:** post-merge follow-up to [#1516](https://github.com/jeong-sik/oas/issues/1516) — Atomic.t + docstrings + test title ([#1529](https://github.com/jeong-sik/oas/issues/1529)) ([ea0023e](https://github.com/jeong-sik/oas/commit/ea0023ece0d9812995ebe8854bcfa1e8aa67f934))
* **capability_manifest:** remove duplicate doc text, fix SDK gate, apply ocamlformat ([5f248c1](https://github.com/jeong-sik/oas/commit/5f248c1d6f331a7e671942fc17afe2b877b7910f))
* **cascade:** gate provider attempts with throttle ([#1595](https://github.com/jeong-sik/oas/issues/1595)) ([30dcc69](https://github.com/jeong-sik/oas/commit/30dcc690119238418ba54e524b1032705cc01333))
* **cascade:** stop on TLS and local resource failures ([#1607](https://github.com/jeong-sik/oas/issues/1607)) ([1599ee0](https://github.com/jeong-sik/oas/commit/1599ee03516446007d96426f304bde4c3b3086d2))
* **cascade:** stop provider terminal fallthrough ([#1454](https://github.com/jeong-sik/oas/issues/1454)) ([15f3f0d](https://github.com/jeong-sik/oas/commit/15f3f0d9480d6d39df72f0c67403b590a1f17a97))
* **cascade:** use Eio mutex for provider health ([#1435](https://github.com/jeong-sik/oas/issues/1435)) ([a041368](https://github.com/jeong-sik/oas/commit/a04136828a78d45d2d6ecfed9563254b0bdbc170))
* **ci:** fill checkpoint delta usage fixture ([4624cf9](https://github.com/jeong-sik/oas/commit/4624cf936f1641bf72ea84033c9bb7a84f6bb7bc))
* **ci:** repair post-merge OAS main checks ([#1648](https://github.com/jeong-sik/oas/issues/1648)) ([39c1e76](https://github.com/jeong-sik/oas/commit/39c1e76ad851fef3f263781cbb19cef2e9cef839))
* **ci:** restore main build after usage update ([36425dc](https://github.com/jeong-sik/oas/commit/36425dc4e7f9a5d8453c11dff7765b7e177f618d))
* **ci:** restore main build after usage update ([9d8b912](https://github.com/jeong-sik/oas/commit/9d8b912743aedb567a0f65317ce2f3eaada27144))
* **collaboration:** make is_claimable claim_phase match exhaustive ([#1524](https://github.com/jeong-sik/oas/issues/1524)) ([a09983d](https://github.com/jeong-sik/oas/commit/a09983dd1c5006c764c9230d5a29ca5200bbfb00))
* **completion:** lower tool-choice fallback log noise ([#1608](https://github.com/jeong-sik/oas/issues/1608)) ([f53a814](https://github.com/jeong-sik/oas/commit/f53a814a7c1afec9d686c7410282d94be9abae4b))
* **content_block:** close 7 catch-all sites across pipeline + context_reducer + tool_use_recovery ([#1519](https://github.com/jeong-sik/oas/issues/1519)) ([c52b945](https://github.com/jeong-sik/oas/commit/c52b9451b6214a3fad94df79a61f1287505b446e))
* **context_reducer:** close 9 content_block catch-all sites in apply ([#1521](https://github.com/jeong-sik/oas/issues/1521)) ([92590ae](https://github.com/jeong-sik/oas/commit/92590ae10e99bbb929ad45705058964729555309))
* **context:** surface reducer repair diagnostics ([#1611](https://github.com/jeong-sik/oas/issues/1611)) ([688ee48](https://github.com/jeong-sik/oas/commit/688ee48efb3ffe227305b9ba52c8a0393f4bba03))
* **cost:** address Copilot review findings on the fail-closed path ([85f0e1f](https://github.com/jeong-sik/oas/commit/85f0e1fdd63c73a9712b2078b587e3c72551ce79))
* **cost:** fail closed when max_cost_usd is set + a turn ran an unpriced model ([dfa9bf1](https://github.com/jeong-sik/oas/commit/dfa9bf1c0ac363c571a2c4bc8556b413de47d02c))
* **cost:** fail closed when max_cost_usd is set + unpriced model ([6ec5725](https://github.com/jeong-sik/oas/commit/6ec5725f4e73093b5a7149bc467293d95b9390eb))
* **discovery:** validate env scan ports ([e6553c7](https://github.com/jeong-sik/oas/commit/e6553c7a8f8a10ef16883b49c15042071b89bce3))
* **dune:** add blank line between stanzas for ocamlformat ([6577be3](https://github.com/jeong-sik/oas/commit/6577be34f22b5ea9d98c3444ab3dba851b6a2e86))
* **dune:** remove orphaned (rule stanza from dune file ([1dc7af9](https://github.com/jeong-sik/oas/commit/1dc7af940a1e8c0093ea934a54b4cad208e48d14))
* **dune:** remove trailing blank line ([4df5435](https://github.com/jeong-sik/oas/commit/4df54355c85a7a34dd47b94e59b953aaa3ea8d43))
* **eval:** tag otel metric json exports ([#1423](https://github.com/jeong-sik/oas/issues/1423)) ([d610422](https://github.com/jeong-sik/oas/commit/d610422aec346db7df4b6da16da450ff50d578a2))
* expose cli stdout recovery metadata ([#1457](https://github.com/jeong-sik/oas/issues/1457)) ([31abd8e](https://github.com/jeong-sik/oas/commit/31abd8e84f790e8a0d4a30a66cffce11e8ba4526))
* **fmt:** join cons operator for Chat_template_kwargs ([#1329](https://github.com/jeong-sik/oas/issues/1329)) ([56931f1](https://github.com/jeong-sik/oas/commit/56931f1c44138a487fa7f51527e626f8f84b77ea))
* **fmt:** ocamlformat compliance followup for [#1324](https://github.com/jeong-sik/oas/issues/1324) ([118db54](https://github.com/jeong-sik/oas/commit/118db5437287f2d5c4124e2f0f23b0c9117b2650))
* **fmt:** ocamlformat compliance for thinking-control match and doc comments ([a671a12](https://github.com/jeong-sik/oas/commit/a671a1233db169cda0898fed810a2870d3330fe1))
* harden exhaustive matches on closed variants (capabilities/streaming/agent) ([#1517](https://github.com/jeong-sik/oas/issues/1517)) ([1cd5d5a](https://github.com/jeong-sik/oas/commit/1cd5d5a9926a2010ca990f66739823e536a5f83d))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([e92553e](https://github.com/jeong-sik/oas/commit/e92553ee4379b9b33277848bd0fdf1f95e743b8e))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([51692a5](https://github.com/jeong-sik/oas/commit/51692a51a1eeb85fa087d7cab5f04b1ae3544dc5))
* **http:** classify empty trust anchors as local resource ([#1610](https://github.com/jeong-sik/oas/issues/1610)) ([4e86499](https://github.com/jeong-sik/oas/commit/4e86499f4c84b8d7793ae8eea878a96ea7e98d63))
* **llm_provider:** extract hardcoded max_tokens 4096 fallback to Constants (S08) ([#1331](https://github.com/jeong-sik/oas/issues/1331)) ([89c9e12](https://github.com/jeong-sik/oas/commit/89c9e12d74d2b6fad58084e9a076300a7aab69b8))
* **llm_provider:** remove anti-patterns in thinking, error classification, and Gemini/GLM backends ([#1326](https://github.com/jeong-sik/oas/issues/1326)) ([df249b6](https://github.com/jeong-sik/oas/commit/df249b650e8456e588ec1a3bbd2f109bc882d6b8))
* **llm_provider:** replace Eio.traceln with Diag.warn in CLI transports (F02) ([#1333](https://github.com/jeong-sik/oas/issues/1333)) ([9756e7e](https://github.com/jeong-sik/oas/commit/9756e7e6ff79ffd94cb637d6cb9c8607552ceeaf))
* **llm:** expose optional transport latency ([#1463](https://github.com/jeong-sik/oas/issues/1463)) ([eed15b4](https://github.com/jeong-sik/oas/commit/eed15b4cf3bbfc2d050b68188a6870af34766436))
* **llm:** lower confidence for fallback capability drift ([#1555](https://github.com/jeong-sik/oas/issues/1555)) ([26339df](https://github.com/jeong-sik/oas/commit/26339df8cacecb49cb33ddaf0ab88a56f85c9874))
* **main:** unblock 3 CI categories after [#1469](https://github.com/jeong-sik/oas/issues/1469)-[#1471](https://github.com/jeong-sik/oas/issues/1471) cascade ([ebfc95d](https://github.com/jeong-sik/oas/commit/ebfc95d6fb94c4e5c2a1c47af1380aa3f78fdbff))
* **main:** unblock 3 CI categories after [#1469](https://github.com/jeong-sik/oas/issues/1469)-[#1471](https://github.com/jeong-sik/oas/issues/1471) merge cascade ([73d727b](https://github.com/jeong-sik/oas/commit/73d727b45fa283bd2bda693678c6bf32687c010d))
* **mcp:** preserve builtin tool permissions ([#1438](https://github.com/jeong-sik/oas/issues/1438)) ([f568a07](https://github.com/jeong-sik/oas/commit/f568a07b653870984dc38722bb2c436c74b78693))
* **memory:** persist episodic procedural backends ([#1594](https://github.com/jeong-sik/oas/issues/1594)) ([e87b73f](https://github.com/jeong-sik/oas/commit/e87b73fd90e83a79c66cf974e02002ec9a5eb9a2))
* **memory:** preserve long-term backend compatibility ([#1628](https://github.com/jeong-sik/oas/issues/1628)) ([2c046ee](https://github.com/jeong-sik/oas/commit/2c046ee883ef0df26a7f8acbf12cce22d8f4bc78))
* **metrics:** aggregate streaming latency samples ([#1577](https://github.com/jeong-sik/oas/issues/1577)) ([a33ac78](https://github.com/jeong-sik/oas/commit/a33ac78895a87db2ff824a4d394c3a108d7807ad))
* **metrics:** deduplicate histogram bucket bounds in prometheus export ([#1564](https://github.com/jeong-sik/oas/issues/1564)) ([b2e8403](https://github.com/jeong-sik/oas/commit/b2e8403897a43660f3ed6ca17529e9c4b7cdebdc))
* **metrics:** emit Circuit_open directly from open-skip branch ([#1566](https://github.com/jeong-sik/oas/issues/1566)) ([8969475](https://github.com/jeong-sik/oas/commit/8969475eb8323d17400a8ba53632961173d0cad3))
* **metrics:** persist provider snapshots as json ([#1573](https://github.com/jeong-sik/oas/issues/1573)) ([d5037d2](https://github.com/jeong-sik/oas/commit/d5037d2346e7e13f5488a13495e65722b0a0a268))
* **metrics:** reject duplicate histogram buckets at register time ([#1643](https://github.com/jeong-sik/oas/issues/1643)) ([2db3378](https://github.com/jeong-sik/oas/commit/2db337807cc71e7bed79accb6d69e82f38029057))
* **metrics:** reject normalized-name collisions at register time ([#1570](https://github.com/jeong-sik/oas/issues/1570)) ([54d4b71](https://github.com/jeong-sik/oas/commit/54d4b71246d382aa8b3561c1a473e8efd9c48d9f))
* **metrics:** reject open-circuit snapshots without failure timestamp ([#1575](https://github.com/jeong-sik/oas/issues/1575)) ([fedcd13](https://github.com/jeong-sik/oas/commit/fedcd13664e32edd03f47b2763ad131cb7d2184c))
* **metrics:** support labeled histograms ([#1572](https://github.com/jeong-sik/oas/issues/1572)) ([e9f5ac6](https://github.com/jeong-sik/oas/commit/e9f5ac6dad19d380e5cb068caafe16eed7800ed6))
* **ollama:** preserve tool calls and avoid hard timeouts ([#1609](https://github.com/jeong-sik/oas/issues/1609)) ([64ec834](https://github.com/jeong-sik/oas/commit/64ec834685faf8f3ecc58817d6020f4aa6ab3126))
* **otel:** propagate trace context to provider calls ([#1576](https://github.com/jeong-sik/oas/issues/1576)) ([4060baa](https://github.com/jeong-sik/oas/commit/4060baac4b8f83468091f66011492c5b4981c7ad))
* pass gemini admin policy env vars to support headless mode disabling ask_user ([#1282](https://github.com/jeong-sik/oas/issues/1282)) ([ac8bdc9](https://github.com/jeong-sik/oas/commit/ac8bdc9628cf849ff2568c58e6b46c310cd7aba9))
* **paths:** replace assert false with invalid_arg, document MCP env var ([#1597](https://github.com/jeong-sik/oas/issues/1597)) ([9efc99d](https://github.com/jeong-sik/oas/commit/9efc99d9a91ed8b7b9658bcc34beb2cbba5d3db0))
* **pipeline:** count runtime MCP tools for tool_choice ([#1593](https://github.com/jeong-sik/oas/issues/1593)) ([f488eab](https://github.com/jeong-sik/oas/commit/f488eabf5d756ffb4a258465663aaf74ea295f42))
* **pipeline:** drop unused agent arg from turn_ready_tool_names callers ([#1599](https://github.com/jeong-sik/oas/issues/1599)) ([7489923](https://github.com/jeong-sik/oas/commit/748992379de975e3b7d705bd29dd6815864ea927))
* **pipeline:** reject invisible tool choice contracts ([#1579](https://github.com/jeong-sik/oas/issues/1579)) ([b33e626](https://github.com/jeong-sik/oas/commit/b33e6267b49913f7fd1b2c59253403d8bf3b24e5))
* **plan:** make progress + is_done variant matches exhaustive ([#1518](https://github.com/jeong-sik/oas/issues/1518)) ([fd82743](https://github.com/jeong-sik/oas/commit/fd827431dc98a0f41fcf3dc7409f6c5bdc35e103))
* propagate provider clocks to completions ([#1319](https://github.com/jeong-sik/oas/issues/1319)) ([6a7b4d1](https://github.com/jeong-sik/oas/commit/6a7b4d1b23216b98dd5a6957dfb19c9d00220410))
* **provider_catalog:** fail-fast on unknown enum strings ([bb73cdc](https://github.com/jeong-sik/oas/commit/bb73cdc0d0db9afaae67c6d66a314d8169af7275))
* **provider_catalog:** fail-fast on unknown enum strings ([5a1cf67](https://github.com/jeong-sik/oas/commit/5a1cf674ff379871d20388b24f14fecc0e9b45d9))
* **provider:** apply ocamlformat to catalog overlay ([edb91b2](https://github.com/jeong-sik/oas/commit/edb91b29d35df8130d844e531a7492af89e3fefc))
* **provider:** apply ocamlformat to catalog overlay ([0b58dfe](https://github.com/jeong-sik/oas/commit/0b58dfecd53d0b5b7687051e3fcfea3588add8e1))
* **provider:** include context for empty HTTP errors ([#1582](https://github.com/jeong-sik/oas/issues/1582)) ([3b49c50](https://github.com/jeong-sik/oas/commit/3b49c5049faee63b045f641bfd4fb0cde0f6ebcd))
* **provider:** persist cascade health snapshots ([#1584](https://github.com/jeong-sik/oas/issues/1584)) ([4277673](https://github.com/jeong-sik/oas/commit/42776731e1ae0b6e505557c6912240f1550a3a3e))
* **provider:** remove GLM tool_choice coerce anti-pattern ([#1351](https://github.com/jeong-sik/oas/issues/1351)) ([7132e1f](https://github.com/jeong-sik/oas/commit/7132e1f178599db7d66503518c5abfd6ce1c7c56))
* **provider:** resolve runtime binding capabilities by config ([#1589](https://github.com/jeong-sik/oas/issues/1589)) ([da757ff](https://github.com/jeong-sik/oas/commit/da757ffc1ebc7a7c94c25370755b9a683b6ce412))
* **provider:** route provider intf through http client ([#1559](https://github.com/jeong-sik/oas/issues/1559)) ([b249b58](https://github.com/jeong-sik/oas/commit/b249b5887064e8da87b04697521742279103b72f))
* **provider:** surface OpenAI harness parse errors ([#1581](https://github.com/jeong-sik/oas/issues/1581)) ([42273ee](https://github.com/jeong-sik/oas/commit/42273ee4a4daf9a68aa5f3aa68b2c553be3cd05e))
* **raw-trace:** require explicit evidence roles ([#1650](https://github.com/jeong-sik/oas/issues/1650)) ([0f4ff62](https://github.com/jeong-sik/oas/commit/0f4ff62afe0ef23895c02ecbf1cbf882709439e3))
* **release:** automate agent_sdk.opam sync inside release-please workflow ([#1604](https://github.com/jeong-sik/oas/issues/1604)) ([4b00bdf](https://github.com/jeong-sik/oas/commit/4b00bdff217e6233ed15bcc722d9aed410c36eba))
* remove coordinator-specific OAS hardcoding ([#1639](https://github.com/jeong-sik/oas/issues/1639)) ([16f0075](https://github.com/jeong-sik/oas/commit/16f0075f5106c8013fc9305ded2d4a59e1ee1557))
* remove mutable anti-patterns — O(n) append, dead mutable, debug printf ([#1619](https://github.com/jeong-sik/oas/issues/1619)) ([5f8e07b](https://github.com/jeong-sik/oas/commit/5f8e07b777285f59c111b1a866166604d5bc4a1a))
* resolve CI failures (coverage, syntax error, sdk gate) ([90303e0](https://github.com/jeong-sik/oas/commit/90303e03addfa5cee334806c8c864c9faff47a91))
* resolve main build failures after release 0.193.6 ([#1532](https://github.com/jeong-sik/oas/issues/1532)) ([04447d4](https://github.com/jeong-sik/oas/commit/04447d4e1ded4ccc49bc101a209d404b206e1a10))
* **retry:** classify admin-disabled and account-suspended 429s as hard quota ([#1358](https://github.com/jeong-sik/oas/issues/1358)) ([45b6af2](https://github.com/jeong-sik/oas/commit/45b6af2f3c3fc59d03a018f727878e5999d417f6))
* **retry:** stop cascade on account usage limit ([#1428](https://github.com/jeong-sik/oas/issues/1428)) ([5ead30d](https://github.com/jeong-sik/oas/commit/5ead30d0c0ca7b72de32b8767bcea411a844eaed))
* **review:** harden recent OAS follow-ups ([66cff92](https://github.com/jeong-sik/oas/commit/66cff92c1987db2f9f69141d8ca736f91f8c11be))
* **runtime:** absorb runtime_server_worker into runtime_server, restore runtime_evidence ([b09ace3](https://github.com/jeong-sik/oas/commit/b09ace33a5b19934aa5057a6e6955ad7c9c16609))
* **runtime:** absorb runtime_server_worker, restore runtime_evidence ([692a4c2](https://github.com/jeong-sik/oas/commit/692a4c2348d1240ed50fc9102c28c9081e61c2f1))
* **scripts:** recognize release-please CHANGELOG header format ([#1513](https://github.com/jeong-sik/oas/issues/1513)) ([188efa6](https://github.com/jeong-sik/oas/commit/188efa67bdb95de6888f0c7660d236e3cc9de2df))
* **sessions:** drop stale parser helper signature ([#1670](https://github.com/jeong-sik/oas/issues/1670)) ([c701d0f](https://github.com/jeong-sik/oas/commit/c701d0f2de0ae01e91b83bea1e1f6491d4877603))
* **streaming:** surface SSE parse failures instead of silent discard ([#1357](https://github.com/jeong-sik/oas/issues/1357)) ([83e40ea](https://github.com/jeong-sik/oas/commit/83e40ea8263a3ef101426b8e9e395e69d510c954))
* **telemetry:** emit context window usage ([#1583](https://github.com/jeong-sik/oas/issues/1583)) ([070b9d4](https://github.com/jeong-sik/oas/commit/070b9d46d764d45d56b506d7edd51188a529a779))
* **test:** make telemetry SCA repo-root discovery fail fast ([b9d4f57](https://github.com/jeong-sik/oas/commit/b9d4f57e21904658f7163e6fcfe52f0fb18b6072))
* **test:** remove duplicate test_telemetry_sca — superseded by test/telemetry_sca/ ([4bab73f](https://github.com/jeong-sik/oas/commit/4bab73fa6236b4e4b8fac6c3d027a206780b217a))
* **test:** rescue test_discovery orphan (record field supports_tools) ([#1392](https://github.com/jeong-sik/oas/issues/1392)) ([720305e](https://github.com/jeong-sik/oas/commit/720305e75c1187fff939507bcbc45a56931b01db))
* **test:** rescue test_pipeline_deep orphan (record field enable_thinking) ([#1394](https://github.com/jeong-sik/oas/issues/1394)) ([5613191](https://github.com/jeong-sik/oas/commit/5613191bd681d10012fde7a24dd9b4211059f45b))
* **test:** rescue test_provider_config orphan (record field reasoning_tokens_estimated) ([#1388](https://github.com/jeong-sik/oas/issues/1388)) ([2724b1f](https://github.com/jeong-sik/oas/commit/2724b1fa67e299f768a99ecd8370be274c4e2582))
* tolerate release version markers ([#1708](https://github.com/jeong-sik/oas/issues/1708)) ([a5cd80f](https://github.com/jeong-sik/oas/commit/a5cd80fd1ffbc12ef3f5188d9c754ebd114958be))
* **tool_selector:** replace failwith with empty list for unimplemented LLM categorical classifier ([#1455](https://github.com/jeong-sik/oas/issues/1455)) ([496c329](https://github.com/jeong-sik/oas/commit/496c329bc4423fb1ddbe61507bbc6b5df1ba23a9))
* **tools:** enforce shell descriptor constraints ([#1602](https://github.com/jeong-sik/oas/issues/1602)) ([ce90f5d](https://github.com/jeong-sik/oas/commit/ce90f5d2575d54ec339bdfd2744c019a8849414f))
* type provider reasoning controls ([#1709](https://github.com/jeong-sik/oas/issues/1709)) ([a2bf6e1](https://github.com/jeong-sik/oas/commit/a2bf6e1c192f59717fe47f7f57f74458e3ffbcaa))
* **types:** preserve missing response usage ([#1449](https://github.com/jeong-sik/oas/issues/1449)) ([9639c92](https://github.com/jeong-sik/oas/commit/9639c9204c75c17d5c4e260111b8cb1be5ea257c))
* warn on invalid cli integer env ([#1456](https://github.com/jeong-sik/oas/issues/1456)) ([21dea98](https://github.com/jeong-sik/oas/commit/21dea9862fab506eb8983740c9c12951b32dbe94))
* wrap agent_sdk base library ([c7fc03b](https://github.com/jeong-sik/oas/commit/c7fc03b19085e8acf8d647f4ea99838d89e539bd))
* **zai_catalog:** remove unsupported glm-5-code from coding auto-models ([92f108c](https://github.com/jeong-sik/oas/commit/92f108c6045b1e0065504ab059ac85a144db7f39))
* **zai_catalog:** remove unsupported glm-5-code from coding auto-models ([186e51c](https://github.com/jeong-sik/oas/commit/186e51c24e0e1eadc50840073396630cdb6b74b9))


### Performance Improvements

* **completion_contract:** build tool-lookup index lazily ([#1600](https://github.com/jeong-sik/oas/issues/1600)) ([e605a13](https://github.com/jeong-sik/oas/commit/e605a133d798a1e1e308727643b59692a5c2bc25))


### Code Refactoring

* remove migrated CDAL modules + façade re-exports (RFC-OAS-011 OAS-E PR-6) ([c5b120d](https://github.com/jeong-sik/oas/commit/c5b120d6f04eb8ea203dec2d1ffc5f8920656cdf))

## [0.197.0](https://github.com/jeong-sik/oas/compare/v0.196.17...v0.197.0) (2026-05-24)


### Breaking Changes

* **sdk:** restore `0.197.0` as the supported compatibility floor for the provider-neutral vendor purge. `v0.196.17` was generated after the purge with a stale release-please manifest and should not be used as the downstream minimum for the breaking SDK surface ([#1727](https://github.com/jeong-sik/oas/issues/1727), [#1729](https://github.com/jeong-sik/oas/issues/1729), [#1731](https://github.com/jeong-sik/oas/issues/1731), [#1737](https://github.com/jeong-sik/oas/issues/1737), [#1739](https://github.com/jeong-sik/oas/issues/1739))

## [0.196.17](https://github.com/jeong-sik/oas/compare/v0.196.16...v0.196.17) (2026-05-24)


### Features

* **runtime:** project checkpoint deltas from replay windows ([#1738](https://github.com/jeong-sik/oas/issues/1738)) ([e0377ad](https://github.com/jeong-sik/oas/commit/e0377ad0e574366fe6c8511e70bbda03a23ff5e7))

## [0.196.16](https://github.com/jeong-sik/oas/compare/v0.196.15...v0.196.16) (2026-05-24)


### Features

* **runtime:** resume paused input agents ([#1724](https://github.com/jeong-sik/oas/issues/1724)) ([59a49d5](https://github.com/jeong-sik/oas/commit/59a49d5413a3ae9cb7ec708971f53e12dfe1cec0))

## [0.196.15](https://github.com/jeong-sik/oas/compare/v0.196.14...v0.196.15) (2026-05-24)


### Features

* **agent:** pause on async elicitation ([#1722](https://github.com/jeong-sik/oas/issues/1722)) ([b40e955](https://github.com/jeong-sik/oas/commit/b40e9557ad3f404c692159d3fd018da368f9c63e))

## [0.196.14](https://github.com/jeong-sik/oas/compare/v0.196.13...v0.196.14) (2026-05-24)


### Features

* bridge runtime windows to sync replay ([#1720](https://github.com/jeong-sik/oas/issues/1720)) ([1b98e4d](https://github.com/jeong-sik/oas/commit/1b98e4dcf6368fea5b452967df67eaa822969e5c))

## [0.196.13](https://github.com/jeong-sik/oas/compare/v0.196.12...v0.196.13) (2026-05-24)


### Features

* add runtime run window reads ([#1716](https://github.com/jeong-sik/oas/issues/1716)) ([c11b35b](https://github.com/jeong-sik/oas/commit/c11b35bb9142b5261d4b61daa324a8792fd85324))

## [0.196.12](https://github.com/jeong-sik/oas/compare/v0.196.11...v0.196.12) (2026-05-24)


### Features

* persist runtime input-required state ([#1714](https://github.com/jeong-sik/oas/issues/1714)) ([656ac61](https://github.com/jeong-sik/oas/commit/656ac61937810763a600a268bd671c7fe8beba30))

## [0.196.11](https://github.com/jeong-sik/oas/compare/v0.196.10...v0.196.11) (2026-05-24)


### Bug Fixes

* tolerate release version markers ([#1708](https://github.com/jeong-sik/oas/issues/1708)) ([a5cd80f](https://github.com/jeong-sik/oas/commit/a5cd80fd1ffbc12ef3f5188d9c754ebd114958be))
* type provider reasoning controls ([#1709](https://github.com/jeong-sik/oas/issues/1709)) ([a2bf6e1](https://github.com/jeong-sik/oas/commit/a2bf6e1c192f59717fe47f7f57f74458e3ffbcaa))

## [0.196.10](https://github.com/jeong-sik/oas/compare/v0.196.9...v0.196.10) (2026-05-24)


### Bug Fixes

* tolerate release version markers ([#1708](https://github.com/jeong-sik/oas/issues/1708)) ([a5cd80f](https://github.com/jeong-sik/oas/commit/a5cd80fd1ffbc12ef3f5188d9c754ebd114958be))

## [0.196.10](https://github.com/jeong-sik/oas/compare/v0.196.9...v0.196.10) (2026-05-22)

### Bug Fixes

* **provider:** spell out provider completion fallbacks ([#1702](https://github.com/jeong-sik/oas/issues/1702)) ([6bc1993](https://github.com/jeong-sik/oas/commit/6bc19932df8521edcc20d70cad8d539f6f6aa19d))

## [0.196.9](https://github.com/jeong-sik/oas/compare/v0.196.8...v0.196.9) (2026-05-21)


### Bug Fixes

* **sessions:** drop stale parser helper signature ([#1670](https://github.com/jeong-sik/oas/issues/1670)) ([c701d0f](https://github.com/jeong-sik/oas/commit/c701d0f2de0ae01e91b83bea1e1f6491d4877603))

## [0.196.8](https://github.com/jeong-sik/oas/compare/v0.196.7...v0.196.8) (2026-05-21)


### Features

* **error:** carry completion contract violation detail ([#1660](https://github.com/jeong-sik/oas/issues/1660)) ([609600d](https://github.com/jeong-sik/oas/commit/609600d896af320868b9578d278e5752f8f28075))
* **raw-trace:** expose validation evidence roles ([#1658](https://github.com/jeong-sik/oas/issues/1658)) ([6d79276](https://github.com/jeong-sik/oas/commit/6d79276611261d0c64a8beebdf2e673e38cba74e))

## [0.196.7](https://github.com/jeong-sik/oas/compare/v0.196.6...v0.196.7) (2026-05-21)


### Features

* **timeout:** add provider timeout policy phases ([#1656](https://github.com/jeong-sik/oas/issues/1656)) ([540cb45](https://github.com/jeong-sik/oas/commit/540cb45918330e7ae274d2b919ef3c510425260d))

## [0.196.6](https://github.com/jeong-sik/oas/compare/v0.196.5...v0.196.6) (2026-05-20)


### Features

* **raw-trace:** expose evidence role summaries ([#1653](https://github.com/jeong-sik/oas/issues/1653)) ([9d2b2e5](https://github.com/jeong-sik/oas/commit/9d2b2e5c2739135d73f7aecdbcf04ed8fceff4c3))

## [0.196.5](https://github.com/jeong-sik/oas/compare/v0.196.4...v0.196.5) (2026-05-20)


### Bug Fixes

* **raw-trace:** require explicit evidence roles ([#1650](https://github.com/jeong-sik/oas/issues/1650)) ([0f4ff62](https://github.com/jeong-sik/oas/commit/0f4ff62afe0ef23895c02ecbf1cbf882709439e3))

## [0.196.4](https://github.com/jeong-sik/oas/compare/v0.196.3...v0.196.4) (2026-05-20)


### Bug Fixes

* **ci:** repair post-merge OAS main checks ([#1648](https://github.com/jeong-sik/oas/issues/1648)) ([39c1e76](https://github.com/jeong-sik/oas/commit/39c1e76ad851fef3f263781cbb19cef2e9cef839))

## [0.196.3](https://github.com/jeong-sik/oas/compare/v0.196.2...v0.196.3) (2026-05-20)


### Bug Fixes

* **metrics:** reject duplicate histogram buckets at register time ([#1643](https://github.com/jeong-sik/oas/issues/1643)) ([2db3378](https://github.com/jeong-sik/oas/commit/2db337807cc71e7bed79accb6d69e82f38029057))

## [0.196.2](https://github.com/jeong-sik/oas/compare/v0.196.1...v0.196.2) (2026-05-19)


### Features

* **completion-contract:** add typed violation_detail with satisfying_tools ([#1642](https://github.com/jeong-sik/oas/issues/1642)) ([42c125f](https://github.com/jeong-sik/oas/commit/42c125f6e31c422dcf387a3546a0ffdbcea1bde0))


### Bug Fixes

* remove coordinator-specific OAS hardcoding ([#1639](https://github.com/jeong-sik/oas/issues/1639)) ([16f0075](https://github.com/jeong-sik/oas/commit/16f0075f5106c8013fc9305ded2d4a59e1ee1557))

## [0.196.1](https://github.com/jeong-sik/oas/compare/v0.196.0...v0.196.1) (2026-05-18)


### Features

* preserve provider timeout evidence ([#1632](https://github.com/jeong-sik/oas/issues/1632)) ([5001b3b](https://github.com/jeong-sik/oas/commit/5001b3b866fce8a31dc5e6f78a654d8ae6e560e5))

## [0.196.0](https://github.com/jeong-sik/oas/compare/v0.195.0...v0.196.0) (2026-05-17)


### ⚠ BREAKING CHANGES

* remove migrated CDAL modules + façade re-exports (RFC-OAS-011 OAS-E PR-6)

### Features

* add ppx_let support with Let_syntax in Result_syntax ([#1353](https://github.com/jeong-sik/oas/issues/1353)) ([9aeb72c](https://github.com/jeong-sik/oas/commit/9aeb72cb33e845fe99cf8e5983cf957a7022de84))
* add structured replay metadata to checkpoints ([#1149](https://github.com/jeong-sik/oas/issues/1149)) ([cbfbe96](https://github.com/jeong-sik/oas/commit/cbfbe96c3dcfe0fa73087f64dc0addd182bf971f))
* **agent_tools:** remove CDAL builtin_descriptor fallback (RFC-OAS-009 v2 PR-B) ([39082f6](https://github.com/jeong-sik/oas/commit/39082f6005888209a5b16c6aaa0b60bd25df050f))
* **agent_tools:** remove CDAL builtin_descriptor fallback (RFC-OAS-009 v2 PR-B) ([41d0144](https://github.com/jeong-sik/oas/commit/41d0144f22fbfc36ea0da2c92487caff638bf807))
* **agent:** add body_timeout_s to cap total HTTP body consumption ([#1209](https://github.com/jeong-sik/oas/issues/1209)) ([db54731](https://github.com/jeong-sik/oas/commit/db5473163d08bc25d4c7c60cf6419fbaad487c26))
* **agent:** add disclosure_level for tool schema serialization ([#1508](https://github.com/jeong-sik/oas/issues/1508)) ([f48ccec](https://github.com/jeong-sik/oas/commit/f48ccec3d1f6045627bb51c913944b7b879baf4d))
* **agent:** add disclosure_resolver for per-turn adaptive disclosure ([#1511](https://github.com/jeong-sik/oas/issues/1511)) ([7ed9c05](https://github.com/jeong-sik/oas/commit/7ed9c05260dce7b813bfaf524a2799573eb6479d))
* **agent:** add turn durability checkpoints ([#1550](https://github.com/jeong-sik/oas/issues/1550)) ([393ff0c](https://github.com/jeong-sik/oas/commit/393ff0c432734c6e2c471fd78b6ebba0040b48aa))
* **agent:** expose stream_idle_timeout_s on Agent.options ([#1195](https://github.com/jeong-sik/oas/issues/1195)) ([bd635d2](https://github.com/jeong-sik/oas/commit/bd635d27ed9dcaa0805ededcb68fd10d7656a42f))
* **agent:** index tool dispatch lookups ([#1557](https://github.com/jeong-sik/oas/issues/1557)) ([b7ea8e6](https://github.com/jeong-sik/oas/commit/b7ea8e6b00dd5ad1d3f4bbadeb26a071228c52f5))
* **agent:** native timeout handling for Agent.run ([#1006](https://github.com/jeong-sik/oas/issues/1006)) ([#1150](https://github.com/jeong-sik/oas/issues/1150)) ([d75c091](https://github.com/jeong-sik/oas/commit/d75c091b06e475451bdac69a50885c3c3a3bdf57))
* **arch:** decouple OAS from MASC by purging A2A and Handoff ([#1322](https://github.com/jeong-sik/oas/issues/1322)) ([d98e00e](https://github.com/jeong-sik/oas/commit/d98e00e43c405850d2fc80e7f52a93ac03c37bcf))
* **base:** Tool_id closed Variant identifier (RFC-OAS-008 PR-2/5) ([3c67d1e](https://github.com/jeong-sik/oas/commit/3c67d1e510fca49692937effd08cefc89aebd079))
* **base:** Tool_id closed Variant identifier (RFC-OAS-008 PR-2/5) ([8f413f8](https://github.com/jeong-sik/oas/commit/8f413f8a063273524f4fd2a22d14e69b1934709e))
* **bench:** TTFT distribution bench + SLO doc (RFC-OAS-020 PR-1b) ([#1625](https://github.com/jeong-sik/oas/issues/1625)) ([2ef4b25](https://github.com/jeong-sik/oas/commit/2ef4b25eade1d4fd6b6292e99842a97c8a78634b))
* **capabilities:** add emits_usage_tokens + provider-label lookup ([#1173](https://github.com/jeong-sik/oas/issues/1173)) ([7ff7288](https://github.com/jeong-sik/oas/commit/7ff7288e69095c28a57b63447e986059fa17826f))
* **capabilities:** add prefix-match ordering regression test for for_model_id (M01) ([#1361](https://github.com/jeong-sik/oas/issues/1361)) ([711e5a0](https://github.com/jeong-sik/oas/commit/711e5a0164081ab1a91745d5d5e3afbe4e1aaa4d))
* **capabilities:** add thinking_control_format and structured capability_drop metrics ([b596d78](https://github.com/jeong-sik/oas/commit/b596d7896daf8b8b488acc3e116843437de2ad93))
* **capabilities:** add thinking_control_format and structured capability_drop metrics ([bff40ae](https://github.com/jeong-sik/oas/commit/bff40aed2578a5b138050dd35b2352488773b9b1))
* **capabilities:** Ollama dynamic capability discovery via /api/show (M03) ([#1362](https://github.com/jeong-sik/oas/issues/1362)) ([eca778b](https://github.com/jeong-sik/oas/commit/eca778bc1e7f6b79ab7c5c734f63da857bd438e7))
* **capabilities:** runtime model capability manifest (H12) ([#1347](https://github.com/jeong-sik/oas/issues/1347)) ([1299541](https://github.com/jeong-sik/oas/commit/1299541bbd5ed25646c69637c4080efa6bfd6cd0))
* **capability_manifest:** add set_global / clear_global runtime override ([#1516](https://github.com/jeong-sik/oas/issues/1516)) ([c3a786f](https://github.com/jeong-sik/oas/commit/c3a786f36f6fc37306c1f8932267b9f684180ed5))
* **ci:** boundary-lint for core→CDAL zero dependency (RFC-OAS-009 v2 PR-D) ([b0c7a44](https://github.com/jeong-sik/oas/commit/b0c7a4484fe1a6514c1a308e9ce01581e356c81a))
* **ci:** boundary-lint for core→CDAL zero dependency (RFC-OAS-009 v2 PR-D) ([f53a3f5](https://github.com/jeong-sik/oas/commit/f53a3f550a9b27848cc58e52ed024036cb86f281))
* **ci:** expand boundary-lint to 20 CDAL prefixes (RFC-OAS-011 OAS-E PR-1) ([0a306ce](https://github.com/jeong-sik/oas/commit/0a306ce0f30e28d44e780eedb68551d2ded634a3))
* **ci:** expand boundary-lint to 20 CDAL prefixes (RFC-OAS-011 OAS-E PR-1) ([e189ed7](https://github.com/jeong-sik/oas/commit/e189ed75b1d25b97a6bf9c4d8536d7c5b79188bc))
* **cli_common_subprocess:** bound CLI subprocess stdout with idle timeout ([#1191](https://github.com/jeong-sik/oas/issues/1191)) ([52a5279](https://github.com/jeong-sik/oas/commit/52a5279595e403560fb1227e8730948af4cc8ea6))
* **cli_common_subprocess:** opt-in stdout_recovery on nonzero exit ([#1200](https://github.com/jeong-sik/oas/issues/1200)) ([b98b391](https://github.com/jeong-sik/oas/commit/b98b391ff3f141916cd95bfec438e9d2d3db03f9))
* **complete:** add body_timeout_s to non-streaming complete + complete_with_retry ([#1622](https://github.com/jeong-sik/oas/issues/1622)) ([79262f3](https://github.com/jeong-sik/oas/commit/79262f374d70798cc76dc43f1503c5f329dfe204))
* **context:** dynamic prompt cache alignment & budget compaction ([49823a6](https://github.com/jeong-sik/oas/commit/49823a614296289568e040ec197473e626031a2f))
* **context:** dynamic prompt cache alignment & budget compaction ([dd6f37e](https://github.com/jeong-sik/oas/commit/dd6f37ea70563c971b08103138fee80444aead55))
* **contract:** add strict required-tool satisfaction hook ([#1180](https://github.com/jeong-sik/oas/issues/1180)) ([c7d54b1](https://github.com/jeong-sik/oas/commit/c7d54b16b7d04fe362d8461112f4c0b99de2e6de))
* **event_bus:** add InferenceTelemetry event for per-turn timings ([#1202](https://github.com/jeong-sik/oas/issues/1202)) ([367de4e](https://github.com/jeong-sik/oas/commit/367de4e5a406e07af844c370c23b7c05c572a5e0))
* **event_bus:** add payload_kind SSOT helper for downstream consumers ([#1205](https://github.com/jeong-sik/oas/issues/1205)) ([c30be14](https://github.com/jeong-sik/oas/commit/c30be14602b2c8ad92395bb097df25ecbd9925e5))
* **event_bus:** add TurnReady event with effective tool list ([#1201](https://github.com/jeong-sik/oas/issues/1201)) ([97b8a60](https://github.com/jeong-sik/oas/commit/97b8a603f1917298ff1fd7814c46a7c108e986df))
* GLM-5-Code models and Kimi CLI model restrictions ([#1334](https://github.com/jeong-sik/oas/issues/1334)) ([6be9be9](https://github.com/jeong-sik/oas/commit/6be9be9be1b601cc797a3e3fbbda8524c95da4f3))
* **guardrails_async:** add per-validator deadline to prevent silent stall ([#1368](https://github.com/jeong-sik/oas/issues/1368)) ([b9e5f09](https://github.com/jeong-sik/oas/commit/b9e5f09791c7ef0f608f1dcc512dadc9368fdeb2))
* **guardrails:** tighten default tool_filter to DenyList + cap ([#1370](https://github.com/jeong-sik/oas/issues/1370)) ([7fa5cdc](https://github.com/jeong-sik/oas/commit/7fa5cdc9a264ef634c1069702dbfc4d90114c064))
* **http_client:** bound Ollama NDJSON stream with idle timeout ([#1185](https://github.com/jeong-sik/oas/issues/1185)) ([49ba678](https://github.com/jeong-sik/oas/commit/49ba6780d8cdc60266538deee7c84b26ab9363f2))
* **http_client:** bound SSE stream with same idle_timeout surface as NDJSON ([#1190](https://github.com/jeong-sik/oas/issues/1190)) ([a905970](https://github.com/jeong-sik/oas/commit/a905970b126191b42bbe64faf75c91c6a3d619ce))
* **lib:** add Cognitive_event typed schema (RFC-0036 PR-B) ([#1451](https://github.com/jeong-sik/oas/issues/1451)) ([f848e75](https://github.com/jeong-sik/oas/commit/f848e75a298827722d5f6cff8162f954ae20f974))
* **llm_provider:** add DashScope first-class support for Qwen models ([b6decd4](https://github.com/jeong-sik/oas/commit/b6decd42eaf46ba2c1b8c3e7b1ac855f4bd4416b))
* **llm_provider:** add DeepSeek v4 models (flash, pro) ([#1252](https://github.com/jeong-sik/oas/issues/1252)) ([19e3f1e](https://github.com/jeong-sik/oas/commit/19e3f1e58a9392ff87a8c587e4ed8c5e385765ce))
* **llm_provider:** Fd_throttle_hook injection point (RFC-0101 PR-3) ([#1618](https://github.com/jeong-sik/oas/issues/1618)) ([29cbbc5](https://github.com/jeong-sik/oas/commit/29cbbc5b1d1593ba77e9c9a6cccac716051f88c2))
* **llm_provider:** implement usage token restoration for CLI wrappers (P7) ([#1342](https://github.com/jeong-sik/oas/issues/1342)) ([53c921a](https://github.com/jeong-sik/oas/commit/53c921a47635c4bc03c42ad33f95dc3f3ebea429))
* **llm_provider:** RFC-0058 Phase B — CLI transport factory ([#1520](https://github.com/jeong-sik/oas/issues/1520)) ([41e87e0](https://github.com/jeong-sik/oas/commit/41e87e0cd1fe4d57c4f627958b34fcf419839745))
* **llm_provider:** structured network_error_kind for NetworkError ([#1147](https://github.com/jeong-sik/oas/issues/1147)) ([2249ff6](https://github.com/jeong-sik/oas/commit/2249ff6d9efa9f695b111c1aa834c35096242acc))
* **llm_provider:** surface typed provider failures ([#1261](https://github.com/jeong-sik/oas/issues/1261)) ([b56b56d](https://github.com/jeong-sik/oas/commit/b56b56d5a33dcb262254ec7cc3e78d681eec6623))
* **llm_provider:** typed TTFT capture + prefill_ms field (RFC-OAS-020 PR-1a) ([#1620](https://github.com/jeong-sik/oas/issues/1620)) ([37b4a0c](https://github.com/jeong-sik/oas/commit/37b4a0cd2a0303282579641038858f222a115547))
* **llm_provider:** Visual_first modality ordering for Gemma 4 ([cf94ce9](https://github.com/jeong-sik/oas/commit/cf94ce9a95deaa34270f3f3c1cb75347ba5ea59d))
* **llm_provider:** Visual_first modality ordering for Gemma 4 ([791eee8](https://github.com/jeong-sik/oas/commit/791eee8b6266fe91d762f76544ae525bb4992f7c))
* **llm_provider:** wire ttfrc_ms and prefill_ms into inference_telemetry ([809b63a](https://github.com/jeong-sik/oas/commit/809b63a5c4dfbeed427d660295de26df3ed928eb))
* **log:** count records dropped without sinks ([#1402](https://github.com/jeong-sik/oas/issues/1402)) ([d039517](https://github.com/jeong-sik/oas/commit/d039517fef5daa0a740545bb1b99661decfa1185))
* **manifest:** carry provider health evidence ([#1398](https://github.com/jeong-sik/oas/issues/1398)) ([07a06e4](https://github.com/jeong-sik/oas/commit/07a06e49e313294a3d3d721dd8d8f2e1badbb39b))
* **mcp_schema:** remove descriptor_for_builtin_tool alias (RFC-OAS-009 v2 PR-C) ([ffb8aff](https://github.com/jeong-sik/oas/commit/ffb8aff3a3bac4bdfce823fe41ca176226ba2f13))
* **mcp_schema:** remove descriptor_for_builtin_tool alias (RFC-OAS-009 v2 PR-C) ([2c41611](https://github.com/jeong-sik/oas/commit/2c416118433aa703f97f1e891b5671e9f67bb931))
* **mcp:** cli provider integration and ollama dynamic capabilities ([8c460d0](https://github.com/jeong-sik/oas/commit/8c460d011b1aed997b106765f48f567a69e6eefd))
* **mcp:** cli provider integration and ollama dynamic capabilities ([230773e](https://github.com/jeong-sik/oas/commit/230773ee8642e44d928a539215e04401957a1cb1))
* **memory:** expose typed long-term retrieve result ([#1627](https://github.com/jeong-sik/oas/issues/1627)) ([0be7c3c](https://github.com/jeong-sik/oas/commit/0be7c3c37fdbfcf69f8c93cdce0514fddedae7e3))
* **metrics:** add Prometheus text export ([#1556](https://github.com/jeong-sik/oas/issues/1556)) ([fc02639](https://github.com/jeong-sik/oas/commit/fc02639b940afe6714f207f08c41dc393e112260))
* **metrics:** emit cascade circuit state ([#1563](https://github.com/jeong-sik/oas/issues/1563)) ([1f69740](https://github.com/jeong-sik/oas/commit/1f69740fb423cc68c04b7d300597a9f164499c84))
* OAS Execution Manifest 고도화 및 Rate Limit Quota (P0~P1) ([44d8c84](https://github.com/jeong-sik/oas/commit/44d8c84676152ffb5eafb24da1ebb01db2d41ddd))
* **oas:** TLA+ CI gate + AgentCancellation spec + lifecycle_status yojson ([#1467](https://github.com/jeong-sik/oas/issues/1467)) ([7cd282f](https://github.com/jeong-sik/oas/commit/7cd282fed27ef6aa0637a6a12ca9356621619039))
* **ollama:** native NDJSON streaming, restore prompt_tok_s/decode_tok_s telemetry ([#1178](https://github.com/jeong-sik/oas/issues/1178)) ([e74a4d3](https://github.com/jeong-sik/oas/commit/e74a4d3161b1ed72cb51ae065f27ab5f7d4e262d))
* P0-P3 goals implementation (Rate limit quota, cascade config) ([1e58068](https://github.com/jeong-sik/oas/commit/1e580685527369f582836bd7aa6afedc59f1f4de))
* **pricing:** dynamic model pricing lookup via env vars (H11) ([#1348](https://github.com/jeong-sik/oas/issues/1348)) ([3017770](https://github.com/jeong-sik/oas/commit/301777035fe23868e27d4d3fa7544f7f3e534fc6))
* provider cascade routing + agent_sdk.base extraction (B→B+) ([#1346](https://github.com/jeong-sik/oas/issues/1346)) ([ac2e6e0](https://github.com/jeong-sik/oas/commit/ac2e6e04f155f687936ac41a55daaf003c3d0655))
* **provider_config:** surface ollama keep_alive and num_ctx to cascade ([#1176](https://github.com/jeong-sik/oas/issues/1176)) ([8308314](https://github.com/jeong-sik/oas/commit/8308314832678aa7532c96bb4c7f9764a2495442))
* **provider:** add external provider catalog overlay ([35241e9](https://github.com/jeong-sik/oas/commit/35241e9a82ce30360449f19a115d6589041f8f79))
* **provider:** add internal_model_rotation_count hint to Provider_config ([#1211](https://github.com/jeong-sik/oas/issues/1211)) ([aae5b48](https://github.com/jeong-sik/oas/commit/aae5b48a33d2d5a0ccc3a1ea7cfa618b3cc8b6dd))
* **provider:** expose runtime bindings ([#1585](https://github.com/jeong-sik/oas/issues/1585)) ([dbabd5c](https://github.com/jeong-sik/oas/commit/dbabd5ca7daf3ab25a861973ba346faddd442201))
* **provider:** load external provider catalog ([a13a1d0](https://github.com/jeong-sik/oas/commit/a13a1d0caa6baf0eaf77cfaa1e0ebdbed380d490))
* **provider:** map transport errors to typed provider errors ([#1448](https://github.com/jeong-sik/oas/issues/1448)) ([e804755](https://github.com/jeong-sik/oas/commit/e804755e3fb4ce81c33cd2b32880b206c588c28a))
* **provider:** P0-P7 LLM provider improvement plan implementation ([#1337](https://github.com/jeong-sik/oas/issues/1337)) ([8fbd8ac](https://github.com/jeong-sik/oas/commit/8fbd8ac7a9570ac2311c0fdeb158c7efd3ff0360))
* **release:** adopt release-please for version + CHANGELOG automation ([fd9931d](https://github.com/jeong-sik/oas/commit/fd9931d7f60f3b966140fdc700fd29c982ac5ea5))
* **release:** adopt release-please for version + CHANGELOG automation ([058ea4b](https://github.com/jeong-sik/oas/commit/058ea4bea2205b21854960f7cd4cb885043a9de8))
* **runtime:** add collaboration projection contract ([#1260](https://github.com/jeong-sik/oas/issues/1260)) ([189a91c](https://github.com/jeong-sik/oas/commit/189a91c4d72fc33add247cb2f2e21cc058ee3149))
* **runtime:** add durable relay delivery primitive ([#1383](https://github.com/jeong-sik/oas/issues/1383)) ([b056099](https://github.com/jeong-sik/oas/commit/b056099b5de703da53d6b2f774db9847f5a18b7c))
* **specs:** TLA+ spec for Agent lifecycle FSM ([#1212](https://github.com/jeong-sik/oas/issues/1212)) ([#1213](https://github.com/jeong-sik/oas/issues/1213)) ([253ca0f](https://github.com/jeong-sik/oas/commit/253ca0f5d4a1f57ebd64957303b974f16cf363c0))
* **specs:** TLA+ spec for context window exhaustion ([#1212](https://github.com/jeong-sik/oas/issues/1212)) ([#1214](https://github.com/jeong-sik/oas/issues/1214)) ([a19bb1a](https://github.com/jeong-sik/oas/commit/a19bb1a3dfdd635884c445e33fdcd818d8c526e3))
* **structured:** expose schema extractors ([#1405](https://github.com/jeong-sik/oas/issues/1405)) ([08eed88](https://github.com/jeong-sik/oas/commit/08eed88c21e8146854f8199946bc87faf5a29544))
* **telemetry:** add SCA registry and audit tests for signal producer coverage ([1f57f3e](https://github.com/jeong-sik/oas/commit/1f57f3ebd1f2e678f638bcffe0ac0ebf87a61321))
* **telemetry:** per-turn typed telemetry events and bus ([7396ed6](https://github.com/jeong-sik/oas/commit/7396ed645cfb33a7f92df49f8c49806779044791))
* **telemetry:** RFC-OAS-019 Phase 1 — Streaming_summary at stream finalize ([#1578](https://github.com/jeong-sik/oas/issues/1578)) ([b26fed8](https://github.com/jeong-sik/oas/commit/b26fed80300016d987cbb5d0e9d817df9d02fe95))
* **telemetry:** wire ttfrc_ms and prefill_ms through patch_telemetry ([39f15ea](https://github.com/jeong-sik/oas/commit/39f15ea25dfa980375253af8f9b1c50815b17165))
* **telemetry:** wire ttfrc_ms and prefill_ms through patch_telemetry ([ef4ef9e](https://github.com/jeong-sik/oas/commit/ef4ef9e51d87411ec5a680a14385fcd613729974))
* **telemetry:** wire ttfrc_ms and prefill_ms to inference_telemetry ([98d5335](https://github.com/jeong-sik/oas/commit/98d5335fa0198e271dae98a420521f396af4934c))
* **transport_claude_code:** expose stdout_idle_timeout_s on config ([#1459](https://github.com/jeong-sik/oas/issues/1459)) ([564e1e7](https://github.com/jeong-sik/oas/commit/564e1e71df332c159dccc5e8280c391e5053af94))
* **transport_codex_cli:** expose stdout_idle_timeout_s on config ([#1458](https://github.com/jeong-sik/oas/issues/1458)) ([64d3e1a](https://github.com/jeong-sik/oas/commit/64d3e1a90eb55f03f251d1b85a0dabe8b6aa2064))
* **transport_gemini_cli:** expose stdout_idle_timeout_s on config ([#1461](https://github.com/jeong-sik/oas/issues/1461)) ([5240005](https://github.com/jeong-sik/oas/commit/5240005c444adbec870ae032882d495af03674ca))
* **transport_kimi_cli:** expose stdout_idle_timeout_s on config ([#1460](https://github.com/jeong-sik/oas/issues/1460)) ([cbfd139](https://github.com/jeong-sik/oas/commit/cbfd139a90baadde01f9940e71b8ac2a8f706547))
* **transport/claude_code:** structured ProviderTerminal for max_turns ([#1204](https://github.com/jeong-sik/oas/issues/1204)) ([162940f](https://github.com/jeong-sik/oas/commit/162940fd60552156c45431544efa3cec5d61f1ca))


### Bug Fixes

* add approval-required fail-closed policy ([#1630](https://github.com/jeong-sik/oas/issues/1630)) ([9f11c50](https://github.com/jeong-sik/oas/commit/9f11c506af1980554324e719427364a5b6461a42))
* add ollama cloud direct auth ([#1561](https://github.com/jeong-sik/oas/issues/1561)) ([9f265c1](https://github.com/jeong-sik/oas/commit/9f265c19fa477ab4810bff7ffca6083c652b8a95))
* add pricing entries for generic and CLI models ([#1197](https://github.com/jeong-sik/oas/issues/1197)) ([2842418](https://github.com/jeong-sik/oas/commit/284241842c1670482e1e2b0caf636d7f295d2fd3))
* **agent_sdk:** qualify base reexports ([#1389](https://github.com/jeong-sik/oas/issues/1389)) ([c310b2d](https://github.com/jeong-sik/oas/commit/c310b2d2fc31db2f83ce2fa447376be4df21f9c8))
* **agent_tools:** restrict find_in_index fallback to non-User tool IDs ([#1568](https://github.com/jeong-sik/oas/issues/1568)) ([5e68d21](https://github.com/jeong-sik/oas/commit/5e68d21d4530af6c8991ff769921749f2287d6ab))
* **agent_turn:** make reserve_strategy_budget strategy match exhaustive ([#1522](https://github.com/jeong-sik/oas/issues/1522)) ([c6428ae](https://github.com/jeong-sik/oas/commit/c6428ae937bd378ff72228671adcb9d328495dc7))
* **agent:** gate context overflow auto retry ([#1553](https://github.com/jeong-sik/oas/issues/1553)) ([8ed4183](https://github.com/jeong-sik/oas/commit/8ed4183fb20d97fe7b4dcb704b9a3d29d674ef4c))
* **agent:** index tool lookup paths ([#1592](https://github.com/jeong-sik/oas/issues/1592)) ([31bda07](https://github.com/jeong-sik/oas/commit/31bda07bd54c4e902b35030ec4d71547718bd1ca))
* **agent:** narrow runtime mcp per turn ([#1596](https://github.com/jeong-sik/oas/issues/1596)) ([36f7b37](https://github.com/jeong-sik/oas/commit/36f7b3779b01c38f3d69e94374c6d0812cb96403))
* **agent:** order checkpoint completion effects ([#1552](https://github.com/jeong-sik/oas/issues/1552)) ([cfbdabd](https://github.com/jeong-sik/oas/commit/cfbdabdf1c40493b36b023a0a97248ff939d571a))
* **agent:** route registry discovery through http client ([#1560](https://github.com/jeong-sik/oas/issues/1560)) ([c0ada64](https://github.com/jeong-sik/oas/commit/c0ada64d5b89196a06969f292b77268f36e03bab))
* **agent:** stop periodic callbacks on cancellation ([#1447](https://github.com/jeong-sik/oas/issues/1447)) ([217ed2a](https://github.com/jeong-sik/oas/commit/217ed2a1833118dbf4dfb7ba7d1d25f92fbbb3f2))
* align agent sdk version metadata ([#1288](https://github.com/jeong-sik/oas/issues/1288)) ([5063db8](https://github.com/jeong-sik/oas/commit/5063db8ce4ff85cc8a583e53639a1e070465d656))
* align kimi cli session reuse with actual CLI contract ([#1157](https://github.com/jeong-sik/oas/issues/1157)) ([8b5bf30](https://github.com/jeong-sik/oas/commit/8b5bf30ac632cea97e46b2da9a7e81c117eaa2ae))
* **api_openai:** make is_zai_provider_config Provider.config match exhaustive ([#1523](https://github.com/jeong-sik/oas/issues/1523)) ([98814d1](https://github.com/jeong-sik/oas/commit/98814d1c56f151ca9b32b46d5e5639e09ab0869a))
* **api:** bound LLM HTTP requests with wall-clock timeout ([#1163](https://github.com/jeong-sik/oas/issues/1163)) ([700d864](https://github.com/jeong-sik/oas/commit/700d8648042c47b96002d44b513aa844b237ccd6))
* **api:** route legacy create_message through http client ([#1558](https://github.com/jeong-sik/oas/issues/1558)) ([a20ed9f](https://github.com/jeong-sik/oas/commit/a20ed9f812c30428e5168bc3aade3e1e86eceb92))
* **backend_gemini:** make has_tool_use content_block match exhaustive (N-of-M followup to [#1519](https://github.com/jeong-sik/oas/issues/1519)/[#1521](https://github.com/jeong-sik/oas/issues/1521)) ([#1525](https://github.com/jeong-sik/oas/issues/1525)) ([01d3276](https://github.com/jeong-sik/oas/commit/01d3276dcc48b37a9ee9ea42f1eee95c4b486e10))
* **backend_openai:** make Thinking-detection content_block matches exhaustive (2 sites, N-of-M followup) ([#1526](https://github.com/jeong-sik/oas/issues/1526)) ([591c961](https://github.com/jeong-sik/oas/commit/591c961fb8f14eb5f45c061774e0ba8fe465685b))
* bound cascade provider attempts ([#1375](https://github.com/jeong-sik/oas/issues/1375)) ([cafb7c0](https://github.com/jeong-sik/oas/commit/cafb7c00674dedc23328a5caa2294a584cfef114))
* **build:** resolve main build/test failures ([3381d9a](https://github.com/jeong-sik/oas/commit/3381d9abe8b37030e35888c659f7f254331b3a32))
* **build:** resolve main CI failures post-0.193.6 ([1b0593f](https://github.com/jeong-sik/oas/commit/1b0593f101ccf70aa443b364fa8f5d5c4ea5f54e))
* **capabilities:** keep reasoning effort overlay conservative ([44ef91e](https://github.com/jeong-sik/oas/commit/44ef91e7822792986e73c6356fa481dd3c46c173))
* **capabilities:** set Chat_template_kwargs for qwen3 ([#1614](https://github.com/jeong-sik/oas/issues/1614)) ([11181bb](https://github.com/jeong-sik/oas/commit/11181bb28147dc2b0e992885e9fabcba591f8b1c))
* **capabilities:** surface manifest load diagnostics ([#1381](https://github.com/jeong-sik/oas/issues/1381)) ([7afb3b0](https://github.com/jeong-sik/oas/commit/7afb3b0457f5b47c54231a3b20b3a7dac15f080b))
* **capability_manifest:** post-merge follow-up to [#1516](https://github.com/jeong-sik/oas/issues/1516) — Atomic.t + docstrings + test title ([#1529](https://github.com/jeong-sik/oas/issues/1529)) ([ea0023e](https://github.com/jeong-sik/oas/commit/ea0023ece0d9812995ebe8854bcfa1e8aa67f934))
* **capability_manifest:** remove duplicate doc text, fix SDK gate, apply ocamlformat ([5f248c1](https://github.com/jeong-sik/oas/commit/5f248c1d6f331a7e671942fc17afe2b877b7910f))
* **cascade:** gate provider attempts with throttle ([#1595](https://github.com/jeong-sik/oas/issues/1595)) ([30dcc69](https://github.com/jeong-sik/oas/commit/30dcc690119238418ba54e524b1032705cc01333))
* **cascade:** stop on TLS and local resource failures ([#1607](https://github.com/jeong-sik/oas/issues/1607)) ([1599ee0](https://github.com/jeong-sik/oas/commit/1599ee03516446007d96426f304bde4c3b3086d2))
* **cascade:** stop provider terminal fallthrough ([#1454](https://github.com/jeong-sik/oas/issues/1454)) ([15f3f0d](https://github.com/jeong-sik/oas/commit/15f3f0d9480d6d39df72f0c67403b590a1f17a97))
* **cascade:** use Eio mutex for provider health ([#1435](https://github.com/jeong-sik/oas/issues/1435)) ([a041368](https://github.com/jeong-sik/oas/commit/a04136828a78d45d2d6ecfed9563254b0bdbc170))
* **ci:** fill checkpoint delta usage fixture ([4624cf9](https://github.com/jeong-sik/oas/commit/4624cf936f1641bf72ea84033c9bb7a84f6bb7bc))
* **ci:** parse ocamlformat-split transport configs ([#1255](https://github.com/jeong-sik/oas/issues/1255)) ([8957f05](https://github.com/jeong-sik/oas/commit/8957f05b05a3112cabb41c26582dac36ee646de8))
* **ci:** restore main build after usage update ([36425dc](https://github.com/jeong-sik/oas/commit/36425dc4e7f9a5d8453c11dff7765b7e177f618d))
* **ci:** restore main build after usage update ([9d8b912](https://github.com/jeong-sik/oas/commit/9d8b912743aedb567a0f65317ce2f3eaada27144))
* **collaboration:** make is_claimable claim_phase match exhaustive ([#1524](https://github.com/jeong-sik/oas/issues/1524)) ([a09983d](https://github.com/jeong-sik/oas/commit/a09983dd1c5006c764c9230d5a29ca5200bbfb00))
* **completion:** lower tool-choice fallback log noise ([#1608](https://github.com/jeong-sik/oas/issues/1608)) ([f53a814](https://github.com/jeong-sik/oas/commit/f53a814a7c1afec9d686c7410282d94be9abae4b))
* **content_block:** close 7 catch-all sites across pipeline + context_reducer + tool_use_recovery ([#1519](https://github.com/jeong-sik/oas/issues/1519)) ([c52b945](https://github.com/jeong-sik/oas/commit/c52b9451b6214a3fad94df79a61f1287505b446e))
* **context_reducer:** close 9 content_block catch-all sites in apply ([#1521](https://github.com/jeong-sik/oas/issues/1521)) ([92590ae](https://github.com/jeong-sik/oas/commit/92590ae10e99bbb929ad45705058964729555309))
* **context:** surface reducer repair diagnostics ([#1611](https://github.com/jeong-sik/oas/issues/1611)) ([688ee48](https://github.com/jeong-sik/oas/commit/688ee48efb3ffe227305b9ba52c8a0393f4bba03))
* **cost:** address Copilot review findings on the fail-closed path ([85f0e1f](https://github.com/jeong-sik/oas/commit/85f0e1fdd63c73a9712b2078b587e3c72551ce79))
* **cost:** fail closed when max_cost_usd is set + a turn ran an unpriced model ([dfa9bf1](https://github.com/jeong-sik/oas/commit/dfa9bf1c0ac363c571a2c4bc8556b413de47d02c))
* **cost:** fail closed when max_cost_usd is set + unpriced model ([6ec5725](https://github.com/jeong-sik/oas/commit/6ec5725f4e73093b5a7149bc467293d95b9390eb))
* **discovery:** validate env scan ports ([e6553c7](https://github.com/jeong-sik/oas/commit/e6553c7a8f8a10ef16883b49c15042071b89bce3))
* **dune:** add blank line between stanzas for ocamlformat ([6577be3](https://github.com/jeong-sik/oas/commit/6577be34f22b5ea9d98c3444ab3dba851b6a2e86))
* **dune:** remove orphaned (rule stanza from dune file ([1dc7af9](https://github.com/jeong-sik/oas/commit/1dc7af940a1e8c0093ea934a54b4cad208e48d14))
* **dune:** remove trailing blank line ([4df5435](https://github.com/jeong-sik/oas/commit/4df54355c85a7a34dd47b94e59b953aaa3ea8d43))
* **eval:** tag otel metric json exports ([#1423](https://github.com/jeong-sik/oas/issues/1423)) ([d610422](https://github.com/jeong-sik/oas/commit/d610422aec346db7df4b6da16da450ff50d578a2))
* expose cli stdout recovery metadata ([#1457](https://github.com/jeong-sik/oas/issues/1457)) ([31abd8e](https://github.com/jeong-sik/oas/commit/31abd8e84f790e8a0d4a30a66cffce11e8ba4526))
* **fmt:** join cons operator for Chat_template_kwargs ([#1329](https://github.com/jeong-sik/oas/issues/1329)) ([56931f1](https://github.com/jeong-sik/oas/commit/56931f1c44138a487fa7f51527e626f8f84b77ea))
* **fmt:** ocamlformat compliance followup for [#1324](https://github.com/jeong-sik/oas/issues/1324) ([118db54](https://github.com/jeong-sik/oas/commit/118db5437287f2d5c4124e2f0f23b0c9117b2650))
* **fmt:** ocamlformat compliance for thinking-control match and doc comments ([a671a12](https://github.com/jeong-sik/oas/commit/a671a1233db169cda0898fed810a2870d3330fe1))
* **fs:** unique tmp per writer to close atomic-write rename race ([#1165](https://github.com/jeong-sik/oas/issues/1165)) ([9c402ad](https://github.com/jeong-sik/oas/commit/9c402adca0d93eff11c680ceae15af326e22b6d4))
* harden exhaustive matches on closed variants (capabilities/streaming/agent) ([#1517](https://github.com/jeong-sik/oas/issues/1517)) ([1cd5d5a](https://github.com/jeong-sik/oas/commit/1cd5d5a9926a2010ca990f66739823e536a5f83d))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([e92553e](https://github.com/jeong-sik/oas/commit/e92553ee4379b9b33277848bd0fdf1f95e743b8e))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([51692a5](https://github.com/jeong-sik/oas/commit/51692a51a1eeb85fa087d7cab5f04b1ae3544dc5))
* **http_client:** bound get_sync/post_sync/streaming with wall-clock timeout ([#1164](https://github.com/jeong-sik/oas/issues/1164)) ([59f40f8](https://github.com/jeong-sik/oas/commit/59f40f8b16e5e7e4aaeb4c71dc147156edc0e63e))
* **http_client:** drain response body to prevent CLOSE_WAIT ([#965](https://github.com/jeong-sik/oas/issues/965)) ([#1148](https://github.com/jeong-sik/oas/issues/1148)) ([e988de7](https://github.com/jeong-sik/oas/commit/e988de72b78a728a4d16b2658952e0abebc1653d))
* **http_client:** SSE keepalive lines no longer reset stream_idle_timeout ([#1246](https://github.com/jeong-sik/oas/issues/1246)) ([91b7c13](https://github.com/jeong-sik/oas/commit/91b7c130e79e7e34ab633db8cddbc1de31299df8))
* **http:** classify empty trust anchors as local resource ([#1610](https://github.com/jeong-sik/oas/issues/1610)) ([4e86499](https://github.com/jeong-sik/oas/commit/4e86499f4c84b8d7793ae8eea878a96ea7e98d63))
* **kimi:** route keeper-scale prompts via stdin ([#1253](https://github.com/jeong-sik/oas/issues/1253)) ([423f6ca](https://github.com/jeong-sik/oas/commit/423f6ca0bab323d18429738ca77087fffa3c0d63))
* **llm_provider:** extract hardcoded max_tokens 4096 fallback to Constants (S08) ([#1331](https://github.com/jeong-sik/oas/issues/1331)) ([89c9e12](https://github.com/jeong-sik/oas/commit/89c9e12d74d2b6fad58084e9a076300a7aab69b8))
* **llm_provider:** parse usage from kimi-cli JSONL output ([#1155](https://github.com/jeong-sik/oas/issues/1155)) ([fcd0e41](https://github.com/jeong-sik/oas/commit/fcd0e41a2b3d5f2ea91105fc316214b39302672d))
* **llm_provider:** remove anti-patterns in thinking, error classification, and Gemini/GLM backends ([#1326](https://github.com/jeong-sik/oas/issues/1326)) ([df249b6](https://github.com/jeong-sik/oas/commit/df249b650e8456e588ec1a3bbd2f109bc882d6b8))
* **llm_provider:** replace Eio.traceln with Diag.warn in CLI transports (F02) ([#1333](https://github.com/jeong-sik/oas/issues/1333)) ([9756e7e](https://github.com/jeong-sik/oas/commit/9756e7e6ff79ffd94cb637d6cb9c8607552ceeaf))
* **llm:** expose optional transport latency ([#1463](https://github.com/jeong-sik/oas/issues/1463)) ([eed15b4](https://github.com/jeong-sik/oas/commit/eed15b4cf3bbfc2d050b68188a6870af34766436))
* **llm:** lower confidence for fallback capability drift ([#1555](https://github.com/jeong-sik/oas/issues/1555)) ([26339df](https://github.com/jeong-sik/oas/commit/26339df8cacecb49cb33ddaf0ab88a56f85c9874))
* **main:** unblock 3 CI categories after [#1469](https://github.com/jeong-sik/oas/issues/1469)-[#1471](https://github.com/jeong-sik/oas/issues/1471) cascade ([ebfc95d](https://github.com/jeong-sik/oas/commit/ebfc95d6fb94c4e5c2a1c47af1380aa3f78fdbff))
* **main:** unblock 3 CI categories after [#1469](https://github.com/jeong-sik/oas/issues/1469)-[#1471](https://github.com/jeong-sik/oas/issues/1471) merge cascade ([73d727b](https://github.com/jeong-sik/oas/commit/73d727b45fa283bd2bda693678c6bf32687c010d))
* **mcp:** preserve builtin tool permissions ([#1438](https://github.com/jeong-sik/oas/issues/1438)) ([f568a07](https://github.com/jeong-sik/oas/commit/f568a07b653870984dc38722bb2c436c74b78693))
* **memory:** persist episodic procedural backends ([#1594](https://github.com/jeong-sik/oas/issues/1594)) ([e87b73f](https://github.com/jeong-sik/oas/commit/e87b73fd90e83a79c66cf974e02002ec9a5eb9a2))
* **memory:** preserve long-term backend compatibility ([#1628](https://github.com/jeong-sik/oas/issues/1628)) ([2c046ee](https://github.com/jeong-sik/oas/commit/2c046ee883ef0df26a7f8acbf12cce22d8f4bc78))
* **metrics:** aggregate streaming latency samples ([#1577](https://github.com/jeong-sik/oas/issues/1577)) ([a33ac78](https://github.com/jeong-sik/oas/commit/a33ac78895a87db2ff824a4d394c3a108d7807ad))
* **metrics:** deduplicate histogram bucket bounds in prometheus export ([#1564](https://github.com/jeong-sik/oas/issues/1564)) ([b2e8403](https://github.com/jeong-sik/oas/commit/b2e8403897a43660f3ed6ca17529e9c4b7cdebdc))
* **metrics:** emit Circuit_open directly from open-skip branch ([#1566](https://github.com/jeong-sik/oas/issues/1566)) ([8969475](https://github.com/jeong-sik/oas/commit/8969475eb8323d17400a8ba53632961173d0cad3))
* **metrics:** persist provider snapshots as json ([#1573](https://github.com/jeong-sik/oas/issues/1573)) ([d5037d2](https://github.com/jeong-sik/oas/commit/d5037d2346e7e13f5488a13495e65722b0a0a268))
* **metrics:** reject normalized-name collisions at register time ([#1570](https://github.com/jeong-sik/oas/issues/1570)) ([54d4b71](https://github.com/jeong-sik/oas/commit/54d4b71246d382aa8b3561c1a473e8efd9c48d9f))
* **metrics:** reject open-circuit snapshots without failure timestamp ([#1575](https://github.com/jeong-sik/oas/issues/1575)) ([fedcd13](https://github.com/jeong-sik/oas/commit/fedcd13664e32edd03f47b2763ad131cb7d2184c))
* **metrics:** support labeled histograms ([#1572](https://github.com/jeong-sik/oas/issues/1572)) ([e9f5ac6](https://github.com/jeong-sik/oas/commit/e9f5ac6dad19d380e5cb068caafe16eed7800ed6))
* **ollama:** preserve tool calls and avoid hard timeouts ([#1609](https://github.com/jeong-sik/oas/issues/1609)) ([64ec834](https://github.com/jeong-sik/oas/commit/64ec834685faf8f3ecc58817d6020f4aa6ab3126))
* **otel:** propagate trace context to provider calls ([#1576](https://github.com/jeong-sik/oas/issues/1576)) ([4060baa](https://github.com/jeong-sik/oas/commit/4060baac4b8f83468091f66011492c5b4981c7ad))
* pass gemini admin policy env vars to support headless mode disabling ask_user ([#1282](https://github.com/jeong-sik/oas/issues/1282)) ([ac8bdc9](https://github.com/jeong-sik/oas/commit/ac8bdc9628cf849ff2568c58e6b46c310cd7aba9))
* **paths:** replace assert false with invalid_arg, document MCP env var ([#1597](https://github.com/jeong-sik/oas/issues/1597)) ([9efc99d](https://github.com/jeong-sik/oas/commit/9efc99d9a91ed8b7b9658bcc34beb2cbba5d3db0))
* **pipeline:** count runtime MCP tools for tool_choice ([#1593](https://github.com/jeong-sik/oas/issues/1593)) ([f488eab](https://github.com/jeong-sik/oas/commit/f488eabf5d756ffb4a258465663aaf74ea295f42))
* **pipeline:** drop unused agent arg from turn_ready_tool_names callers ([#1599](https://github.com/jeong-sik/oas/issues/1599)) ([7489923](https://github.com/jeong-sik/oas/commit/748992379de975e3b7d705bd29dd6815864ea927))
* **pipeline:** honor effective tool contract retry ([#1184](https://github.com/jeong-sik/oas/issues/1184)) ([e56ab56](https://github.com/jeong-sik/oas/commit/e56ab56a667ea4145d7bbd8ea5a2d1c194f2cde6))
* **pipeline:** reject invisible tool choice contracts ([#1579](https://github.com/jeong-sik/oas/issues/1579)) ([b33e626](https://github.com/jeong-sik/oas/commit/b33e6267b49913f7fd1b2c59253403d8bf3b24e5))
* **plan:** make progress + is_done variant matches exhaustive ([#1518](https://github.com/jeong-sik/oas/issues/1518)) ([fd82743](https://github.com/jeong-sik/oas/commit/fd827431dc98a0f41fcf3dc7409f6c5bdc35e103))
* **pricing:** add gpt-5.5 rates ([#1189](https://github.com/jeong-sik/oas/issues/1189)) ([7b72b41](https://github.com/jeong-sik/oas/commit/7b72b41143cad951c9a1c56b2fdfa91dedd14304))
* **pricing:** map claude_code alias to sonnet-4-6 rates ([#1198](https://github.com/jeong-sik/oas/issues/1198)) ([94c3061](https://github.com/jeong-sik/oas/commit/94c306126398ed54095e51b6ef647baf467e9273))
* propagate provider clocks to completions ([#1319](https://github.com/jeong-sik/oas/issues/1319)) ([6a7b4d1](https://github.com/jeong-sik/oas/commit/6a7b4d1b23216b98dd5a6957dfb19c9d00220410))
* **provider_catalog:** fail-fast on unknown enum strings ([bb73cdc](https://github.com/jeong-sik/oas/commit/bb73cdc0d0db9afaae67c6d66a314d8169af7275))
* **provider_catalog:** fail-fast on unknown enum strings ([5a1cf67](https://github.com/jeong-sik/oas/commit/5a1cf674ff379871d20388b24f14fecc0e9b45d9))
* **provider:** align KIMI direct API with KIMI_API_KEY only ([#1159](https://github.com/jeong-sik/oas/issues/1159)) ([8919542](https://github.com/jeong-sik/oas/commit/891954246c4c6097eeb0fabecd51f37d4675c6e3))
* **provider:** apply ocamlformat to catalog overlay ([edb91b2](https://github.com/jeong-sik/oas/commit/edb91b29d35df8130d844e531a7492af89e3fefc))
* **provider:** apply ocamlformat to catalog overlay ([0b58dfe](https://github.com/jeong-sik/oas/commit/0b58dfecd53d0b5b7687051e3fcfea3588add8e1))
* **provider:** include context for empty HTTP errors ([#1582](https://github.com/jeong-sik/oas/issues/1582)) ([3b49c50](https://github.com/jeong-sik/oas/commit/3b49c5049faee63b045f641bfd4fb0cde0f6ebcd))
* **provider:** persist cascade health snapshots ([#1584](https://github.com/jeong-sik/oas/issues/1584)) ([4277673](https://github.com/jeong-sik/oas/commit/42776731e1ae0b6e505557c6912240f1550a3a3e))
* **provider:** register dashscope alias for DashScope kind ([#1207](https://github.com/jeong-sik/oas/issues/1207)) ([f04ea5a](https://github.com/jeong-sik/oas/commit/f04ea5a25abc2ef31ed35ee5b5b418c843292083))
* **provider:** remove GLM tool_choice coerce anti-pattern ([#1351](https://github.com/jeong-sik/oas/issues/1351)) ([7132e1f](https://github.com/jeong-sik/oas/commit/7132e1f178599db7d66503518c5abfd6ce1c7c56))
* **provider:** resolve runtime binding capabilities by config ([#1589](https://github.com/jeong-sik/oas/issues/1589)) ([da757ff](https://github.com/jeong-sik/oas/commit/da757ffc1ebc7a7c94c25370755b9a683b6ce412))
* **provider:** route provider intf through http client ([#1559](https://github.com/jeong-sik/oas/issues/1559)) ([b249b58](https://github.com/jeong-sik/oas/commit/b249b5887064e8da87b04697521742279103b72f))
* **provider:** surface OpenAI harness parse errors ([#1581](https://github.com/jeong-sik/oas/issues/1581)) ([42273ee](https://github.com/jeong-sik/oas/commit/42273ee4a4daf9a68aa5f3aa68b2c553be3cd05e))
* **release:** automate agent_sdk.opam sync inside release-please workflow ([#1604](https://github.com/jeong-sik/oas/issues/1604)) ([4b00bdf](https://github.com/jeong-sik/oas/commit/4b00bdff217e6233ed15bcc722d9aed410c36eba))
* **release:** refuse to tag from non-main or stale main ([#1136](https://github.com/jeong-sik/oas/issues/1136), [#1135](https://github.com/jeong-sik/oas/issues/1135)) ([#1168](https://github.com/jeong-sik/oas/issues/1168)) ([fe1efc2](https://github.com/jeong-sik/oas/commit/fe1efc2ba0063fac05eb3ad6e85b9c1a51e1df75))
* remove mutable anti-patterns — O(n) append, dead mutable, debug printf ([#1619](https://github.com/jeong-sik/oas/issues/1619)) ([5f8e07b](https://github.com/jeong-sik/oas/commit/5f8e07b777285f59c111b1a866166604d5bc4a1a))
* resolve CI failures (coverage, syntax error, sdk gate) ([90303e0](https://github.com/jeong-sik/oas/commit/90303e03addfa5cee334806c8c864c9faff47a91))
* resolve main build failures after release 0.193.6 ([#1532](https://github.com/jeong-sik/oas/issues/1532)) ([04447d4](https://github.com/jeong-sik/oas/commit/04447d4e1ded4ccc49bc101a209d404b206e1a10))
* **retry:** classify admin-disabled and account-suspended 429s as hard quota ([#1358](https://github.com/jeong-sik/oas/issues/1358)) ([45b6af2](https://github.com/jeong-sik/oas/commit/45b6af2f3c3fc59d03a018f727878e5999d417f6))
* **retry:** stop cascade on account usage limit ([#1428](https://github.com/jeong-sik/oas/issues/1428)) ([5ead30d](https://github.com/jeong-sik/oas/commit/5ead30d0c0ca7b72de32b8767bcea411a844eaed))
* **review:** harden recent OAS follow-ups ([66cff92](https://github.com/jeong-sik/oas/commit/66cff92c1987db2f9f69141d8ca736f91f8c11be))
* **runtime:** absorb runtime_server_worker into runtime_server, restore runtime_evidence ([b09ace3](https://github.com/jeong-sik/oas/commit/b09ace33a5b19934aa5057a6e6955ad7c9c16609))
* **runtime:** absorb runtime_server_worker, restore runtime_evidence ([692a4c2](https://github.com/jeong-sik/oas/commit/692a4c2348d1240ed50fc9102c28c9081e61c2f1))
* **runtime:** preserve raw trace run id on events ([#1192](https://github.com/jeong-sik/oas/issues/1192)) ([c69e09a](https://github.com/jeong-sik/oas/commit/c69e09a9c7f10e50708ea9fcd3dfaa0f9df8072c))
* **scripts:** recognize release-please CHANGELOG header format ([#1513](https://github.com/jeong-sik/oas/issues/1513)) ([188efa6](https://github.com/jeong-sik/oas/commit/188efa67bdb95de6888f0c7660d236e3cc9de2df))
* **streaming:** surface SSE parse failures instead of silent discard ([#1357](https://github.com/jeong-sik/oas/issues/1357)) ([83e40ea](https://github.com/jeong-sik/oas/commit/83e40ea8263a3ef101426b8e9e395e69d510c954))
* sync version truth for 0.170.1 ([2e86f5a](https://github.com/jeong-sik/oas/commit/2e86f5a852b218a1e3839c80e1cb519db91d7b96))
* **telemetry:** emit context window usage ([#1583](https://github.com/jeong-sik/oas/issues/1583)) ([070b9d4](https://github.com/jeong-sik/oas/commit/070b9d46d764d45d56b506d7edd51188a529a779))
* **test:** make telemetry SCA repo-root discovery fail fast ([b9d4f57](https://github.com/jeong-sik/oas/commit/b9d4f57e21904658f7163e6fcfe52f0fb18b6072))
* **test:** remove duplicate test_telemetry_sca — superseded by test/telemetry_sca/ ([4bab73f](https://github.com/jeong-sik/oas/commit/4bab73fa6236b4e4b8fac6c3d027a206780b217a))
* **test:** rescue test_discovery orphan (record field supports_tools) ([#1392](https://github.com/jeong-sik/oas/issues/1392)) ([720305e](https://github.com/jeong-sik/oas/commit/720305e75c1187fff939507bcbc45a56931b01db))
* **test:** rescue test_pipeline_deep orphan (record field enable_thinking) ([#1394](https://github.com/jeong-sik/oas/issues/1394)) ([5613191](https://github.com/jeong-sik/oas/commit/5613191bd681d10012fde7a24dd9b4211059f45b))
* **test:** rescue test_provider_config orphan (record field reasoning_tokens_estimated) ([#1388](https://github.com/jeong-sik/oas/issues/1388)) ([2724b1f](https://github.com/jeong-sik/oas/commit/2724b1fa67e299f768a99ecd8370be274c4e2582))
* **tool_selector:** replace failwith with empty list for unimplemented LLM categorical classifier ([#1455](https://github.com/jeong-sik/oas/issues/1455)) ([496c329](https://github.com/jeong-sik/oas/commit/496c329bc4423fb1ddbe61507bbc6b5df1ba23a9))
* **tools:** enforce shell descriptor constraints ([#1602](https://github.com/jeong-sik/oas/issues/1602)) ([ce90f5d](https://github.com/jeong-sik/oas/commit/ce90f5d2575d54ec339bdfd2744c019a8849414f))
* **transport/codex:** pass --ephemeral to suppress session race ([#1199](https://github.com/jeong-sik/oas/issues/1199)) ([a8ebf0c](https://github.com/jeong-sik/oas/commit/a8ebf0c459d6ec5d951e0ba704aeb9b92e9934ef))
* **transport/codex:** route HTTP MCP Bearer tokens via env var indirection ([#1203](https://github.com/jeong-sik/oas/issues/1203)) ([a4fdbc8](https://github.com/jeong-sik/oas/commit/a4fdbc88b737ff7c560b24f01566f08c6d68457e))
* **types:** preserve missing response usage ([#1449](https://github.com/jeong-sik/oas/issues/1449)) ([9639c92](https://github.com/jeong-sik/oas/commit/9639c9204c75c17d5c4e260111b8cb1be5ea257c))
* **usage:** keep api usage per response ([#1186](https://github.com/jeong-sik/oas/issues/1186)) ([bbe5e6b](https://github.com/jeong-sik/oas/commit/bbe5e6b099f508ae720e054bed6ad9855e367d71))
* warn on invalid cli integer env ([#1456](https://github.com/jeong-sik/oas/issues/1456)) ([21dea98](https://github.com/jeong-sik/oas/commit/21dea9862fab506eb8983740c9c12951b32dbe94))
* wrap agent_sdk base library ([c7fc03b](https://github.com/jeong-sik/oas/commit/c7fc03b19085e8acf8d647f4ea99838d89e539bd))
* **zai_catalog:** remove unsupported glm-5-code from coding auto-models ([92f108c](https://github.com/jeong-sik/oas/commit/92f108c6045b1e0065504ab059ac85a144db7f39))
* **zai_catalog:** remove unsupported glm-5-code from coding auto-models ([186e51c](https://github.com/jeong-sik/oas/commit/186e51c24e0e1eadc50840073396630cdb6b74b9))


### Performance Improvements

* **completion_contract:** build tool-lookup index lazily ([#1600](https://github.com/jeong-sik/oas/issues/1600)) ([e605a13](https://github.com/jeong-sik/oas/commit/e605a133d798a1e1e308727643b59692a5c2bc25))


### Code Refactoring

* remove migrated CDAL modules + façade re-exports (RFC-OAS-011 OAS-E PR-6) ([c5b120d](https://github.com/jeong-sik/oas/commit/c5b120d6f04eb8ea203dec2d1ffc5f8920656cdf))

## [0.194.1](https://github.com/jeong-sik/oas/compare/v0.194.0...v0.194.1) (2026-05-17)


### Bug Fixes

* **capabilities:** set Chat_template_kwargs for qwen3 ([#1614](https://github.com/jeong-sik/oas/issues/1614)) ([11181bb](https://github.com/jeong-sik/oas/commit/11181bb28147dc2b0e992885e9fabcba591f8b1c))

## [0.194.0](https://github.com/jeong-sik/oas/compare/v0.193.16...v0.194.0) (2026-05-16)


### ⚠ BREAKING CHANGES

* remove migrated CDAL modules + façade re-exports (RFC-OAS-011 OAS-E PR-6)

### Features

* add ppx_let support with Let_syntax in Result_syntax ([#1353](https://github.com/jeong-sik/oas/issues/1353)) ([9aeb72c](https://github.com/jeong-sik/oas/commit/9aeb72cb33e845fe99cf8e5983cf957a7022de84))
* add structured replay metadata to checkpoints ([#1149](https://github.com/jeong-sik/oas/issues/1149)) ([cbfbe96](https://github.com/jeong-sik/oas/commit/cbfbe96c3dcfe0fa73087f64dc0addd182bf971f))
* **agent_tools:** remove CDAL builtin_descriptor fallback (RFC-OAS-009 v2 PR-B) ([39082f6](https://github.com/jeong-sik/oas/commit/39082f6005888209a5b16c6aaa0b60bd25df050f))
* **agent_tools:** remove CDAL builtin_descriptor fallback (RFC-OAS-009 v2 PR-B) ([41d0144](https://github.com/jeong-sik/oas/commit/41d0144f22fbfc36ea0da2c92487caff638bf807))
* **agent:** add body_timeout_s to cap total HTTP body consumption ([#1209](https://github.com/jeong-sik/oas/issues/1209)) ([db54731](https://github.com/jeong-sik/oas/commit/db5473163d08bc25d4c7c60cf6419fbaad487c26))
* **agent:** add disclosure_level for tool schema serialization ([#1508](https://github.com/jeong-sik/oas/issues/1508)) ([f48ccec](https://github.com/jeong-sik/oas/commit/f48ccec3d1f6045627bb51c913944b7b879baf4d))
* **agent:** add disclosure_resolver for per-turn adaptive disclosure ([#1511](https://github.com/jeong-sik/oas/issues/1511)) ([7ed9c05](https://github.com/jeong-sik/oas/commit/7ed9c05260dce7b813bfaf524a2799573eb6479d))
* **agent:** add tiered recall prompt assembly ([#1133](https://github.com/jeong-sik/oas/issues/1133)) ([283d766](https://github.com/jeong-sik/oas/commit/283d76611ad74310f925937830f0d5f359f208b9))
* **agent:** add turn durability checkpoints ([#1550](https://github.com/jeong-sik/oas/issues/1550)) ([393ff0c](https://github.com/jeong-sik/oas/commit/393ff0c432734c6e2c471fd78b6ebba0040b48aa))
* **agent:** expose stream_idle_timeout_s on Agent.options ([#1195](https://github.com/jeong-sik/oas/issues/1195)) ([bd635d2](https://github.com/jeong-sik/oas/commit/bd635d27ed9dcaa0805ededcb68fd10d7656a42f))
* **agent:** index tool dispatch lookups ([#1557](https://github.com/jeong-sik/oas/issues/1557)) ([b7ea8e6](https://github.com/jeong-sik/oas/commit/b7ea8e6b00dd5ad1d3f4bbadeb26a071228c52f5))
* **agent:** native timeout handling for Agent.run ([#1006](https://github.com/jeong-sik/oas/issues/1006)) ([#1150](https://github.com/jeong-sik/oas/issues/1150)) ([d75c091](https://github.com/jeong-sik/oas/commit/d75c091b06e475451bdac69a50885c3c3a3bdf57))
* **arch:** decouple OAS from MASC by purging A2A and Handoff ([#1322](https://github.com/jeong-sik/oas/issues/1322)) ([d98e00e](https://github.com/jeong-sik/oas/commit/d98e00e43c405850d2fc80e7f52a93ac03c37bcf))
* **base:** Tool_id closed Variant identifier (RFC-OAS-008 PR-2/5) ([3c67d1e](https://github.com/jeong-sik/oas/commit/3c67d1e510fca49692937effd08cefc89aebd079))
* **base:** Tool_id closed Variant identifier (RFC-OAS-008 PR-2/5) ([8f413f8](https://github.com/jeong-sik/oas/commit/8f413f8a063273524f4fd2a22d14e69b1934709e))
* **capabilities:** add emits_usage_tokens + provider-label lookup ([#1173](https://github.com/jeong-sik/oas/issues/1173)) ([7ff7288](https://github.com/jeong-sik/oas/commit/7ff7288e69095c28a57b63447e986059fa17826f))
* **capabilities:** add prefix-match ordering regression test for for_model_id (M01) ([#1361](https://github.com/jeong-sik/oas/issues/1361)) ([711e5a0](https://github.com/jeong-sik/oas/commit/711e5a0164081ab1a91745d5d5e3afbe4e1aaa4d))
* **capabilities:** add thinking_control_format and structured capability_drop metrics ([b596d78](https://github.com/jeong-sik/oas/commit/b596d7896daf8b8b488acc3e116843437de2ad93))
* **capabilities:** add thinking_control_format and structured capability_drop metrics ([bff40ae](https://github.com/jeong-sik/oas/commit/bff40aed2578a5b138050dd35b2352488773b9b1))
* **capabilities:** Ollama dynamic capability discovery via /api/show (M03) ([#1362](https://github.com/jeong-sik/oas/issues/1362)) ([eca778b](https://github.com/jeong-sik/oas/commit/eca778bc1e7f6b79ab7c5c734f63da857bd438e7))
* **capabilities:** runtime model capability manifest (H12) ([#1347](https://github.com/jeong-sik/oas/issues/1347)) ([1299541](https://github.com/jeong-sik/oas/commit/1299541bbd5ed25646c69637c4080efa6bfd6cd0))
* **capability_manifest:** add set_global / clear_global runtime override ([#1516](https://github.com/jeong-sik/oas/issues/1516)) ([c3a786f](https://github.com/jeong-sik/oas/commit/c3a786f36f6fc37306c1f8932267b9f684180ed5))
* **ci:** boundary-lint for core→CDAL zero dependency (RFC-OAS-009 v2 PR-D) ([b0c7a44](https://github.com/jeong-sik/oas/commit/b0c7a4484fe1a6514c1a308e9ce01581e356c81a))
* **ci:** boundary-lint for core→CDAL zero dependency (RFC-OAS-009 v2 PR-D) ([f53a3f5](https://github.com/jeong-sik/oas/commit/f53a3f550a9b27848cc58e52ed024036cb86f281))
* **ci:** expand boundary-lint to 20 CDAL prefixes (RFC-OAS-011 OAS-E PR-1) ([0a306ce](https://github.com/jeong-sik/oas/commit/0a306ce0f30e28d44e780eedb68551d2ded634a3))
* **ci:** expand boundary-lint to 20 CDAL prefixes (RFC-OAS-011 OAS-E PR-1) ([e189ed7](https://github.com/jeong-sik/oas/commit/e189ed75b1d25b97a6bf9c4d8536d7c5b79188bc))
* **cli_common_subprocess:** bound CLI subprocess stdout with idle timeout ([#1191](https://github.com/jeong-sik/oas/issues/1191)) ([52a5279](https://github.com/jeong-sik/oas/commit/52a5279595e403560fb1227e8730948af4cc8ea6))
* **cli_common_subprocess:** opt-in stdout_recovery on nonzero exit ([#1200](https://github.com/jeong-sik/oas/issues/1200)) ([b98b391](https://github.com/jeong-sik/oas/commit/b98b391ff3f141916cd95bfec438e9d2d3db03f9))
* **context:** dynamic prompt cache alignment & budget compaction ([49823a6](https://github.com/jeong-sik/oas/commit/49823a614296289568e040ec197473e626031a2f))
* **context:** dynamic prompt cache alignment & budget compaction ([dd6f37e](https://github.com/jeong-sik/oas/commit/dd6f37ea70563c971b08103138fee80444aead55))
* **contract:** add strict required-tool satisfaction hook ([#1180](https://github.com/jeong-sik/oas/issues/1180)) ([c7d54b1](https://github.com/jeong-sik/oas/commit/c7d54b16b7d04fe362d8461112f4c0b99de2e6de))
* **event_bus:** add InferenceTelemetry event for per-turn timings ([#1202](https://github.com/jeong-sik/oas/issues/1202)) ([367de4e](https://github.com/jeong-sik/oas/commit/367de4e5a406e07af844c370c23b7c05c572a5e0))
* **event_bus:** add payload_kind SSOT helper for downstream consumers ([#1205](https://github.com/jeong-sik/oas/issues/1205)) ([c30be14](https://github.com/jeong-sik/oas/commit/c30be14602b2c8ad92395bb097df25ecbd9925e5))
* **event_bus:** add TurnReady event with effective tool list ([#1201](https://github.com/jeong-sik/oas/issues/1201)) ([97b8a60](https://github.com/jeong-sik/oas/commit/97b8a603f1917298ff1fd7814c46a7c108e986df))
* GLM-5-Code models and Kimi CLI model restrictions ([#1334](https://github.com/jeong-sik/oas/issues/1334)) ([6be9be9](https://github.com/jeong-sik/oas/commit/6be9be9be1b601cc797a3e3fbbda8524c95da4f3))
* **guardrails_async:** add per-validator deadline to prevent silent stall ([#1368](https://github.com/jeong-sik/oas/issues/1368)) ([b9e5f09](https://github.com/jeong-sik/oas/commit/b9e5f09791c7ef0f608f1dcc512dadc9368fdeb2))
* **guardrails:** tighten default tool_filter to DenyList + cap ([#1370](https://github.com/jeong-sik/oas/issues/1370)) ([7fa5cdc](https://github.com/jeong-sik/oas/commit/7fa5cdc9a264ef634c1069702dbfc4d90114c064))
* **http_client:** bound Ollama NDJSON stream with idle timeout ([#1185](https://github.com/jeong-sik/oas/issues/1185)) ([49ba678](https://github.com/jeong-sik/oas/commit/49ba6780d8cdc60266538deee7c84b26ab9363f2))
* **http_client:** bound SSE stream with same idle_timeout surface as NDJSON ([#1190](https://github.com/jeong-sik/oas/issues/1190)) ([a905970](https://github.com/jeong-sik/oas/commit/a905970b126191b42bbe64faf75c91c6a3d619ce))
* **lib:** add Cognitive_event typed schema (RFC-0036 PR-B) ([#1451](https://github.com/jeong-sik/oas/issues/1451)) ([f848e75](https://github.com/jeong-sik/oas/commit/f848e75a298827722d5f6cff8162f954ae20f974))
* **llm_provider:** add DashScope first-class support for Qwen models ([b6decd4](https://github.com/jeong-sik/oas/commit/b6decd42eaf46ba2c1b8c3e7b1ac855f4bd4416b))
* **llm_provider:** add DeepSeek v4 models (flash, pro) ([#1252](https://github.com/jeong-sik/oas/issues/1252)) ([19e3f1e](https://github.com/jeong-sik/oas/commit/19e3f1e58a9392ff87a8c587e4ed8c5e385765ce))
* **llm_provider:** implement usage token restoration for CLI wrappers (P7) ([#1342](https://github.com/jeong-sik/oas/issues/1342)) ([53c921a](https://github.com/jeong-sik/oas/commit/53c921a47635c4bc03c42ad33f95dc3f3ebea429))
* **llm_provider:** RFC-0058 Phase B — CLI transport factory ([#1520](https://github.com/jeong-sik/oas/issues/1520)) ([41e87e0](https://github.com/jeong-sik/oas/commit/41e87e0cd1fe4d57c4f627958b34fcf419839745))
* **llm_provider:** structured network_error_kind for NetworkError ([#1147](https://github.com/jeong-sik/oas/issues/1147)) ([2249ff6](https://github.com/jeong-sik/oas/commit/2249ff6d9efa9f695b111c1aa834c35096242acc))
* **llm_provider:** surface typed provider failures ([#1261](https://github.com/jeong-sik/oas/issues/1261)) ([b56b56d](https://github.com/jeong-sik/oas/commit/b56b56d5a33dcb262254ec7cc3e78d681eec6623))
* **llm_provider:** Visual_first modality ordering for Gemma 4 ([cf94ce9](https://github.com/jeong-sik/oas/commit/cf94ce9a95deaa34270f3f3c1cb75347ba5ea59d))
* **llm_provider:** Visual_first modality ordering for Gemma 4 ([791eee8](https://github.com/jeong-sik/oas/commit/791eee8b6266fe91d762f76544ae525bb4992f7c))
* **llm_provider:** wire ttfrc_ms and prefill_ms into inference_telemetry ([809b63a](https://github.com/jeong-sik/oas/commit/809b63a5c4dfbeed427d660295de26df3ed928eb))
* **log:** count records dropped without sinks ([#1402](https://github.com/jeong-sik/oas/issues/1402)) ([d039517](https://github.com/jeong-sik/oas/commit/d039517fef5daa0a740545bb1b99661decfa1185))
* **manifest:** carry provider health evidence ([#1398](https://github.com/jeong-sik/oas/issues/1398)) ([07a06e4](https://github.com/jeong-sik/oas/commit/07a06e49e313294a3d3d721dd8d8f2e1badbb39b))
* **mcp_schema:** remove descriptor_for_builtin_tool alias (RFC-OAS-009 v2 PR-C) ([ffb8aff](https://github.com/jeong-sik/oas/commit/ffb8aff3a3bac4bdfce823fe41ca176226ba2f13))
* **mcp_schema:** remove descriptor_for_builtin_tool alias (RFC-OAS-009 v2 PR-C) ([2c41611](https://github.com/jeong-sik/oas/commit/2c416118433aa703f97f1e891b5671e9f67bb931))
* **mcp:** cli provider integration and ollama dynamic capabilities ([8c460d0](https://github.com/jeong-sik/oas/commit/8c460d011b1aed997b106765f48f567a69e6eefd))
* **mcp:** cli provider integration and ollama dynamic capabilities ([230773e](https://github.com/jeong-sik/oas/commit/230773ee8642e44d928a539215e04401957a1cb1))
* **metrics:** add Prometheus text export ([#1556](https://github.com/jeong-sik/oas/issues/1556)) ([fc02639](https://github.com/jeong-sik/oas/commit/fc02639b940afe6714f207f08c41dc393e112260))
* **metrics:** emit cascade circuit state ([#1563](https://github.com/jeong-sik/oas/issues/1563)) ([1f69740](https://github.com/jeong-sik/oas/commit/1f69740fb423cc68c04b7d300597a9f164499c84))
* OAS Execution Manifest 고도화 및 Rate Limit Quota (P0~P1) ([44d8c84](https://github.com/jeong-sik/oas/commit/44d8c84676152ffb5eafb24da1ebb01db2d41ddd))
* **oas:** TLA+ CI gate + AgentCancellation spec + lifecycle_status yojson ([#1467](https://github.com/jeong-sik/oas/issues/1467)) ([7cd282f](https://github.com/jeong-sik/oas/commit/7cd282fed27ef6aa0637a6a12ca9356621619039))
* **ollama:** native NDJSON streaming, restore prompt_tok_s/decode_tok_s telemetry ([#1178](https://github.com/jeong-sik/oas/issues/1178)) ([e74a4d3](https://github.com/jeong-sik/oas/commit/e74a4d3161b1ed72cb51ae065f27ab5f7d4e262d))
* P0-P3 goals implementation (Rate limit quota, cascade config) ([1e58068](https://github.com/jeong-sik/oas/commit/1e580685527369f582836bd7aa6afedc59f1f4de))
* **pricing:** dynamic model pricing lookup via env vars (H11) ([#1348](https://github.com/jeong-sik/oas/issues/1348)) ([3017770](https://github.com/jeong-sik/oas/commit/301777035fe23868e27d4d3fa7544f7f3e534fc6))
* provider cascade routing + agent_sdk.base extraction (B→B+) ([#1346](https://github.com/jeong-sik/oas/issues/1346)) ([ac2e6e0](https://github.com/jeong-sik/oas/commit/ac2e6e04f155f687936ac41a55daaf003c3d0655))
* **provider_config:** surface ollama keep_alive and num_ctx to cascade ([#1176](https://github.com/jeong-sik/oas/issues/1176)) ([8308314](https://github.com/jeong-sik/oas/commit/8308314832678aa7532c96bb4c7f9764a2495442))
* **provider_kind:** expose all list + default_api_key_env + property tests ([#1126](https://github.com/jeong-sik/oas/issues/1126)) ([fde9cae](https://github.com/jeong-sik/oas/commit/fde9cae959b32096db72149720b0a155f9b986e8))
* **provider_kind:** lift is_subprocess_cli to the sum type's module ([#1128](https://github.com/jeong-sik/oas/issues/1128)) ([abd7d7e](https://github.com/jeong-sik/oas/commit/abd7d7e10763a884246878ead3e62b77fd56ac41))
* **provider:** add external provider catalog overlay ([35241e9](https://github.com/jeong-sik/oas/commit/35241e9a82ce30360449f19a115d6589041f8f79))
* **provider:** add internal_model_rotation_count hint to Provider_config ([#1211](https://github.com/jeong-sik/oas/issues/1211)) ([aae5b48](https://github.com/jeong-sik/oas/commit/aae5b48a33d2d5a0ccc3a1ea7cfa618b3cc8b6dd))
* **provider:** expose runtime bindings ([#1585](https://github.com/jeong-sik/oas/issues/1585)) ([dbabd5c](https://github.com/jeong-sik/oas/commit/dbabd5ca7daf3ab25a861973ba346faddd442201))
* **provider:** load external provider catalog ([a13a1d0](https://github.com/jeong-sik/oas/commit/a13a1d0caa6baf0eaf77cfaa1e0ebdbed380d490))
* **provider:** map transport errors to typed provider errors ([#1448](https://github.com/jeong-sik/oas/issues/1448)) ([e804755](https://github.com/jeong-sik/oas/commit/e804755e3fb4ce81c33cd2b32880b206c588c28a))
* **provider:** P0-P7 LLM provider improvement plan implementation ([#1337](https://github.com/jeong-sik/oas/issues/1337)) ([8fbd8ac](https://github.com/jeong-sik/oas/commit/8fbd8ac7a9570ac2311c0fdeb158c7efd3ff0360))
* **release:** adopt release-please for version + CHANGELOG automation ([fd9931d](https://github.com/jeong-sik/oas/commit/fd9931d7f60f3b966140fdc700fd29c982ac5ea5))
* **release:** adopt release-please for version + CHANGELOG automation ([058ea4b](https://github.com/jeong-sik/oas/commit/058ea4bea2205b21854960f7cd4cb885043a9de8))
* **retry:** add NotFound variant to api_error for HTTP 404 ([#1139](https://github.com/jeong-sik/oas/issues/1139)) ([95bdfac](https://github.com/jeong-sik/oas/commit/95bdfac920869f965d864b99126cc428fdcb5445))
* **runtime:** add collaboration projection contract ([#1260](https://github.com/jeong-sik/oas/issues/1260)) ([189a91c](https://github.com/jeong-sik/oas/commit/189a91c4d72fc33add247cb2f2e21cc058ee3149))
* **runtime:** add durable relay delivery primitive ([#1383](https://github.com/jeong-sik/oas/issues/1383)) ([b056099](https://github.com/jeong-sik/oas/commit/b056099b5de703da53d6b2f774db9847f5a18b7c))
* **specs:** TLA+ spec for Agent lifecycle FSM ([#1212](https://github.com/jeong-sik/oas/issues/1212)) ([#1213](https://github.com/jeong-sik/oas/issues/1213)) ([253ca0f](https://github.com/jeong-sik/oas/commit/253ca0f5d4a1f57ebd64957303b974f16cf363c0))
* **specs:** TLA+ spec for context window exhaustion ([#1212](https://github.com/jeong-sik/oas/issues/1212)) ([#1214](https://github.com/jeong-sik/oas/issues/1214)) ([a19bb1a](https://github.com/jeong-sik/oas/commit/a19bb1a3dfdd635884c445e33fdcd818d8c526e3))
* **structured:** expose schema extractors ([#1405](https://github.com/jeong-sik/oas/issues/1405)) ([08eed88](https://github.com/jeong-sik/oas/commit/08eed88c21e8146854f8199946bc87faf5a29544))
* **telemetry:** add SCA registry and audit tests for signal producer coverage ([1f57f3e](https://github.com/jeong-sik/oas/commit/1f57f3ebd1f2e678f638bcffe0ac0ebf87a61321))
* **telemetry:** per-turn typed telemetry events and bus ([7396ed6](https://github.com/jeong-sik/oas/commit/7396ed645cfb33a7f92df49f8c49806779044791))
* **telemetry:** RFC-OAS-019 Phase 1 — Streaming_summary at stream finalize ([#1578](https://github.com/jeong-sik/oas/issues/1578)) ([b26fed8](https://github.com/jeong-sik/oas/commit/b26fed80300016d987cbb5d0e9d817df9d02fe95))
* **telemetry:** wire ttfrc_ms and prefill_ms through patch_telemetry ([39f15ea](https://github.com/jeong-sik/oas/commit/39f15ea25dfa980375253af8f9b1c50815b17165))
* **telemetry:** wire ttfrc_ms and prefill_ms through patch_telemetry ([ef4ef9e](https://github.com/jeong-sik/oas/commit/ef4ef9e51d87411ec5a680a14385fcd613729974))
* **telemetry:** wire ttfrc_ms and prefill_ms to inference_telemetry ([98d5335](https://github.com/jeong-sik/oas/commit/98d5335fa0198e271dae98a420521f396af4934c))
* **transport_claude_code:** expose stdout_idle_timeout_s on config ([#1459](https://github.com/jeong-sik/oas/issues/1459)) ([564e1e7](https://github.com/jeong-sik/oas/commit/564e1e71df332c159dccc5e8280c391e5053af94))
* **transport_codex_cli:** expose stdout_idle_timeout_s on config ([#1458](https://github.com/jeong-sik/oas/issues/1458)) ([64d3e1a](https://github.com/jeong-sik/oas/commit/64d3e1a90eb55f03f251d1b85a0dabe8b6aa2064))
* **transport_gemini_cli:** expose stdout_idle_timeout_s on config ([#1461](https://github.com/jeong-sik/oas/issues/1461)) ([5240005](https://github.com/jeong-sik/oas/commit/5240005c444adbec870ae032882d495af03674ca))
* **transport_kimi_cli:** expose stdout_idle_timeout_s on config ([#1460](https://github.com/jeong-sik/oas/issues/1460)) ([cbfd139](https://github.com/jeong-sik/oas/commit/cbfd139a90baadde01f9940e71b8ac2a8f706547))
* **transport/claude_code:** structured ProviderTerminal for max_turns ([#1204](https://github.com/jeong-sik/oas/issues/1204)) ([162940f](https://github.com/jeong-sik/oas/commit/162940fd60552156c45431544efa3cec5d61f1ca))


### Bug Fixes

* add ollama cloud direct auth ([#1561](https://github.com/jeong-sik/oas/issues/1561)) ([9f265c1](https://github.com/jeong-sik/oas/commit/9f265c19fa477ab4810bff7ffca6083c652b8a95))
* add pricing entries for generic and CLI models ([#1197](https://github.com/jeong-sik/oas/issues/1197)) ([2842418](https://github.com/jeong-sik/oas/commit/284241842c1670482e1e2b0caf636d7f295d2fd3))
* **agent_sdk:** qualify base reexports ([#1389](https://github.com/jeong-sik/oas/issues/1389)) ([c310b2d](https://github.com/jeong-sik/oas/commit/c310b2d2fc31db2f83ce2fa447376be4df21f9c8))
* **agent_tools:** restrict find_in_index fallback to non-User tool IDs ([#1568](https://github.com/jeong-sik/oas/issues/1568)) ([5e68d21](https://github.com/jeong-sik/oas/commit/5e68d21d4530af6c8991ff769921749f2287d6ab))
* **agent_turn:** make reserve_strategy_budget strategy match exhaustive ([#1522](https://github.com/jeong-sik/oas/issues/1522)) ([c6428ae](https://github.com/jeong-sik/oas/commit/c6428ae937bd378ff72228671adcb9d328495dc7))
* **agent:** gate context overflow auto retry ([#1553](https://github.com/jeong-sik/oas/issues/1553)) ([8ed4183](https://github.com/jeong-sik/oas/commit/8ed4183fb20d97fe7b4dcb704b9a3d29d674ef4c))
* **agent:** index tool lookup paths ([#1592](https://github.com/jeong-sik/oas/issues/1592)) ([31bda07](https://github.com/jeong-sik/oas/commit/31bda07bd54c4e902b35030ec4d71547718bd1ca))
* **agent:** narrow runtime mcp per turn ([#1596](https://github.com/jeong-sik/oas/issues/1596)) ([36f7b37](https://github.com/jeong-sik/oas/commit/36f7b3779b01c38f3d69e94374c6d0812cb96403))
* **agent:** order checkpoint completion effects ([#1552](https://github.com/jeong-sik/oas/issues/1552)) ([cfbdabd](https://github.com/jeong-sik/oas/commit/cfbdabdf1c40493b36b023a0a97248ff939d571a))
* **agent:** route registry discovery through http client ([#1560](https://github.com/jeong-sik/oas/issues/1560)) ([c0ada64](https://github.com/jeong-sik/oas/commit/c0ada64d5b89196a06969f292b77268f36e03bab))
* **agent:** stop periodic callbacks on cancellation ([#1447](https://github.com/jeong-sik/oas/issues/1447)) ([217ed2a](https://github.com/jeong-sik/oas/commit/217ed2a1833118dbf4dfb7ba7d1d25f92fbbb3f2))
* align agent sdk version metadata ([#1288](https://github.com/jeong-sik/oas/issues/1288)) ([5063db8](https://github.com/jeong-sik/oas/commit/5063db8ce4ff85cc8a583e53639a1e070465d656))
* align kimi cli session reuse with actual CLI contract ([#1157](https://github.com/jeong-sik/oas/issues/1157)) ([8b5bf30](https://github.com/jeong-sik/oas/commit/8b5bf30ac632cea97e46b2da9a7e81c117eaa2ae))
* **api_openai:** make is_zai_provider_config Provider.config match exhaustive ([#1523](https://github.com/jeong-sik/oas/issues/1523)) ([98814d1](https://github.com/jeong-sik/oas/commit/98814d1c56f151ca9b32b46d5e5639e09ab0869a))
* **api:** bound LLM HTTP requests with wall-clock timeout ([#1163](https://github.com/jeong-sik/oas/issues/1163)) ([700d864](https://github.com/jeong-sik/oas/commit/700d8648042c47b96002d44b513aa844b237ccd6))
* **api:** route legacy create_message through http client ([#1558](https://github.com/jeong-sik/oas/issues/1558)) ([a20ed9f](https://github.com/jeong-sik/oas/commit/a20ed9f812c30428e5168bc3aade3e1e86eceb92))
* **backend_gemini:** make has_tool_use content_block match exhaustive (N-of-M followup to [#1519](https://github.com/jeong-sik/oas/issues/1519)/[#1521](https://github.com/jeong-sik/oas/issues/1521)) ([#1525](https://github.com/jeong-sik/oas/issues/1525)) ([01d3276](https://github.com/jeong-sik/oas/commit/01d3276dcc48b37a9ee9ea42f1eee95c4b486e10))
* **backend_openai:** make Thinking-detection content_block matches exhaustive (2 sites, N-of-M followup) ([#1526](https://github.com/jeong-sik/oas/issues/1526)) ([591c961](https://github.com/jeong-sik/oas/commit/591c961fb8f14eb5f45c061774e0ba8fe465685b))
* bound cascade provider attempts ([#1375](https://github.com/jeong-sik/oas/issues/1375)) ([cafb7c0](https://github.com/jeong-sik/oas/commit/cafb7c00674dedc23328a5caa2294a584cfef114))
* **build:** resolve main build/test failures ([3381d9a](https://github.com/jeong-sik/oas/commit/3381d9abe8b37030e35888c659f7f254331b3a32))
* **build:** resolve main CI failures post-0.193.6 ([1b0593f](https://github.com/jeong-sik/oas/commit/1b0593f101ccf70aa443b364fa8f5d5c4ea5f54e))
* **capabilities:** keep reasoning effort overlay conservative ([44ef91e](https://github.com/jeong-sik/oas/commit/44ef91e7822792986e73c6356fa481dd3c46c173))
* **capabilities:** surface manifest load diagnostics ([#1381](https://github.com/jeong-sik/oas/issues/1381)) ([7afb3b0](https://github.com/jeong-sik/oas/commit/7afb3b0457f5b47c54231a3b20b3a7dac15f080b))
* **capability_manifest:** post-merge follow-up to [#1516](https://github.com/jeong-sik/oas/issues/1516) — Atomic.t + docstrings + test title ([#1529](https://github.com/jeong-sik/oas/issues/1529)) ([ea0023e](https://github.com/jeong-sik/oas/commit/ea0023ece0d9812995ebe8854bcfa1e8aa67f934))
* **capability_manifest:** remove duplicate doc text, fix SDK gate, apply ocamlformat ([5f248c1](https://github.com/jeong-sik/oas/commit/5f248c1d6f331a7e671942fc17afe2b877b7910f))
* **cascade:** gate provider attempts with throttle ([#1595](https://github.com/jeong-sik/oas/issues/1595)) ([30dcc69](https://github.com/jeong-sik/oas/commit/30dcc690119238418ba54e524b1032705cc01333))
* **cascade:** stop on TLS and local resource failures ([#1607](https://github.com/jeong-sik/oas/issues/1607)) ([1599ee0](https://github.com/jeong-sik/oas/commit/1599ee03516446007d96426f304bde4c3b3086d2))
* **cascade:** stop provider terminal fallthrough ([#1454](https://github.com/jeong-sik/oas/issues/1454)) ([15f3f0d](https://github.com/jeong-sik/oas/commit/15f3f0d9480d6d39df72f0c67403b590a1f17a97))
* **cascade:** use Eio mutex for provider health ([#1435](https://github.com/jeong-sik/oas/issues/1435)) ([a041368](https://github.com/jeong-sik/oas/commit/a04136828a78d45d2d6ecfed9563254b0bdbc170))
* **ci:** fill checkpoint delta usage fixture ([4624cf9](https://github.com/jeong-sik/oas/commit/4624cf936f1641bf72ea84033c9bb7a84f6bb7bc))
* **ci:** parse ocamlformat-split transport configs ([#1255](https://github.com/jeong-sik/oas/issues/1255)) ([8957f05](https://github.com/jeong-sik/oas/commit/8957f05b05a3112cabb41c26582dac36ee646de8))
* **ci:** restore main build after usage update ([36425dc](https://github.com/jeong-sik/oas/commit/36425dc4e7f9a5d8453c11dff7765b7e177f618d))
* **ci:** restore main build after usage update ([9d8b912](https://github.com/jeong-sik/oas/commit/9d8b912743aedb567a0f65317ce2f3eaada27144))
* **collaboration:** make is_claimable claim_phase match exhaustive ([#1524](https://github.com/jeong-sik/oas/issues/1524)) ([a09983d](https://github.com/jeong-sik/oas/commit/a09983dd1c5006c764c9230d5a29ca5200bbfb00))
* **completion:** lower tool-choice fallback log noise ([#1608](https://github.com/jeong-sik/oas/issues/1608)) ([f53a814](https://github.com/jeong-sik/oas/commit/f53a814a7c1afec9d686c7410282d94be9abae4b))
* **content_block:** close 7 catch-all sites across pipeline + context_reducer + tool_use_recovery ([#1519](https://github.com/jeong-sik/oas/issues/1519)) ([c52b945](https://github.com/jeong-sik/oas/commit/c52b9451b6214a3fad94df79a61f1287505b446e))
* **context_reducer:** close 9 content_block catch-all sites in apply ([#1521](https://github.com/jeong-sik/oas/issues/1521)) ([92590ae](https://github.com/jeong-sik/oas/commit/92590ae10e99bbb929ad45705058964729555309))
* **context:** surface reducer repair diagnostics ([#1611](https://github.com/jeong-sik/oas/issues/1611)) ([688ee48](https://github.com/jeong-sik/oas/commit/688ee48efb3ffe227305b9ba52c8a0393f4bba03))
* **cost:** address Copilot review findings on the fail-closed path ([85f0e1f](https://github.com/jeong-sik/oas/commit/85f0e1fdd63c73a9712b2078b587e3c72551ce79))
* **cost:** fail closed when max_cost_usd is set + a turn ran an unpriced model ([dfa9bf1](https://github.com/jeong-sik/oas/commit/dfa9bf1c0ac363c571a2c4bc8556b413de47d02c))
* **cost:** fail closed when max_cost_usd is set + unpriced model ([6ec5725](https://github.com/jeong-sik/oas/commit/6ec5725f4e73093b5a7149bc467293d95b9390eb))
* **discovery:** validate env scan ports ([e6553c7](https://github.com/jeong-sik/oas/commit/e6553c7a8f8a10ef16883b49c15042071b89bce3))
* **dune:** add blank line between stanzas for ocamlformat ([6577be3](https://github.com/jeong-sik/oas/commit/6577be34f22b5ea9d98c3444ab3dba851b6a2e86))
* **dune:** remove orphaned (rule stanza from dune file ([1dc7af9](https://github.com/jeong-sik/oas/commit/1dc7af940a1e8c0093ea934a54b4cad208e48d14))
* **dune:** remove trailing blank line ([4df5435](https://github.com/jeong-sik/oas/commit/4df54355c85a7a34dd47b94e59b953aaa3ea8d43))
* **eval:** tag otel metric json exports ([#1423](https://github.com/jeong-sik/oas/issues/1423)) ([d610422](https://github.com/jeong-sik/oas/commit/d610422aec346db7df4b6da16da450ff50d578a2))
* expose cli stdout recovery metadata ([#1457](https://github.com/jeong-sik/oas/issues/1457)) ([31abd8e](https://github.com/jeong-sik/oas/commit/31abd8e84f790e8a0d4a30a66cffce11e8ba4526))
* **fmt:** join cons operator for Chat_template_kwargs ([#1329](https://github.com/jeong-sik/oas/issues/1329)) ([56931f1](https://github.com/jeong-sik/oas/commit/56931f1c44138a487fa7f51527e626f8f84b77ea))
* **fmt:** ocamlformat compliance followup for [#1324](https://github.com/jeong-sik/oas/issues/1324) ([118db54](https://github.com/jeong-sik/oas/commit/118db5437287f2d5c4124e2f0f23b0c9117b2650))
* **fmt:** ocamlformat compliance for thinking-control match and doc comments ([a671a12](https://github.com/jeong-sik/oas/commit/a671a1233db169cda0898fed810a2870d3330fe1))
* **fs:** unique tmp per writer to close atomic-write rename race ([#1165](https://github.com/jeong-sik/oas/issues/1165)) ([9c402ad](https://github.com/jeong-sik/oas/commit/9c402adca0d93eff11c680ceae15af326e22b6d4))
* harden exhaustive matches on closed variants (capabilities/streaming/agent) ([#1517](https://github.com/jeong-sik/oas/issues/1517)) ([1cd5d5a](https://github.com/jeong-sik/oas/commit/1cd5d5a9926a2010ca990f66739823e536a5f83d))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([e92553e](https://github.com/jeong-sik/oas/commit/e92553ee4379b9b33277848bd0fdf1f95e743b8e))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([51692a5](https://github.com/jeong-sik/oas/commit/51692a51a1eeb85fa087d7cab5f04b1ae3544dc5))
* **http_client:** bound get_sync/post_sync/streaming with wall-clock timeout ([#1164](https://github.com/jeong-sik/oas/issues/1164)) ([59f40f8](https://github.com/jeong-sik/oas/commit/59f40f8b16e5e7e4aaeb4c71dc147156edc0e63e))
* **http_client:** drain response body to prevent CLOSE_WAIT ([#965](https://github.com/jeong-sik/oas/issues/965)) ([#1148](https://github.com/jeong-sik/oas/issues/1148)) ([e988de7](https://github.com/jeong-sik/oas/commit/e988de72b78a728a4d16b2658952e0abebc1653d))
* **http_client:** SSE keepalive lines no longer reset stream_idle_timeout ([#1246](https://github.com/jeong-sik/oas/issues/1246)) ([91b7c13](https://github.com/jeong-sik/oas/commit/91b7c130e79e7e34ab633db8cddbc1de31299df8))
* **http:** classify empty trust anchors as local resource ([#1610](https://github.com/jeong-sik/oas/issues/1610)) ([4e86499](https://github.com/jeong-sik/oas/commit/4e86499f4c84b8d7793ae8eea878a96ea7e98d63))
* **kimi:** route keeper-scale prompts via stdin ([#1253](https://github.com/jeong-sik/oas/issues/1253)) ([423f6ca](https://github.com/jeong-sik/oas/commit/423f6ca0bab323d18429738ca77087fffa3c0d63))
* **llm_provider:** extract hardcoded max_tokens 4096 fallback to Constants (S08) ([#1331](https://github.com/jeong-sik/oas/issues/1331)) ([89c9e12](https://github.com/jeong-sik/oas/commit/89c9e12d74d2b6fad58084e9a076300a7aab69b8))
* **llm_provider:** parse usage from kimi-cli JSONL output ([#1155](https://github.com/jeong-sik/oas/issues/1155)) ([fcd0e41](https://github.com/jeong-sik/oas/commit/fcd0e41a2b3d5f2ea91105fc316214b39302672d))
* **llm_provider:** populate telemetry for streamed responses via non-HTTP transports ([#1140](https://github.com/jeong-sik/oas/issues/1140)) ([362e0a6](https://github.com/jeong-sik/oas/commit/362e0a67f178e33d058bff867d24bb30d6697b42))
* **llm_provider:** remove anti-patterns in thinking, error classification, and Gemini/GLM backends ([#1326](https://github.com/jeong-sik/oas/issues/1326)) ([df249b6](https://github.com/jeong-sik/oas/commit/df249b650e8456e588ec1a3bbd2f109bc882d6b8))
* **llm_provider:** replace Eio.traceln with Diag.warn in CLI transports (F02) ([#1333](https://github.com/jeong-sik/oas/issues/1333)) ([9756e7e](https://github.com/jeong-sik/oas/commit/9756e7e6ff79ffd94cb637d6cb9c8607552ceeaf))
* **llm:** expose optional transport latency ([#1463](https://github.com/jeong-sik/oas/issues/1463)) ([eed15b4](https://github.com/jeong-sik/oas/commit/eed15b4cf3bbfc2d050b68188a6870af34766436))
* **llm:** lower confidence for fallback capability drift ([#1555](https://github.com/jeong-sik/oas/issues/1555)) ([26339df](https://github.com/jeong-sik/oas/commit/26339df8cacecb49cb33ddaf0ab88a56f85c9874))
* **main:** unblock 3 CI categories after [#1469](https://github.com/jeong-sik/oas/issues/1469)-[#1471](https://github.com/jeong-sik/oas/issues/1471) cascade ([ebfc95d](https://github.com/jeong-sik/oas/commit/ebfc95d6fb94c4e5c2a1c47af1380aa3f78fdbff))
* **main:** unblock 3 CI categories after [#1469](https://github.com/jeong-sik/oas/issues/1469)-[#1471](https://github.com/jeong-sik/oas/issues/1471) merge cascade ([73d727b](https://github.com/jeong-sik/oas/commit/73d727b45fa283bd2bda693678c6bf32687c010d))
* **mcp:** preserve builtin tool permissions ([#1438](https://github.com/jeong-sik/oas/issues/1438)) ([f568a07](https://github.com/jeong-sik/oas/commit/f568a07b653870984dc38722bb2c436c74b78693))
* **memory:** persist episodic procedural backends ([#1594](https://github.com/jeong-sik/oas/issues/1594)) ([e87b73f](https://github.com/jeong-sik/oas/commit/e87b73fd90e83a79c66cf974e02002ec9a5eb9a2))
* **metrics:** aggregate streaming latency samples ([#1577](https://github.com/jeong-sik/oas/issues/1577)) ([a33ac78](https://github.com/jeong-sik/oas/commit/a33ac78895a87db2ff824a4d394c3a108d7807ad))
* **metrics:** deduplicate histogram bucket bounds in prometheus export ([#1564](https://github.com/jeong-sik/oas/issues/1564)) ([b2e8403](https://github.com/jeong-sik/oas/commit/b2e8403897a43660f3ed6ca17529e9c4b7cdebdc))
* **metrics:** emit Circuit_open directly from open-skip branch ([#1566](https://github.com/jeong-sik/oas/issues/1566)) ([8969475](https://github.com/jeong-sik/oas/commit/8969475eb8323d17400a8ba53632961173d0cad3))
* **metrics:** persist provider snapshots as json ([#1573](https://github.com/jeong-sik/oas/issues/1573)) ([d5037d2](https://github.com/jeong-sik/oas/commit/d5037d2346e7e13f5488a13495e65722b0a0a268))
* **metrics:** reject normalized-name collisions at register time ([#1570](https://github.com/jeong-sik/oas/issues/1570)) ([54d4b71](https://github.com/jeong-sik/oas/commit/54d4b71246d382aa8b3561c1a473e8efd9c48d9f))
* **metrics:** reject open-circuit snapshots without failure timestamp ([#1575](https://github.com/jeong-sik/oas/issues/1575)) ([fedcd13](https://github.com/jeong-sik/oas/commit/fedcd13664e32edd03f47b2763ad131cb7d2184c))
* **metrics:** support labeled histograms ([#1572](https://github.com/jeong-sik/oas/issues/1572)) ([e9f5ac6](https://github.com/jeong-sik/oas/commit/e9f5ac6dad19d380e5cb068caafe16eed7800ed6))
* **ollama:** preserve tool calls and avoid hard timeouts ([#1609](https://github.com/jeong-sik/oas/issues/1609)) ([64ec834](https://github.com/jeong-sik/oas/commit/64ec834685faf8f3ecc58817d6020f4aa6ab3126))
* **otel:** propagate trace context to provider calls ([#1576](https://github.com/jeong-sik/oas/issues/1576)) ([4060baa](https://github.com/jeong-sik/oas/commit/4060baac4b8f83468091f66011492c5b4981c7ad))
* pass gemini admin policy env vars to support headless mode disabling ask_user ([#1282](https://github.com/jeong-sik/oas/issues/1282)) ([ac8bdc9](https://github.com/jeong-sik/oas/commit/ac8bdc9628cf849ff2568c58e6b46c310cd7aba9))
* **paths:** replace assert false with invalid_arg, document MCP env var ([#1597](https://github.com/jeong-sik/oas/issues/1597)) ([9efc99d](https://github.com/jeong-sik/oas/commit/9efc99d9a91ed8b7b9658bcc34beb2cbba5d3db0))
* **pipeline:** count runtime MCP tools for tool_choice ([#1593](https://github.com/jeong-sik/oas/issues/1593)) ([f488eab](https://github.com/jeong-sik/oas/commit/f488eabf5d756ffb4a258465663aaf74ea295f42))
* **pipeline:** drop unused agent arg from turn_ready_tool_names callers ([#1599](https://github.com/jeong-sik/oas/issues/1599)) ([7489923](https://github.com/jeong-sik/oas/commit/748992379de975e3b7d705bd29dd6815864ea927))
* **pipeline:** honor effective tool contract retry ([#1184](https://github.com/jeong-sik/oas/issues/1184)) ([e56ab56](https://github.com/jeong-sik/oas/commit/e56ab56a667ea4145d7bbd8ea5a2d1c194f2cde6))
* **pipeline:** reject invisible tool choice contracts ([#1579](https://github.com/jeong-sik/oas/issues/1579)) ([b33e626](https://github.com/jeong-sik/oas/commit/b33e6267b49913f7fd1b2c59253403d8bf3b24e5))
* **plan:** make progress + is_done variant matches exhaustive ([#1518](https://github.com/jeong-sik/oas/issues/1518)) ([fd82743](https://github.com/jeong-sik/oas/commit/fd827431dc98a0f41fcf3dc7409f6c5bdc35e103))
* **pricing:** add gpt-5.5 rates ([#1189](https://github.com/jeong-sik/oas/issues/1189)) ([7b72b41](https://github.com/jeong-sik/oas/commit/7b72b41143cad951c9a1c56b2fdfa91dedd14304))
* **pricing:** map claude_code alias to sonnet-4-6 rates ([#1198](https://github.com/jeong-sik/oas/issues/1198)) ([94c3061](https://github.com/jeong-sik/oas/commit/94c306126398ed54095e51b6ef647baf467e9273))
* propagate provider clocks to completions ([#1319](https://github.com/jeong-sik/oas/issues/1319)) ([6a7b4d1](https://github.com/jeong-sik/oas/commit/6a7b4d1b23216b98dd5a6957dfb19c9d00220410))
* **provider_catalog:** fail-fast on unknown enum strings ([bb73cdc](https://github.com/jeong-sik/oas/commit/bb73cdc0d0db9afaae67c6d66a314d8169af7275))
* **provider_catalog:** fail-fast on unknown enum strings ([5a1cf67](https://github.com/jeong-sik/oas/commit/5a1cf674ff379871d20388b24f14fecc0e9b45d9))
* **provider:** align KIMI direct API with KIMI_API_KEY only ([#1159](https://github.com/jeong-sik/oas/issues/1159)) ([8919542](https://github.com/jeong-sik/oas/commit/891954246c4c6097eeb0fabecd51f37d4675c6e3))
* **provider:** apply ocamlformat to catalog overlay ([edb91b2](https://github.com/jeong-sik/oas/commit/edb91b29d35df8130d844e531a7492af89e3fefc))
* **provider:** apply ocamlformat to catalog overlay ([0b58dfe](https://github.com/jeong-sik/oas/commit/0b58dfecd53d0b5b7687051e3fcfea3588add8e1))
* **provider:** include context for empty HTTP errors ([#1582](https://github.com/jeong-sik/oas/issues/1582)) ([3b49c50](https://github.com/jeong-sik/oas/commit/3b49c5049faee63b045f641bfd4fb0cde0f6ebcd))
* **provider:** persist cascade health snapshots ([#1584](https://github.com/jeong-sik/oas/issues/1584)) ([4277673](https://github.com/jeong-sik/oas/commit/42776731e1ae0b6e505557c6912240f1550a3a3e))
* **provider:** register dashscope alias for DashScope kind ([#1207](https://github.com/jeong-sik/oas/issues/1207)) ([f04ea5a](https://github.com/jeong-sik/oas/commit/f04ea5a25abc2ef31ed35ee5b5b418c843292083))
* **provider:** remove GLM tool_choice coerce anti-pattern ([#1351](https://github.com/jeong-sik/oas/issues/1351)) ([7132e1f](https://github.com/jeong-sik/oas/commit/7132e1f178599db7d66503518c5abfd6ce1c7c56))
* **provider:** resolve runtime binding capabilities by config ([#1589](https://github.com/jeong-sik/oas/issues/1589)) ([da757ff](https://github.com/jeong-sik/oas/commit/da757ffc1ebc7a7c94c25370755b9a683b6ce412))
* **provider:** route provider intf through http client ([#1559](https://github.com/jeong-sik/oas/issues/1559)) ([b249b58](https://github.com/jeong-sik/oas/commit/b249b5887064e8da87b04697521742279103b72f))
* **provider:** surface OpenAI harness parse errors ([#1581](https://github.com/jeong-sik/oas/issues/1581)) ([42273ee](https://github.com/jeong-sik/oas/commit/42273ee4a4daf9a68aa5f3aa68b2c553be3cd05e))
* **release:** automate agent_sdk.opam sync inside release-please workflow ([#1604](https://github.com/jeong-sik/oas/issues/1604)) ([4b00bdf](https://github.com/jeong-sik/oas/commit/4b00bdff217e6233ed15bcc722d9aed410c36eba))
* **release:** refuse to tag from non-main or stale main ([#1136](https://github.com/jeong-sik/oas/issues/1136), [#1135](https://github.com/jeong-sik/oas/issues/1135)) ([#1168](https://github.com/jeong-sik/oas/issues/1168)) ([fe1efc2](https://github.com/jeong-sik/oas/commit/fe1efc2ba0063fac05eb3ad6e85b9c1a51e1df75))
* resolve CI failures (coverage, syntax error, sdk gate) ([90303e0](https://github.com/jeong-sik/oas/commit/90303e03addfa5cee334806c8c864c9faff47a91))
* resolve main build failures after release 0.193.6 ([#1532](https://github.com/jeong-sik/oas/issues/1532)) ([04447d4](https://github.com/jeong-sik/oas/commit/04447d4e1ded4ccc49bc101a209d404b206e1a10))
* **retry:** classify admin-disabled and account-suspended 429s as hard quota ([#1358](https://github.com/jeong-sik/oas/issues/1358)) ([45b6af2](https://github.com/jeong-sik/oas/commit/45b6af2f3c3fc59d03a018f727878e5999d417f6))
* **retry:** stop cascade on account usage limit ([#1428](https://github.com/jeong-sik/oas/issues/1428)) ([5ead30d](https://github.com/jeong-sik/oas/commit/5ead30d0c0ca7b72de32b8767bcea411a844eaed))
* **review:** harden recent OAS follow-ups ([66cff92](https://github.com/jeong-sik/oas/commit/66cff92c1987db2f9f69141d8ca736f91f8c11be))
* **runtime:** absorb runtime_server_worker into runtime_server, restore runtime_evidence ([b09ace3](https://github.com/jeong-sik/oas/commit/b09ace33a5b19934aa5057a6e6955ad7c9c16609))
* **runtime:** absorb runtime_server_worker, restore runtime_evidence ([692a4c2](https://github.com/jeong-sik/oas/commit/692a4c2348d1240ed50fc9102c28c9081e61c2f1))
* **runtime:** preserve raw trace run id on events ([#1192](https://github.com/jeong-sik/oas/issues/1192)) ([c69e09a](https://github.com/jeong-sik/oas/commit/c69e09a9c7f10e50708ea9fcd3dfaa0f9df8072c))
* **scripts:** recognize release-please CHANGELOG header format ([#1513](https://github.com/jeong-sik/oas/issues/1513)) ([188efa6](https://github.com/jeong-sik/oas/commit/188efa67bdb95de6888f0c7660d236e3cc9de2df))
* **streaming:** surface SSE parse failures instead of silent discard ([#1357](https://github.com/jeong-sik/oas/issues/1357)) ([83e40ea](https://github.com/jeong-sik/oas/commit/83e40ea8263a3ef101426b8e9e395e69d510c954))
* sync version truth for 0.170.1 ([2e86f5a](https://github.com/jeong-sik/oas/commit/2e86f5a852b218a1e3839c80e1cb519db91d7b96))
* sync version truth for 0.170.1 ([3610eb8](https://github.com/jeong-sik/oas/commit/3610eb8ac495125a664fdff8a460cf575ac35ac0))
* **telemetry:** emit context window usage ([#1583](https://github.com/jeong-sik/oas/issues/1583)) ([070b9d4](https://github.com/jeong-sik/oas/commit/070b9d46d764d45d56b506d7edd51188a529a779))
* **test:** make telemetry SCA repo-root discovery fail fast ([b9d4f57](https://github.com/jeong-sik/oas/commit/b9d4f57e21904658f7163e6fcfe52f0fb18b6072))
* **test:** remove duplicate test_telemetry_sca — superseded by test/telemetry_sca/ ([4bab73f](https://github.com/jeong-sik/oas/commit/4bab73fa6236b4e4b8fac6c3d027a206780b217a))
* **test:** rescue test_discovery orphan (record field supports_tools) ([#1392](https://github.com/jeong-sik/oas/issues/1392)) ([720305e](https://github.com/jeong-sik/oas/commit/720305e75c1187fff939507bcbc45a56931b01db))
* **test:** rescue test_pipeline_deep orphan (record field enable_thinking) ([#1394](https://github.com/jeong-sik/oas/issues/1394)) ([5613191](https://github.com/jeong-sik/oas/commit/5613191bd681d10012fde7a24dd9b4211059f45b))
* **test:** rescue test_provider_config orphan (record field reasoning_tokens_estimated) ([#1388](https://github.com/jeong-sik/oas/issues/1388)) ([2724b1f](https://github.com/jeong-sik/oas/commit/2724b1fa67e299f768a99ecd8370be274c4e2582))
* **tool_selector:** replace failwith with empty list for unimplemented LLM categorical classifier ([#1455](https://github.com/jeong-sik/oas/issues/1455)) ([496c329](https://github.com/jeong-sik/oas/commit/496c329bc4423fb1ddbe61507bbc6b5df1ba23a9))
* **tools:** enforce shell descriptor constraints ([#1602](https://github.com/jeong-sik/oas/issues/1602)) ([ce90f5d](https://github.com/jeong-sik/oas/commit/ce90f5d2575d54ec339bdfd2744c019a8849414f))
* **tracing:** implement graceful shutdown/flush hooks for raw trace generation during timeouts ([90ba7f0](https://github.com/jeong-sik/oas/commit/90ba7f0a39561623e659301925359ac218639347))
* **transport/codex:** pass --ephemeral to suppress session race ([#1199](https://github.com/jeong-sik/oas/issues/1199)) ([a8ebf0c](https://github.com/jeong-sik/oas/commit/a8ebf0c459d6ec5d951e0ba704aeb9b92e9934ef))
* **transport/codex:** route HTTP MCP Bearer tokens via env var indirection ([#1203](https://github.com/jeong-sik/oas/issues/1203)) ([a4fdbc8](https://github.com/jeong-sik/oas/commit/a4fdbc88b737ff7c560b24f01566f08c6d68457e))
* **types:** preserve missing response usage ([#1449](https://github.com/jeong-sik/oas/issues/1449)) ([9639c92](https://github.com/jeong-sik/oas/commit/9639c9204c75c17d5c4e260111b8cb1be5ea257c))
* **usage:** keep api usage per response ([#1186](https://github.com/jeong-sik/oas/issues/1186)) ([bbe5e6b](https://github.com/jeong-sik/oas/commit/bbe5e6b099f508ae720e054bed6ad9855e367d71))
* warn on invalid cli integer env ([#1456](https://github.com/jeong-sik/oas/issues/1456)) ([21dea98](https://github.com/jeong-sik/oas/commit/21dea9862fab506eb8983740c9c12951b32dbe94))
* wrap agent_sdk base library ([c7fc03b](https://github.com/jeong-sik/oas/commit/c7fc03b19085e8acf8d647f4ea99838d89e539bd))
* **zai_catalog:** remove unsupported glm-5-code from coding auto-models ([92f108c](https://github.com/jeong-sik/oas/commit/92f108c6045b1e0065504ab059ac85a144db7f39))
* **zai_catalog:** remove unsupported glm-5-code from coding auto-models ([186e51c](https://github.com/jeong-sik/oas/commit/186e51c24e0e1eadc50840073396630cdb6b74b9))


### Performance Improvements

* **completion_contract:** build tool-lookup index lazily ([#1600](https://github.com/jeong-sik/oas/issues/1600)) ([e605a13](https://github.com/jeong-sik/oas/commit/e605a133d798a1e1e308727643b59692a5c2bc25))


### Code Refactoring

* remove migrated CDAL modules + façade re-exports (RFC-OAS-011 OAS-E PR-6) ([c5b120d](https://github.com/jeong-sik/oas/commit/c5b120d6f04eb8ea203dec2d1ffc5f8920656cdf))

## [0.193.16](https://github.com/jeong-sik/oas/compare/v0.193.15...v0.193.16) (2026-05-17)

### Features

* **metrics:** emit provider-agnostic tool-call counts for LLM responses

### Bug Fixes

* **agent:** allow coordinators to own context-overflow compact retry
* **ollama:** remove the default hard cascade attempt timeout for local Ollama
* **ollama:** preserve parallel tool-call arguments and warn on malformed calls

## [0.193.15](https://github.com/jeong-sik/oas/compare/v0.193.14...v0.193.15) (2026-05-15)


### Bug Fixes

* **release:** automate agent_sdk.opam sync inside release-please workflow ([#1604](https://github.com/jeong-sik/oas/issues/1604)) ([4b00bdf](https://github.com/jeong-sik/oas/commit/4b00bdff217e6233ed15bcc722d9aed410c36eba))

## [0.193.14](https://github.com/jeong-sik/oas/compare/v0.193.13...v0.193.14) (2026-05-15)


### Bug Fixes

* **pipeline:** drop unused agent arg from turn_ready_tool_names callers ([#1599](https://github.com/jeong-sik/oas/issues/1599)) ([7489923](https://github.com/jeong-sik/oas/commit/748992379de975e3b7d705bd29dd6815864ea927))


### Performance Improvements

* **completion_contract:** build tool-lookup index lazily ([#1600](https://github.com/jeong-sik/oas/issues/1600)) ([e605a13](https://github.com/jeong-sik/oas/commit/e605a133d798a1e1e308727643b59692a5c2bc25))

## [0.193.13](https://github.com/jeong-sik/oas/compare/v0.193.12...v0.193.13) (2026-05-15)


### Bug Fixes

* **agent:** index tool lookup paths ([#1592](https://github.com/jeong-sik/oas/issues/1592)) ([31bda07](https://github.com/jeong-sik/oas/commit/31bda07bd54c4e902b35030ec4d71547718bd1ca))
* **agent:** narrow runtime mcp per turn ([#1596](https://github.com/jeong-sik/oas/issues/1596)) ([36f7b37](https://github.com/jeong-sik/oas/commit/36f7b3779b01c38f3d69e94374c6d0812cb96403))
* **cascade:** gate provider attempts with throttle ([#1595](https://github.com/jeong-sik/oas/issues/1595)) ([30dcc69](https://github.com/jeong-sik/oas/commit/30dcc690119238418ba54e524b1032705cc01333))
* **memory:** persist episodic procedural backends ([#1594](https://github.com/jeong-sik/oas/issues/1594)) ([e87b73f](https://github.com/jeong-sik/oas/commit/e87b73fd90e83a79c66cf974e02002ec9a5eb9a2))
* **paths:** replace assert false with invalid_arg, document MCP env var ([#1597](https://github.com/jeong-sik/oas/issues/1597)) ([9efc99d](https://github.com/jeong-sik/oas/commit/9efc99d9a91ed8b7b9658bcc34beb2cbba5d3db0))
* **pipeline:** count runtime MCP tools for tool_choice ([#1593](https://github.com/jeong-sik/oas/issues/1593)) ([f488eab](https://github.com/jeong-sik/oas/commit/f488eabf5d756ffb4a258465663aaf74ea295f42))
* **provider:** resolve runtime binding capabilities by config ([#1589](https://github.com/jeong-sik/oas/issues/1589)) ([da757ff](https://github.com/jeong-sik/oas/commit/da757ffc1ebc7a7c94c25370755b9a683b6ce412))

## [0.193.12](https://github.com/jeong-sik/oas/compare/v0.193.11...v0.193.12) (2026-05-14)


### Features

* **provider:** expose runtime bindings ([#1585](https://github.com/jeong-sik/oas/issues/1585)) ([dbabd5c](https://github.com/jeong-sik/oas/commit/dbabd5ca7daf3ab25a861973ba346faddd442201))


### Bug Fixes

* **provider:** persist cascade health snapshots ([#1584](https://github.com/jeong-sik/oas/issues/1584)) ([4277673](https://github.com/jeong-sik/oas/commit/42776731e1ae0b6e505557c6912240f1550a3a3e))

## [0.193.11](https://github.com/jeong-sik/oas/compare/v0.193.10...v0.193.11) (2026-05-14)


### Features

* **metrics:** emit cascade circuit state ([#1563](https://github.com/jeong-sik/oas/issues/1563)) ([1f69740](https://github.com/jeong-sik/oas/commit/1f69740fb423cc68c04b7d300597a9f164499c84))
* **telemetry:** RFC-OAS-019 Phase 1 — Streaming_summary at stream finalize ([#1578](https://github.com/jeong-sik/oas/issues/1578)) ([b26fed8](https://github.com/jeong-sik/oas/commit/b26fed80300016d987cbb5d0e9d817df9d02fe95))


### Bug Fixes

* **agent_tools:** restrict find_in_index fallback to non-User tool IDs ([#1568](https://github.com/jeong-sik/oas/issues/1568)) ([5e68d21](https://github.com/jeong-sik/oas/commit/5e68d21d4530af6c8991ff769921749f2287d6ab))
* **metrics:** aggregate streaming latency samples ([#1577](https://github.com/jeong-sik/oas/issues/1577)) ([a33ac78](https://github.com/jeong-sik/oas/commit/a33ac78895a87db2ff824a4d394c3a108d7807ad))
* **metrics:** deduplicate histogram bucket bounds in prometheus export ([#1564](https://github.com/jeong-sik/oas/issues/1564)) ([b2e8403](https://github.com/jeong-sik/oas/commit/b2e8403897a43660f3ed6ca17529e9c4b7cdebdc))
* **metrics:** emit Circuit_open directly from open-skip branch ([#1566](https://github.com/jeong-sik/oas/issues/1566)) ([8969475](https://github.com/jeong-sik/oas/commit/8969475eb8323d17400a8ba53632961173d0cad3))
* **metrics:** persist provider snapshots as json ([#1573](https://github.com/jeong-sik/oas/issues/1573)) ([d5037d2](https://github.com/jeong-sik/oas/commit/d5037d2346e7e13f5488a13495e65722b0a0a268))
* **metrics:** reject normalized-name collisions at register time ([#1570](https://github.com/jeong-sik/oas/issues/1570)) ([54d4b71](https://github.com/jeong-sik/oas/commit/54d4b71246d382aa8b3561c1a473e8efd9c48d9f))
* **metrics:** reject open-circuit snapshots without failure timestamp ([#1575](https://github.com/jeong-sik/oas/issues/1575)) ([fedcd13](https://github.com/jeong-sik/oas/commit/fedcd13664e32edd03f47b2763ad131cb7d2184c))
* **metrics:** support labeled histograms ([#1572](https://github.com/jeong-sik/oas/issues/1572)) ([e9f5ac6](https://github.com/jeong-sik/oas/commit/e9f5ac6dad19d380e5cb068caafe16eed7800ed6))
* **otel:** propagate trace context to provider calls ([#1576](https://github.com/jeong-sik/oas/issues/1576)) ([4060baa](https://github.com/jeong-sik/oas/commit/4060baac4b8f83468091f66011492c5b4981c7ad))
* **pipeline:** reject invisible tool choice contracts ([#1579](https://github.com/jeong-sik/oas/issues/1579)) ([b33e626](https://github.com/jeong-sik/oas/commit/b33e6267b49913f7fd1b2c59253403d8bf3b24e5))
* **provider:** include context for empty HTTP errors ([#1582](https://github.com/jeong-sik/oas/issues/1582)) ([3b49c50](https://github.com/jeong-sik/oas/commit/3b49c5049faee63b045f641bfd4fb0cde0f6ebcd))
* **provider:** surface OpenAI harness parse errors ([#1581](https://github.com/jeong-sik/oas/issues/1581)) ([42273ee](https://github.com/jeong-sik/oas/commit/42273ee4a4daf9a68aa5f3aa68b2c553be3cd05e))
* **telemetry:** emit context window usage ([#1583](https://github.com/jeong-sik/oas/issues/1583)) ([070b9d4](https://github.com/jeong-sik/oas/commit/070b9d46d764d45d56b506d7edd51188a529a779))

## [0.193.10](https://github.com/jeong-sik/oas/compare/v0.193.9...v0.193.10) (2026-05-13)


### Features

* **agent:** index tool dispatch lookups ([#1557](https://github.com/jeong-sik/oas/issues/1557)) ([b7ea8e6](https://github.com/jeong-sik/oas/commit/b7ea8e6b00dd5ad1d3f4bbadeb26a071228c52f5))
* **metrics:** add Prometheus text export ([#1556](https://github.com/jeong-sik/oas/issues/1556)) ([fc02639](https://github.com/jeong-sik/oas/commit/fc02639b940afe6714f207f08c41dc393e112260))


### Bug Fixes

* add ollama cloud direct auth ([#1561](https://github.com/jeong-sik/oas/issues/1561)) ([9f265c1](https://github.com/jeong-sik/oas/commit/9f265c19fa477ab4810bff7ffca6083c652b8a95))
* **agent:** route registry discovery through http client ([#1560](https://github.com/jeong-sik/oas/issues/1560)) ([c0ada64](https://github.com/jeong-sik/oas/commit/c0ada64d5b89196a06969f292b77268f36e03bab))
* **api:** route legacy create_message through http client ([#1558](https://github.com/jeong-sik/oas/issues/1558)) ([a20ed9f](https://github.com/jeong-sik/oas/commit/a20ed9f812c30428e5168bc3aade3e1e86eceb92))
* **llm:** lower confidence for fallback capability drift ([#1555](https://github.com/jeong-sik/oas/issues/1555)) ([26339df](https://github.com/jeong-sik/oas/commit/26339df8cacecb49cb33ddaf0ab88a56f85c9874))
* **provider:** route provider intf through http client ([#1559](https://github.com/jeong-sik/oas/issues/1559)) ([b249b58](https://github.com/jeong-sik/oas/commit/b249b5887064e8da87b04697521742279103b72f))

## [0.193.9](https://github.com/jeong-sik/oas/compare/v0.193.8...v0.193.9) (2026-05-13)


### Features

* **agent:** add turn durability checkpoints ([#1550](https://github.com/jeong-sik/oas/issues/1550)) ([393ff0c](https://github.com/jeong-sik/oas/commit/393ff0c432734c6e2c471fd78b6ebba0040b48aa))


### Bug Fixes

* **agent:** gate context overflow auto retry ([#1553](https://github.com/jeong-sik/oas/issues/1553)) ([8ed4183](https://github.com/jeong-sik/oas/commit/8ed4183fb20d97fe7b4dcb704b9a3d29d674ef4c))
* **agent:** order checkpoint completion effects ([#1552](https://github.com/jeong-sik/oas/issues/1552)) ([cfbdabd](https://github.com/jeong-sik/oas/commit/cfbdabdf1c40493b36b023a0a97248ff939d571a))

## [0.193.9](https://github.com/jeong-sik/oas/compare/v0.193.8...v0.193.9) (2026-05-13)


### Features

* **agent:** add generic turn-boundary checkpoint sink for crash recovery


### Bug Fixes

* **context:** make tool-use/result repair span-aware for strict providers
* **runtime:** save checkpoint snapshots before appending Checkpoint_saved events

## [0.193.8](https://github.com/jeong-sik/oas/compare/v0.193.7...v0.193.8) (2026-05-12)


### Features

* **provider:** add external provider catalog overlay ([35241e9](https://github.com/jeong-sik/oas/commit/35241e9a82ce30360449f19a115d6589041f8f79))
* **provider:** load external provider catalog ([a13a1d0](https://github.com/jeong-sik/oas/commit/a13a1d0caa6baf0eaf77cfaa1e0ebdbed380d490))


### Bug Fixes

* **capabilities:** keep reasoning effort overlay conservative ([44ef91e](https://github.com/jeong-sik/oas/commit/44ef91e7822792986e73c6356fa481dd3c46c173))
* **ci:** restore main build after usage update ([36425dc](https://github.com/jeong-sik/oas/commit/36425dc4e7f9a5d8453c11dff7765b7e177f618d))
* **ci:** restore main build after usage update ([9d8b912](https://github.com/jeong-sik/oas/commit/9d8b912743aedb567a0f65317ce2f3eaada27144))
* **cost:** address Copilot review findings on the fail-closed path ([85f0e1f](https://github.com/jeong-sik/oas/commit/85f0e1fdd63c73a9712b2078b587e3c72551ce79))
* **cost:** fail closed when max_cost_usd is set + a turn ran an unpriced model ([dfa9bf1](https://github.com/jeong-sik/oas/commit/dfa9bf1c0ac363c571a2c4bc8556b413de47d02c))
* **cost:** fail closed when max_cost_usd is set + unpriced model ([6ec5725](https://github.com/jeong-sik/oas/commit/6ec5725f4e73093b5a7149bc467293d95b9390eb))
* **discovery:** validate env scan ports ([e6553c7](https://github.com/jeong-sik/oas/commit/e6553c7a8f8a10ef16883b49c15042071b89bce3))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([e92553e](https://github.com/jeong-sik/oas/commit/e92553ee4379b9b33277848bd0fdf1f95e743b8e))
* **hooks:** catch user-hook exceptions in invoke / invoke_validated ([51692a5](https://github.com/jeong-sik/oas/commit/51692a51a1eeb85fa087d7cab5f04b1ae3544dc5))
* **provider_catalog:** fail-fast on unknown enum strings ([bb73cdc](https://github.com/jeong-sik/oas/commit/bb73cdc0d0db9afaae67c6d66a314d8169af7275))
* **provider_catalog:** fail-fast on unknown enum strings ([5a1cf67](https://github.com/jeong-sik/oas/commit/5a1cf674ff379871d20388b24f14fecc0e9b45d9))
* **provider:** apply ocamlformat to catalog overlay ([edb91b2](https://github.com/jeong-sik/oas/commit/edb91b29d35df8130d844e531a7492af89e3fefc))
* **provider:** apply ocamlformat to catalog overlay ([0b58dfe](https://github.com/jeong-sik/oas/commit/0b58dfecd53d0b5b7687051e3fcfea3588add8e1))
* **review:** harden recent OAS follow-ups ([66cff92](https://github.com/jeong-sik/oas/commit/66cff92c1987db2f9f69141d8ca736f91f8c11be))
* **test:** make telemetry SCA repo-root discovery fail fast ([b9d4f57](https://github.com/jeong-sik/oas/commit/b9d4f57e21904658f7163e6fcfe52f0fb18b6072))

## [0.193.7](https://github.com/jeong-sik/oas/compare/v0.193.6...v0.193.7) (2026-05-12)


### Features

* **capability_manifest:** add set_global / clear_global runtime override ([#1516](https://github.com/jeong-sik/oas/issues/1516)) ([c3a786f](https://github.com/jeong-sik/oas/commit/c3a786f36f6fc37306c1f8932267b9f684180ed5))
* **llm_provider:** RFC-0058 Phase B — CLI transport factory ([#1520](https://github.com/jeong-sik/oas/issues/1520)) ([41e87e0](https://github.com/jeong-sik/oas/commit/41e87e0cd1fe4d57c4f627958b34fcf419839745))


### Bug Fixes

* **agent_turn:** make reserve_strategy_budget strategy match exhaustive ([#1522](https://github.com/jeong-sik/oas/issues/1522)) ([c6428ae](https://github.com/jeong-sik/oas/commit/c6428ae937bd378ff72228671adcb9d328495dc7))
* **api_openai:** make is_zai_provider_config Provider.config match exhaustive ([#1523](https://github.com/jeong-sik/oas/issues/1523)) ([98814d1](https://github.com/jeong-sik/oas/commit/98814d1c56f151ca9b32b46d5e5639e09ab0869a))
* **backend_gemini:** make has_tool_use content_block match exhaustive (N-of-M followup to [#1519](https://github.com/jeong-sik/oas/issues/1519)/[#1521](https://github.com/jeong-sik/oas/issues/1521)) ([#1525](https://github.com/jeong-sik/oas/issues/1525)) ([01d3276](https://github.com/jeong-sik/oas/commit/01d3276dcc48b37a9ee9ea42f1eee95c4b486e10))
* **backend_openai:** make Thinking-detection content_block matches exhaustive (2 sites, N-of-M followup) ([#1526](https://github.com/jeong-sik/oas/issues/1526)) ([591c961](https://github.com/jeong-sik/oas/commit/591c961fb8f14eb5f45c061774e0ba8fe465685b))
* **capability_manifest:** post-merge follow-up to [#1516](https://github.com/jeong-sik/oas/issues/1516) — Atomic.t + docstrings + test title ([#1529](https://github.com/jeong-sik/oas/issues/1529)) ([ea0023e](https://github.com/jeong-sik/oas/commit/ea0023ece0d9812995ebe8854bcfa1e8aa67f934))
* **collaboration:** make is_claimable claim_phase match exhaustive ([#1524](https://github.com/jeong-sik/oas/issues/1524)) ([a09983d](https://github.com/jeong-sik/oas/commit/a09983dd1c5006c764c9230d5a29ca5200bbfb00))
* **content_block:** close 7 catch-all sites across pipeline + context_reducer + tool_use_recovery ([#1519](https://github.com/jeong-sik/oas/issues/1519)) ([c52b945](https://github.com/jeong-sik/oas/commit/c52b9451b6214a3fad94df79a61f1287505b446e))
* **context_reducer:** close 9 content_block catch-all sites in apply ([#1521](https://github.com/jeong-sik/oas/issues/1521)) ([92590ae](https://github.com/jeong-sik/oas/commit/92590ae10e99bbb929ad45705058964729555309))
* harden exhaustive matches on closed variants (capabilities/streaming/agent) ([#1517](https://github.com/jeong-sik/oas/issues/1517)) ([1cd5d5a](https://github.com/jeong-sik/oas/commit/1cd5d5a9926a2010ca990f66739823e536a5f83d))
* **plan:** make progress + is_done variant matches exhaustive ([#1518](https://github.com/jeong-sik/oas/issues/1518)) ([fd82743](https://github.com/jeong-sik/oas/commit/fd827431dc98a0f41fcf3dc7409f6c5bdc35e103))
* resolve main build failures after release 0.193.6 ([#1532](https://github.com/jeong-sik/oas/issues/1532)) ([04447d4](https://github.com/jeong-sik/oas/commit/04447d4e1ded4ccc49bc101a209d404b206e1a10))

## [0.193.6](https://github.com/jeong-sik/oas/compare/v0.193.5...v0.193.6) (2026-05-11)


### Bug Fixes

* **scripts:** recognize release-please CHANGELOG header format ([#1513](https://github.com/jeong-sik/oas/issues/1513)) ([188efa6](https://github.com/jeong-sik/oas/commit/188efa67bdb95de6888f0c7660d236e3cc9de2df))

## [0.193.5](https://github.com/jeong-sik/oas/compare/v0.193.4...v0.193.5) (2026-05-11)


### Features

* **agent:** add disclosure_resolver for per-turn adaptive disclosure ([#1511](https://github.com/jeong-sik/oas/issues/1511)) ([7ed9c05](https://github.com/jeong-sik/oas/commit/7ed9c05260dce7b813bfaf524a2799573eb6479d))

## [0.193.4](https://github.com/jeong-sik/oas/compare/v0.193.3...v0.193.4) (2026-05-11)


### Features

* **agent:** add disclosure_level for tool schema serialization ([#1508](https://github.com/jeong-sik/oas/issues/1508)) ([f48ccec](https://github.com/jeong-sik/oas/commit/f48ccec3d1f6045627bb51c913944b7b879baf4d))

### Compatibility Notes

* `Agent.options` is a concrete stable record in `Agent.mli`; the added `disclosure_level` field is source-breaking for downstream code that constructs or pattern-matches the record directly. Prefer `Builder.with_disclosure_level` for new code.

## [0.193.3](https://github.com/jeong-sik/oas/compare/v0.193.2...v0.193.3) (2026-05-11)


### Features

* **llm_provider:** wire ttfrc_ms and prefill_ms into inference_telemetry ([809b63a](https://github.com/jeong-sik/oas/commit/809b63a5c4dfbeed427d660295de26df3ed928eb))
* **telemetry:** wire ttfrc_ms and prefill_ms through patch_telemetry ([39f15ea](https://github.com/jeong-sik/oas/commit/39f15ea25dfa980375253af8f9b1c50815b17165))
* **telemetry:** wire ttfrc_ms and prefill_ms through patch_telemetry ([ef4ef9e](https://github.com/jeong-sik/oas/commit/ef4ef9e51d87411ec5a680a14385fcd613729974))
* **telemetry:** wire ttfrc_ms and prefill_ms to inference_telemetry ([98d5335](https://github.com/jeong-sik/oas/commit/98d5335fa0198e271dae98a420521f396af4934c))

## [0.193.2](https://github.com/jeong-sik/oas/compare/v0.193.1...v0.193.2) (2026-05-10)


### Features

* **telemetry:** add SCA registry and audit tests for signal producer coverage ([1f57f3e](https://github.com/jeong-sik/oas/commit/1f57f3ebd1f2e678f638bcffe0ac0ebf87a61321))
* **telemetry:** per-turn typed telemetry events and bus ([7396ed6](https://github.com/jeong-sik/oas/commit/7396ed645cfb33a7f92df49f8c49806779044791))

## [0.193.1](https://github.com/jeong-sik/oas/compare/v0.193.0...v0.193.1) (2026-05-10)


### Bug Fixes

* **runtime:** absorb runtime_server_worker into runtime_server, restore runtime_evidence ([b09ace3](https://github.com/jeong-sik/oas/commit/b09ace33a5b19934aa5057a6e6955ad7c9c16609))
* **runtime:** absorb runtime_server_worker, restore runtime_evidence ([692a4c2](https://github.com/jeong-sik/oas/commit/692a4c2348d1240ed50fc9102c28c9081e61c2f1))

## [0.193.0](https://github.com/jeong-sik/oas/compare/v0.192.1...v0.193.0) (2026-05-08)


### ⚠ BREAKING CHANGES

* remove migrated CDAL modules + façade re-exports (RFC-OAS-011 OAS-E PR-6)

### Features

* **agent_tools:** remove CDAL builtin_descriptor fallback (RFC-OAS-009 v2 PR-B) ([39082f6](https://github.com/jeong-sik/oas/commit/39082f6005888209a5b16c6aaa0b60bd25df050f))
* **agent_tools:** remove CDAL builtin_descriptor fallback (RFC-OAS-009 v2 PR-B) ([41d0144](https://github.com/jeong-sik/oas/commit/41d0144f22fbfc36ea0da2c92487caff638bf807))
* **base:** Tool_id closed Variant identifier (RFC-OAS-008 PR-2/5) ([3c67d1e](https://github.com/jeong-sik/oas/commit/3c67d1e510fca49692937effd08cefc89aebd079))
* **base:** Tool_id closed Variant identifier (RFC-OAS-008 PR-2/5) ([8f413f8](https://github.com/jeong-sik/oas/commit/8f413f8a063273524f4fd2a22d14e69b1934709e))
* **ci:** boundary-lint for core→CDAL zero dependency (RFC-OAS-009 v2 PR-D) ([b0c7a44](https://github.com/jeong-sik/oas/commit/b0c7a4484fe1a6514c1a308e9ce01581e356c81a))
* **ci:** boundary-lint for core→CDAL zero dependency (RFC-OAS-009 v2 PR-D) ([f53a3f5](https://github.com/jeong-sik/oas/commit/f53a3f550a9b27848cc58e52ed024036cb86f281))
* **ci:** expand boundary-lint to 20 CDAL prefixes (RFC-OAS-011 OAS-E PR-1) ([0a306ce](https://github.com/jeong-sik/oas/commit/0a306ce0f30e28d44e780eedb68551d2ded634a3))
* **ci:** expand boundary-lint to 20 CDAL prefixes (RFC-OAS-011 OAS-E PR-1) ([e189ed7](https://github.com/jeong-sik/oas/commit/e189ed75b1d25b97a6bf9c4d8536d7c5b79188bc))
* **mcp_schema:** remove descriptor_for_builtin_tool alias (RFC-OAS-009 v2 PR-C) ([ffb8aff](https://github.com/jeong-sik/oas/commit/ffb8aff3a3bac4bdfce823fe41ca176226ba2f13))
* **mcp_schema:** remove descriptor_for_builtin_tool alias (RFC-OAS-009 v2 PR-C) ([2c41611](https://github.com/jeong-sik/oas/commit/2c416118433aa703f97f1e891b5671e9f67bb931))
* **release:** adopt release-please for version + CHANGELOG automation ([fd9931d](https://github.com/jeong-sik/oas/commit/fd9931d7f60f3b966140fdc700fd29c982ac5ea5))
* **release:** adopt release-please for version + CHANGELOG automation ([058ea4b](https://github.com/jeong-sik/oas/commit/058ea4bea2205b21854960f7cd4cb885043a9de8))


### Bug Fixes

* **main:** unblock 3 CI categories after [#1469](https://github.com/jeong-sik/oas/issues/1469)-[#1471](https://github.com/jeong-sik/oas/issues/1471) cascade ([ebfc95d](https://github.com/jeong-sik/oas/commit/ebfc95d6fb94c4e5c2a1c47af1380aa3f78fdbff))
* **zai_catalog:** remove unsupported glm-5-code from coding auto-models ([92f108c](https://github.com/jeong-sik/oas/commit/92f108c6045b1e0065504ab059ac85a144db7f39))
* **zai_catalog:** remove unsupported glm-5-code from coding auto-models ([186e51c](https://github.com/jeong-sik/oas/commit/186e51c24e0e1eadc50840073396630cdb6b74b9))


### Code Refactoring

* remove migrated CDAL modules + façade re-exports (RFC-OAS-011 OAS-E PR-6) ([c5b120d](https://github.com/jeong-sik/oas/commit/c5b120d6f04eb8ea203dec2d1ffc5f8920656cdf))

## [0.193.0] - 2026-05-09

### BREAKING CHANGES

- **CDAL framework relocated to `masc_mcp.cdal_runtime`** (RFC-OAS-011). The
  Contract-Driven Agent Loop modules previously hosted in `agent_sdk` were
  consumer-side governance only ever used by `masc-mcp`; their presence in
  the SDK was a layering violation surfaced by RFC-OAS-009 v2. All 23
  modules now live in `masc_mcp.cdal_runtime` (jeong-sik/masc-mcp); `agent_sdk`
  no longer exposes them.

  Modules removed from `Agent_sdk`:
  `Cdal_proof`, `Mode_enforcer`, `Mode_resolver`, `Risk_contract`,
  `Risk_class`, `Execution_mode`, `Proof_capture`, `Proof_store`,
  `Contract_runner`, `Effect_evidence`, `Direct_evidence`, `Verified_output`,
  `Conformance`, `Cognitive_event`, `Audit`, `Autonomy_exec`,
  `Autonomy_diff_guard`, `Autonomy_trace_analyzer`, `Sessions_proof`,
  `Runtime_evidence`. Façade re-exports from `lib/agent_sdk.{ml,mli}`
  also dropped (#1489).

  Migration: external consumers should depend on `masc_mcp.cdal_runtime`
  for these symbols, or define their own equivalents.

- **`lib/sessions.{ml,mli}` no longer `include module type of Sessions_proof`**
  (#1489). The proof-bundle assembly migrated with the rest of CDAL.
  `Sessions_types` and `Sessions_store` includes are unchanged. Code using
  `Agent_sdk.Sessions.proof_bundle` etc. needs to switch to
  `Masc_mcp_cdal_runtime.Sessions_proof.proof_bundle`.

### Removed

- `lib/execution_manifest.{ml,mli}` (#1486): dead module, zero callers
  across OAS+masc-mcp ecosystem. Surfaced by the expanded CDAL boundary
  lint because its mli carried `Execution_mode.t`/`Risk_class.t` fields.
- `lib/runtime_server_worker.{ml,mli}` (#1487): dead module, zero
  production callers. Removed alongside its `Runtime_evidence` 15-call
  dependency chain and three associated test files (`test_runtime_evidence`,
  `test_runtime_server_worker`, `test_runtime_worker_integration`).
- 18 CDAL test files + 4 demo executables purged (#1488): coverage
  follows the modules to `masc_mcp.cdal_runtime`. `test_tool.ml` also
  drops its `builtin_descriptor` test group (5 cases) — RFC-OAS-009 v2
  PR-B/C unwired the API and PR-6 deletes the function entirely.

### Added

- `scripts/lint-core-cdal-boundary.sh` (#1483, #1485): rg-based CI guard
  that forbids OAS core (`lib/agent`, `lib/llm_provider`, `lib/protocol`,
  `lib/base`) from referencing CDAL modules. Originally 9 prefixes
  (RFC-OAS-009 v2 PR-D), expanded to 20 (RFC-OAS-011 OAS-E PR-1) after
  inventory revealed 14 implied-CDAL prefixes (`Audit`, `Autonomy_*`,
  `Sessions_proof`, `Runtime_evidence`, etc.) had been silently leaking.
- `lib/base/tool_id.{ml,mli}`: closed Variant `Tool_id.t` module.
  Identifier moves from string SSOT to typed Variant; Phase 1 of
  RFC-OAS-008. (#1475)
- New `Boundary Lint (Core→CDAL)` GitHub Actions job (#1483): fast
  `ripgrep`-only check, runs on Drafts, ≤5 min timeout. Provides
  same-minute feedback ahead of the heavier `Build & Test` matrix.

### Changed

- `lib/agent/agent_tools.ml:68` (#1481): `concurrency_class_of_tool` no
  longer falls back to `Mode_enforcer.builtin_descriptor` when the
  Tool's descriptor is missing. Instead returns
  `Tool.Sequential_workspace` (fail-closed). Severs the first of two
  core→CDAL reverse dependencies identified by RFC-OAS-009 v2 §1.1.1.
- `lib/protocol/mcp_schema.ml:63` (#1482): drops the
  `descriptor_for_builtin_tool` alias and its inline tests.
  `mcp_tool_to_sdk_tool` now creates `Tool.t` with `descriptor = None`
  by default; consumers supply via `Tool.with_descriptor` or MCP tool
  annotation. Severs the second of the two reverse dependencies.
- `lib/agent/agent_turn.ml:137` (#1485): doc comment reword
  ("Audit log…" → "Diagnostic log…") so the expanded boundary lint
  doesn't catch a coincidental keyword in a comment that was never an
  actual `Audit` module reference.

### Reclassified (no breaking change)

- `Agent_sdk.Guardrails_async` / `Guardrail_llm` / `Guardrail_tripwire`
  intentionally **stay** in OAS core. The OAS-E boundary-lint expansion
  initially flagged them but they are SDK-native safety hooks (carried
  as record fields in `agent_types.t` / `builder.t`) — Anthropic-style
  surface, not CDAL. Documented in `scripts/lint-core-cdal-boundary.sh`.
  Their cdal_runtime copies (introduced during MM-2 migration) are now
  redundant artifacts to be retired in masc-mcp's RFC-OAS-013.

### Documentation

- `docs/rfc/RFC-OAS-008-typed-tool-identification.md`: typed tool
  identification design (Phase 1 only). Scope intentionally narrow —
  registry / lookup migration deferred. (#1474)
- `docs/rfc/RFC-OAS-009-tool-name-ignorance.md`: redefined v2 (Sever
  Core→CDAL Dependencies) supersedes the merged v1 (default_tool_entries
  cleanup). v1's original intent migrates to RFC-OAS-012 once CDAL is
  hosted by masc-mcp.
- `docs/rfc/RFC-OAS-011-cdal-migration-to-masc-mcp.md`: cross-repo CDAL
  migration plan (#1480). Records the leaf-first batch ordering, the
  zero-downtime three-step merge sequence (masc-mcp self-contained →
  OAS-side removal → opam pin bump), and Sessions facade trim handoff.
- `docs/rfc/RFC-OAS-012-tool-name-ignorance-within-cdal.md`: post-migration
  cleanup plan (#1480). RFC-OAS-009 v1's original intent
  (`default_tool_entries` empty, `classify_tool` global removal,
  `capability_snapshot.tools` schema bump) now lives inside
  `masc_mcp.cdal_runtime` rather than OAS.

### Stat

OAS-E sweep total: **-18,237 LoC** removed across 6 PRs (#1485–#1489
plus #1483). Counterpart: ~7,531 LoC migrated into
`masc_mcp.cdal_runtime` across MM-2 batches (jeong-sik/masc-mcp PRs
#14248, #14253, #14255, #14259, #14264). Net OAS lib reduction
larger than the migrated payload — most of the delta was over-tested
dead surface accumulated alongside the CDAL framework.

## [0.192.1] - 2026-05-08

### Added
- `lib/llm_provider/modality.{ml,mli}`: `Modality.priority` type with `Preserve_input_order` (default) and `Visual_first` (Gemma 4 family) variants. Stable sort within group, no behavior change for non-Gemma callers. (#1469)
- `test/test_agent_cancellation_tla_parity.ml`: OCaml mirror predicates for `specs/AgentCancellation.tla` invariants. Validates `Runtime.phase` 7-state alphabet, 3 terminal phases, and `TerminalIsStable` (terminal → non-terminal disallowed). (#1471)

### Fixed
- `examples/cli_transports_demo.ml`: unwrap `latency_ms : int option` with `-1` sentinel for unmeasured case. Build error from #1463 (latency option migration) now resolved. (#1473)
- `.github/workflows/ci.yml`: TLA buggy-spec gate accepts both TLC exit codes 12 (state-level) and 13 (trace-level) as expected invariant violation. `ContentReplacementState` was producing exit 13 and falling through. (#1473)
- `lib/{cognitive_event.ml,llm_provider/capabilities.ml,llm_provider/modality.{ml,mli},llm_provider/types.ml,agent/agent_lifecycle.{ml,mli}}`: ocamlformat 0.29.0 (janestreet profile) drift accumulated across #1469-#1471 merges. (#1473)

### Changed
- `.github/workflows/ci.yml`: deduplicate `tla-model-check` job, keep `tla-specs` only. Removes redundant runtime. (#1470)

## [0.192.0] - 2026-05-08

### Added
- `specs/AgentCancellation.tla`: TLA+ specification for agent cancellation lifecycle. 7-phase alphabet, 3 terminal phases, `TerminalIsStable` and `CancelledRequiresSignal` invariants. Companion `.cfg` + `-buggy.cfg` for clean/buggy parity. (#1465, #1467)
- `Lifecycle_status.t`: `[@@deriving yojson]` derivation for JSON codec. (#1467)
- `.github/workflows/ci.yml`: `tla-specs` CI gate runs TLC against all `specs/*.cfg` (clean) and asserts invariant violation against `specs/*-buggy.cfg`. (#1465, #1467)

## [0.191.0] - 2026-05-07

### Changed
- `Llm_provider.Llm_transport.sync_result.latency_ms`, `Types.inference_telemetry.request_latency_ms`, and `Metrics.on_request_end` now carry `int option` latency. Transports report `Some ms` only when they measured elapsed time and `None` when latency is unavailable, so telemetry JSON emits `null` instead of conflating unknown latency with a measured `0`. Downstream consumers must handle the optional field when updating their OAS pin. (#1450, #1463)

### Added
- `lib/cognitive_event.{ml,mli}`: typed JSON-codecable cognitive event schema for SDK consumers. Four variants — `Gravity_ranked`, `Intent_predicted`, `Mode_transitioned`, `Disclosure_level` — backed by `[@@deriving yojson, show]` plus a `name` label getter and an `is_well_formed` invariant checker. Host coordinators emit these; the SDK does not produce them itself in this release. The type lives here so future SDK-side consumers (Hooks, Tracing) share a single schema. RFC-0036 PR-B. (#1451)
- `Context_intent.Cognitive_op` variant: routes to `Skip` retrieval depth so coordinator hosts can request classification without triggering heavy retrieval. RFC-0036 Extension A. (#1453)
- Transport CLI configs (`codex`, `claude_code`, `kimi_cli`, `gemini_cli`) expose `clock` and `stdout_idle_timeout_s` options to bound subprocess silence. Both must be `Some _` for the idle bound to engage. (#1458, #1459, #1460, #1461)
- `Provider_adapter`: map transport errors to typed provider errors. (#1448)
- Execution manifest carries risk-class cascade defaults. (#1441)
- Contract carries quota allocations. (#1443)
- Cascade timeout attempt diagnostics. (#1452)
- CLI stdout recovery metadata exposed via `recovered_exit_code` field. (#1457)
- `test/test_cognitive_event.ml`: 5 alcotest cases (label stability, well-formed accepts, well-formed rejects 12 invalid inputs, yojson roundtrip, yojson rejects garbage). (#1451)

### Fixed
- `Cascade`: stop provider terminal fallthrough. (#1454)
- `Tool_selector`: replace `failwith` with empty list for unimplemented LLM categorical classifier (still fails loudly via downstream contract checks; localized to one classifier site). (#1455)
- Warn on invalid CLI integer env. (#1456)
- `Types.api_response.usage`: preserve missing response usage instead of defaulting to zero. (#1449)
- `Agent`: stop periodic callbacks on cancellation. (#1447)

### Internal
- `scripts/check-sdk-independence.sh`: 2-tier scan with `--include-tests` and `--strict-tests` flags; OCaml comment heuristic + `boundary-allow` markers for intentional historical references. (#1462)
- Test fixtures neutralized of coordinator-specific vocabulary; long-standing migration / incident comments tagged with `boundary-allow`. (#1462)
- Restore SDK independence after merges that re-introduced coordinator terminology in `lib/` doc comments. (#1464)
- `chore(fmt)`: format execution manifest defaults; ocamlformat applied to contract + test_contract. (#1445, #1446)


## [0.190.26] - 2026-05-06

### Fixed
## [0.190.25] - 2026-05-06

### Fixed
- `Complete_cascade` provider-health tracker now uses `Eio.Mutex.lock`/`unlock` instead of `Stdlib.Mutex` + `Fun.protect`. The cascade path runs on Eio, so a `Stdlib.Mutex` waiter would block the whole domain rather than yield through the scheduler. This is one concrete cancellation hotspot retired from the broader cancellation-guard epic — not the whole epic. Refs: jeong-sik/masc-mcp#10395, jeong-sik/masc-mcp#11929. (#1435)

### Added
- `test/test_complete_cascade.ml`: concurrent Eio fiber regression that records provider failures through the shared health tracker, proving the new `Eio.Mutex` path is safe under concurrent updates. (#1435)
- `test/dune`: re-wired `test_runtime` (worker integration) and `test_structured_stream` as standalone test stanzas, clearing the last entries from the compile-failure orphan list. (#1434, #1436)

## [0.190.24] - 2026-05-06

### Added
- `test/dune`: re-wired `test_guardrails_async` as a standalone focused suite, removing it from the compile-failure orphan list. (#1432)

### Changed
- `test/test_guardrails_async.ml`: guarded-call assertions updated to the current final-unit API shape. 14 tests pass under the focused dune build. (#1432)

## [0.190.23] - 2026-05-06

### Added
- `test/dune`: re-wired `test_event_integration` as a standalone test stanza with its Eio/Cohttp dependencies, removing it from the compile-failure orphan list. (#1430)

### Changed
- `test/test_event_integration.ml`: replaced the stale private `Handoff` type reference with the public `Subagent.to_handoff_target` helper so the suite compiles against the current `lib/agent` interface. 5 tests pass under the focused dune build. (#1430)

## [0.190.22] - 2026-05-06

### Fixed
- `Llm_provider.Retry` now classifies the provider message `"Your account has exceeded the API usage limit"` as **hard account-level quota exhaustion** rather than a transient rate limit, so `Complete_cascade.complete_cascade` halts immediately instead of burning retries on the dead provider and cascading into fallback work. Surfaces the terminal quota state to callers without the wasted attempts. Related: jeong-sik/masc-mcp#11929. (#1428)

### Added
- `test/test_complete_cascade.ml`: cascade regression proving hard-quota classification stops without invoking fallback providers; the existing nonpositive `attempt_timeout_s` sentinel regression wired into the `complete_cascade` Alcotest suite; cascade test header updated to reflect current mocked-transport coverage. (#1428)
- `test/dune` + `test/test_deep_coverage.ml`: re-wired `test_deep_coverage` and restored the Alcotest runner for the active deep-coverage sections (74 tests). The commented A2A task-store section is left untouched per its dead-body status. (#1427)

## [0.190.21] - 2026-05-06

### Added
- `test/dune`: re-wired `test_agent_card` as a standalone test stanza, removing it from the compile-fail orphan list. (#1425)

### Fixed
- `test/test_agent_card.ml`: removed the stale `cascade` field from the `Agent_card.agent_info` fixture; the field was dropped from the production type but the orphaned test still populated it, blocking compile. (#1425)

## [0.190.20] - 2026-05-06

### Added
- `Eval_otel_bridge.to_metrics_json`: each exported metric object now carries a `tags` field with `agent_name` and `run_id`, so dashboards and report consumers can join JSON metrics back to the originating eval run without out-of-band context. The native OTel summary span already carried this correlation; the JSON export path was the gap. (#1423)

### Fixed
- `lib/eval_otel_bridge.ml` and `test/test_eval_otel_bridge.ml`: ocamlformat auto-promote on the new `to_metrics_json` correlation-tags blocks. #1423 was merged with the OCaml Format check failing (non-required gate), so the canonical breakdown of the new `match` arm and the long `Yojson.Safe.Util.(...)` chain landed unfmt; the bump captures the auto-promote as a single restart.

## [0.190.19] - 2026-05-06

### Added
- `test/dune`: re-wired `test_full_pipeline_cov` as a standalone test stanza, removing the last entry from the `pre-existing runtime failures` orphan list. (#1421)

### Fixed
- `test/test_full_pipeline_cov.ml`: canned mock provider response text is now JSON-escaped before being embedded in the response body string, so the structured-JSON parse path under test no longer fails on unescaped quotes/backslashes inside the mocked content. (#1421)

## [0.190.18] - 2026-05-06

### Added
- `test/dune`: re-wired `test_cli` as a standalone test stanza with full provider/runtime libraries (`cohttp-eio`, `eio_main`, `str`, `unix`, `yojson`) and `OAS_RUNTIME_PATH` env wiring so the CLI version/init/card/help/eval suite can locate the runtime binary inside the dune sandbox. (#1419)

## [0.190.17] - 2026-05-06

### Added
- `test/dune`: re-wired `test_builder` as an Eio-enabled standalone test stanza. (#1417)

### Changed
- `test/test_builder.ml` `extract_token_budget`: helper now recursively traverses `Context_reducer.Dynamic` strategies via a probe message large enough to drive the dynamic selector into its budgeted branch, so `from_context_config` assertions inspect the realized strategy shape instead of bailing on `Dynamic`. (#1417)

## [0.190.16] - 2026-05-06

### Added
- `test/dune`: re-wired `test_api` as a standalone test stanza. (#1415)

### Changed
- `test/test_api.ml`: SSE unknown-event and malformed-JSON assertions updated to expect the structured parser error variants emitted by the current `Streaming.parse_sse_event` contract, replacing the previous `None`-return expectations. (#1415)

## [0.190.15] - 2026-05-06

### Added
- `test/dune`: re-wired `test_lenient_json` as a focused stanza, removing it from the runtime-failure orphan list. (#1413)

### Changed
- `Lenient_json.parse`: `maybe_unwrap_string` now also triggers when the inner string starts with `"`, matching the existing recovery transform's behavior so triple-stringified JSON strings are unwrapped consistently with double-stringified objects/arrays. Trigger condition expanded from `t.[0] = '{' || t.[0] = '['` to `t.[0] = '{' || t.[0] = '[' || t.[0] = '"'`. (#1413)

## [0.190.14] - 2026-05-05

### Added
- `test/dune`: re-wired `test_complete_http`, `test_streaming`, and `test_llm_provider_cov` as focused test stanzas. Removes them from the runtime-failure orphan list and restores coverage for HTTP request metrics shaping, SSE typed-error parsing, and Gemini thinking-budget defaults. (#1408, #1410, #1411)

### Changed
- `test/test_complete_http.ml`: tests now construct `Metrics.t` via `{ Metrics.noop with on_cache_hit = ...; ... }` so they tolerate new optional metric callbacks (`on_capability_drop`, etc.) added since the suite was orphaned. (#1408)
- `test/test_streaming.ml`: `test_parse_invalid_json` and `test_parse_unknown_event_type` now assert the typed `SSEParseFailed` and `SSEUnknownEventType` variants instead of the previous `None` return, matching the current `Streaming.parse_sse_event` contract. (#1410)
- `test/test_llm_provider_cov.ml`: Gemini thinking default assertion follows `Constants.Thinking.gemini_budget ()` instead of the previously hard-coded value, so environment overrides flow through. (#1411)

## [0.190.13] - 2026-05-05

### Added
- `Structured.schema_to_json_schema` exposes the provider-native object schema generated from a typed schema, and `Structured.schema_extractor` lets `run_structured` callers reuse the same fenced-JSON parsing and `schema.parse` validation as direct structured extraction. (#1405)
- `test/dune`: re-wired `test_provider_bridge` and `test_provider_complete` as focused provider test stanzas, restoring coverage for ZAI coding auto-model order, GLM request shaping, Anthropic prompt caching, and structured-output rejection. (#1406)

### Fixed
- `Backend_anthropic.build_request` now requires both `cache_system_prompt = true` AND `String.length s >= prompt_cache_min_chars` to mark the system prompt cacheable (changed `||` → `&&`). Short system prompts stay plain strings even when the user opts into caching, matching Anthropic's documented minimum prompt length gate. (#1406)

### Changed
- `test/test_provider_bridge.ml`: ZAI coding auto-model default order updated to `[glm-5-code; glm-5.1; glm-5; glm-5-turbo; glm-4.7; glm-4.5-air]`. (#1406)
- `test/test_provider_complete.ml`: `test_glm_preserved_reasoning_replay_and_auto_tool_choice` renamed to `..._drops_unsupported_tool_choice` and assertion changed from "tool_choice coerced to auto" to "tool_choice key absent from request" to match current production behavior. Output-schema rejection assertion loosened from `"json mode only"` to `"json mode"`. (#1406)

## [0.190.12] - 2026-05-05

### Changed
- `.github/workflows/ci.yml`: extracted the duplicated "Pin fork packages" + 3-attempt `opam install . --deps-only --with-test --yes` retry block from the `build-and-test` and `lint` jobs into a single shared script `scripts/ci-setup-deps.sh`. Both jobs now invoke `opam exec -- bash scripts/ci-setup-deps.sh`. Removes ~28 lines of duplication and one drift surface (fork SHA / retry policy now changes in one place).
- `CLAUDE.md`: removed the literal `0.184.0` from the SDK version SSOT line (drifted vs `lib/sdk_version.ml`); coverage convention reworded from aspirational `75%+` to the actual CI ratchet floor pattern referenced from `ci.yml` `THRESHOLD`.

## [0.190.11] - 2026-05-05

### Added
- `Agent_sdk.Log.dropped_without_sink_count` exposes how many enabled log records were discarded because no sink was registered, allowing hosts to detect missing telemetry wiring without forcing stderr output. `Log.emit` reads `global_sinks` first and only allocates a record on the `sinks` arm, so the no-sink path stays cheap. `clear_sinks` now also resets the dropped counter so isolated tests start at 0. (#1402)

### Changed
- `lib/agent/agent.ml` per-turn log docstring reworded from "the record is counted and otherwise discarded" to "enabled emit attempt is counted and dropped without allocating a record" so it matches the actual `Log.emit` no-sink branch behavior. (#1402)

## [0.190.10] - 2026-05-05

### Changed
- `Mode_enforcer.record_effect_evidence` now stores the repo-relative path produced by `__FILE__` (e.g. `lib/mode_enforcer.ml`) in `source_path` instead of the basename-only payload introduced in 0.190.9. The repo-relative form preserves directory context while still being build-environment independent. The corresponding `test/test_cdal.ml` substring assertion was tightened to fail on basename-only regressions. (#1400)

### Added
- `test_circuit_open_skips_provider_and_falls_back` regression in `test/test_complete_cascade.ml`: proves an OPEN provider is skipped and the next provider in the cascade succeeds without invoking the open one. (#1400)

## [0.190.9] - 2026-05-05

### Added
- `Complete_cascade.provider_health_info` carries `circuit_open`, `health_score`, `consecutive_failures`, and `cooldown_remaining_s`. `provider_health_scores` exposes a list helper. `Execution_manifest` gains `provider_health` and optional `cascade_config`. `Effect_evidence` records carry `source_path`/`source_line`. `Agent_sdk` re-exports `Execution_manifest`. (#1398)

### Changed
- `circuit_open_and_remaining` returns `(false, None)` once the cooldown has elapsed instead of `(false, Some 0.0)`; the `.mli` documents the `cooldown_remaining_s` invariant. `Mode_enforcer.record_effect_evidence` writes `Filename.basename __FILE__` so evidence rows do not leak absolute build paths. (#1398)

## [0.190.8] - 2026-05-05

### Fixed
- `test/test_pipeline_deep.ml` orphan stanza rescue. `Hooks.turn_params` literal 한 곳에 누락된 `enable_thinking = None` 을 추가해 22 alcotest 케이스가 default runtest 신호에 합류. 같은 sprint-b orphan rescue 시리즈 (#1388/#1392/#1394) 의 일부. (#1394)

## [0.190.7] - 2026-05-05

### Fixed
- `test/test_discovery.ml` orphan stanza rescue. orphan 사유 "(record missing 'supports_tools')" 가 stale — `props` 레코드 literal 한 곳에 `supports_tools = None` 추가 후 8 alcotest 케이스 default runtest 신호에 합류. (#1392)

### Tests
- `test_event_bus.ml` 의 Custom event payload fixture 를 masc-specific `masc.keeper.lifecycle` 에서 downstream-neutral `downstream.agent.lifecycle` 로 교체. SDK 레이어 테스트가 특정 컨슈머 namespace 에 결합되는 것 방지. (#1393)

## [0.190.6] - 2026-05-05

### Fixed
- `Agent_sdk` top-level mli/ml 의 base 모듈 re-export 들을 `Agent_sdk_base.*` 로 명시 qualify. `agent_sdk.base` `wrapped: true` 전환 (#1385) 이후 `Agent_sdk.cmi` 가 global `Types`/`Error` 인터페이스를 import 하던 잔존 의존을 제거. ocamlobjinfo 기준 `Agent_sdk_base__Types`, `Agent_sdk_base__Error` 만 import 하도록 정리. (#1389)

## [0.190.5] - 2026-05-05

### Fixed
- `test/test_provider_config.ml` orphan stanza rescue. orphan 사유 "(record missing 'reasoning_tokens_estimated')" 가 stale 였음 — 필드는 `lib/llm_provider/types.mli:182` 에 이미 존재했고 다른 callsite 도 `; reasoning_tokens_estimated = false` 명시. `inference_telemetry` literal 한 곳만 누락되어 한 줄 추가 후 47 alcotest 케이스 다시 default runtest 신호에 합류. (#1388)

## [0.190.4] - 2026-05-05

### Added
- `Relay_delivery` 프리미티브: persist-then-publish 패턴을 위한 2-stage delivery state machine + retry queue + stats. `Runtime_health` probe 도 함께 노출. (#1383)

### Changed
- `agent_sdk.base` 라이브러리 `wrapped: true` 로 전환. `Agent_sdk` 가 `Agent_sdk_base` 전체를 `re_export` 하고 `Result_syntax` 를 포함한 모든 base 모듈을 top-level alias 로 노출. 직접 `agent_sdk.base` 의존하던 다운스트림은 `agent_sdk` 또는 qualified `Agent_sdk_base.*` 경로로 마이그레이션. (#1385)

### Build
- 신규 `.github/workflows/pr-automation.yml` Draft Auto-Merge Guard: human approval 라벨 없는 PR 의 auto-merge 활성화 + draft 해제를 자동 차단. labels REST 페이지네이션 사용, `allow-auto-merge` 빌트인 라벨은 명시적으로 bypass 후보에서 제외. (#1384, fixes #1278)

## [0.190.3] - 2026-05-05

### Fixed
- `Capability_manifest`: 성공한 매니페스트 로드를 `Diag.info` 로 승격해 운영자가 디버그 플래그 없이도 override 레이어 활성화를 확인할 수 있게 함. 잘못된 JSON 타입(예: bool 자리에 string)은 silent fallback 대신 `Diag.warn` 으로 보고. `member_int` 가 Yojson 의 `Intlit` 변형도 명시적으로 처리해 큰 정수 리터럴이 잘못된 "expected int, got int" 메시지로 무시되는 문제 해결. `Diag.with_sink` 의 mli 가 테스트/단일 스레드 부트스트랩 전용 의도를 명시. (#1381, fixes #1372)

## [0.190.2] - 2026-05-05

### Build
- `test/dune` 의 wired stanza 들이 `Transport.find_runtime` 호출 시 sandbox cwd 에서 `_build/default/bin/oas_runtime.exe` 를 못 찾는 문제 해결. 두 단계로 처리:
  - `.github/workflows/ci.yml`: Test/Coverage step 에 `OAS_RUNTIME_PATH=${{ github.workspace }}/_build/default/bin/oas_runtime.exe` 환경변수 export. Coverage step 의 `dune clean` 이후엔 `dune build bin/oas_runtime.exe` 도 추가. (#1377)
  - `test/dune`: 모든 wired `(tests ...)` 와 `test_complete_cascade` stanza 에 `(deps %{bin:oas-runtime})` + `(action (setenv OAS_RUNTIME_PATH %{bin:oas-runtime} (run %{test})))` 추가. self-contained 동작 — 로컬 `dune runtest` 도 더 이상 환경변수 의존성 없음. (#1378)
- 이전에 wired 안 돼 있던 100+ 테스트 모듈을 `test/dune` 에 그룹화 stanza 로 정식 wiring. 기존에 실수로 격리돼 있던 회귀 테스트들이 CI 의 default runtest 신호에 합류. compile-fail / pre-existing 실패 suite 는 헤더 코멘트로 명시 skip 처리. (#1374)

## [0.190.1] - 2026-05-05

### Fixed
- `Complete_cascade.complete_cascade` honors per-kind attempt-timeout defaults (`Provider_config.default_attempt_timeout_s`) so unbounded provider waits no longer stall a turn. `Some t` with `t <= 0.0` opts out of the cascade-level timeout for callers that need to keep long-running local-model calls (e.g. an Ollama instance loading a large MoE) running to completion. Error messages render the timeout via `%g` so short test budgets like `0.01s` are not truncated to `0.0s`. Fast-path regression test now asserts elapsed wall-clock time stays below 1.0s; a broken implementation that waited the full transport sleep would fail. (#1375)

## [0.190.0] - 2026-05-05

### Added
- `Guardrails_async.run_output_validators` now takes a per-validator deadline (default 5s) so a single hung validator no longer stalls the whole turn. Timeouts are reported as `Timeout` rather than swallowed. (#1368)
- `Guardrails.tool_filter` defaults tightened to `DenyList []` with an explicit cap, replacing the implicit allow-all that left tool exposure unbounded by default. Existing callers passing `Allow_all` are unaffected. (#1370)

### Changed
- `Agent_turn_budget` derives `current_max`, `extensions_count`, and `total_extended` from `history` instead of carrying parallel mutable fields. Eliminates the lock-step update invariant that previously could drift on partial-failure paths. (#1364)
- `Provider_config` exposes `request_path_default_for_kind` and `output_schema_of_response_format` helpers. `make` uses them, and direct record-literal callers can pin the same defaults via the helpers instead of duplicating the per-kind table. (#1366, #1367)
- `Agent_turn` `call_time_pruner` magic numbers (token thresholds, stage hooks) externalized to a typed `call_time_pruner_config` so consumers can override per-deployment without forking. (#1371)

### Security
- `Autonomy_diff_guard` normalizes input (Unicode NFC, whitespace, and quote folding) before substring matching so guard rules cannot be bypassed by trivially-encoded variants. Adds 100+ regression cases. (#1369)

## [0.189.1] - 2026-05-05

### Added
- Ollama dynamic capability discovery via `/api/show`: `Discovery` overlays Ollama-reported tool/multimodal/JSON capabilities on top of the static capability table when probing Ollama endpoints. Pure capability merge with no new public API. (#1362)

### Fixed
- DashScope structured output now goes through `validate_output_schema_request` correctly. The validator previously gated only on `config.output_schema`, allowing callers to construct a `Provider_config.t` with `response_format = JsonSchema _` and `output_schema = None` and silently bypass GLM/DashScope tightening. The new helper `structured_schema_requested` treats either field as a native-schema request. (#1360)

### Tests
- Added `prefix_ordering` regression suite for `Capabilities.for_model_id`: every shadow pair (longer prefix shadowed by an earlier shorter prefix) is asserted to resolve to the more-specific branch. Anti-pattern M01: silent capability mismatch when prefixes are reordered. (#1361)

## [0.189.0] - 2026-05-05

### Added
- `Capability_manifest` module: explicitly loaded external JSON manifest for runtime model capability overrides. Supports prefix-matching, schema-version gating, and per-model boolean/int overrides for tool-use, structured-output, multimodal, sampling, and reasoning capabilities. (#1347)
- `Pricing.pricing_entry` type and dynamic pricing override API:
  `install_pricing_overrides`, `clear_pricing_overrides`,
  `pricing_entry_of_json`, `parse_pricing_entries_json`,
  `load_pricing_file`, `pricing_overrides_from_env`.
  Set `OAS_PRICING_FILE` (path to a JSON array file) or
  `OAS_PRICING_OVERRIDES` (inline JSON) to override per-model pricing
  at runtime without a code release.  A `Diag.warn` fires once per
  process when installed overrides are older than 24 h (H11).

### Fixed
- SSE streaming parse failures and unknown event types are now surfaced via the new `SSEParseFailed` and `SSEUnknownEventType` events, both in `Llm_provider.Streaming.parse_sse_event` and the public `Agent_sdk.Streaming` accumulator. Previously the wildcard catch-all silently dropped malformed/unknown chunks, producing phantom completions when the cascade layer expected provider failover. (#1357)

## [0.188.1] - 2026-05-05

### Changed
- Removed unused Jane Street `base` package from opam/dune-project dependency lists. No `open Base` or `Base.<Module>` usage existed in `lib/`, `bin/`, or `test/`; the local `agent_sdk.base` sub-library is unrelated. (#1349)

### Tests
- Added regression coverage for capability-gated serializer paths in `Backend_ollama` and `Backend_openai`: `top_k` inclusion under default capabilities, `seed` capability gate, and Ollama `done_reason=tool_calls` / thinking-block parsing. (#1356)

### Docs
- Archived `RFC-OAS-006-weighted-cascade-routing` and the `CascadeFSM*` TLA+ specs to `docs/archive/2026-04/`. Aligned `RFC-tool-selector` Section 6.3 wording with the post-0.144.0 single-provider implementation. Removed dead `Cascade_config` test sections from `test_llm_provider_cov.ml` (-235 LOC) and `test_backend_gemini.ml` (-22 LOC). (#1350)

## [0.188.0] - 2026-05-05

### Added
- Provider cascade routing with cross-provider failover and circuit breaking (`Complete_cascade`).
- `agent_sdk.base` sub-library extraction: Types, Error, Context, Tool, Model_registry, Completion_contract_id, Result_syntax.
- `ppx_let` support via `Result_syntax.Let_syntax` module (`let%bind`, `let%map`, `and%bind`).
- LLM provider metrics module (`Metrics`) for request/response/latency tracking.
- Dynamic prompt cache alignment and context budget compaction.
- MCP CLI provider integration with Ollama dynamic capabilities.
- GLM-5-Code models and Kimi CLI model restrictions.

### Changed
- `artifact_service.ml` migrated to `let%bind`/`Let_syntax.return` style.

## [0.187.7] - 2026-05-02

### Added
- Execution Manifest with `provider_health`, `rate_limit_quota`, and Risk_class cascade mappings.

## [0.187.6] - 2026-05-01

### Fixed

- Align generated opam package metadata and runtime SDK version with the current dune project version.

## [0.187.4] - 2026-04-30

### Fixed

- Format the memory query follow-up so the CI format gate remains green after the memory prefix query merge.

## [0.187.3] - 2026-04-30

### Added

- Collaboration substrate priority/quota contract, including typed request priority and quota attribution helpers.
- Collaboration performance budget contract for downstream multi-agent UI scheduling and coalescing expectations.

## [0.187.2] - 2026-04-30

### Changed

- Version bump with opam package metadata truth synced after the v0.187.1 release cut.

## [0.187.1] - 2026-04-30

### Changed

- Version bump only (post-CI gate merge).

## [0.187.0] - 2026-04-30

### Added

- **Runtime sync/replay window contract** exposes `Agent_sdk.Runtime_sync` with stream cursors, replay window metadata, persistence capability metadata, append-only offline merge helpers, cursor-based delta filtering, schema `docs/schemas/runtime-sync-window-v1.json`, and focused coverage for downstream offline/online sync integrations.

## [0.186.0] - 2026-04-30

### Added

- **Typed provider failure transport surface** via `Llm_provider.Http_client.ProviderFailure`, covering capacity exhaustion, hard quota, capability mismatch, CLI policy invalid, CLI startup failure, provider parse failure, and unknown provider failure.
- **Runtime collaboration projection contract** adds generic presence, activity, and system-health event types plus `Runtime_projection.collaboration_events_of_event` for downstream multi-agent UIs. Presence is explicitly ephemeral and 30Hz-coalesced; no persisted collaboration runtime event kind is introduced.

### Changed

- **Gemini CLI capacity and policy failures now classify at the transport edge** instead of surfacing as `NetworkError Unknown`. `MODEL_CAPACITY_EXHAUSTED` maps to `Capacity_exhausted`, request-scoped runtime MCP rejection maps to `Capability_mismatch`, and Gemini policy warnings such as `Unrecognized tool name "glm"` map to `Cli_policy_invalid`.

## [0.185.0] - 2026-04-30

### Added

- **DeepSeek v4 provider inventory entries** for `deepseek-v4-flash` and `deepseek-v4-pro`, including model registry aliases and provider config coverage for downstream cascade routing.

### Fixed

- **Kimi CLI large-prompt handling** now routes large prompts through stdin instead of argv so OS argument length limits do not truncate or reject long requests.
- **Transport drift gate parsing** handles the split ocamlformat configuration shape used by the current tree.

### Changed

- **Test stanza layout** in `test/dune` now uses grouped `(tests ...)` stanzas for auto-discovery while preserving the same test executables and CI coverage.

## [0.184.0] - 2026-04-28

### Fixed

- **SSE keepalive comments no longer reset `stream_idle_timeout`** in `Llm_provider.Http_client.read_sse`. Per the W3C EventSource spec, lines starting with `:` are comments / keepalives and carry no event payload. Previously these lines reset the `Eio.Time.with_timeout_exn` deadline like any other line, so a provider that emitted only keepalives without ever sending `event:` / `data:` lines would never trip the idle timeout — the entire stream had to wait for the upstream consumer's hard cap (downstream observed: keeper turn-level 3600s wall-clock). Now keepalive skipping happens inside the same timeout window, preserving the deadline across an arbitrary number of keepalives. `read_ndjson` is unaffected (NDJSON has no comment concept). Public API surface unchanged; semantic of the existing `?idle_timeout` parameter is now "inter-event idle" instead of "inter-line idle". Companion regression test: `test/test_streaming_keepalive_idle.ml`.

## [0.183.0] - 2026-04-28

### Changed

- **Removed `lib/str_match.{ml,mli}` thin wrapper (#1221 via #1223).** The 4-line `Str.search_forward` wrapper was used at 6 call sites across 4 files (`approval.ml`, `harness.ml`, `hooks.ml`, `orchestrator.ml`). Folded the helper into `Util.regex_match` where the rest of the shared substring/regex utilities live. No behavioral change — the compiled `Str.search_forward` body is identical.

### Added

- **`Util.regex_match : Str.regexp -> string -> bool`.** Boolean wrapper around `Str.search_forward` that returns `false` instead of raising `Not_found`. Exposed alongside the existing `safe_sub`, `contains_substring_ci`, and `clip` helpers.

## [0.182.0] - 2026-04-28

### Added

- **`Provider_config.internal_model_rotation_count` hint (#1211).** Threaded through provider config so cascade/orchestrator layers can observe how many internal rotations a provider has performed. Read-only hint; default is 0.

### Changed

- **Removed `lib/retry.{ml,mli}` and `lib/sse_parser.{ml,mli}` thin re-export shims (#1220 via #1225).** Both files were 1-line `include Llm_provider.X` wrappers. Public surface is preserved through explicit `module Retry = Llm_provider.Retry` (and `Sse_parser`) in `lib/agent_sdk.{ml,mli}`, so external `Agent_sdk.Retry.X` access is unchanged. Internal lib/ consumers now alias `Llm_provider.Retry` per file; affected test stanzas in `test/dune` gained `llm_provider` as a `(libraries ...)` dep.

### Tests

- **Eio HTTP body cancellation regression guard (#1210).** Pins the cancellation-propagation contract for `Llm_provider.Http_client` so future edits cannot silently drop body-read interruption.
- **Register orphan `test_tool_set` with QCheck deps (#1179, via #1224).** Closes the last orphan from the #1025 series; cold-cache `dune build @check` no longer fails on `Unbound module QCheck` for `test/test_tool_set.ml`.

### Docs

- **CLAUDE.md / CONTRIBUTING.md SSOT alignment (#1215, #1216, #1217, #1218 via #1222).** Bumps the AI-assistant reference from a hardcoded `v0.149.0` to the SSOT (`lib/sdk_version.ml`), corrects the `CONTRIBUTING.md` version-source pointer (`agent_sdk.ml` → `sdk_version.ml`), and expands the Provider Support table to list `backend_anthropic`, `backend_openai`, `backend_gemini`, `backend_glm`, `backend_ollama` as the actual concrete backends.

### Closed (no code change)

- **#1219 — `Proof_store` public Read API.** Verified resolved by masc-mcp PR #11512: `proof_artifact_reader.ml` now delegates to `Oas.Proof_store.{resolve_ref, make_ref, read_json}` instead of hardcoding the OAS internal layout. The OAS-side Read API was already sufficient.

## [0.181.0] - 2026-04-27

### Added

- **`Agent.options.body_timeout_s` (`float option`).** Caps total HTTP body consumption time, distinct from `stream_idle_timeout_s` which only resets between successful lines and so cannot interrupt a single bulk read. On expiry the result is `Error (NetworkError { kind = Timeout; _ })` with a message that names the configured deadline and the `Builder.with_body_timeout` setter, so cascade/retry treats it as retryable while operators retain attribution. Requires `clock`; without one the wrapper is skipped and behaviour matches `<= 0.180.0`. Threaded through `Builder`, `Pipeline.stage_route`, and `Llm_provider.Complete.complete_stream` / `complete_stream_http`.
- `Builder.with_body_timeout : float -> t -> t` setter.
- Unit tests (`test/test_body_timeout.ml`) pin the message-prefix contract so future edits cannot silently downgrade body-deadline expiry to `kind = Unknown`.

## [0.180.0] - 2026-04-27

### Changed

- **`Provider_registry`: rename `alibaba_defaults` → `dashscope_defaults`.** Canonical name follows the `DashScope` provider kind introduced in 0.178.0. The `alibaba` registry entry remains as alias for backward compatibility, both pointing to the same defaults.

### Added

- Test coverage for `dashscope` registry lookup (max_context 131K, dashscope_capabilities).

## [0.179.0] - 2026-04-27

### Added

- **`Event_bus.payload_kind` SSOT helper.** Adds `payload_kind : payload -> string` so downstream consumers can categorize events by kind without maintaining exhaustive match sites that break on variant addition.

## [0.178.0] - 2026-04-26

### Added

- **DashScope native provider support.** Adds a first-class `DashScope` provider kind to correctly expose `supports_tool_choice=true` and `supports_min_p=true` for Qwen models, bypassing the conservative `Ollama` defaults.

## [0.177.0] - 2026-04-25

### Fixed

- **`claude_code` provider cost recovery.** `pricing_for_model_opt`
  now matches the `claude_code` and `cc:` aliases that the Claude
  Code transport surfaces in `telemetry.model_used` instead of a
  canonical model id, estimating at sonnet-4-6 rates as the modal
  Anthropic backend. Restores `cost_usd` reporting for every
  `claude_code` keeper turn (previously null because substring
  matches against opus/sonnet/haiku never fired). Per-call accuracy
  via canonical model resolution from the API response remains a
  follow-up.

## [0.176.0] - 2026-04-25

### Added

- **Agent-level stream idle timeout control.** `Agent.options` and
  `Builder.t` now expose `stream_idle_timeout_s`, with
  `Builder.with_stream_idle_timeout` for callers that need bounded
  streaming turns. `Pipeline_stage_route.dispatch_stream` forwards the
  value into `Complete.complete_stream`, so downstream consumers can opt
  into retryable idle timeout failures across HTTP SSE, Ollama NDJSON,
  and CLI subprocess streaming paths.

## [0.175.0] - 2026-04-25

### Added

- **HTTP SSE stream idle timeout parity.** `Complete.complete_stream`
  now applies `stream_idle_timeout_s` to every HTTP streaming path,
  including Anthropic, OpenAI-compatible, Gemini, GLM, and Ollama native
  NDJSON streams. The timeout remains caller-owned and surfaces stalled
  endpoints as retryable timeout-shaped network errors.
- **CLI subprocess stdout idle timeout.** Shared non-interactive CLI
  subprocess execution now accepts `?clock` and
  `?stdout_idle_timeout_s`, so silent CLI hangs can be interrupted
  without imposing a total runtime cap.

### Fixed

- **Pipeline retry honors effective tool contract.** Missing-required-tool retry
  now consults the resolved completion contract (post provider-capability
  resolution) instead of the originally requested contract. Providers that
  intentionally relax unsupported tool requirements no longer enter forced
  retry loops.
- **Per-response usage is preserved.** Ollama and CLI transports keep
  usage on each returned response instead of letting aggregate turn
  accounting overwrite or drop the provider payload.
- **Runtime participant events preserve raw trace run ids.** Runtime
  participant lifecycle events now carry `raw_trace_run_id` through to
  the top-level EventBus `run_id`, keeping generic trace correlation
  intact for downstream consumers.
- **Provider pricing entries refreshed again.** Added pricing for
  `gpt-5.5` alongside the existing current OpenAI model table refresh.

## [0.173.0] - 2026-04-25

### Added

- **Bounded Ollama NDJSON streams.** `Complete.complete_stream` and
  `Http_client.read_ndjson` now accept optional `?clock` and
  `?stream_idle_timeout_s`. When set, each NDJSON line read is wrapped in
  `Eio.Time.with_timeout_exn`; a stalled stream raises `Eio.Time.Timeout`,
  which `catch_network` already maps to a retryable `NetworkError`. No new
  error surface, no default injected at the SDK layer — callers decide the
  idle budget.

### Fixed

- **Provider pricing entries refreshed.** Added pricing for current
  `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex`, and `gpt-5.2` from the
  official OpenAI rate cards. `gpt-5.3-codex-spark` left unpriced because
  the Codex rate card marks research-preview pricing as non-final.
- **Streamed `response.model` no longer blank.** When a provider omits
  `model` from the streamed final chunk, `patch_telemetry` now fills it
  from the configured `model_id` so downstream consumers receive a stable
  identifier.

## [0.172.0] - 2026-04-24

### Added

- **Native NDJSON streaming for Ollama.** `Complete.complete_stream_http`
  Ollama branch now speaks the native `/api/chat` endpoint and parses the
  newline-delimited JSON wire format directly, replacing the prior detour
  through Backend_openai's SSE shape. Adds `Http_client.read_ndjson`,
  `Streaming.parse_ollama_ndjson_chunk`, and
  `Streaming.ollama_chunk_to_events` as new public exports.
- **Restored Ollama timing telemetry.** Streaming responses now carry
  `prompt_eval_count`, `prompt_eval_duration`, `eval_count`, and
  `eval_duration` — the four Ollama-only fields the OpenAI compat detour
  was stripping. Token-count usage and `inference_timings` on streaming
  responses are byte-identical to the non-streaming path
  (masc-mcp #8968 / #8969).

## [0.171.0] - 2026-04-24

### Added

- **Strict required-tool satisfaction hooks.** Completion contracts can now
  validate required tool calls with a caller-supplied typed predicate, so
  read-only/observability tools no longer have to count as productive action
  at runtime boundaries.

## [0.170.9] - 2026-04-24

### Added

- **Truth-layer evidence primitives.** `Event_envelope`, `Effect_evidence`, and
  `Runtime_health` provide cross-runtime event causality, tool-effect decision
  evidence, and runtime health snapshot shapes. `Mode_enforcer` now records
  effect evidence for every pre-tool decision, and `Proof_capture` persists
  those rows under `evidence/effects.json` for downstream proof consumers
  (#1158).
- **`Capabilities.emits_usage_tokens` + `capabilities_for_provider_label`.**
  `Llm_provider.Capabilities.capabilities` gains an
  `emits_usage_tokens : bool` field (default `true`) that captures whether
  a provider's standard response carries `input_tokens`/`output_tokens`.
  CLI-class wrappers that strip usage before returning (`codex_cli`,
  `gemini_cli`, `kimi_cli`) declare it `false`; all direct APIs keep the
  default. A companion `capabilities_for_provider_label : string ->
  capabilities option` lookup and a matching
  `Capability_filter.emits_usage_tokens` predicate let adapters that
  track provider kind as a string query this flag without reinventing
  a provider allowlist. Downstream metrics/coverage layers (e.g.
  masc-mcp `Provider_adapter.is_structurally_unmetered_provider`) can
  now consume the SDK directly as the SSOT (#1173).

### Fixed

- **Split pipeline stages now build messages through the shared constructor.** The post-split `stage_input`, `stage_collect`, and `stage_execute` paths now use `make_message` instead of stale record literals, so newly required fields such as `metadata` stay aligned with the shared message shape and downstream pipeline builds stop breaking after the stage split (#1151).
- **Kimi CLI session reuse now matches the actual CLI contract.** `transport_kimi_cli` now passes config files via `--config-file`, keeps `--session <id>` stable across turns, and stops assuming `--continue` is valid with an explicit session id. This preserves the intended token-saving delta prompt behavior for keeper-style multi-turn sessions without relying on a CLI flag combination that `kimi` rejects.

## [0.170.8] - 2026-04-24

### Fixed

- **`scripts/release.sh` now refuses to tag from anywhere other than
  a main branch synced with `origin/main`.** Previously the script
  ran `git tag -a` against the current `HEAD`, so running it from a
  feature branch (or before the release PR was merged) left the tag
  on a release-cut commit whose SHA was rewritten by GitHub's PR
  rebase merge. The tag then pointed to a commit no longer reachable
  from main, which broke release-provenance audits and every
  downstream consumer that pinned by SHA-equivalent. The script now
  fails fast when `git rev-parse --abbrev-ref HEAD` is not the
  integration branch or when local HEAD differs from `origin/main`,
  with the remediation printed inline (#1136, #1135, #1168).

## [0.170.7] - 2026-04-24

### Fixed

- **Atomic file writes no longer race on a shared tmp path.** Previously
  both `Fs_result.write_file` (blocking path) and the `Eio.Path` callers
  in `Checkpoint_store.save`, `A2a_task_store.store_task`,
  `Memory_file_backend.persist`, and `Durable_event.save_to_file` derived
  the tmp name from the target (`<path>.tmp`). Two fibers writing to the
  same logical file could therefore race, with writer A's `rename`
  consuming the shared tmp before writer B's `rename` ran, surfacing as
  `Eio.Io Fs Not_found (renameat …)`. A new `Fs_atomic_eio.save_atomic`
  helper gives every writer a unique tmp suffix (pid + wall-clock ns +
  `Atomic` counter) and best-effort fsyncs the tmp file and parent
  directory; the five call sites now delegate to this helper (or the
  unified `Fs_result.write_file`). `A2a_task_store.store_task` only
  updates its in-memory cache on `Ok`, so cache and disk can no longer
  drift when the atomic write fails after flush (#1165).

### Notes

- **Race test skipped under `BISECT_ENABLE=yes`.** `test_atomic_write_race`
  is gated off when the Coverage report job re-runs the suite with bisect
  instrumentation, because the extra io_uring submissions from bisect hooks
  blow the CI container's memlock budget and cause unrelated downstream
  tests to fail with `Unix_error(ENOMEM, "io_uring_queue_init")`. The
  happy-path line coverage of `Fs_atomic_eio.save_atomic` is retained
  indirectly via the existing `test_checkpoint_store`,
  `test_a2a_task_store`, and `test_memory_file_backend` suites (#1165).

## [0.170.6] - 2026-04-24

### Changed

- **SDK independence boundary now enforced in CI.** The `SDK Independence
  Gate` job rejects PRs that reintroduce cross-SDK imports, keeping
  `agent_sdk` consumable without pulling downstream-specific modules
  (#1160).

## [0.170.5] - 2026-04-24

### Added

- **Truth-layer evidence primitives.** New types and helpers for
  recording evidence alongside LLM outputs so callers can persist
  rationale and citations without bespoke serialisers (#1158).

### Fixed

- **KIMI direct API aligned with `KIMI_API_KEY` only.** The provider
  previously fell back across several env var candidates, so setting
  the wrong one silently routed traffic to the default key. Routing is
  now keyed exclusively on `KIMI_API_KEY` (#1159).
- **kimi CLI session reuse matched to actual CLI contract.** Session
  IDs are threaded through follow-up turns instead of being dropped
  after the first turn (#1157).
- **HTTP MCP reconnect state preserved across transport restarts** —
  the client no longer loses its resume token when the underlying
  socket is replaced (#1156).

## [0.170.4] - 2026-04-23

### Fixed

- **`llm_provider` parses usage fields from kimi-cli JSONL output.**
  Token counts now surface on KIMI CLI responses; previously
  `prompt_tokens` and `completion_tokens` were dropped (#1155).

### Changed

- **MCP fixture names genericised in transport tests** so new
  providers can reuse the harness without name collisions (#1154).

## [0.170.3] - 2026-04-22

### Added

- **Native timeout handling for `Agent.run`.** Uses Eio's clock
  primitives instead of callback-based workarounds, so timeouts
  compose with the surrounding switch (#1006, #1150).
- **Structured replay metadata in checkpoints.** Replay flows persist
  a typed payload instead of free-form strings, enabling downstream
  tooling to reason about replay provenance (#1149).
- **Structured `network_error_kind` on `NetworkError`.** The
  `llm_provider` error surface classifies transport failures
  (DNS / connect / read / idle) so callers can pick a retry policy
  without string-matching error messages (#1147).

### Fixed

- **HTTP client drains response body to prevent CLOSE\_WAIT
  accumulation.** Long-lived cascades had been leaking sockets into
  CLOSE\_WAIT, eventually exhausting the local port pool (#965,
  #1148).
- **Pipeline message constructor drift resolved** — stages no longer
  produce messages that downstream stages cannot decode after the
  6-stage split (#1151).

### Changed

- **Pipeline split by stage (prepare / route / retry).** `pipeline.ml`
  was broken up along the three stages that were already documented in
  the architecture notes, reducing module size and clarifying
  responsibilities (#1146, #1152).

## [0.170.2] - 2026-04-22

### Fixed

- **Raw trace generation now flushes gracefully on timeout.** When the
  surrounding operation cancelled, the trace backend used to lose its
  in-flight buffer because shutdown raced with cancellation; a typed
  flush hook now drains before the backend tears down (#1141).

## [0.170.1] - 2026-04-22

### Added

- **`NotFound` variant on `api_error` for HTTP 404.** Callers can now
  distinguish 404 from generic HTTP failures without string-matching
  the status code inside error messages (#1139).

### Changed

- **`Otel_tracer` span records made immutable** so they are safe to
  share across Eio fibers without an owning-fiber lock (#1138).

### Fixed

- **Streamed telemetry populated via non-HTTP transports.** Previously
  only HTTP-backed streams emitted telemetry; CLI and in-process
  transports now produce the same span shape (#1140).

## [0.170.0] - 2026-04-21

### Added

- **Tiered recall prompt assembly and budgeting.** Agents can now carry optional typed `tiered_memory = { long_term; mid_term; short_term }` through `Agent.options` and `Builder.with_tiered_memory`. Turn preparation renders a pinned synthetic User recall block after leading system messages, keeps a fixed `LONG -> MID -> SHORT` order, and omits blank tiers (#1133).

### Changed

- **Context reduction and compaction now account for pinned recall tokens.** Reducers reserve the recall token budget before trimming raw history, and proactive/emergency compaction watermarks are computed from `raw history + recall` while only stored raw messages are compacted (#1133).

### Notes

- **Registry coverage now fails loudly when `Provider_kind` and the provider registry drift.** Added a dedicated regression test asserting every `Provider_kind` resolves to a registered entry, closing a silent coverage gap in the provider registry surface (#1132).

## [0.169.0] - 2026-04-21

### Added

- **Typed `Provider_kind` sum type, hoisted to its own module.** `Llm_provider.Provider_kind.t` now lives in a standalone compilation unit (`lib/llm_provider/provider_kind.ml`) so it can be shared by records in `Types` without creating a dependency cycle with `Provider_config`. `Provider_config` re-exports the type via manifest rebinding (`type provider_kind = Provider_kind.t = | Anthropic | ... | Kimi | ...`) so every existing `Provider_config.Anthropic` / `Provider_config.string_of_provider_kind` caller keeps compiling unchanged (#1122).

- **`Provider_kind.of_string` canonical parser.** Accepts the canonical lowercase forms emitted by `to_string` plus the documented legacy aliases (`claude → Anthropic`, `openai → OpenAI_compat`, `llama → Ollama`). Case-insensitive; leading/trailing whitespace trimmed. Returns `None` for unknown inputs so callers fail fast instead of silently defaulting to a wrong provider (#1122).

- **Hand-written `Provider_kind.pp` / `show` / `to_yojson` / `of_yojson`.** Preserve the existing lowercase wire format (`"anthropic"`, not `"Anthropic"`) so records embedding the variant (`Types.inference_telemetry.provider_kind`) can use derived yojson without breaking on-disk or over-the-wire payloads (#1122).

- **`Provider_kind.all : t list` and `Provider_kind.default_api_key_env : t -> string option`** (re-exported as `Provider_config.all_provider_kinds` and `Provider_config.default_api_key_env`). `all` is the canonical enumeration used by tests, CLI completion, and future QCheck generators; `default_api_key_env` centralizes the per-kind env-var convention (`Anthropic → Some "ANTHROPIC_API_KEY"`, …). `Provider.default_api_key_env_of_kind` now delegates through the sum type (#1126).

- **Kimi Code provider support.** Added `Kimi` (direct Anthropic-compatible `/v1/messages`) and `Kimi_cli` (subprocess transport via `kimi --print`) variants plus their transports, capabilities, and registry entries (#1125).

### Changed

- **`Types.inference_telemetry.provider_kind` is now `Provider_kind.t option`** (was `string option`). Wire format unchanged — the derived yojson transits through the hand-written `Provider_kind.{to,of}_yojson` so every record serializes the same lowercase strings (`"ollama"`, `"anthropic"`, `"openai_compat"`, …). Existing readers that pattern-matched on the string literal (`Some "ollama"`) move to constructors (`Some Provider_config.Ollama`) at the two callsites in `Complete.complete_cascade` (#1122).

- **`agent_config.resolve_provider` now dispatches on `Provider_kind.of_string`** instead of an ad-hoc `match provider_str with | "anthropic" | ... | _ -> ...` ladder. Closes three drift bugs reported in the tick-6 audit: the SDK-emitted `"openai_compat"` string now resolves to OpenAICompat (was dropping to a broken registry fallback), the documented `"claude"` alias routes to Anthropic, and parsing is case-insensitive (#1123).

- **`Provider_bridge.resolve_auto_model_id` takes `Provider_kind.t` directly**, not a stringified `provider_name`. Removes the dead `"openai"` / `"openrouter"` branches (unreachable from the prior stringify path) and makes future variant additions fail loudly in the compiler rather than silently falling into a wildcard (#1124).

### Notes

- Tests: 44/44 in `test_provider_config` (+13 over 0.164.0 covering parser, serializers, enumeration, and wire-format regressions), 31+4 in the newly-registered `test_agent_config_deep` (was silently unregistered in `test/dune` before #1123), full `@test/runtest` green.

## [0.164.0] - 2026-04-21

### Fixed

- **Codex CLI transport honors request model IDs.** `transport_codex_cli` now passes a non-empty, non-`auto` `Provider_config.model_id` through `codex exec --model`, matching Claude Code and Gemini CLI behavior while preserving `auto` as "use the user's CLI default".
- **ApprovalRequired fallback no longer emits an operator-facing WARN without a callback.** The existing fail-open behavior is unchanged, but `agent_tools` now records the fallback at debug level so consumers do not see an unactionable warning on every approval-less tool execution.

### Added

- **`Hooks.on_idle_escalated` adds runtime-computed idle severity.** Callers can opt into a structured idle hook carrying `nudge` / `final_warning` / `skip` severity while keeping the legacy `on_idle` path for compatibility. `skip_at` reuses `max_idle_turns`; `final_at` is configurable per agent via `idle_final_warning_at`.
- **Tool error retry classification now honors explicit runtime error classes.** `Types.tool_error` carries an optional typed `error_class`, and `Tool_retry_policy.decide` now prefers that explicit classification over legacy `failure_kind` inference. Recoverable errors marked `Deterministic` no longer blind-retry.

### Changed

- **`response_format` now uses a typed variant surface** for agent config, builders, provider config, and checkpoints: `Off | JsonMode | JsonSchema of Yojson.Safe.t` (issue #957). `Builder.with_response_format_json`, `Provider_config.make ?response_format_json`, and checkpoint decoding of legacy `response_format_json: bool` remain as compatibility shims. In this step, provider request builders honor `JsonMode`; `JsonSchema _` is preserved through config/persistence but not yet emitted as provider-native schema parameters.

- **Completion contract violations now carry typed contract IDs.** `Error.CompletionContractViolation.contract` now uses `Completion_contract_id.t` instead of `string`. `Agent_sdk.Completion_contract` and `Agent_sdk.Completion_contract_id` are re-exported; downstream code that serialized the old string field should switch to `Completion_contract_id.to_string`.

### Notes

- **Version boundary realigned for downstream pins.** `main` now advertises `0.164.0` so post-`0.163.0` public API growth no longer masquerades as the earlier `0.163.0` floor used by downstream SHA pins and compatibility checks.

## [0.163.0] - 2026-04-20

### Added

- **`Hooks.Nudge` accepted from `before_turn`.** Previously only `OnIdle` could return `Nudge`; `before_turn` returning `Nudge` was silently dropped by the pipeline (`stage_input` only handled `ElicitInput`). The decision matrix and `legal_decisions_for_stage` now list `K_Nudge` for `before_turn`, and `pipeline.ml stage_input` appends the nudge text as a User-role message before tool preparation so it reaches the model in the same turn. Mirrors the `on_idle` Nudge handler at `pipeline.ml:392`. Generic primitive — payload is opaque text, no domain knowledge in OAS.

## [0.162.0] - 2026-04-19

### Added

- **`Event_bus` envelopes carry `caused_by`.** `envelope.caused_by : string option` links every event back to the originating run. Three emitters wire it through: `orchestrator` (`AgentStarted` → `AgentCompleted`/`AgentFailed`, PR #1019), `agent` handoff (`HandoffRequested` → `HandoffCompleted`, PR #1020), `agent_tools` (`ToolCalled` → `ToolCompleted`, PR #1021). Enables causation tracing across a single run without re-parsing agent logs.
- **`Tool_retry_policy.error_class` variant** (PR #1027). Contract-first typed classification of tool errors drives retry decisions; replaces string-based pattern matching at callsites.
- **`Agent_turn.idle_granularity` opt-in variant** (PR #1024). Fine-grained `is_idle` reporting for callers that need sub-turn idle signals without changing the default coarse-grained behavior.
- **Inference profile exposes `top_p` / `top_k` / `min_p`** (PR #1015). Constants-layer extension so cascade configs can pin sampling parameters without provider-specific escapes.

### Fixed

- **CLI transports disable MCP by default in headless mode** (PR #999). `transport_claude_code` / `transport_codex_cli` / `transport_gemini_cli` stop inheriting user MCP config for non-interactive invocations unless explicitly opted in via `OAS_*_ALLOWED_MCP`. Eliminates the "connection refused to dead MCP port" noise observed in keeper logs.
- **`Hooks.OnToolError` emitted on tool execution failure** (PR #1031). Prior behavior left callers relying on `stop_reason` heuristics; now the failure path fires a dedicated hook with the error payload.
- **`Hooks.OnError` emitted on tool-not-found dispatch failure** (PR #1035 — deferred, see PR description).
- **`llm_provider` honors `~cwd` at the OS level** via `env -C <dir>` prefix (PR #1016). Earlier implementation relied on the CLI's own `--cwd` flag, which was inconsistent across providers and silently dropped by some wrappers.

### Changed

- **`LLM_ENDPOINTS` parsing unified** via `Discovery.parse_llm_endpoints_env` (PR #1014). Transports and discovery now share a single comma-split + trim routine.

### Chore

- **Test registry cleanup.** Six orphan tests wired into `test/dune` — `test_agent_config` (#1030), `test_agent_turn_budget_unit` (#1026), `test_agent_tool` (#1033), `test_agent_typed` (#1034), `test_agent_pipeline` (#1036), `test_agent_lifecycle` (#1037). No behavior change; tests were previously not run.

## [0.161.0] - 2026-04-19

### Fixed

- **`transport_gemini_cli.build_args` no longer emits `--system-prompt`.** Gemini CLI (>=0.38) rejects the flag with `Unknown arguments: system-prompt` and the subprocess exits with code 1, so any cascade member using `gemini_cli:auto` with a system prompt was failing every turn. System text is now folded into the `-p` argument as labelled `[System]` / `[User]` blocks via the new `effective_prompt` helper, which keeps the role distinction without requiring a CLI flag. `None` / empty system prompts pass through unchanged, so the argv for prompt-only callers is byte-identical to pre-0.161.0.

## [0.160.1] - 2026-04-18

### Fixed

- **Completion contract no longer rejects no-ToolUse responses when the model was cut off mid-turn.** `completion_contract.validate_response` now treats `stop_reason = MaxTokens` or `Unknown "pause_turn"` as resumable for `Require_tool_use` / `Require_specific_tool`, so callers can continue the turn (or raise `max_tokens`) instead of seeing a spurious `CompletionContractViolation`. Observed on Anthropic Haiku 4.5 where extended thinking consumes the 8192-token output budget before a ToolUse block emits and the API returns `pause_turn`. `EndTurn`, `StopToolUse`, `StopSequence`, and unknown reasons other than `pause_turn` continue to reject no-ToolUse responses (PR #1001).

## [0.160.0] - 2026-04-18

### Added

- **Event bus backpressure policy + stats + purpose labels** (PR #998).

## [0.159.0] - 2026-04-18

### Added

- **Historical env-driven CLI flag experiment.** Non-interactive CLI transports briefly accepted transport-specific env aliases at `build_args` time. Those aliases are retired; current callers should use explicit transport config records and current provider/model env keys.
- `lib/llm_provider/cli_common_env.{ml,mli}` centralises env parsing (`get`, `bool`, `list`, `kv_pairs`) so the three transports agree on truthy values and splitting rules.

### Notes

- Gemini CLI has no runtime flag to disable hooks — hook lifecycle remains governed by the `gemini hooks` subcommand, outside transport scope.
- Codex CLI exposes no dedicated `--no-mcp` / `--no-hooks` flags; every toggle there flows through `-c key=value` TOML overrides.

## [0.157.1] - 2026-04-18

### Fixed

- **TLS EOFs now stay on the retryable network-error path.** `llm_provider/http_client.ml` now maps `End_of_file` and `Sys_error` into `NetworkError`, so transient peer-close / socket-teardown failures no longer escape as top-level worker exceptions and instead flow through the existing retry/cascade logic (PR #995).
- **OpenAI-compatible sampling defaults now respect model capability records.** `apply_sampling_defaults` no longer auto-injects `min_p=0.05` for Gemini/GLM-style OpenAI-compatible models that advertise `supports_min_p = false`, which removes the warn-and-drop path while preserving the existing default for Qwen-class and unknown localhost endpoints.

## [0.155.1] - 2026-04-17

### Changed

- **OAS telemetry now stays inside the OAS boundary.** Provider fallback observability was removed from the public metrics/Event_bus surface so OAS remains a single-provider runtime and orchestration policy stays outside the SDK.
- **Runtime telemetry preserves raw-trace linkage and anomaly detail structurally.** Runtime participant events now carry `raw_trace_run_id`, `stop_reason`, `completion_anomaly`, and `failure_cause`, and sessions publish a `runtime-raw-trace-json` artifact so external consumers can correlate runtime state with raw traces without reverse-parsing free-form strings.

## [0.154.0] - 2026-04-17

### Added

- **`Content_replacement_event_bridge`.** Observer-only wrappers around `Content_replacement_state.record_replacement` / `record_kept` that publish `Custom("content_replacement_frozen", ...)` after successful state mutation, with an explicit `action` discriminator and `seen_count_after` payload (PR #982).
- **`Hooks.PostCompact` + `hooks.post_compact`.** Observer-only post-compaction lifecycle surface fired after successful proactive and emergency compaction, preserving the existing Event_bus behavior while exposing the reduced message set to hook consumers (PR #985).

### Fixed

- **Direct API dispatch now patches latency telemetry.** `Api.create_message` measures wall-clock request time on the non-cascade path and overwrites the parser-layer `request_latency_ms = 0` sentinel, so responses created through `Pipeline.stage_route -> Api.create_message` report real latency instead of zeros (PR #972).

### Removed (operator-facing)

- **`oas-review` CLI binary (`bin/review_agent.ml`).** Operator/example tool, not part of the SDK runtime contract. The same agent is still buildable from the example tree via `dune exec examples/review_agent.exe -- <owner/repo> <pr_number>` for anyone who wants the script. Audit reference: `docs/_audit/2026-04-17-coordination-leak-candidates.md` (PR #978).
- **`oas-autonomy-smoke` CLI binary (`bin/autonomy_smoke_cli.ml`).** Operator-facing diagnostics that wrapped `Autonomy_trace_analyzer` to compare divergence across runs. The underlying library module `Autonomy_trace_analyzer` remains exported through `Agent_sdk.Autonomy_trace_analyzer`; downstream consumers that want the same diagnostic loop can call the library directly instead of relying on the CLI. Audit reference: same file as above.

Net effect: the `agent_sdk` opam package no longer publishes `oas-review` or `oas-autonomy-smoke` binaries. `oas` and `oas-runtime` are unchanged. The `lib/` API surface is unchanged.

## [0.155.0] - 2026-04-17

Verification tests + real-world examples for the v0.154.0 event surface.

### Added

- **`test/test_event_integration.ml`** — end-to-end assertions that
  the new variants actually emit where they should:
  - Orchestrator error path publishes `AgentFailed` alongside
    `AgentCompleted(Error _)`.
  - `Agent.run_with_handoffs` emits `HandoffRequested` then
    `HandoffCompleted` in order, with the sub-prompt in `reason`.
  - `Hooks.invoke` dispatches `OnContextCompacted` payloads correctly
    and `Hooks.empty.on_context_compacted` defaults to `None`.
- **`test/test_multivendor_live.ml`** — live smoke test that drives
  the golden transcript against every reachable provider
  (Anthropic, OpenAI, Gemini via OpenAI-compat, and any
  OpenAI-compatible local endpoint discovered via `LLM_ENDPOINTS`:
  llama-server, Ollama, vLLM, LM Studio, TGI, …). Each case skips
  gracefully when its prerequisite is missing, so CI without
  credentials stays green. Verifies Invariants I1/I2
  (provider-agnostic native variants, envelope preservation) against
  real providers rather than mocks only.
- **`examples/agent_failure_observability.ml`** — subscribes to an
  Event_bus and drives an orchestrator failure path so the
  `AgentFailed` payload (`agent_name`, `task_id`, `error`, `elapsed`)
  is visible at runtime. No LLM / network required.
- **`examples/handoff_lifecycle.ml`** — two-agent handoff with an
  inline mock OpenAI-compatible server; prints the
  `HandoffRequested` → `HandoffCompleted` lifecycle so the `reason`
  and `elapsed` fields are self-documenting.

### Changed

- **`test_orchestrator.ml::test_event_bus_receives_completed`**
  no longer assumes `AgentCompleted` is the last event — since
  v0.154.0 the companion `AgentFailed` follows it on error paths,
  so the test now looks events up by payload shape and also
  asserts the `AgentFailed` companion is emitted.

## [0.154.0] - 2026-04-17

Event system cleanup + boundary enforcement.

### Added

- **`Event_bus.AgentFailed`** payload variant. Emitted alongside
  `AgentCompleted` whenever a task ends with `Error`. Subscribers that
  want to match on failure directly no longer need to destructure the
  `result` Result.t. Provider-agnostic.
- **`Event_bus.HandoffRequested`** and **`HandoffCompleted`** payload
  variants. Emitted at the sub-agent run bracket inside
  `Agent.run_with_handoffs`. Mirrors OpenAI Agents SDK
  `handoff_requested` / `handoff_occurred`. Provider-agnostic.
- **`Hooks.OnContextCompacted`** hook event + `on_context_compacted`
  field on the `hooks` record. Fires at the same call sites as
  `Event_bus.ContextCompacted`. Use this hook for audit / metrics;
  Event_bus remains for async observation.
- **`Journal_bridge.make`** now accepts `?correlation_id` and `?run_id`
  so journal events bridged onto `Event_bus` share the same envelope as
  the surrounding agent run.
- **`docs/EVENT-CATALOG.md`** single source of truth for every event
  surface (Event_bus, Hooks, Durable journal, Runtime protocol, LLM
  wire stream, A2A), reserved Custom namespaces, multi-vendor matrix,
  and the Hook vs Event decision matrix.
- **`test/test_multivendor_events.ml`** asserts Event_bus taxonomy
  invariants (envelope preservation, event_type_name stability, golden
  lifecycle transcript) that every provider must honor.

### Changed (Breaking)

- **Runtime events decomposed per variant.** Previously all 13
  `Runtime.event_kind` variants flattened into one
  `Custom("runtime.event", json)`; now each gets its own name:
  `runtime.session_started`, `runtime.turn_recorded`,
  `runtime.agent_became_live`, …, `runtime.session_failed`. Subscribers
  can filter by topic without JSON parsing. The stdout
  `Event_message` protocol write is unchanged (primary transport).
- **Durable Custom names normalized colon → dot.**
  `durable:turn_started` → `durable.turn_started` (8 names). Matches
  runtime and provider namespace convention.
- **`Event_bus.TaskStateChanged` removed.** Dead variant from
  v0.31–0.35 A2A roadmap — declared but never emitted, no consumers.
  The SSE-only `A2a_server.task_event` is a separate, unrelated type
  and is unaffected.
- **`Journal_bridge.make` signature** changed from
  `bus:Event_bus.t -> Durable_event.event -> unit` to
  `bus:Event_bus.t -> ?correlation_id:string -> ?run_id:string ->
   unit -> (Durable_event.event -> unit)`. Call sites: add `()`.
- **`Hooks.hooks` record** gains `on_context_compacted` field; `empty`
  and `compose` updated. Pattern matches on `Hooks.hook_event` must add
  an `OnContextCompacted` arm.
- **`Event_bus.payload` pattern matches** must add arms for the four
  new variants (`AgentFailed`, `HandoffRequested`, `HandoffCompleted`)
  and drop the `TaskStateChanged` arm.

### Refactored

- `eval_collector.ml` replaces `_ -> ()` wildcard with explicit arms
  per payload variant so future variants don't silently drop.

### Migration for downstream consumers

The only known consumer (masc-mcp) subscribes to native Event_bus
variants via explicit arms; expect compile errors against v0.154.0 for:
- new variants (add arms for `AgentFailed`, `HandoffRequested`,
  `HandoffCompleted`)
- removed variant (delete `TaskStateChanged` arm)
- `Hooks.hooks` record field addition
- `Journal_bridge.make` signature

See `docs/EVENT-CATALOG.md` for the full taxonomy and boundary
guidance.

## [0.153.1] - 2026-04-17

### Changed

- **Documentation alignment with code reality.** README rewritten so the architecture diagram, provider table, scope-limitations table, and version statement reflect what is actually wired in `lib/` and `lib_swarm/`. The literal version string has been removed from the README; `lib/sdk_version.ml` is the only source of truth (PR #976).
- **SDK boundary tightened: OAS docs no longer name any specific downstream coordinator.** Comment in `lib/agent/agent_types.ml`, `docs/sdk-independence-principle.md`, RFCs, and supporting docs were generalized to "downstream consumer" / "external coordinator". The OAS-vs-named-coordinator analysis at `docs/design/cascade-boundary-analysis.md` was moved to `docs/archive/2026-04/` (PR #976). `CHANGELOG.md` itself is intentionally untouched in that PR — it is a historical record.
- **Personal-project disclaimer added at the top of README.** Makes the no-SLA / no-support posture explicit (PR #976).
- **Repo hygiene.** `TODO.md` removed from tracking; `.gitignore` broadened to absorb common operator-local scratch (`_build_*/`, one-off `*.py`, ad-hoc analysis `.md`) so future drops don't slip into commits (PR #977).
- **Audit tracker added.** `docs/_audit/2026-04-17-coordination-leak-candidates.md` records the read-only sweep of `lib/`, `lib_swarm/`, `bin/`, and RFCs for coordination-layer leaks. Four low-risk candidates documented; structure otherwise clean (PR #978).

No code or API changes. Bump captures the documentation/hygiene cycle as a tagged release boundary.
## [0.153.0] - 2026-04-17

### Changed

**`Budget_strategy.default_summarizer` is now exported in `budget_strategy.mli`.** Previously it was only used internally as the fallback for `strategies_for_phase` and `reduce_for_budget` when no custom `summarizer` was supplied. With the 0.152.0 addition of `Agent.options.summarizer`, downstream consumers writing wrapper summarizers had to re-implement the extractive default byte-for-byte to preserve the `[Summary of N earlier messages]` shape. Exporting lets them delegate instead.

Signature: `val default_summarizer : Types.message list -> string`. No behavior change; this is strictly an API surface addition.

3 new tests in `test_budget_strategy.ml`: empty → `[No prior context]` marker, header + role prefix shape, per-message truncation at 100 chars.

## [0.152.0] - 2026-04-17

### Added

**`Agent_types.options.summarizer : (message list -> string) option`.** Exposes the Budget_strategy Emergency-phase summarizer callback as a per-agent option so downstream consumers can inject a domain-aware summary function. When `None` (default), the built-in `Budget_strategy.default_summarizer` is used and behavior is unchanged.

- `Builder.with_summarizer` setter registers a custom callback.
- `pipeline.ml` (`proactive_compact` + `emergency_compact`) threads `?summarizer:agent.options.summarizer` into `Budget_strategy.reduce_for_budget`.
- The existing `?summarizer` optional parameter on `Budget_strategy.reduce_for_budget` is unchanged; it is simply now reachable from `Agent.options`.

Motivation: consumers may need application-specific summary semantics before messages are re-injected as compacted history. Previously the only customization path was post-hoc transformation via `context_reducer`, which runs **after** `reduce_for_budget` — by that point the `[Summary of N earlier messages]` string is already materialized. Exposing the summarizer on `Agent.options` makes that boundary explicit while keeping OAS domain-agnostic.

PR #973.

## [0.151.0] - 2026-04-16

### Added

**`Anthropic cache_extended_ttl` field.** Opt-in 1-hour prompt cache TTL for Anthropic Messages API callers. When `cache_extended_ttl = true`, cache control blocks are stamped with the extended-beta TTL instead of the default 5-minute window.

PR #962.

## [0.150.0] - 2026-04-16

### Removed (breaking, operator-facing)

**`OAS_OLLAMA_SUPPORTS_TOOL_CHOICE` env var deleted.** The process-wide env knob coupled deployment config to library semantics: a single boolean forced every Ollama-served model into the same `supports_tool_choice` setting, and the SDK silently matched on the runtime environment instead of the caller's declared config. Consumers that want a model-specific override now declare it per-call; see Added below.

Deleted:
- `Capabilities.parse_ollama_supports_tool_choice_env` (`lib/llm_provider/capabilities.ml`)
- `Capabilities.ollama_supports_tool_choice_default` (module-init env read)
- 12 inline `%test` cases exercising the env parser
- `ollama_capabilities.supports_tool_choice` is now hardcoded `false`; the documented Qwen3.5+Jinja opt-in path is through the new `supports_tool_choice_override` field.

### Added

**`Provider_config.supports_tool_choice_override : bool option`.** Lets the caller declare per-config whether their model honors `tool_choice:required`. `None` falls through to the per-kind default in `Capabilities` and the per-model override in `Capabilities.for_model_id`. `Some b` wins over both.

Rationale: keeps the SDK model-agnostic. The SDK no longer matches on `model_id` substrings ("qwen") to guess model-side behavior — the consumer (e.g. a cascade loader that knows it deployed Qwen3.5 with the Jinja chat template) declares the fact on each `Provider_config.t`.

Consumed by `backend_openai.build_request`: when `supports_tool_choice_override = Some b`, `b` is used instead of the capability record to decide whether the `tool_choice` body field is sent.

### Migration

- Callers that set `OAS_OLLAMA_SUPPORTS_TOOL_CHOICE=1` in deployment: drop the env var, pass `~supports_tool_choice_override:true` to `Provider_config.make` instead (or declare it in your cascade config and thread it through).
- Callers that did not set the env var: no behavioral change (default was already `false`).

## [0.148.0] - 2026-04-15

### Removed (breaking)

**Legacy cascade API fully evicted.** 0.146.0 removed `lib/llm_provider/cascade_*` modules but the older primary+fallbacks cascade API remained (Api/Retry/Provider/Builder/Agent layers). This release deletes it too, making OAS unambiguously single-provider.

Deleted:
- `type Provider.cascade` + `Provider.cascade` constructor (`lib/provider.ml/.mli`)
- `Api.create_message_cascade` (`lib/api.ml/.mli`)
- `Retry.with_cascade` (`lib/llm_provider/retry.ml/.mli`)
- `Builder.with_cascade`, `Builder.with_fallback` (`lib/agent/builder.ml/.mli`)
- `options.cascade` field on agent options (`lib/agent/agent_types.ml/.mli`, `lib/agent/agent.mli`)
- `cascade` field on `Agent_card.agent_info` + cascade_providers export (`lib/protocol/agent_card.ml/.mli`)
- `Pipeline.stage_route` cascade branch (now always `Api.create_message` single-provider)
- Tests: cascade cases in `test_deep_coverage.ml`, `test_e2e_v024.ml`, `test_bug_hunt.ml`, `test_provider.ml`, `test_builder_coverage.ml`
- Example: `examples/custom_provider.ml` (cascade demo) + `examples/dune` stanza

### Migration

Callers that relied on `Builder.with_cascade` / `Builder.with_fallback`:
1. Implement your own cascade loop around `Agent.run` / `Api.create_message`, OR
2. Use MASC's `lib/cascade/` if you're building in the MASC ecosystem.

Canonical pattern (MASC `oas_worker_named.ml` `try_cascade`):
```ocaml
let rec try_cascade remaining last_err =
  match remaining with
  | [] -> Error (format_exhausted_error last_err)
  | provider :: rest ->
    match Agent.run_with_provider agent ~provider with
    | Ok r -> Ok r
    | Error e when should_retry e -> try_cascade rest (Some e)
    | Error e -> Error e
```

### Rationale

Two parallel cascade systems existed in OAS: the `cascade.json`-based FSM (removed in 0.146.0) and this legacy primary+fallbacks record. Both are orchestration responsibilities, not SDK responsibilities. The SDK is now a pure `Provider_config.t → api_response` function.

## [0.146.0] - 2026-04-15

### Removed (breaking)

**Cascade completely evicted from OAS.** OAS is now a pure single-provider SDK.

Deleted modules (lib/llm_provider/):
- `cascade_config.ml` + `.mli` — parser/resolver utilities
- `cascade_config_loader.ml` + `.mli` — cascade.json hot-reload
- `cascade_fsm.ml` + `.mli` — pure decision FSM
- `cascade_health_filter.ml` — error classification
- `cascade_health_tracker.ml` + `.mli` — provider success/fail + cooldown
- `cascade_model_resolve.ml` + `.mli` — glm:auto alias resolution
- `cascade_throttle.ml` + `.mli` — local endpoint slot table

Deleted tests:
- `test/test_cascade.ml`, `test_cascade_config.ml`, `test_cascade_config_ext.ml`, `test_cascade_deep.ml`

Deleted example:
- `examples/cascade_failover.ml`

### Internal

- `Provider_bridge.resolve_auto_model_id` inlined (was delegating to `Cascade_model_resolve`)
- `Provider_bridge.resolve_glm_model_id`, `resolve_glm_coding_model_id` inlined (direct `Zai_catalog` calls)
- Stale docstring references (`{!Cascade_config}`) left in `constants.ml`, `provider_registry.mli`, `provider.ml`/`.mli` — to be purged in follow-up cleanup

### Migration

Cascade ownership moved to MASC (masc-mcp#7382 scaffold + #7386 migrate).
Consumers previously using `Llm_provider.Cascade_*` should:
1. Implement their own cascade loop around `Complete.complete`, OR
2. Use MASC's `lib/cascade/` modules (import MASC's masc_cascade or replicate the pattern)

Reference: MASC `oas_worker_named.ml` `try_cascade` function shows the canonical single-provider-loop pattern.

### Rationale

Cascade is an orchestrator responsibility, not an SDK responsibility. OAS was accumulating orchestration code (FSM, health tracking, throttle tables, weighted selection) that tightly coupled the SDK to MASC's operational model. Extracting cascade to MASC lets OAS focus on one job: "give me a Provider_config.t, I'll call it and return the response."

## [0.144.0] - 2026-04-15

### Removed (breaking)

- `Cascade_executor` module deleted (839 lines). Zero remaining callers
  after Judge and Tool_selector migrated to single-provider in 0.142.0
  and 0.143.0. Callers that need multi-provider failover drive their
  own loop around `Complete.complete` (MASC's `oas_worker_named.ml`
  `try_cascade` is the reference pattern).

### Internal

- Stale docstring references to `Cascade_executor` removed from
  `Context_reducer`, `Text_estimate`, and `test_complete_http`.

Note: `Cascade_config`, `Cascade_fsm`, `Cascade_health_tracker`,
`Cascade_health_filter`, `Cascade_throttle`, `Cascade_model_resolve`
remain for this release — they are SDK utilities that MASC still
consumes directly. A follow-up PR moves them into MASC and removes
them from OAS entirely (MAJOR bump).

## [0.143.0] - 2026-04-15

### Changed (breaking)

- `Tool_selector.default_rerank_fn` now takes `~provider:Provider_config.t`
  instead of `~cascade_name`, `~defaults`, `?config_path`, `?clock`. OAS
  no longer resolves cascade.json inside the rerank closure — callers
  that want multi-provider failover pick a single `Provider_config.t`
  per rerank (MASC selects from `cascade.json` and passes the winner).
- Implementation: replaces 4-step cascade resolve + `Cascade_executor.
  complete_cascade_with_accept` with a direct `Complete.complete` call.
  Rerank still overrides sampling (temperature 0.0, max_tokens 200) for
  deterministic, short replies. BM25 fallback on LLM failure unchanged.

### Migration

Before:
```ocaml
let rerank = Tool_selector.default_rerank_fn
  ~sw ~net ~cascade_name:"tool_selector"
  ~defaults:["llama:auto"] ~k:5 ()
```

After:
```ocaml
(* Caller resolves one provider from whatever source and passes it in. *)
let provider = (* ... *) in
let rerank = Tool_selector.default_rerank_fn
  ~sw ~net ~provider ~k:5 ()
```

Rationale: cascade is MASC's responsibility. OAS is a single-provider SDK.

## [0.142.0] - 2026-04-15

### Changed (breaking)

- `Judge.judge` now takes `~provider:Provider_config.t` instead of
  resolving a named cascade internally. OAS no longer owns cascade
  orchestration — callers that want multi-provider failover pick a
  single `Provider_config.t` per call (MASC selects from `cascade.json`
  and passes the winner).
- `Judge.judge_config` dropped `cascade_name` and `max_turns` fields.
  `max_turns` was dead (single-turn evaluation is the only mode);
  `cascade_name` belongs in the orchestrator, not in OAS.
- `Judge.judge` dropped `?clock` and `?config_path` parameters.
  Single-provider calls do not retry with backoff and do not read
  `cascade.json`.

### Migration

Before:
```ocaml
let cfg = { Judge.default_config () with cascade_name = "my-judge" } in
Judge.judge ~sw ~net ?clock ?config_path ~config:cfg ~context ()
```

After:
```ocaml
(* Caller resolves one provider from whatever source (cascade.json,
   a static value, etc.) and passes it in. *)
let provider = (* ... *) in
let cfg = Judge.default_config () in
Judge.judge ~sw ~net ~provider ~config:cfg ~context ()
```

Rationale: cascade is MASC's responsibility. OAS is a single-provider SDK.

## [0.140.0] - 2026-04-15

### Removed (breaking)

- `Cascade_config.complete_named`, `Cascade_config.complete_named_stream` —
  the named-cascade convenience wrappers. Callers should compose the
  primitives directly:
    1. `Cascade_config.resolve_model_strings` (config lookup + defaults)
    2. `Cascade_config.expand_model_strings_for_execution`
    3. `Cascade_config.parse_model_strings`
    4. `Cascade_config.filter_healthy`
    5. `Cascade_executor.complete_cascade_with_accept` (or `_stream`)
  In-tree consumers `judge.ml` (oas#925) and `tool_selector.ml` (oas#926)
  were migrated to this pattern in the previous two releases.
- `Cascade_config.complete_cascade_with_accept`,
  `Cascade_config.complete_cascade_stream` re-export shims — call
  `Cascade_executor.complete_cascade_with_accept` /
  `Cascade_executor.complete_cascade_stream` directly.
- `Cascade_config.filter_healthy_internal` private helper — only callers
  were the deleted wrappers above. Public `Cascade_config.filter_healthy`
  is unchanged.

### Migration

```ocaml
(* Before: *)
Cascade_config.complete_named ~sw ~net ?clock ?config_path
  ~name ~defaults ~messages ~temperature ~max_tokens ()

(* After: *)
let model_strings =
  Cascade_config.resolve_model_strings ?config_path ~name ~defaults ()
  |> Cascade_config.expand_model_strings_for_execution
in
let providers =
  Cascade_config.parse_model_strings ~temperature ~max_tokens model_strings
in
let healthy = Cascade_config.filter_healthy ~sw ~net providers in
Cascade_executor.complete_cascade_with_accept ~sw ~net ?clock
  ~accept:(fun _ -> Ok ()) healthy ~messages ~tools:[]
```

## [0.139.0] - 2026-04-15

### Added
- `Cascade_config.resolve_model_strings_with_trace` — structured selection
  trace for cascade decisions. Returns the ordered model list plus a
  `selection_trace` with per-candidate `config_weight`, `effective_weight`,
  `success_rate`, and `in_cooldown`. Enables dashboards/telemetry to
  surface *why* a provider was chosen first without re-deriving state.
- `Cascade_health_tracker.provider_info` / `all_providers` — structured
  snapshot API for the rolling-window health tracker. Returns
  `provider_info` records (key, success rate, consecutive failures,
  cooldown state + expiry, events in window). Complements the existing
  string-based `provider_summary`.

### Notes
- No breaking changes. Existing consumers of `resolve_model_strings_traced`
  and `provider_summary` are unaffected.

## [0.138.0] - 2026-04-15

### Fixed
- `Context_reducer` now strips orphaned `ToolResult` blocks before the API
  call so compacted contexts do not trip `tool_call_id` validation on
  OpenAI-compatible providers (#917).
- `Utf8_sanitize` strips disallowed control characters to prevent
  downstream JSON serialization faults (#916).

## [0.137.0] - 2026-04-15

### Added
- Weighted cascade routing for named/default profiles:
  - `cascade.json` model arrays now accept `{ "model", "weight" }` entries.
  - First-attempt provider selection uses weighted random ordering while
    preserving deterministic fallback priority.
  - Health-aware weight adjustment and cooldown-aware filtering feed the
    effective provider order before execution (#911).

### Fixed
- Anthropic response parsing now initializes telemetry placeholders
  consistently with the other provider backends (#912).
- OpenAI-compatible request builders strip orphaned `ToolResult` blocks
  before serialization so compacted contexts no longer trip invalid
  `tool_call_id` errors on GLM/Groq/DeepSeek paths (#914).

## [0.136.0] - 2026-04-14

### Added
- `Event_bus.ContextOverflowImminent` payload — proactive warning emitted
  before context overflow occurs, with `estimated_tokens`, `limit_tokens`,
  and `ratio` fields (#901).
- `Event_bus.ContextCompactStarted` payload — marks compaction start with
  a `trigger` field (`proactive`, `emergency`, or `operator`) (#901).
- `Context_reducer.estimate_next_turn_overhead` — estimates fixed overhead
  (system prompt + tool descriptions + output reserve) for budget projection
  before the next turn (#901).
- `Cascade_executor.truncate_to_context_strict` — strict variant of
  `truncate_to_context` that returns `Error (\`Over_budget (est, budget))`
  instead of silently passing over-budget content. Original function
  unchanged for backward compatibility (#901).

## [0.135.0] - 2026-04-14

### Added
- `Agent.save_journal t path` — thin wrapper over
  {!Durable_event.save_to_file}. Returns `Error "no journal"` when the
  agent has no journal attached (#894).
- `Builder.with_auto_dump_journal ~path` — installs an
  `on_run_complete` callback that dumps the journal on every run
  completion. Creates a fresh journal if one is not attached so the
  dump is never empty (#894).

## [0.134.0] - 2026-04-14

### Added
- `Durable_event` JSONL persistence primitives:
  `save_to_file` (atomic tmp+rename) and `load_from_file`
  (missing → empty journal, malformed → line-numbered error) (#892).

### Changed
- Version bump to 0.134.0 after integrating the full Durable_event
  journal stack from 0.133.0.

## [0.133.0] - 2026-04-14

### Added
- `Durable_event` integration across agent runtime (#890, #891):
  - `agent_types.options.journal` field + `Builder.with_journal`.
  - `pipeline.ml` appends `Turn_started`, `State_transition`,
    `Llm_request`, `Llm_response`, `Error_occurred`,
    `Checkpoint_saved` (proactive + emergency).
  - `agent_tools.ml` appends `Tool_called` / `Tool_completed` with
    idempotency keys suitable for replay deduplication.
- `Durable_event.create ?on_append` fan-out callback (#891).
- `Journal_bridge.make ~bus` projects every journal event onto
  `Event_bus.Custom ("durable:<kind>", payload)` — Event_bus
  subscribers observe the full journal stream without payload
  schema changes (#891).

## [0.132.0] - 2026-04-13

### Added
- `Diag` module in `llm_provider` — pluggable structured diagnostic logging
  with level filtering and consumer-replaceable sink. Replaces 27 raw
  `Printf.eprintf` calls across 6 files.

## [0.131.0] - 2026-04-13

### Removed
- `Provider.local_qwen`, `Provider.local_mlx` deprecated aliases.
- `vote` type, `vote_request`, `Vote` command, `Vote_recorded` event
  (dead code: projection ignored votes, field never populated).
- `"local-qwen"` provider resolver string alias.
- `session.votes` field from runtime session record.

### Added
- Diagnostic logging in `cascade_health_filter.ml` for provider
  filtering decisions (API key drops, cloud-only fallback).

## [0.126.0] - 2026-04-13

### Added
- `Context_reducer.cap_message_tokens` strategy to cap per-message token
  budgets while preserving recent turns and inserting a truncation marker
  when the middle is dropped.
- Swiss Verdict JSON schema v1 at `docs/schemas/swiss-verdict.schema.json`.
- `Harness.verdict_to_json`, `Harness.swiss_verdict_to_json`, and
  `Eval.run_metrics_to_json` for schema-aligned evaluation export.

### Changed
- Checkpoint delta metrics now use the `oas.checkpoint.*` namespace instead
  of flat `checkpoint_delta_*` names.

## [0.125.0] - 2026-04-13

### Removed
- `Api.named_cascade` type, constructor, `create_message_named`,
  `create_message_named_stream`, and `Builder.with_named_cascade`.
  Cascade FSM moved to MASC in Phase 2; this removes the dead OAS residue.
- `config/cascade.json` — cascade config is now MASC-owned SSOT.
- `Agent.t.named_cascade` field and `?named_cascade` parameter from
  `Agent.create` and `Agent.resume`.

### Changed
- `Tool_selector.default_rerank_fn`: replaced `~named_cascade` parameter
  with explicit `~cascade_name`, `~defaults`, and `?config_path`.

## [0.122.1] - 2026-04-12

### Fixed
- Anthropic: Messages API conformance — tool_choice nesting + thinking gate (#835)
- Anthropic: serialize temperature/top_p/top_k in build_body_assoc (#834)
- Anthropic: capabilities_for_model consults for_model_id (#825)
- Gemini: capabilities.supports_top_k = true (#833)
- Anthropic: capabilities.supports_top_k = true (#832)
- OpenAI: route silent capability drops through warn helper (#831)
- OpenAI: gate min_p/top_k on capabilities.supports_* (#830)
- MCP: truncate_output uses CJK-aware token estimator + UTF-8 boundary (#828)
- Ollama: send keep_alive as integer when value parses as int (#821)
- Builder: derive context_thresholds fallback from provider capabilities (#823)

### Changed
- Extract canonical CJK-aware text estimator to llm_provider (#829)
- Drop dead Gemini/GLM exception catches in create_message (#836)
- Add n > 0 guard to effective_max_context (#826)

## [0.122.0] - 2026-04-12

### Added
- Capabilities: OAS_OLLAMA_SUPPORTS_TOOL_CHOICE env override (#801)
- Cascade: per-entry api_key_env override in cascade config (#817)
- Agent: emit per-turn timing line to stderr for budget diagnosis (#816)
- Complete: log base_url + capture body on HTTP 5xx (#814)
- Ollama: pin keep_alive=-1 by default to prevent model eviction (#813)

### Fixed
- Pipeline: derive proactive_context_window from model capabilities (#815)
- Pipeline: remove per-LLM-request Eio.traceln spam for Unspecified priority default (#799)
- Cascade: apply per-model timeout to last provider (#805)

### Changed
- Discovery: drop the model-specific local URL fallback; use `OAS_LOCAL_LLM_URL` for local runtime overrides (#818)

## [0.121.0] - 2026-04-11

### Added
- Multi-vendor inference providers: Groq, DeepSeek, Alibaba, SiliconFlow (#789)
- Process-wide global registry for Metrics.t (#807)
- on_http_status hook for provider response counters (#804)

## [0.120.0] - 2026-04-11

### Fixed
- Retry: treat hard-quota 429s as non-retryable (#798)
- Retry: flat-error-string extraction (#795)

## [0.118.1] - 2026-04-09

### Changed
- `oas-review` now reports the shared SDK version instead of a stale hardcoded `0.46.0` string.
- `swarm_plan_cache` mode decoding now uses explicit `result` handling instead of exception-driven control flow while preserving legacy serialized mode names.

## [0.117.0] - 2026-04-09

### Added
- Runtime `glm:auto` expansion now yields ordered GLM execution fallbacks for named completions, streaming completions, and local capacity selection. Closes #738.
- `glm:auto` now expands to a multi-model GLM cascade during config/model resolution instead of a single default model. Closes #736.

### Changed
- `Constants.Inference_profile.agent_default` and `worker_default` now use `max_tokens = 16_384`; endpoint docs also clarify that port `8085` is the llama.cpp default. Closes #737.

### Fixed
- OpenAI-compatible requests now send explicit `Content-Length` headers to avoid chunked-encoding rejection by strict upstreams. Closes #735.
- `backend_openai` omits `tool_choice` for models that do not advertise tool-choice support, preserving backward compatibility for unknown models. Closes #725.
- Legacy tool parameter lists are normalized into JSON Schema before OpenAI-compatible/Ollama tool serialization. Closes #734.
- `complete_http` adds pre-flight JSON-body validation and richer 4xx diagnostics for malformed provider payloads. Closes #726.
- Cascade diagnostic logs now quote field values and gate debug output behind `OAS_CASCADE_DIAG`. Closes #724.
- Retry follow-up cleanup tightened wording, allocation behavior, and inline coverage around `retry.ml`. Closes #723.

## [0.111.0] - 2026-04-07

### Added
- `ollama` provider in cascade registry. `ollama:auto` routes to Ollama MLX
  server at `OLLAMA_HOST` or `http://127.0.0.1:11434`. Always available (no
  API key required). OpenAI-compatible endpoint, 262k max context.

## [0.110.0] - 2026-04-07

### Added
- `Agent.make_extend_turns_tool` with public `Agent.t` type for runtime turn extension. Closes #674.
- Slot pinning for llama-server KV cache reuse via `slot_id` parameter in sync and streaming paths. Closes #672.
- Per-model timeout for non-last cascade providers (default 1200s). Closes #679.
- End-to-end test proving context_injector to LLM delivery chain. Closes #673.

### Fixed
- 4 design debt items from boundary audit: removed stale references, aligned provider abstractions. Closes #667, #668, #669, #670.
- Preserve `Context.t` identity in `context_with_contract` to prevent hooks from reading empty data on resume. Closes #676.
- Sync `model_endpoints` before cascade parsing so `endpoint_for_model` can route `llama:model_id` correctly. Closes #677.

## [0.109.0] - 2026-04-06

### Added
- 17 new tool descriptor mappings for HITL (`ask_user_question`), web (`web_fetch`, `web_search`), task management (`task_create/update/list/get/output/stop`), team (`team_create/delete`), browser interaction (`navigate`, `computer`, `find`, `form_input`, `javascript_tool`, `tabs_create_mcp`, `upload_image`), and notebook (`notebook_read`). Addresses #646.
- Inline tests for `Mode_enforcer.builtin_descriptor` and `Mcp_schema.descriptor_for_builtin_tool`.

## [0.108.0] - 2026-04-06

### Added
- `max_turns` field in `BeforeTurnParams` hook event. Consumers can compute remaining turns without duplicating max_turns tracking. Closes #658.

## [0.107.0] - 2026-04-06

### Changed
- A2A `message_part_to_yojson` outputs v1.0 Part shape with `type` discriminator field. Text: `{"type":"text","text":"..."}`. File: nested `{"type":"file","file":{...}}` with `bytes`/`uri`. Data: `{"type":"data","data":{...}}`. Legacy format parsing preserved in `of_yojson`. Closes #591.

## [0.106.0] - 2026-04-06

### Added
- `Constants.Inference_profile.worker_default` (temp=0.2, max_tokens=4096) and `deterministic` (temp=0.0, max_tokens=4096) inference profiles for downstream coordinators.
- `Budget_strategy.context_metrics` type and constructor — aggregates usage ratio, compression phase, and limit proximity into a single value.
- Lifecycle transition guards (A2A pattern): `Lifecycle.validate_transition` enforces valid state machine transitions.
- Collaboration and Plan transition guards with typed error reporting.

## [0.105.0] - 2026-04-06

### Changed
- Consolidated hardcoded endpoint URLs (`http://127.0.0.1:8085`, `http://localhost:8085`) into `Constants.Endpoints` module. All production and test code references the SSOT constants instead of string literals. Prevents port drift across files (prior art: #557).
- `Constants.Anthropic.prompt_cache_min_chars` extracts the prompt caching threshold (3500 chars) from `backend_anthropic.ml`.
- `provider.ml` local URL detection replaced magic number 16 with `String.length`-based prefix check.
## [0.104.0] - 2026-04-06

### Added
- `Mode_enforcer.builtin_descriptor` derives `Tool.descriptor` from the builtin registry. Read-only tools get `Parallel_read`, mutation tools get `Sequential_workspace`, shell/external tools get `Exclusive_external`. Consumers can query descriptors for built-in tools without hardcoding.
- `agent_tools.concurrency_class_of_tool` now falls back to `builtin_descriptor` when a tool has no attached descriptor, enabling correct parallelization of read-only built-in tools.

## [0.102.0] - 2026-04-06

### Added
- `Agent_types.options.priority` field (`Request_priority.t option`). Enables the resume path to set scheduling priority without requiring a full `agent_config` override. When set, overrides `config.priority` on the resumed agent. Builder path already uses `Builder.with_priority`.

### Fixed
- Resume path no longer defaults to `Unspecified` priority when the caller intends a specific scheduling class (fixes #616).

## [0.101.0] - 2026-04-05

### Added
- `Tool_index.entry.aliases` field for additional BM25 tokens (e.g. Korean keywords). Aliases are appended to name+description during tokenization. Existing code using `{ name; description; group }` must add `aliases = []`.
- `TopK_bm25.confidence_threshold` parameter. When the top BM25 score falls below this threshold, `fallback_tools` are unioned with the results. `None` disables fallback. Distinct from `Tool_index.config.min_score` which filters individual documents.
- `TopK_bm25.fallback_tools` parameter for curated tool subsets to include on low-confidence queries.

### Changed
- `Tool_index.entry` record now requires `aliases` field (source-breaking for direct record construction).
- **BREAKING**: `TopK_llm` variant now uses `rerank_fn` closure instead of `selector_config`. The stub (`failwith "Phase 3"`) has been replaced with a working 2-stage implementation: BM25 pre-filter then LLM reranking via caller-injected closure.
- `TopK_llm` strategy: `select` may perform I/O via `rerank_fn`. Not idempotent for this strategy. `always_include` provides deterministic lower bound.
- `default_rerank_fn` provided for `Cascade_config`-based LLM reranking. Captures Eio resources in closure.

## [0.100.7] - 2026-04-04

### Added
- Shared inference-contract helpers in `Provider` for provider/model/modality/task resolution without forcing existing `model_spec` callers to migrate.
- `Context_overflow` CDAL result status for infra-level provider errors.

### Fixed
- Internal tool retry policy now preserves non-recoverable failures and clamps invalid retry counts before retry scheduling.

## [0.100.6] - 2026-04-04

### Added
- `PolicyChannel` for lazy tool policy propagation to spawned agents.

### Fixed
- Removed MASC-specific tool names from `tool_index` test fixtures to keep OAS boundary tests SDK-local.

## [0.100.5] - 2026-04-04

### Added
- `Response_harness` for deterministic text and tool-output extraction from model responses.
- Real A2A HTTP binding with `tasks/sendSubscribe` SSE streaming.
- `Inference_profile` as the single source of truth for inference defaults.
- `Tool_index` scoped retrieval and rebuild APIs for dynamic tool-set updates.
- Hook-level `system_prompt_override`, policy decision lineage, and a fail-closed decision validity matrix.

### Changed
- `Agent_tools` now treats `Exclusive_external` tool batches as a barrier-separated execution class.
- CDAL mode enforcement uses descriptor-driven classification instead of hardcoded heuristics.
- Turn pipeline now prunes in-memory tool results and enforces a message cap between turns.

### Fixed
- Hook tool-filter overrides are intersected with operator policy instead of widening access.
- Discovery now reports actual Ollama context size, and SDK-facing surfaces no longer leak MASC-specific references.

## [0.100.3] - 2026-04-04

### Added
- Cascade slot-full fallthrough for load distribution across providers.

### Changed
- Local endpoint defaults are consolidated behind `Discovery.default_endpoint`.
- HTTP mock servers in tests now use ephemeral ports instead of fixed allocations.

### Fixed
- Capability filtering fails closed on unknown limits instead of silently allowing them.
- Runtime rejects unknown provider names instead of coercing them to `Local`.
- Pricing distinguishes unknown models from genuinely free providers.
- Eio cancellation and runtime mutex handling were hardened around shutdown paths.

## [0.100.2] - 2026-04-03

### Added
- Tool execution scheduling metadata is now recorded in raw traces and CDAL proof-store tool traces.

### Changed
- `Hooks.PreToolUse`, `Hooks.PostToolUse`, and `Hooks.PostToolUseFailure` now carry `tool_use_id` plus deterministic schedule metadata.
- `Raw_trace.Tool_execution_started` records `planned_index`, `batch_index`, `batch_size`, and `concurrency_class`.

## [0.100.1] - 2026-04-03

### Added
- `Tool.concurrency_class` metadata for explicit tool execution contracts.

### Changed
- `Agent_tools.execute_tools` now schedules `Parallel_read` tools in parallel batches and runs workspace or external tools sequentially.
- Tools without declared concurrency metadata now default to conservative sequential execution.

## [0.99.8] - 2026-04-01

### Added
- Turn-level slot yielding for swarm efficiency (#538).
- Explicit permit API for turn-level slot yielding (#536).
- Custom tokenizer support for BM25 tool index (#540).
- OpenAI `auto` model resolution in cascade config (#541).

### Changed
- `Log` module globals use `Atomic.t` for data-race-free reads (#543).

## [0.99.7] - 2026-03-31

### Changed
- Remove 586 lines of redundant inline tests from `memory.ml` (821 → 209 lines). Covered by alcotest suites.
- Remove 8 dead re-exports and 1 internal-only function that were only consumed by the removed inline tests.

## [0.99.6] - 2026-03-31

### Changed
- Extract `Cascade_health_filter` and `Cascade_executor` from `cascade_config.ml` (983 → 721 lines). No public API changes.

## [0.99.5] - 2026-03-31

### Fixed
- Cascade no longer tries remaining providers on local resource exhaustion (EADDRNOTAVAIL, EMFILE, ENOBUFS). Saves wasted connection attempts when ephemeral ports or FDs are depleted.

## [0.99.4] - 2026-03-31

### Fixed
- Deduplicated `env_or` in `cascade_model_resolve.ml` (2 inline closures → 1 module-level function).
- Replace O(n) structural list comparison with O(1) counter check at loop exit.

## [0.99.3] - 2026-03-31

### Fixed
- Consolidated duplicate `Sys.getenv_opt` patterns in `review_agent.ml` and `mcp.ml` to use `Defaults` helpers.

## [0.99.2] - 2026-03-31

### Added
- `Defaults.int_env_or` / `Defaults.float_env_or` — typed env var helpers for int and float values.
- `OAS_MCP_HTTP_URL` env var — configurable MCP HTTP default endpoint.
- `OAS_REVIEW_MODEL` env var — configurable review agent model selection.
- `OAS_AGENT_MAX_RETRIES`, `OAS_AGENT_INITIAL_DELAY`, `OAS_AGENT_MAX_DELAY` env vars — configurable swarm retry policy.

### Fixed
- Periodic callback exceptions now logged via `Printf.eprintf` instead of silently swallowed.
- Fatal exceptions (`Out_of_memory`, `Stack_overflow`, `Sys.Break`) re-raised in periodic callbacks.

## [0.99.1] - 2026-03-31

### Added
- `Swarm_plan_cache` module — convergence trajectory caching and warm-start for swarm runs (#508).
  - `structural_fingerprint` — deterministic hash of config structure (agents, roles, mode, convergence params).
  - `template_of_state` — captures quality signals and per-agent scores from converged runs.
  - `hints_of_template` / `apply_hints` — tighter iteration bounds and agent reordering (Decentralized only).
  - `make_recording_callbacks` — opt-in integration via `on_converged` callback composition.
  - `fs_backend` — filesystem-backed cache with atomic writes.
- `Swarm_plan_cache.agent_score_to_json` / `agent_score_of_json` — public score serialization.
- `Checkpoint` delta support (#498) — `compute_delta` / `apply_delta` with full restore fallback.
- `Stub_tool_results` reducer strategy for observation masking (#500).
- Swarm checkpoint fidelity gate — `converged` flag preserved in checkpoint v2 (#499, #505).

### Fixed
- `Custom_role` JSON roundtrip — strip inner quotes from `ppx_deriving.show` output (#508).
- GLM default base URL changed to `api.z.ai` (#501).
- Provider mock token counts made explicit (#507).

## [0.98.0] - 2026-03-30

### Added
- `Slot_scheduler.snapshot` — non-blocking point-in-time capacity snapshot.
- `Slot_scheduler.try_with_permit` — non-blocking slot acquisition returning `'a option`.
- `Provider_throttle.capacity_source` type — `Discovered | Fallback` discriminator.
- `Provider_throttle.source`, `snapshot`, `try_permit`, `queue_length`, `max_concurrent` getters.
- `Cascade_throttle.capacity_info` type with `process_*` prefix for process-scoped counts.
- `Cascade_throttle.capacity` — single-endpoint capacity query.
- `Cascade_config.local_capacity_for_selections` — cascade-selection-scoped capacity query with cold start probe via `~sw ~net`.

### Changed
- `Provider_throttle.of_discovery_status` now tags result with `source = Discovered`.
- `Cascade_throttle.populate` promotes Fallback entries to Discovered when probe returns slot data.

## [0.97.0] - 2026-03-30

## [0.96.0] - 2026-03-30

### Added
- `Slot_scheduler` module — priority-aware slot scheduling with Eio.Mutex + Eio.Promise (#483).
- `Provider_throttle.with_permit_priority` — priority-aware permit acquisition.
- `Unspecified` variant in `Request_priority` — logs warning, dispatched as Proactive.
- `Request_priority.resolve` — resolves Unspecified to Proactive with warning.
- `priority` field in `Types.agent_config` — flows through Agent.run pipeline to cascade throttle.
- `?priority` parameter in `Api.create_message_named` and `create_message_named_stream`.

### Changed
- `Provider_throttle` now uses `Slot_scheduler` internally instead of `Eio.Semaphore`.
- Higher priority requests (Interactive) are dequeued before lower priority (Background) when slots are full.

## [0.95.0] - 2026-03-30

### Added
- `Request_priority` module — `Interactive | Proactive | Background` priority type for LLM completion scheduling (#478).
- `?priority` parameter added to all completion and cascade functions.
- `to_yojson`/`of_yojson` converters for `Request_priority`.

### Changed
- `complete_stream_cascade` now correctly threads `?priority` through to `complete_stream`.

## [0.94.0] - 2026-03-29

### Added
- Single-agent vs swarm baseline evaluation harness for comparing agent performance (#474).
- Operator-level tool policy — declarative allow/deny rules applied before tool dispatch (#473).

### Changed
- Pin CI and MCP SDK to OCaml 5.4.1 rollout (#472).
- Declare explicit scope limitations in project documentation (#471).

### Fixed
- Sync execution state back to original agent after contract runner handoff (#467).

## [0.93.2] - 2026-03-29

### Added
- Add `Swarm_types.agent_entry.extensions` so downstream consumers can attach explicit pass-through metadata to swarm entries.
- Add read-side `Proof_store` APIs for artifact ref resolution, JSON/JSONL reads, manifest/contract loading, and run listing.
- Annotate all 186 `.mli` files with explicit stability tiers and document the tier policy in `docs/api-stability.md`.

### Changed
- Move GitHub Actions off Node 20 by upgrading `actions/checkout` to `v5` and `actions/upload-artifact` to `v6`.

### Fixed
- Replace MASC-specific coordination keywords in `Context_intent` with coordinator-agnostic generic terms.
- Make `Fs_result.ensure_dir` recursive as documented and reject proof-store artifact refs with traversal-style `run_id` values.

## [0.93.1] - 2026-03-28

### Fixed
- Refactor swarm convergence bookkeeping into explicit state transitions so Eio async control flow no longer depends on ad-hoc `ref` accumulators.
- Make streaming mailbox draining cooperative and replace swarm round-robin selection's global `ref` counter with `Atomic.t`.

## [0.92.2] - 2026-03-27

### Changed
- Raise `mcp_protocol`, `mcp_protocol_eio`, and `mcp_protocol_http` minimum versions to `>= 1.0.0`, and pin CI's `mcp-protocol-sdk` checkout to the 1.0.1 SHA.

### Fixed
- Log swarm metric-evaluation failures to stderr and clarify ignored mailbox/usage paths in the runner to make convergence-loop debugging easier.

## [0.92.1] - 2026-03-27

### Fixed
- Improve HTTP client error context for hostname/TLS setup failures and preserve `Eio.Cancel.Cancelled` during socket cleanup.
- Build MCP tool-result test fixtures via JSON parsing so local newer MCP SDK pins and CI's older schema both pass.

## [0.92.0] - 2026-03-26

### Changed
- `Swarm_types.metric_source` now uses `Argv_command of string list` for process metrics, and `Runner.eval_metric` executes argv directly via `Eio.Process.parse_out`.
  Migration: replace `Shell_command "cmd --flag value"` with `Argv_command ["cmd"; "--flag"; "value"]`.

### Fixed
- `scripts/release.sh` now validates version consistency against `lib/sdk_version.ml` and `agent_sdk.opam`, matching the current version single-source-of-truth layout.

## [0.91.2] - 2026-03-26

### Fixed
- Guard `Fiber.fork` bodies against exception leaks in resilience paths.
- Widen `cohttp-eio` 6.2 connect return typing and sync version metadata.
- Isolate outbound HTTP connections with per-request `Switch.run`.
- Replace `Unix.sleepf` with `Eio.Time.sleep` in tests.
- Replace blocking swarm metric process handling with `Eio.Process`.

### Changed
- Eliminate `assert false` and `failwith` from strict error handling paths.
- Remove mutable state and `ref` usage from trajectory and metrics.

## [0.91.1] - 2026-03-26

### Fixed
- Temp file resource leak in 6 cascade_config inline tests and 3 test files (Fun.protect pattern).
- `eval_baseline.load` used failwith instead of direct Result return.
- `succession.metrics_of_json` inconsistent float parsing (try-with to to_float_option).

## [0.89.0] - 2026-03-24

### Added
- **Reflexion module** (`Reflexion`): act-evaluate-reflect-retry loop primitive based on MAR (Multi-Agent Reflexion) pattern. Separated concerns: Act/Diagnose/Critique/Aggregate. Integrates with Episodic memory for reflection persistence. `Reflexion.run` executes the loop, `format_reflection` formats failed verdicts, `on_stop_evaluator` wraps as hook adapter. 11 tests.
- **Clear_tool_results strategy** (`Context_reducer`): replaces processed tool results in older turns with short markers, preserving tool_use_id for API consistency. Safest and lightest form of context compaction (Anthropic recommendation).
- **PreCompact hook event** (`Hooks`): new lifecycle event emitted before context compression. Carries `messages`, `estimated_tokens`, and `budget_tokens` for pre-compaction intervention.
- `pre_compact` field in `Hooks.hooks` record.
- **Tool_index module** (`Tool_index`): pure OCaml BM25 implementation for dynamic tool exposure. Indexes tool descriptions at startup, retrieves top-K relevant tools per query. Confidence gate for automatic fallback. Group co-retrieval. 8 inline tests.
- **Retrieval_based strategy** (`Progressive_tools`): BM25-indexed tool retrieval per turn context. Extracts query from last user message. Falls back to full catalog below confidence threshold. `always_include` for essential tools.
- **Durable_event module** (`Durable_event`): event-sourced agent loop journal. 9 event types (Turn_started, Llm_request/response, Tool_called/completed, State_transition, Heartbeat, Checkpoint_saved, Error_occurred). Idempotency keys for replay-safe tool execution. Heartbeat lease detection. Replay summary for crash recovery. Full JSON round-trip. 14 tests.

### References
- MAR: Multi-Agent Reflexion (arxiv:2512.20845)
- Anthropic "Effective Context Engineering" (tool result clearing)
- ACON: Optimizing Context Compression (arxiv:2510.00615)
- ITR: Dynamic Tool Exposure (arxiv:2602.17046)
- Diagrid "Still Not Durable" (event sourcing gap analysis)

## [0.78.0] - 2026-03-20

### Added
- `max_context` field in `Provider_registry.entry` — default context window size per provider.
- Usage helpers in `Types`: `zero_api_usage`, `usage_of_response`.
- `cc` (Claude Code) provider integrated into `reg` pattern with `max_context:200_000`.

## [0.77.0] - 2026-03-20

### Added
- **Plan module** (`Plan`): goal decomposition into ordered steps with dependency DAG. Step lifecycle (Pending/Running/Done/Failed/Skipped), re-planning, progress tracking, JSON serialization. Complementary to Durable (Plan = what to do, Durable = how to execute reliably). 20 tests.
- `examples/plan_execute_demo.ml`: 4 scenarios (linear deployment, re-planning after failure, serialization, dependency graph).

### Design decisions
- Norm module deferred to MASC. Norms are inter-agent (social), not intra-agent. Principle: "agent itself = OAS, MASC = consumer".

## [0.76.0] - 2026-03-20

### Added
- **Governance layer**: runtime governance for agent decisions.
  - `Policy`: priority-ordered rule evaluation at 6 decision points (BeforeToolCall, BeforeHandoff, BeforeResponse, ResourceRequest, BeforeMemoryWrite, Custom) with 4 verdicts (Allow, Deny, AllowWithCondition, Escalate). 11 tests.
  - `Audit`: immutable log of policy decisions with capacity eviction, query filters, JSON export. 11 tests.
  - `Durable`: typed step chains with execution journal for crash recovery. Execute/resume/suspend with retry. JSON round-trip. 20 tests.
- `test_governance_integration.ml`: 9 integration tests (Policy+Audit, Durable+Audit, full governance flow).
- `examples/governance_demo.ml`: 6 scenarios (tool governance, handoff escalation, resource budget, durable pipeline, resume, serialization).
- `Fs_result`: Result-based filesystem operations replacing scattered try/with patterns.
- `Memory_tools`: agent-facing memory store/recall/forget tools.
- `Verified_output`: phantom-typed compile-time output verification (`unverified`/`verified` type tags).
- `Memory_access`: deny-by-default agent-scoped permission layer (prefix-based key patterns).
- Gemini native backend: `contents/parts` wire format, `thinkingConfig`, `functionCall/Response`, SSE streaming. 30 tests.
- Inline tests via `ppx_inline_test` for 13 modules.

### Changed
- 5 files migrated to `Fs_result`, removing 143 lines of duplicated I/O.
- `Thread.create` replaced with `Eio.Fiber.fork` in runtime server.
- `Digest.string` replaced with stable hash; 18 bare catch-all patterns eliminated.

## [0.75.0] - 2026-03-20

### Added
- **5-tier Memory**: Episodic (time-decaying salience, interaction history) and Procedural (pattern matching, success/failure tracking with confidence) memory tiers added to the existing Scratchpad/Working/Long_term model. 17 new tests.
- **.mli 100% coverage**: All 133 modules now have API contract files (.mli). 49 new .mli files across 6 PRs. Dead code discovered and removed during the process.
- **Coverage 83%**: 44 new test files covering structured output, runtime_client, transport, API, MCP, streaming, orchestrator, swarm, and more.

### Changed
- `Memory.stats` returns `int * int * int * int * int` (added episodic and procedural counts). **Breaking change** from 3-tuple.
- `Memory.tier` variant extended with `Episodic` and `Procedural`.
- `eval_collector.ml`: removed unnecessary `mutable` on `start_time` field.

## [0.71.0] - 2026-03-19

### Added
- **Named Cascade API**: `Api.named_cascade`, `Builder.with_named_cascade` — named cascade profiles integrated into Agent/Builder layer. Pipeline routes through `Cascade_config.complete_named` with automatic failover.
- `.mli` API contracts for 13 modules: runtime_projection, transport, a2a_task, mcp, conformance, direct_evidence, runtime_server, runtime_store, runtime_evidence, agent_config, otel_tracer, streaming, internal_query_engine. Total .mli coverage: 61 -> 74/128 (48% -> 58%).
- Stream accumulator tests (23 cases): `create_stream_acc`, `accumulate_event`, `finalize_stream_acc`, `map_http_error`.
- Coverage tests for cache, pipeline, streaming, structured modules.

### Changed
- **Exception handling**: 16 catch-all `| exn ->` patterns narrowed to specific types across 10 files. `async_agent.ml` now re-raises `Out_of_memory`/`Stack_overflow`/`Sys.Break` (bug fix).

## [0.70.0] - 2026-03-19

### Added
- `.mli` API contracts for 5 core modules: `harness.mli` (170L), `context_reducer.mli` (71L), `eval.mli` (126L), `checkpoint.mli` (62L), `session.mli` (51L). Total .mli count: 56 -> 61.

### Changed
- No new features. Stabilization release for v1.0 preparation.

## [0.69.0] - 2026-03-19

### Added
- **Provider Registry** (`Provider_registry`): extensible provider catalog with `register`/`unregister`/`find`/`available`/`find_capable`. Pre-populated with 5 known providers (llama, claude, gemini, glm, openrouter). Formalizes the hardcoded `known_providers` list from `Cascade_config`.
- **Capability Filter** (`Capability_filter`): composable predicates for capability-aware provider selection. `requires_tools`, `requires_streaming`, `requires_reasoning`, `requires_all`/`requires_any` combinators.

## [0.68.1] - 2026-03-19

### Fixed
- **Guardrails_async**: fix Eio cancellation swallowing — `try ... with _ -> ()` replaced with dedicated `Eio.Switch.run`. Removed unused `~sw` parameter from `run_input`/`run_output`/`guarded` (breaking API change, pre-v1.0).
- **Builder**: add `max_cost_usd >= 0.0` validation in `build_safe`. Negative budget no longer silently triggers `CostBudgetExceeded`.

### Added
- `runtime.mli`: public API contract for wire protocol types. Documents collaboration field migration to `Collaboration.t`. (v0.66 formalization)

## [0.68.0] - 2026-03-19

### Added
- **Eval baseline** (`Eval_baseline`): golden-file JSON comparison for regression detection. `save`/`load`/`compare` with tolerance-based metric diffs. `pass_at_k` metric. (#v0.68)
- **Eval report** (`Eval_report`): structured report combining baseline comparison, harness verdicts, and pass@k. JSON + human-readable output. (#v0.68)

## [0.67.0] - 2026-03-19

### Added
- **Async guardrails** (`Guardrails_async`): parallel input/output validation via `Eio.Fiber.all`. `input_validator`/`output_validator` types. `guarded` combinator gates LLM call on input validation, runs output validators post-response. (#v0.67)

## [0.65.0] - 2026-03-19

### Added
- **Working memory** (`Memory`): 3-tier facade over `Context.t`. Scratchpad (per-turn), Working (cross-turn), Long_term (external callback). `store`/`recall`/`forget`/`promote`. Fallback recall across tiers. (#v0.65)

## [0.62.0] - 2026-03-19

### Added
- **Cost tracker** (`Cost_tracker`): USD budget enforcement via `agent_config.max_cost_usd`. `check_budget` returns `CostBudgetExceeded` when exceeded. Structured `cost_report` with per-call averages.
- **Context offload** (`Context_offload`): large tool results (>threshold) written to filesystem, replaced with path + preview. Fail-open: on write failure, original content preserved.
- `Error.CostBudgetExceeded` agent error variant with `spent_usd`/`limit_usd` fields.
- `Builder.with_max_cost_usd` for chainable agent configuration.
- `agent_config.max_cost_usd: float option` field.

### Changed
- `Agent.run_loop` now checks cost budget alongside token budget before each turn.

## [0.61.0] - 2026-03-19

### Added
- `agent_config.initial_messages`: seed agent conversations with prior history on first run. (#214)
- **Streaming cascade** (`Complete.complete_stream_cascade`, `Cascade_config.complete_named_stream`): multi-provider streaming with failover. Failover on connection/HTTP errors before stream starts; committed once SSE begins. No mid-stream resume, no caching.

## [0.60.0] - 2026-03-19

### Added
- **MCP HTTP transport**: unified `Mcp.managed` type with `transport` variant (Stdio | Http). JSON config auto-detects via `"url"` key. (#209)
- `Agent_config.to_builder` connects MCP servers at build time with optional `~sw ~mgr`. (#209)
- `Checkpoint.t` `working_context` field for MASC context co-storage. Checkpoint version 3 -> 4 (backward compat). (#197)
- `Hooks.OnError` and `Hooks.OnToolError` hook events for LLM/tool failure callbacks. (#198)
- `message.name` and `message.tool_call_id` optional fields + `make_message` constructor. (#201)
- `Event_bus.filter_topic`, `filter_any`, `filter_all` filter combinators. (#199)
- `Swarm_types.swarm_config` `resource_check` and `max_concurrent_agents` fields. Runner enforces both. (#200)
- `Selection` module: `RoundRobin`, `Random`, `Custom` agent selection strategies. (#202)
- `Cascade_config.complete_named` `timeout_sec` parameter. (#208)
- docs: `stateful-tools.md` (closure, context, external patterns). (#203)
- docs: `config-externalization.md` (Env_config pattern). (#204)

### Fixed
- MCP HTTP: use `base_url` directly (no `/mcp` append). (#210)
- MCP HTTP: SSE response parser fallback + JSON-only Accept header. (#210)
- OpenAI SSE streaming: parse `reasoning_content` field. (#207)

## [0.59.0] - 2026-03-18

### Added
- `Cascade_config` module in `llm_provider`: named cascade profiles with JSON hot-reload and discovery-aware health filtering.
  - `parse_model_string`: "provider:model" string to `Provider_config.t` (llama, claude, gemini, glm, openrouter, custom).
  - `load_profile`: JSON config file loading with mtime-based hot-reload.
  - `filter_healthy`: Discovery-integrated local endpoint health filtering.
  - `complete_named`: convenience cascade execution combining config loading, health filtering, and failover.
- 14 new tests for cascade_config (parse, config, health).

## [0.58.0] - 2026-03-18

Version bump only. No functional changes since 0.57.0.

## [0.57.0] - 2026-03-18

### Added
- `Collaboration.t`: 3-Type session split (Session/Collaboration/Orchestrator) for multi-agent shared context. (#173)
- Runtime-Collaboration bridge + `swarm_config` collaboration field. (#190)
- `agent_telemetry` extended with `usage_stats` and `turn_count`. (#180)
- `Structured.extract_with_retry`: total usage tracking across retry attempts. (#181)
- Swarm retry truncation, agent retry, and budget enforcement. (#189)

### Fixed
- Self-review findings across 4 modules. (#174)
- Race semantics + hierarchical fiber limit. (#179)
- `async_agent` cancel now terminates the fiber via sub-switch. (#183)
- Retry jitter + minimum token threshold for prompt caching. (#186)
- Checkpoint history restore + retry jitter + cache threshold. (#188)
- Production hardening: jitter, cache threshold, agent retry, budget, checkpoint. (#187)

### Changed
- Vendor-neutral naming for local LLM provider. (#182)
- Replace model enum with string + `Model_registry`. (#184)
- Vendor-neutral capability naming + resolve model IDs eagerly. (#185)

## [0.56.0] - 2026-03-18

### Added
- `Complete.cache` interface + metrics hooks. (#149)
- `Async_agent`: async agent execution + `raw_trace` `Eio.Mutex` fix. (#150)
- Swarm telemetry bridge: expose Layer 1 trace refs to consumers. (#152)
- `Structured.extractor` API + `run_structured` for Agent-level extraction. (#155)
- `Append_instruction`: dynamic hook-based instruction injection. (#156)
- Anthropic prompt caching control in `llm_provider`. (#157)
- `Structured.extract_with_retry`: validation retry loop. (#158)
- Consumer API: high-level agent execution with telemetry. (#159)
- Consensus + hierarchical orchestration patterns. (#160)
- A2A Client: Agent-to-Agent protocol client. (#161)
- `Agent_typed`: phantom-type lifecycle state machine (experimental). (#162)

### Changed
- Removed Ollama provider. OpenAI-compatible is the only local path. (#151)

## [0.54.0] - 2026-03-18

### Added
- `Types.text_of_response`: extract text from `api_response` for MASC convergence. (#147)

## [0.53.0] - 2026-03-18

### Added
- `Complete.complete_with_retry`: exponential backoff retry for LLM completions. (#144)
- `Complete.complete_cascade`: multi-provider failover with retry per-provider. (#144)
- `Complete.complete_stream`: streaming completion with SSE event accumulation for both Anthropic and OpenAI-compatible providers. (#144)
- `Complete.is_retryable`: classify HTTP errors as retryable (429, 500, 502, 503, 529, network errors). (#144)
- `Provider_bridge`: convert legacy `Provider.config` to `Provider_config.t`. (#144)
- `Provider_bridge.cascade_to_provider_config`: convert legacy cascade to new cascade type. (#144)

## [0.51.0] - 2026-03-18

### Added
- `Autonomy_trace_analyzer`: quantify agent autonomy via diversity/divergence metrics on raw traces. Classifications: Autonomous/Scripted/Random. (#132)
- `Traced_swarm` (lib_swarm): `Runner.run` wrapper with automatic per-agent `Raw_trace` sinks. (#132)
- `autonomy_smoke_cli`: offline trace analysis and live multi-agent smoke testing. (#132)
- `Trajectory` module: Harbor-inspired trajectory recording with sandbox runner. (#136)
- `Repair_dangling_tool_calls` context reducer strategy. (#135)
- `Prune_tool_args` context reducer for ToolUse input truncation. (#127)
- `state_isolation` for subagent parent state control. (#130)
- Default `context_reducer` wired with repair + prune + drop_thinking. (#139)

### Fixed
- `test_raw_trace`: mock server returns plain JSON but pipeline routes to SSE parser. Switched to sync `Agent.run`. (#138)
- Shell argument quoting in examples, path traversal rejection. (#137)
- CI: exclude hanging integration tests from `dune runtest`. (#132)

### Changed
- `autonomy_smoke_cli` refactored to use `Traced_swarm.run_traced` (parallel Decentralized mode). (#132)

## [0.50.0] - 2026-03-18

### Added
- `.mli` API contracts for 13 modules: `builder`, `event_bus`, `log`, `orchestrator`, `capabilities`, `backend_anthropic`, `backend_openai`, `api_common`, `a2a_server`, `a2a_task_store`, `agent_registry`, `mcp_http`, `mcp_session`.
- `examples/swarm_review.ml`: 3-agent Supervisor-mode swarm PR review.
- `examples/codegen_agent.ml`: natural language to OCaml code generation.
- `bin/review_agent.ml`: cmdliner-based `oas-review` CLI with `--provider` selection.
- `test_http_client.ml`: 14 tests for HTTP client pure functions, SSE parsing, content block roundtrips, and Error_domain conversion.
- README: 3-layer architecture diagram, Swarm Engine section, updated module table and stability tiers.
- CHANGELOG: backfilled v0.41.0 through v0.46.0 entries.

### Changed
- `Log.t` fields `trace_id` and `span_id` changed from mutable to immutable (functional update via `with_trace_id`/`with_span_id`).
- README restructured with Layer 1/Layer 2 architecture, Swarm execution example.
- Version bumped to `0.50.0`.

## [0.46.0] - 2026-03-17

### Added
- `agent.mli`: `Agent.t` becomes abstract type with accessor functions (`Agent.state`, `Agent.lifecycle`, `Agent.tools`, `Agent.context`, `Agent.options`, `Agent.net`). (#124)
- `examples/review_agent.ml`: first real OAS agent — code review via gh CLI tool_use. (#123)

### Changed
- Library-internal code uses `Agent_types.t` directly; external consumers go through abstract `Agent.t` and accessor API. (#124)
- `direct_evidence.ml`, `orchestrator.ml`, `builder.ml` updated to use accessor-based patterns. (#124)

## [0.45.0] - 2026-03-17

### Added
- `Http_client` module in `llm_provider/`: `post_sync`, `post_stream` (Eio+cohttp), `read_sse`, `inject_stream_param`. Network errors captured as `http_error` ADT. (#122)

### Changed
- `streaming.ml` delegates HTTP to `Http_client.post_stream` + `read_sse`, removing ~180 lines of inline HTTP/SSE code. (#122)
- `complete.ml` refactored to share HTTP path via `Http_client.post_sync`. (#122)

## [0.44.0] - 2026-03-17

### Added
- Multi-provider SSE streaming: OpenAI-compatible and Ollama now support native SSE streaming (previously `UnsupportedProvider` error). (#122)
- `llm_provider/streaming.ml`: `parse_openai_sse_chunk`, `openai_stream_state`, `openai_chunk_to_events` for OpenAI delta-to-block conversion. (#122)
- `test_streaming_openai.ml`: 15 unit tests for chunk parsing and event conversion. (#122)

### Changed
- `provider.ml`: `supports_native_streaming` enabled for `openai_chat_capabilities`. (#122)
- Ollama Chat redirects to `/v1/chat/completions` for SSE compatibility. (#122)

## [0.43.0] - 2026-03-17

### Added
- Structured A2A errors: `A2a of a2a_error` ADT replaces `A2a of string`. 5 typed variants: `TaskNotFound`, `InvalidTransition`, `MessageSendFailed`, `ProtocolError`, `StoreCapacityExceeded`. (#118)
- Instance-based OTel tracer: each `create`/`create_eio` returns independent tracer with own span stack, preventing misattribution in concurrent agents. (#118)
- `Tool_set` module: O(1) tool lookup wired into agent core. (#114)
- `Provider_intf`: `supports_streaming` wired into pipeline Route. (#114)
- `Error_domain`: pipeline stage context tagging. (#114)
- 150 new tests, coverage 70.78% to 75.45%. (#120)

### Fixed
- `raw_trace.ml` reverted to `Stdlib.Mutex` (Eio context not guaranteed in all call sites). (#119)
- Concurrent mutable state in `transport` and `artifact_service` protected. (#117)
- OS Mutex replaced with `Eio.Mutex` across codebase, version strings unified. (#115)

### Changed
- `sdk_version` bumped to `"0.43.0"`. (#115)

## [0.42.0] - 2026-03-17

### Added
- `agent_sdk_swarm` library (`lib_swarm/`): Layer 2 Swarm Engine with 3 orchestration modes (Decentralized, Supervisor, Pipeline), convergence loop, `Eio.Mutex` state protection. (#112)
- `swarm_types.ml`: `agent_role`, `orchestration_mode`, `convergence_config`, `agent_entry`, `swarm_state`, `swarm_callbacks`, `swarm_result`. (#112)
- `runner.ml`: `eval_metric`, `run_single_pass`, `run` with convergence loop. (#112)
- `test_swarm.ml`: 13 unit tests for swarm types and metric evaluation. (#112)
- `llm_provider` sub-library (`lib/llm_provider/`): shared LLM types for OAS and MASC. (#111)
  - `types.ml`: role, content_block, message, SSE, tool types
  - `capabilities.ml`: provider capability flags + presets
  - `pricing.ml`: per-model cost estimation
  - `error.ml`: provider-level error types

### Changed
- Monolithic `agent_sdk.mli` (3928 lines) removed. Per-module `.mli` files replace it. (#113)
- OAS `types.ml` re-exports `llm_provider` types via `include` for nominal type equality. (#111)

## [0.41.0] - 2026-03-17

### Changed
- **Architecture restructuring**: protocol modules moved to `lib/protocol/`, agent modules to `lib/agent/`. (#109)
  - `(include_subdirs unqualified)` in `lib/dune` for automatic discovery
  - Module names and public API unchanged
- A2A task store: O(1) list operations + bounded in-memory capacity. (#110)

### Added
- Per-module `.mli` files for 6 core modules (initial batch from Phase 1-3). (#109)
- `pipeline.ml` + `pipeline.mli`: 6-stage turn pipeline. (#109)

## [0.40.0] - 2026-03-16

### Added
- v0.36: File-backed A2A task persistence (`a2a_task_store.ml`) — atomic write, validate_task_id, GC
- v0.37: MCP HTTP transport (`mcp_http.ml`) + SSE parser (`sse_parser.ml`) — JSON-RPC 2.0 over HTTP
- v0.38: Agent Registry (`agent_registry.ml`) — Hashtbl-based registry with capability lookup
- v0.39: Approval Pipeline (`approval.ml`) — composable multi-step approval evaluation
- v0.40: SDK CLI (`bin/oas_cli.ml`) + Agent Config (`agent_config.ml`) — cmdliner-based CLI entry point
- 7 new test suites (69 tests, 1,183 LOC)
- Error types: `HttpTransportFailed`, `DiscoveryFailed`

### Changed
- `sdk_version` bumped to `"0.40.0"`

## [0.30.0] - 2026-03-16

### Added
- Skill Registry (`skill_registry.ml`) — runtime skill loading/matching
- Agent Card (`agent_card.ml`) — agent metadata + capability declaration
- ElicitInput handler — interactive user input during agent runs

## [0.28.1] - 2026-03-16

### Fixed
- MCP `read_response` non-tail-recursive loop — stack overflow risk on long sessions
- MCP `mcp_tool_of_json` silent "tool" name fallback — now returns None

### Added
- 101 new tests, coverage 65.32% to 75.14%
- Export missing `[@@deriving yojson, show]` in `agent_sdk.mli`

## [0.28.0] - 2026-03-16

### Changed
- Split `sessions.ml` into `sessions_types.ml` + `sessions_store.ml` + `sessions_proof.ml`

### Added
- Cache cost tracking (`Provider.pricing_for_model`, `estimate_cost`)
- Context reduction strategies (`context_reducer.ml`)

## [0.27.0] - 2026-03-16

### Added
- Prompt caching for all providers (Anthropic `cache_control` ephemeral)
- Provider registry E2E integration tests
- Extracted module tests (`api_dispatch`, `api_ollama`)

## [0.26.0] - 2026-03-16

### Changed
- **agent.ml split** (944→671 lines, 29% reduction): Extracted `Agent_lifecycle` and `Agent_checkpoint` modules. (#90)
- **Unified sync/streaming turns**: `run_turn_core` with `api_strategy` parameter replaces duplicated turn functions (~170 lines dedup). (#90)
- **CI coverage gate**: 65% threshold enforced. (#90)

### Fixed
- **MCP race condition**: `next_id` in `Mcp.send_request` protected by `Eio.Mutex`. (#90)

### Added
- **Provider pricing**: OpenAI (gpt-4o, gpt-4o-mini, gpt-4.1, o3-mini) and local models (ollama/qwen/llama = 0.0). (#90)
- **MCP health/reconnect**: `Mcp.is_alive`, `Mcp.reconnect`, `Mcp.connect_all_best_effort`. (#90)
- **Transport status**: `Transport.status` query. (#90)
- **Provider registry**: Runtime custom provider registration (`register_provider`, `find_provider`). (#90)
- **test_api_dispatch**: 10 dispatch tests. **test_property_advanced**: 20 QCheck property tests. (#90)
- **docs/custom-providers.md**: vLLM example guide. (#90)

## [0.25.1] - 2026-03-16

### Fixed
- **Error classification**: OpenAI-compatible API errors in response body were classified as `NetworkError` (retryable) instead of `InvalidRequest` (non-retryable). Added `Openai_api_error` exception with correct routing in `Api.create_message`. (#86)
- **Crash on unexpected JSON**: `api_ollama.ml` used `assert false` for unreachable branch, which would crash with `Assert_failure` if triggered. Replaced with descriptive `failwith`. (#86)
- **Silent exception in worker thread**: `runtime_server.ml` raised `Failure` inside `Eio.Switch.run`, losing the error in the worker thread. Changed to `Result` propagation. (#86)

### Added
- **`tool_choice: None_`**: Disables tool use for a turn. Serializes to `{"type":"none"}` (Anthropic) / `"none"` (OpenAI). (#86)
- **`disable_parallel_tool_use`**: Config field to force sequential tool execution. Maps to `tool_choice.disable_parallel_tool_use` (Anthropic) / `parallel_tool_calls: false` (OpenAI). (#86)
- **`yojson` derivation** for `Sessions`, `Raw_trace`, and `Tool` types. (#87)
- **Makefile** with `make test`, `make coverage`, `make clean` targets. (#85)

## [0.25.0] - 2026-03-16

### Added
- **`Agent_turn` module** (new): Common turn logic extracted from `agent.ml`. Provides `prepare_turn`, `accumulate_usage`, `update_idle_detection`, `apply_context_injection`, `check_token_budget`, `make_tool_results`, and `filter_valid_messages`.

### Changed
- **Streaming path feature parity**: `run_turn_stream_with_trace` now includes `BeforeTurnParams` hook, `apply_turn_params`, `extra_system_context`, `tool_filter_override`, and `context_injector`.
- `agent.ml` reduced by ~50 lines through delegation to `Agent_turn`.

### Added (v0.25.0-rc)
- **Test harness framework** (`Harness`): 6-type pluggable verification — Behavioral, Adversarial, Performance, Regression, Swiss Cheese (multi-layer), Composability.
- **Provider mock** (`Provider_mock`): network-free scripted responses with cycling, convenience builders for text/tool_use/thinking responses.
- **Per-turn parameter adjustment** (`Hooks.turn_params`, `BeforeTurnParams`): hooks can adjust temperature, thinking_budget, tool_choice, tool_filter per turn via `AdjustParams` decision. Parameters revert after each API call.
- **Reasoning extraction** (`Hooks.extract_reasoning`): extracts thinking blocks, detects uncertainty markers, identifies tool selection rationale.
- **Dynamic context strategy** (`Context_reducer.Dynamic`): select windowing strategy at runtime based on turn count and message state.
- **Conditional orchestration** (`Orchestrator.conditional_plan`): `Branch`, `Loop`, `Sequence`, `Cond_parallel` with route conditions (`Always`, `ResultOk`, `TextContains`, `And`, `Or`, `Not`).
- **Context scope isolation** (`Context.isolated_scope`): `create_scope` with `propagate_up`/`propagate_down` key control for sub-agent delegation.

## [0.24.0] - 2026-03-16

### Added
- **Cascade failover** (`Provider.cascade`): multi-provider failover with primary + fallback list. Retry-aware cascade with `Retry.with_cascade`.
- **Idle detection**: fingerprint-based tool call repetition detection. Configurable `max_idle_turns` with `OnIdle` hook event and `IdleDetected` error.
- **Context compaction** (`Context_reducer`): 6 strategies — `Keep_last_n`, `Token_budget`, `Prune_tool_outputs`, `Merge_contiguous`, `Drop_thinking`, `Compose`. Turn-boundary-aware grouping preserves ToolUse/ToolResult pairs.
- **Context injection** (`Hooks.context_injector`): post-tool-execution hook that updates `Context` key-value store and appends extra messages to the conversation.
- **Cost tracking** (`Provider.pricing_for_model`, `Provider.estimate_cost`): per-model pricing with cumulative `estimated_cost_usd` in `usage_stats`.
- `test_bug_hunt.ml`: 7 bug candidate reproduction and fix verification tests.
- `test_e2e_v024.ml`: 5 end-to-end integration scenarios against live local LLM (gated behind `LLAMA_LIVE_TEST=1`).

### Fixed
- **B1 CRITICAL**: `context_injector` exception crashed the tool loop. Wrapped in `try-with`; exceptions are caught and logged silently.
- **B2 HIGH**: `create_message_cascade` with `clock=None` skipped all fallback providers. Fallbacks are now tried sequentially on retryable errors.
- **B3 HIGH**: Injected `extra_messages` could violate role alternation. Added role validation that drops messages creating same-role adjacency.
- **B4 HIGH**: `Token_budget` strategy returned empty message list when budget was smaller than the most recent turn. Added guard that always keeps the last turn.
- **B5 MEDIUM**: Idle detection failed for empty-empty fingerprint comparison (`[] <> []` = false). Changed `last_tool_calls` from `list` to `option` to distinguish "not yet set" from "empty set".
- **B6 MEDIUM**: `Drop_thinking` replaced thinking-only messages with `Text ""`. Changed to drop the entire message instead of inserting empty text.

### Changed
- `Agent.t.last_tool_calls`: internal type changed from `tool_call_fingerprint list` to `tool_call_fingerprint list option` (not in public API).

## [0.23.0] - 2026-03-15

### Breaking
- `Agent.t` is now an abstract type. Direct field access (`agent.state`, `agent.tools`, etc.) is replaced by accessor functions: `Agent.state`, `Agent.lifecycle`, `Agent.tools`, `Agent.context`, `Agent.options`, `Agent.net`.
- `test_add_message` test removed (external mutation of agent state is no longer possible).

### Migration from 0.22.x

`Agent.t` field access must be replaced with accessor functions:

```ocaml
(* Before (0.22.x) *)
let state = agent.state in
let tools = agent.tools in
let ctx = agent.context in

(* After (0.23.0) *)
let state = Agent.state agent in
let tools = Agent.tools agent in
let ctx = Agent.context agent in
```

`Builder.build` still works but emits a deprecation warning. Switch to `build_safe` for validation:

```ocaml
(* Before *)
let agent = Builder.build builder in

(* After *)
match Builder.build_safe builder with
| Ok agent -> (* use agent *)
| Error err -> Printf.eprintf "Config error: %s\n" (Error.to_string err)
```

### Added
- `Agent.state`, `Agent.lifecycle`, `Agent.tools`, `Agent.context`, `Agent.options`, `Agent.net` accessor functions.
- `Builder.build_safe : t -> (Agent.t, Error.sdk_error) result` with validation:
  - `max_turns > 0`
  - `max_tokens > 0`
  - `thinking_budget` requires `enable_thinking = true`
- `Error.InvalidConfig` variant for configuration validation errors.
- CI pipeline: GitHub Actions with OCaml 5.1.x + 5.4.x matrix, bisect_ppx coverage, odoc, version-check.
- `examples/` directory with 6 examples (3 moved from `bin/`, 3 new).
- `CONTRIBUTING.md` with build instructions, code style, PR expectations.
- Module stability tiers in README (Stable / Evolving / Experimental).

### Deprecated
- `Builder.build` -- use `Builder.build_safe` for validated construction.
- `Provider.local_qwen` -- use `Provider.Local` constructor directly.
- `Provider.local_mlx` -- use `Provider.Local` constructor directly.

### Changed
- README restructured for third-party onboarding: Installation, Quickstart, Provider table, stability tiers.
- Demo executables moved from `bin/` to `examples/`.
- Version consistency enforced by CI (dune-project == agent_sdk.ml).

## [0.22.0] - 2026-03-14

### Added
- hook lifecycle evidence in direct raw traces:
  - `hook_invoked` records
  - `post_tool_use_failure` hook event
- session/proof getters:
  - `Sessions.get_hook_summary`
  - `Sessions.get_tool_catalog`
- `proof_bundle` now includes:
  - `hook_summary`
  - `tool_catalog`

### Changed
- direct-agent conformance summaries now include hook event and tool catalog counts.
- direct evidence persists a `tool-catalog` artifact for consumer-safe tool contract reads.
- raw trace summaries now expose hook counts and hook names.

## [0.21.0] - 2026-03-14

### Added
- `Direct_evidence` stable consumer getters:
  - `get_proof_bundle`
  - `get_conformance`
- `Tool.descriptor_to_yojson`
- richer shell/tool descriptor fields:
  - `chaining_allowed`
  - `redirection_allowed`
  - `pipes_allowed`
  - `examples`

### Changed
- direct-agent worker summaries now expose stable identity and lifecycle fields:
  - `worker_id`
  - `runtime_actor`
  - `primary_alias`
  - `accepted_at`
  - `ready_at`
  - `first_progress_at`
- runtime participants backfill the same identity/lifecycle vocabulary for summary-first consumers.
- `Conformance.summary` now includes latest worker status, aliases, and resolved runtime/model.
- `Conformance.check.code` now includes direct-evidence and identity/runtime consistency failures.

## [0.20.0] - 2026-03-14

### Added
- `Direct_evidence` module for direct-agent proof bundle materialization:
  - `persist`
  - `get_worker_run`
  - `run_conformance`
- `Agent.lifecycle_snapshot` for direct-agent lifecycle status visibility.
- `Tool` minimal descriptor surface:
  - `descriptor`
  - optional shell constraints
  - optional workdir policy hint
- machine-stable conformance failure codes on `Conformance.check.code`
- `oas_direct_conformance_demo` executable

### Changed
- direct-agent evidence can now be written into the same session-scoped runtime store layout that `Sessions.get_proof_bundle` expects.
- `Sessions.worker_run` now carries `role` and `aliases`.
- direct-agent conformance reuses the same `Sessions` and `Conformance` path instead of requiring consumer-side reconstruction.

## [0.19.0] - 2026-03-14

### Added
- Consumer-safe worker lifecycle surface:
  - `Sessions.get_latest_accepted_worker_run`
  - `Sessions.get_latest_ready_worker_run`
  - `Sessions.get_latest_running_worker_run`
  - `Sessions.get_latest_completed_worker_run`
  - `Sessions.get_latest_failed_worker_run`
  - `Sessions.get_latest_validated_worker_run`
- `worker_run` now exposes lifecycle and runtime selection metadata:
  - `status`
  - `requested_provider`
  - `requested_model`
  - `resolved_provider`
  - `resolved_model`
  - `last_progress_at`
- `proof_bundle` now carries:
  - `latest_accepted_worker_run`
  - `latest_ready_worker_run`
  - `latest_running_worker_run`
  - `latest_completed_worker_run`
- Conformance checks now cover lifecycle-oriented consistency:
  - latest accepted/ready/running/completed ordering
  - lifecycle timestamp monotonicity
  - resolved runtime presence consistency

### Changed
- Runtime participants persist requested and resolved provider/model metadata into session state.
- Runtime telemetry now records resolved provider/model for worker live/completed/failed events.
- Runtime store writes session/proof/evidence files atomically to reduce resume/read races on background consumers.
- `oas_conformance_demo` now exposes latest worker lifecycle ids in its summary output.

## [0.18.0] - 2026-03-14

### Added
- Harness-level `Conformance` module:
  - `Conformance.check`
  - `Conformance.report`
  - `Conformance.run`
- Deterministic conformance checks over `Sessions.get_proof_bundle` covering:
  - raw trace shape consistency
  - validated worker count consistency
  - latest worker / latest validated worker / latest failed worker consistency
  - trace capability consistency
  - validated worker raw-capability guarantees
- `oas_conformance_demo` executable for generating a machine-readable conformance report from a mock runtime session.

### Changed
- `0.18.0` treats `proof_bundle` as the canonical verifier input for session-level harness conformance.
- Consumers can now validate a session with a single `Conformance.run` call instead of re-assembling their own pass/fail logic around proof bundles.

## [0.17.0] - 2026-03-14

### Added
- Session-level worker-run evidence getters for summary-first consumers:
  - `Sessions.get_worker_runs`
  - `Sessions.get_latest_worker_run`
  - `Sessions.get_latest_completed_worker_run`
  - `Sessions.get_latest_failed_worker_run`
- Worker-run summaries now expose:
  - `worker_run_id`
  - `agent_name`
  - `trace_capability`
  - `validated`
  - `tool_names`
  - `final_text`
  - `stop_reason`
  - `error`
  - `started_at`
  - `finished_at`
- Raw trace validation now includes consumer-friendly verdict details:
  - `paired_tool_result_count`
  - `has_file_write`
  - `verification_pass_after_file_write`
  - `final_text`
  - `tool_names`
  - `stop_reason`
  - `failure_reason`

### Changed
- `Sessions.get_proof_bundle` now carries worker-run oriented summary fields:
  - `worker_runs`
  - `latest_worker_run`
  - `latest_validated_worker_run`
  - `latest_failed_worker_run`
  - `validated_worker_runs`
  - `raw_trace_run_count`
  - `validated_worker_run_count`
  - `trace_capabilities`
- Runtime participants persist `provider` and `model` into session state so worker evidence can be read without reconstructing it from raw records.
- Runtime mock workers now emit a minimal raw trace so dashboard-style consumers can use the same summary/validation surfaces as direct-agent runs.

## [0.16.0] - 2026-03-14

### Added
- Consumer-safe evidence hardening on top of `0.15.0`:
  - `Sessions.get_latest_raw_trace_run`
  - `Sessions.get_raw_trace_summaries`
  - `Sessions.get_raw_trace_validations`
- Proof bundle now carries validated summary shape:
  - `latest_raw_trace_run`
  - `raw_trace_summaries`
  - `raw_trace_validations`
  - `capabilities`

### Changed
- `Raw_trace` can now be created directly under a session-scoped `raw-traces/` directory with `create_for_session`.
- `Sessions.get_proof_bundle` is now sufficient as a summary-first evidence entrypoint for consumers that should avoid raw path parsing by default.
- `Builder.with_raw_trace` and top-level `create_agent ?raw_trace` remain available for direct-agent consumers.

## [0.15.0] - 2026-03-14

### Added
- Session-scoped raw trace evidence surface:
  - `Raw_trace.create_for_session`
  - `Raw_trace.read_runs`
  - `Raw_trace.summarize_run`
  - `Raw_trace.validate_run`
- `Sessions` raw trace getters:
  - `Sessions.get_raw_trace_runs`
  - `Sessions.get_raw_trace_run`
  - `Sessions.get_raw_trace_records`
  - `Sessions.get_raw_trace_summary`
  - `Sessions.validate_raw_trace_run`
- `Builder.with_raw_trace` and optional `raw_trace` support in top-level `create_agent`.

### Changed
- `Sessions.get_proof_bundle` now includes `structured_telemetry` and discovered `raw_trace_runs`.
- Session-scoped direct agent runs can now be discovered and validated without parsing `Checkpoint.messages`.
- Runtime store now reserves a stable `raw-traces/` directory under each session root.

## [0.14.0] - 2026-03-14

### Added
- Append-only agent-level raw trace capability for direct `Agent` runs:
  - `Raw_trace.create`
  - `Raw_trace.read_all`
  - `Raw_trace.read_run`
  - `Agent.last_raw_trace_run`
- `Agent.options.raw_trace` for attaching a JSONL raw trace sink to `run` / `run_stream` / resumed agents.
- Raw trace record types:
  - `run_started`
  - `assistant_block`
  - `tool_execution_started`
  - `tool_execution_finished`
  - `run_finished`

### Changed
- Direct `Agent.run_stream` tool loops can now emit immutable audit traces without changing `Checkpoint`, which remains the latest-state resume mechanism.
- `Builder` now carries the new `Agent.options.raw_trace` field with a default of `None`.

## [0.13.0] - 2026-03-14

### Added
- Structured telemetry schema alongside the legacy string-based telemetry surface:
  - `Sessions.structured_event_count`
  - `Sessions.structured_telemetry_step`
  - `Sessions.structured_telemetry`
  - `Sessions.get_telemetry_structured`
- Telemetry artifacts now include normalized `event_name` counts and per-step structured fields such as actor, role, provider, model, checkpoint label, and outcome.

### Changed
- Telemetry JSON keeps the legacy `kind` and raw `event_counts` output, but now also emits normalized event-name fields for stable downstream verification.
- Runtime tests now validate structured telemetry metadata rather than relying only on `kind` string substring checks.

## [0.12.0] - 2026-03-14

### Added
- Official session proof-bundle read APIs:
  - `Sessions.get_telemetry`
  - `Sessions.get_evidence`
  - `Sessions.get_proof_bundle`
- Typed proof-bundle surface in `Sessions` for telemetry step counts, evidence files, and combined session/report/proof retrieval.

### Changed
- Runtime proof and evidence artifacts can now be consumed through the SDK without relying on raw artifact-name lookups.
- Runtime tests now verify the public proof-bundle getters rather than parsing evidence JSON ad hoc.

## [0.11.0] - 2026-03-14

### Added
- Provider model-spec and capability registry:
  - `Provider.capabilities`
  - `Provider.model_spec`
  - `Provider.capabilities_for_model`
  - `Provider.capabilities_for_config`
  - `Provider.model_spec_of_config`
- Scoped cross-turn state in `Context`:
  - scopes: `App`, `User`, `Session`, `Temp`, `Custom`
  - helpers: `delete`, `snapshot`, `scoped_key`, `get_scoped`, `set_scoped`, `delete_scoped`, `keys_in_scope`, `diff`
- Artifact service and session artifact access:
  - `Artifact_service.list`
  - `Artifact_service.get_text`
  - `Sessions.list_artifacts`
  - `Sessions.get_artifact_text`
- MCP expansion beyond tools:
  - `Mcp.list_resources`
  - `Mcp.read_resource`
  - `Mcp.list_prompts`
  - `Mcp.get_prompt`
- Trace-driven evaluation:
  - `Trace_eval.summarize`
  - `Trace_eval.evaluate`
  - `Trace_eval.evaluate_flushed`
- Runtime evidence bundle generation:
  - telemetry JSON artifact
  - telemetry markdown artifact
  - evidence JSON artifact with persisted file hashes
- `oas_proof_demo` executable for reproducible non-test proof bundles

### Changed
- OpenAI-compatible request shaping is now capability-gated instead of relying on scattered provider/model conditionals.
- Qwen-only request fields (`top_k`, `min_p`, `chat_template_kwargs.enable_thinking`) are omitted for generic OpenAI-compatible providers.
- Checkpoints now persist agent context and restore it through `Agent.resume` and `Session.resume_from`.
- Runtime artifact metadata is now first-class:
  - `artifact_id`
  - `mime_type`
  - `size_bytes`
- Runtime proof checks are stronger and deterministic:
  - `terminal_event`
  - `seq_contiguous`
  - `artifact_ids_unique`

### Fixed
- Runtime finalize now persists telemetry/evidence artifacts even after the session has entered a terminal phase.
- MCP output truncation is budget-aware for tool and resource text responses.
- Session-level proof/demo evidence now includes artifact manifests with file sizes and MD5 digests.

## [0.10.0] - 2026-03-13

### Added
- Harness-first runtime layer with bundled `oas-runtime` subprocess, file-backed session journal, report/proof generation, and typed runtime protocol
- High-level `query` / `Client` surface on top of the runtime harness, with low-level `runtime_query` / `Runtime_client` escape hatches
- Session helpers for listing, reading, renaming, and tagging persisted runtime sessions
- `Contract` module for explicit runtime awareness, trigger context, tool grants, MCP allowlists, and skill bundles
- Builder helpers for contract-aware assembly: `with_contract`, `with_skill`, `with_skills`, `with_tool_grants`, `with_mcp_tool_allowlist`
- Long-lived interactive client semantics:
  - partial message surfacing (`Partial_message`)
  - progressive receive (`receive_messages`, `receive_response`, `wait_for_messages`)
  - resume/attach via `session_id` / `resume_session`
  - persisted session settings across reconnects

### Changed
- Default high-level local-first path is now `provider = Some "local-qwen"` and `model = Some "qwen3.5"` for `llama.cpp`-style local runtimes
- Runtime transport now uses a background reader thread to handle response, control, and event envelopes
- `set_model` now persists through runtime session updates instead of mutating SDK-local state only
- Builder now compiles explicit contracts into composed system prompts, filtered local tools, filtered MCP tool surfaces, and reserved context metadata

### Fixed
- Runtime protocol version mismatch is detected during initialize handshake
- Blank protocol lines are ignored on both SDK and runtime sides instead of surfacing as JSON parse failures
- Runtime tests now reflect asynchronous worker completion semantics rather than assuming synchronous spawn completion

## [0.9.1] - 2026-03-11

### Changed (breaking)
- `Types.tool_choice_of_json`: `(_, string) result` → `(_, Error.sdk_error) result`
- `Provider.resolve`: `(_, string) result` → `(_, Error.sdk_error) result`
- `.mli`: `module Retry : sig ... end` and `module Error : sig ... end` → module aliases for type equality

### Fixed
- `Checkpoint.of_json`: removed redundant `Result.map_error` bridge for `tool_choice_of_json` (now returns `sdk_error` directly)
- `Api.create_message`, `Streaming.create_message_stream`: pass through `Provider.resolve` error directly instead of re-wrapping

### Migration
- All SDK functions now return `(_, Error.sdk_error) result` — structured error migration is complete
- `Structured.schema.parse` retains `('a, string) result` (user-provided parser; wrapped to `sdk_error` at boundary)

## [0.9.0] - 2026-03-11

### Added
- `Error` module: 2-level structured error type hierarchy (`sdk_error`) replacing `(_, string) result` across the SDK
  - 7 domain-specific inner types: `api_error`, `agent_error`, `mcp_error`, `config_error`, `serialization_error`, `io_error`, `orchestration_error`
  - `agent_error.TokenBudgetExceeded` with `{ kind; used; limit }` for structured budget checks
  - `Error.to_string` for human-readable messages, `Error.is_retryable` for retry decisions
  - `Error.api_error` is a type alias for `Retry.api_error` (zero-cost reuse)

### Changed (breaking)
- `api.ml` split into `api_common.ml`, `api_anthropic.ml`, `api_openai.ml`, `api_ollama.ml` — public API (`Api.create_message`) unchanged
- `agent.ml` split: tool execution extracted to `agent_tools.ml`, handoff helpers to `agent_handoff.ml` — public API unchanged
- `Mcp_bridge` module removed from public API — use `Mcp.connect` and `Mcp.to_tools` instead
- 33 function signatures changed from `(_, string) result` to `(_, Error.sdk_error) result` across 14 modules
- `Api.create_message`: no longer flattens `Retry.api_error` to string; returns `Error (Api err)` preserving the structured error
- `Agent.check_token_budget`: returns `Error.sdk_error option` instead of `string option`
- `Streaming.create_message_stream`: returns `Error.sdk_error` with `Config (UnsupportedProvider _)` for non-Anthropic providers
- `Orchestrator.task_result.result`: error type changed from `string` to `Error.sdk_error`
- `Event_bus.AgentCompleted.result`: error type changed from `string` to `Error.sdk_error`
- `Checkpoint_store.create`: `Eio.Fs.dir_ty Eio.Path.t -> t` changed to `-> (t, Error.sdk_error) result`
- `Checkpoint_store.list`: `t -> string list` changed to `-> (string list, Error.sdk_error) result`

### Fixed
- Removed string prefix matching anti-pattern in `agent.ml` (was guessing error types from message text)
- `Api.create_message` no longer discards structured error information from retry layer
- `Checkpoint_store.create`: now returns result instead of silently ignoring `mkdirs` failure
- `Checkpoint_store.list`: now returns result instead of silently returning `[]` on `read_dir` failure
- `Retry.classify_error`: narrowed `with _ ->` to `Yojson.Json_error | Type_error` so non-JSON exceptions propagate

### Migration
- Tool handler interfaces (`Tool.t`) retain `(string, string) result` (user-provided handlers, not SDK errors)
- Use `Error.to_string` where string representation is needed

### Internal
- Test coverage baseline: 63.72% (1491/2340 points, bisect_ppx)

## [0.8.3] - 2026-03-11

### Changed
- `Mcp.t`: removed `mutable tools` field — `list_tools` is now pure, `to_tools` takes explicit `mcp_tool list` argument

### Changed (breaking)
- `Mcp.to_tools`: signature changed from `t -> Tool.t list` to `t -> mcp_tool list -> Tool.t list`

### Added (tests)
- `test_mcp_session.ml`: server_spec roundtrip, JSON serialization with env, reconnect_all empty case
- `test_otel.ml`: in-progress span JSON, flush/reset state, concurrent span creation

## [0.8.1] - 2026-03-11

### Fixed
- `Event_bus`: replaced raw `lock`/`unlock` with `Eio.Mutex.use_rw ~protect:true` and `use_ro` for exception safety
- `Mcp_session.reconnect_all`: return type now `Mcp.managed list * (info * string) list` to preserve error messages from failed connections
- `Checkpoint.of_json`: malformed `mcp_sessions` (non-array, non-null) now returns `Error` instead of silently defaulting to `[]`
- `test_event_bus.ml`: added missing `Eio_main.run` wrappers to 4 tests that used Eio primitives without a domain context

### Changed (breaking)
- `Mcp_session.reconnect_all`: return type changed from `Mcp.managed list * info list` to `Mcp.managed list * (info * string) list` — callers matching on the second element need to destructure the `(info, error_msg)` pair
- `Event_bus.filter_agent`: `Custom` events now pass through all agent-scoped filters (previously silently dropped because `Custom` had no `agent_name` field)

## [0.8.0] - 2026-03-11

### Added
- `Agent.clone`: deep-copy agent state with fresh or copied context, shared net/tools/options
- `Context.copy`: shallow-copy context hashtable
- `Structured.extract_stream`: SSE streaming for structured output extraction with schema validation
- `Event_bus`: typed publish/subscribe for agent lifecycle events (Eio.Stream per subscriber)
  - 7 event types: AgentStarted, AgentCompleted, ToolCalled, ToolCompleted, TurnStarted, TurnCompleted, Custom
  - 3 built-in filters: `filter_agent`, `filter_tools_only`, `accept_all`
  - Integrated into Agent.options, Orchestrator.config, Builder.with_event_bus
- `Mcp_session`: persistent MCP session capture/restore for checkpoint/resume cycles
  - `capture`/`capture_all`: serialize server specs and discovered tool schemas
  - `reconnect_all`: re-establish MCP connections from saved info
- `Checkpoint` v1 to v2 migration: added `mcp_sessions` field with backward compatibility
- `Mcp.managed`: added `spec` field to preserve original server_spec for reconnection

### Changed
- Agent: `run_turn`, `run_turn_stream`, `find_and_execute_tool` publish events to event_bus
- Orchestrator: `run_task` publishes AgentStarted/AgentCompleted events
- Version bump: 0.7.1 -> 0.8.0 (27 modules, 584 tests)

## [0.7.1] - 2026-03-11

### Fixed
- `Otel_tracer`: all mutable span operations (`start_span`, `end_span`, `add_event`, `add_attrs`, `flush`, `reset`) protected with `Stdlib.Mutex`
- `Otel_tracer.start_span`: ID generation moved outside critical section to reduce lock contention

### Changed
- README: architecture table expanded to 25 modules, version synced to 0.7.1
- `Mcp.initialize`, `Mcp_bridge.initialize`: client_version updated to 0.7.1
- CHANGELOG: added `[0.7.0]` section for previously undocumented changes

### Removed
- `Random.self_init()` calls in `Session` and `Otel_tracer` (unnecessary on OCaml 5.x domain-local PRNG)

## [0.6.0] - 2026-03-11

### Added
- `Agent.resume`: restore agent from a `Checkpoint.t` with messages, usage, turn count, model, and config
- `Session.resume_from`: create a new session linked to a checkpoint's session_id via `resumed_from`
- MCP server lifecycle management: `Mcp.server_spec`, `Mcp.managed`, `Mcp.connect_and_load`, `Mcp.connect_all`, `Mcp.close_all`

### Changed
- MCP client: replaced self-contained implementation with `mcp-protocol-sdk` v0.10.0 wrapper (PR #29)
- `Mcp_bridge`: added Eio-native MCP client bridge module (PR #24)
- Version bump: 0.5.0 -> 0.6.0

## [0.5.0] - 2026-03-10

### Added
- `Tracing` module: observability via `TRACER` module type with `Null_tracer` (zero-allocation no-op) and `Fmt_tracer` (stderr output)
- `with_span` exception-safe RAII pattern for span lifecycle management
- Agent API calls and tool executions wrapped with tracing spans
- Human-in-the-Loop: `ApprovalRequired` hook decision variant with `approval_callback` type
- `approval_decision` type: `Approve`, `Reject of string`, `Edit of Yojson.Safe.t`
- `Context_reducer` module: message windowing with turn-boundary grouping
- `keep_last` strategy: retain last N turn groups
- `token_budget` strategy: approximate token-based windowing (4-char heuristic)
- `custom` strategy: user-provided `message list -> message list` function
- `group_into_turns`: respects ToolUse/ToolResult pairing constraint
- `find_and_execute_tool` helper: eliminates code duplication in tool execution

### Changed
- `Agent.t` record: added `tracer`, `approval`, `context_reducer` fields (all optional with defaults)
- `hook_decision` type: added `ApprovalRequired` variant (non-breaking: exhaustive match warning only)
- Context reducer applies as a view before API calls; full history preserved in agent state

### Migration Guide
- `hook_decision` match expressions will emit warning 8 for missing `ApprovalRequired` case. Add the case or use wildcard.
- New `Agent.create` optional params: `?tracer`, `?approval`, `?context_reducer` (all default to no-op/None)

## [0.4.0] - 2026-03-10

### Added
- `Structured` module: typed structured output extraction via tool_use + tool_choice=Tool pattern
- Token budget tracking: `max_input_tokens` and `max_total_tokens` fields in `agent_config`
- Token budget enforcement in agent run loop (per-turn check before API call)
- Property-based tests using QCheck (model/role/param_type round-trip, usage commutativity)
- Test coverage for structured output extraction and token budget logic

### Changed
- **BREAKING**: `MessageStart` and `MessageDelta` SSE event usage type changed from `(int * int) option` to `api_usage option`
- Streaming SSE parser now extracts `cache_creation_input_tokens` and `cache_read_input_tokens` from `message_start` events
- `create_message_stream` accumulates cache tokens in usage stats

### Migration Guide
- `MessageStart { usage = Some (inp, out) }` → `MessageStart { usage = Some { input_tokens; output_tokens; cache_creation_input_tokens; cache_read_input_tokens } }`
- `MessageDelta { usage = Some (inp, out) }` → same pattern
- New `agent_config` fields have `None` defaults (backward compatible for config construction)

## [0.3.2] - 2026-03-10

### Added
- `Session` module for conversation persistence (save/load JSON)
- `Skill` module for reusable agent capability bundles
- `Subagent` module for spawning child agents with isolated context
- Test hardening: 106+ unit tests across 15 test files
- `replace_tool_result` bug fix in `Agent` module

### Changed
- README synced to v0.3.1 feature set (prompt caching status corrected)

## [0.3.1] - 2026-03-10

### Added
- Prompt caching: `cache_system_prompt` config option wraps system prompt with `cache_control` ephemeral
- `api_usage` record type with `cache_creation_input_tokens` and `cache_read_input_tokens` fields
- `usage_stats` accumulates cache token counts across turns

### Changed
- **BREAKING**: `api_response.usage` type changed from `(int * int) option` to `api_usage option`
- **BREAKING**: `add_usage` accepts `api_usage` record instead of two ints
- `usage_stats` cache fields renamed to `total_cache_creation_input_tokens` / `total_cache_read_input_tokens` for consistency
- `create_agent` convenience function now accepts `?cache_system_prompt`

### Known Limitations
- Streaming mode (`create_message_stream`) reports cache tokens as 0. SSE event types still use `(int * int) option` for usage. Full streaming cache support planned for v0.4.0.

## [0.3.0] - 2026-03-05

### Added
- Fleet Orchestration: `Fleet` module with member selection, parallel execution (#747)
- `Handoff` module for multi-agent tool delegation (#747)
- `Context` module for shared key-value state across agents (#747)
- `Guardrails` module with tool filtering (AllowList, DenyList, Custom) and turn limits (#747)
- `Streaming` module with SSE event parsing and usage tracking (#747)
- API retry with exponential backoff and configurable max attempts (#749)

### Changed
- Provider config extended with `max_retries` field (#749)

## [0.2.0] - 2026-03-01

### Added
- Provider abstraction: Anthropic, Local (OpenAI-compatible), OpenAICompat (#730)
- Hook system: `before_api_call`, `after_api_call`, `before_tool_use`, `after_tool_use` (#730)
- Agent loop with tool execution and multi-turn conversation (#730)

## [0.1.0] - 2026-02-11

### Added
- Initial release: Types, API client, basic agent loop

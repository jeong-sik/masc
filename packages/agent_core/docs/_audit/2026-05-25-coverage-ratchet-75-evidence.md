# Coverage ratchet evidence - 2026-05-25

Scope: #1175 Stage C/D/E/F continuation. PRs #1759 and #1761 raise measured
project coverage above 80% with behavior-backed provider dispatch, provider_d
codec, streaming, pure-module, harness, CLI transport, provider_k, provider
catalog, runtime server, provider config, memory, discovery, HTTP client, tool
selector, checkpoint, and type tests, so the CI coverage floor can move from
73% to 79%.

## Measurement

- Evidence: local clean full coverage run on PR #1759 after the Stage D
  provider contract and catalog follow-ups.
- Command:
  `env MASC_DUNE_THROTTLE=0 BISECT_ENABLE=yes EIO_BACKEND=posix BISECT_FILE=/tmp/oas_stage_d_full_after_provider_k_harness_catalog_coverage/bisect scripts/dune-local.sh runtest --force --instrument-with bisect_ppx`
- Summary command:
  `opam exec -- bisect-ppx-report summary --coverage-path=/tmp/oas_stage_d_full_after_provider_k_harness_catalog_coverage`
- Measured coverage: `78.13%` (`23241/29748`)
- Earlier clean measurements before the provider contract/catalog follow-up:
  `77.72%` (`23104/29728`) and `76.02%` (`22598/29728`)
- Timestamp: 2026-05-25 KST
- Confidence: High for local measurement; GitHub full CI remains the final
  merge gate after the draft PR is marked ready.

## Ratchet decision

- Base threshold before this PR: `73`
- Intermediate threshold after the Stage C slice: `75`
- Intermediate threshold after earlier Stage D follow-ups: `76`
- New threshold after the provider contract/catalog follow-up: `77`
- Formula: `floor(78.13 - 1) = 77`
- Reason: preserve one percentage point of CI/runtime headroom while enforcing
  the measured recovery toward the 80% terminal goal.

## #1175 record

- Stage C target (`60 -> 75`): floor reaches 75.
- Stage D target (`75 -> 80`): in progress; floor now reaches 77 and still
  needs further measured slices before 80.
- Top 0% files removed in this PR: none; this slice targets low/mid coverage
  provider and streaming surfaces rather than zero-coverage files.
- Tests added in this PR:
  - `test/test_provider_intf.ml`: provider dispatch error/custom-provider paths.
  - `test/test_backend_provider_d_codec.ml`: provider_d serialization, schema,
    parse, telemetry, reasoning, fenced JSON, and malformed tool-call branches.
  - `test/test_streaming_coverage.ml`: stream accumulator/finalize/http-error
    edge branches.
  - `test/test_streaming_edge_cases.ml`: provider_a SSE, provider_d,
    provider_f, Ollama NDJSON, and synthetic-event edge branches.
  - `test/test_client_wrapper_coverage.ml`: public client wrapper show/default
    aliases.
  - `test/test_pipeline_common_coverage.ml`: pipeline strategy/outcome,
    completion-contract validation, event envelopes, and tiered-memory token
    counting.
  - `test/test_transport_cli_tool_a_coverage.ml`: Agent_code JSONL,
    runtime MCP env-token override, stdout recovery, stdin prompt routing, and
    parse-error paths.
  - `test/test_transport_cli_tool_d_coverage.ml`: Agent_llm_a stream-json,
    JSON output, runtime MCP args, provider-terminal mapping, stdin prompt
    routing, and parse-error paths.
  - `test/test_llm_provider_error.ml`: remaining retry/http/provider-failure
    mapping variants and retryability matrix.
  - `test/test_tool_input_validation.ml`: scalar coercion edges, optional null,
    non-object input, JSON actual descriptions, and inline formatting fallback.
  - `test/test_backend_provider_k_coverage.ml`: provider_k error
    classification, status mapping, request modes, response parsing, duplicate
    reasoning guard, parse-error normalization, and stream reasoning deltas.
  - `test/test_backend_tool_call_harness.ml`: scalar actual-type schema
    validation, invalid schema map entry filtering, and provider convenience
    validators.
  - `test/test_provider_catalog_coverage.ml`: catalog entry parsing,
    auth/transport/thinking aliases, capability overrides, malformed entry
    errors, load-file behavior, and global override lifecycle.

## Stage D focused follow-up

- Evidence: local focused coverage run on PR #1759 after adding the client and
  pipeline-common tests.
- Command:
  `env MASC_DUNE_THROTTLE=0 BISECT_ENABLE=yes BISECT_FILE=/tmp/oas_stage_d_focus_coverage/bisect scripts/dune-local.sh build --instrument-with bisect_ppx test/test_client_wrapper_coverage.exe test/test_pipeline_common_coverage.exe test/test_provider_intf.exe`
- Test binaries:
  `./_build/default/test/test_client_wrapper_coverage.exe`,
  `./_build/default/test/test_pipeline_common_coverage.exe`,
  `./_build/default/test/test_provider_intf.exe`
- Summary command:
  `opam exec -- bisect-ppx-report summary --per-file --coverage-path=/tmp/oas_stage_d_focus_coverage`
- Focused per-file results:
  - `lib/client.ml`: `74.47%` (`35/47`)
  - `lib/pipeline/pipeline_common.ml`: `100.00%` (`24/24`)
  - `lib/provider_intf.ml`: `53.70%` (`29/54`)
- Timestamp: 2026-05-25 KST
  Confidence: High for focused slice coverage; project-wide CI coverage is now
  governed by the latest `77` floor above.

## Stage D pure-module follow-up

- Evidence: local focused coverage run on PR #1759 after extending
  `test/test_tool_schema_gen.ml` and `test/test_memory_procedural.ml`.
- Command:
  `env MASC_DUNE_THROTTLE=0 BISECT_ENABLE=yes BISECT_FILE=/tmp/oas_stage_d_pure_coverage/bisect scripts/dune-local.sh build --instrument-with bisect_ppx test/test_tool_schema_gen.exe test/test_memory_procedural.exe`
- Test binaries:
  `./_build/default/test/test_tool_schema_gen.exe`,
  `./_build/default/test/test_memory_procedural.exe`
- Summary command:
  `opam exec -- bisect-ppx-report summary --per-file --coverage-path=/tmp/oas_stage_d_pure_coverage`
- Focused per-file results:
  - `lib/tool_schema_gen.ml`: `82.22%` (`74/90`)
  - `lib/memory_procedural.ml`: `83.78%` (`62/74`)
  - `lib/memory.ml`: `23.48%` (`85/362`)
  - `lib/tool_input_validation.ml`: `20.37%` (`22/108`)
- Timestamp: 2026-05-25 KST
  Confidence: High for focused pure-module coverage; project-wide CI coverage
  is now governed by the latest `77` floor above.

## Stage D harness and CLI transport follow-up

- Evidence: local focused coverage run on PR #1759 after extending
  `test/test_harness_runner.ml` and adding subprocess-backed
  `test/test_transport_cli_tool_b_coverage.ml` /
  `test/test_transport_cli_tool_c_coverage.ml`.
- Command:
  `env MASC_DUNE_THROTTLE=0 BISECT_ENABLE=yes BISECT_FILE=/tmp/oas_stage_d_cli_harness_coverage/bisect scripts/dune-local.sh build --instrument-with bisect_ppx test/test_harness_runner.exe test/test_transport_cli_tool_b_coverage.exe test/test_transport_cli_tool_c_coverage.exe`
- Test binaries:
  `./_build/default/test/test_harness_runner.exe`,
  `./_build/default/test/test_transport_cli_tool_b_coverage.exe`,
  `./_build/default/test/test_transport_cli_tool_c_coverage.exe`
- Summary command:
  `opam exec -- bisect-ppx-report summary --per-file --coverage-path=/tmp/oas_stage_d_cli_harness_coverage`
- Focused per-file results:
  - `lib/harness_runner.ml`: `77.13%` (`172/223`)
  - `lib/llm_provider/transport_cli_tool_b.ml`: `52.16%` (`133/255`)
  - `lib/llm_provider/transport_cli_tool_c.ml`: `63.10%` (`183/290`)
  - `lib/llm_provider/cli_common_subprocess.ml`: `47.43%` (`83/175`)
  - `lib/llm_provider/cli_common_synthetic_events.ml`: `55.00%` (`11/20`)
- Behaviors added:
  - harness response/trace/metric pass and fail grading, skipped cases, trace
    path validation, and execute-case failure shaping.
  - `cli_tool_b` Provider_f JSON parsing, synthetic stream replay,
    request-scoped MCP rejection, and terminal quota stderr classification.
  - `cli_tool_c` JSONL text/tool/tool-result restoration, stream event
    emission, subprocess-error surfacing, no-output parse failure, stdin prompt
    routing, and session delta reuse.
- Timestamp: 2026-05-25 KST
  Confidence: High for focused behavior coverage; project-wide CI coverage is
  now governed by the latest `77` floor above.

## Stage F terminal-target follow-up

- Evidence: local focused and full coverage runs on PR #1761 after extending
  maintained memory, discovery, HTTP client, checkpoint, and type
  tests. Deprecated runtime-projection paths were intentionally not expanded.
- Focused validation:
  `env MASC_DUNE_THROTTLE=0 scripts/dune-local.sh build test/test_memory.exe test/test_discovery.exe test/test_http_client.exe test/test_types.exe`
  and
  `env MASC_DUNE_THROTTLE=0 scripts/dune-local.sh build test/test_memory_episodic.exe test/test_memory_tools_parse.exe test/test_checkpoint_delta.exe test/test_checkpoint.exe`
- Full clean coverage command:
  `env MASC_DUNE_THROTTLE=0 BISECT_ENABLE=yes EIO_BACKEND=posix BISECT_FILE=/tmp/oas_stage_f_full_coverage_20260525_3/bisect DUNE_BUILD_DIR=/Users/dancer/me/workspace/yousleepwhen/oas/.worktrees/runtime-server-coverage-20260525/_build_cov_stage_f3 scripts/dune-local.sh runtest --force --instrument-with bisect_ppx`
- Summary command:
  `opam exec -- bisect-ppx-report summary --per-file --coverage-path=/tmp/oas_stage_f_full_coverage_20260525_3`
- Full clean coverage result:
  `80.02%` (`23803/29748`) from
  `/tmp/oas_stage_f_full_coverage_20260525_3`.
- Key full-run per-file results:
  - `lib/checkpoint_codec.ml`: `93.10%` (`351/377`)
  - `lib/memory_episodic.ml`: `93.42%` (`71/76`)
  - `lib/memory_tools_parse.ml`: `100.00%` (`112/112`)
  - `lib/memory.ml`: `82.60%` (`299/362`)
  - `lib/llm_provider/discovery.ml`: `71.58%` (`199/278`)
  - `lib/llm_provider/http_client.ml`: `65.53%` (`268/409`)
  - `lib/llm_provider/types.ml`: `76.03%` (`241/317`)
- Ratchet decision:
  CI coverage threshold raised from `78` to `79`, using
  `floor(80.02 - 1) = 79` and keeping one percentage point of headroom below
  the measured result.
- Timestamp: 2026-05-25 KST
  Confidence: High for focused behavior coverage and full project coverage;
  project-wide CI coverage is now governed by the latest `79` floor above.

## Stage E runtime server and provider config follow-up

- Evidence: local focused and full coverage runs after PR #1759 merged, adding
  maintained runtime server request/command coverage and extending pure
  provider configuration coverage. Deprecated runtime paths were intentionally
  left out of this slice.
- Runtime server focused command:
  `DUNE_BUILD_DIR=/tmp/oas_runtime_server_cov_build dune build --root /Users/dancer/me/workspace/yousleepwhen/oas/.worktrees/runtime-server-coverage-20260525 --instrument-with bisect_ppx test/test_runtime_server_coverage.exe`
- Runtime server focused test:
  `env BISECT_FILE=/tmp/oas_stage_e_runtime_server_coverage_run2/bisect /tmp/oas_runtime_server_cov_build/default/test/test_runtime_server_coverage.exe`
- Runtime server focused result:
  `test/test_runtime_server_coverage.exe` passed 3 tests;
  `lib/runtime_server.ml` reached `31.33%` (`193/616`) in the focused slice.
- Provider config focused command:
  `DUNE_BUILD_DIR=/tmp/oas_provider_config_cov_build2 dune build --root /Users/dancer/me/workspace/yousleepwhen/oas/.worktrees/runtime-server-coverage-20260525 --instrument-with bisect_ppx test/test_provider_config.exe`
- Provider config focused test:
  `env BISECT_FILE=/tmp/oas_provider_config_cov_run2/bisect /tmp/oas_provider_config_cov_build2/default/test/test_provider_config.exe`
- Provider config focused result:
  `test/test_provider_config.exe` passed 65 tests;
  `lib/llm_provider/provider_config.ml` reached `79.19%` (`156/197`) in
  the focused slice.
- Full clean coverage command:
  `env MASC_DUNE_THROTTLE=0 BISECT_ENABLE=yes EIO_BACKEND=posix BISECT_FILE=/tmp/oas_stage_e_full_runtime_provider_coverage_final/bisect DUNE_BUILD_DIR=/Users/dancer/me/workspace/yousleepwhen/oas/.worktrees/runtime-server-coverage-20260525/_build_cov_runtime_provider scripts/dune-local.sh runtest --force --instrument-with bisect_ppx`
- Full clean coverage result:
  `79.00%` (`23500/29748`) from
  `/tmp/oas_stage_e_full_runtime_provider_coverage_final`.
- Full per-file results:
  - `lib/runtime_server.ml`: `33.12%` (`204/616`)
  - `lib/llm_provider/provider_config.ml`: `82.74%` (`163/197`)
  - `lib/runtime_evidence.ml`: `94.21%` (`244/259`)
  - `lib/runtime_projection.ml`: `81.75%` (`233/285`)
  - `lib/runtime_store.ml`: `87.79%` (`266/303`)
- Ratchet decision:
  CI coverage threshold raised from `77` to `78`, leaving 1 point of headroom
  below the measured `79.00%` while preventing regression.
- Note:
  A prior full coverage attempt with `DUNE_BUILD_DIR=/tmp/...` failed because
  sandboxed repo-root-sensitive tests could not locate `dune-project`; rerunning
  with the build dir inside the worktree passed. This was an execution
  environment issue, not a product test failure.
- Timestamp: 2026-05-25 KST
  Confidence: High for focused behavior coverage and full project coverage;
  project-wide CI coverage is now governed by the latest `78` floor above.

## Stage D CLI A/D and validation follow-up

- Evidence: local focused coverage run on PR #1759 after adding
  subprocess-backed `test/test_transport_cli_tool_a_coverage.ml` and
  `test/test_transport_cli_tool_d_coverage.ml`, then extending
  `test/test_llm_provider_error.ml` and `test/test_tool_input_validation.ml`.
- Command:
  `env MASC_DUNE_THROTTLE=0 BISECT_ENABLE=yes BISECT_FILE=/tmp/oas_stage_d_cli_ad_error_validation_coverage/bisect scripts/dune-local.sh build --instrument-with bisect_ppx test/test_transport_cli_tool_a_coverage.exe test/test_transport_cli_tool_d_coverage.exe test/test_llm_provider_error.exe test/test_tool_input_validation.exe`
- Test binaries:
  `./_build/default/test/test_transport_cli_tool_a_coverage.exe`,
  `./_build/default/test/test_transport_cli_tool_d_coverage.exe`,
  `./_build/default/test/test_llm_provider_error.exe`,
  `./_build/default/test/test_tool_input_validation.exe`
- Summary command:
  `opam exec -- bisect-ppx-report summary --per-file --coverage-path=/tmp/oas_stage_d_cli_ad_error_validation_coverage`
- Focused per-file results:
  - `lib/llm_provider/error.ml`: `81.95%` (`109/133`)
  - `lib/tool_input_validation.ml`: `87.04%` (`94/108`)
  - `lib/llm_provider/transport_cli_tool_a.ml`: `73.09%` (`277/379`)
  - `lib/llm_provider/transport_cli_tool_d.ml`: `69.40%` (`220/317`)
  - `lib/llm_provider/cli_common_subprocess.ml`: `48.57%` (`85/175`)
- Behaviors added:
  - `cli_tool_a` JSONL text/tool/tool-result restoration, telemetry for
    provider-internal command execution, stream events, nonzero-exit stdout
    recovery, runtime MCP bearer-token env indirection, stdin prompt routing,
    and empty-output parse failure.
  - `cli_tool_d` stream-json structured text/thinking/tool-use restoration,
    stream events, JSON-output fallback, internal provider-terminal mapping,
    runtime MCP argv construction, stdin prompt routing, and empty-output parse
    failure.
  - provider error mapping for retry/auth/invalid/not-found/context/network/
    timeout variants, provider-failure subtypes, accept rejection, terminal
    `Other`, and retryability classification.
  - tool input validation for scalar coercion edge cases, JSON actual
    descriptions, optional null, non-object input, and inline path fallback.
- Timestamp: 2026-05-25 KST
  Confidence: High for focused behavior coverage; project-wide CI coverage is
  now governed by the latest `77` floor above.

## Stage D provider contract and catalog follow-up

- Evidence: local focused coverage run on PR #1759 after adding
  `test/test_backend_provider_k_coverage.ml`,
  `test/test_provider_catalog_coverage.ml`, and extending
  `test/test_backend_tool_call_harness.ml`.
- Command:
  `env MASC_DUNE_THROTTLE=0 BISECT_ENABLE=yes BISECT_FILE=/tmp/oas_stage_d_provider_contract_catalog_coverage/bisect scripts/dune-local.sh build --instrument-with bisect_ppx test/test_backend_provider_k_coverage.exe test/test_backend_tool_call_harness.exe test/test_provider_catalog_coverage.exe`
- Test binaries:
  `BISECT_FILE=/tmp/oas_stage_d_provider_contract_catalog_coverage/bisect ./_build/default/test/test_backend_provider_k_coverage.exe`,
  `BISECT_FILE=/tmp/oas_stage_d_provider_contract_catalog_coverage/bisect ./_build/default/test/test_backend_tool_call_harness.exe`,
  `BISECT_FILE=/tmp/oas_stage_d_provider_contract_catalog_coverage/bisect ./_build/default/test/test_provider_catalog_coverage.exe`
- Summary command:
  `opam exec -- bisect-ppx-report summary --per-file --coverage-path=/tmp/oas_stage_d_provider_contract_catalog_coverage`
- Focused per-file results:
  - `lib/llm_provider/backend_provider_k.ml`: `51.97%` (`66/127`)
  - `lib/llm_provider/backend_tool_call_harness.ml`: `59.09%`
    (`182/308`)
  - `lib/llm_provider/provider_catalog.ml`: `86.09%` (`291/338`)
- Full clean coverage after this follow-up:
  `78.13%` (`23241/29748`) from
  `/tmp/oas_stage_d_full_after_provider_k_harness_catalog_coverage`.
- Behaviors added:
  - provider_k retry/error classification, HTTP status mapping, thinking and
    tool-stream request modes, usage/reasoning parsing, duplicate reasoning
    suppression, parse-error wrapping, and stream reasoning chunks.
  - tool-call harness scalar actual-type reporting, missing/invalid schema-map
    filtering, feedback formatting, and provider convenience validators.
  - provider catalog auth/transport/thinking aliases, capability override
    matrix, malformed entry handling, file load failures, and global override
    lifecycle.
- Timestamp: 2026-05-25 KST
  Confidence: High for focused behavior coverage; project-wide CI coverage is
  now governed by the latest `77` floor above.

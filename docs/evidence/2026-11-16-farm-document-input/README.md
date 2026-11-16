# Farm WIM-S03: document capability candidate

This is a source candidate and limited validation record, dated 2026-11-16.
It does not establish deployed behavior or complete the Farm multimodal goal.
The original scope remains in the [Farm plan](../../reports/2026-11-12-agent-farm-plan.md).

## Identity and review

- Base: `85f2823f053a693cecc8b63d6d0cb460dd10f9d0`.
- Provider projection: `0ecf7bd04792cf97d0cab2ab07e61da09bac2445`.
- MASC declaration, projection and UI: `6b4589d360235b79b43b40dd6d4b379c836a8322`.
- Reviewed combined 34-file diff SHA-256:
  `c14f4d79f746523c3dbb36a13796b1601a95c397db7bace7e5d94f0d4e7c2fbe`.
- Independent source reviewer `continuity_audit` did not edit the candidate.
  Final review found no unresolved P0/P1/P2. It is not a GitHub approval or
  evidence of another model/account.

The review found and the candidate addressed: native Ollama wire bounds, old
document admission tests, Anthropic signed-prefix mismatch, Responses sizing
mismatch, and shallow nested tool-result projection. Documentation distinguishes
initial H5 readings from same-round provider omission/rejection.

## Changed behavior and written cases

| Boundary | Candidate behavior | Behavioral evidence status |
| --- | --- | --- |
| TOML → materialization → wire | Explicit `supports-document-input`; absence false; other catalog decisions preserved | Cases written, not run |
| Native transport | Ollama and official clients cannot gain native document support by declaration | Cases written, not run |
| Candidate input → H5 | Documents use document support; unsupported combinations use text readings/references | Cases written, not run |
| Goal/history/checkpoint/tool result | Nested media traversed; originals and tool identity retained; subsequent capable candidate gets originals | Cases written, not run |
| Anthropic/Responses history → serializer | Frozen document decision used by sizing and wire | Cases written, not run |
| Anthropic replay | Prefix receipt and next request bind the same transmitted document view | Cases written, not run |
| Dashboard payload → decoder | Declared/effective document flags remain separate; missing remains unknown | One selected case passed |

Production reader and admission semantics are described in
[H5](../../KEEPER-MEDIA-FALLBACK-H5.md) and the
[runtime reference](../../RUNTIME-TOML-REFERENCE.md).

## Checks actually run

- `git diff --check`: passed.
- `ocamlc -stop-after parsing -c <file>` on the 26 changed OCaml files: passed
  with local OCaml 5.5.1. This is syntax only, not a typecheck; the repository
  pins 5.5.2. The local parse receipt is under
  `artifacts/farm-document-capabilities-20261116/parse-results.json`.
- Dashboard TypeScript `tsc --noEmit -p tsconfig.json`: passed, using the existing
  main-checkout dependencies via an ignored worktree symlink; no install/build.
- Selected Dashboard API runtime decoder case: 1 passed, 286 skipped.
  Skipped cases are not passes. This is not a browser rendering check.

Dashboard commands (working directory `dashboard/`):

```sh
./node_modules/.bin/tsc --noEmit -p tsconfig.json
./node_modules/.bin/vitest run --config vitest.config.ts src/api/dashboard.test.ts \
  -t 'preserves stable provider lane IDs emitted by the API' \
  --no-file-parallelism --maxWorkers=1
```

Agent tool sessions 78759 and 92270 respectively ended with exit 0. The latter
reported duration 1.89 s and start 09:36:44 local time. No log file was captured;
this records the tool observation. Typecheck preceded the final decoder test
assertions; production Dashboard source was unchanged between those checks.

No Dune build, OCaml typecheck, executable OCaml suite, provider call, PDF/STT
integration, installed binary, restart or browser screenshot was run here.

Focused OCaml targets for subsequent execution are
`test_runtime_provider_auth_headers`, `test_model_capability_presence`,
`test_runtime_toml_wrong_typed_keys`, `test_runtime_config_validity`,
`test_runtime_modality_reroute`, `test_gate_keeper_backend`,
`test_keeper_turn_driver_failover`, and Agent Core's
`test_media_document_admission` / `test_provider_agnostic_reasoning_replay`.
These are planned targets, not executed checks or a full regression result.

## Publication and remaining product work

The local native stack uses `fix/farm-document-capabilities-20261116`,
`fix/farm-document-input-20261116`, then `docs/farm-document-evidence-20261116`.
Local GitHub CLI authentication and transport were unavailable in the preceding
work unit. Connector access supports inspection but does not supply native-stack
CLI credentials. PR publication, PR-number changelog fragments, GitHub review,
execution and deployment remain outstanding. This stack's
`gh stack submit --auto` also exited 4 before publication with
`authentication token not found for host github.com`.

Before committing, connector comparison from the recorded base to remote main
reported six later commits and no overlapping changed paths. This is a scoped
source observation, not proof that every dependency has unchanged behavior.
The open-PR document/capability search returned no result; search is not a full
semantic duplicate audit. Refresh remote scope before integration.

The next implementation boundaries remain:

1. Preserve non-text MCP identity results through the real tool consumer.
2. Feed documents produced during an active tool round through external reading
   when the runtime cannot accept them. Currently Core records an omission on
   Anthropic/Responses/Chat/GLM/Gemini, while native Ollama rejects the document.
3. Give Responses tool output a native document path instead of JSON text where
   the provider protocol permits it, with actual wire tests.
4. Validate real PDF reading, provider failover, restart, UI and multi-Keeper
   operation on an installed candidate. Source review cannot satisfy these.

All other Farm requirements remain in their original plan. This candidate does
not establish full external-tool support, scale, world portability or completion.

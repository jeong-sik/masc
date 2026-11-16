# Farm WIM-S03: document capability candidate

This is a source candidate and limited validation record, dated 2026-11-16.
It does not establish deployed behavior or complete the Farm multimodal goal.
The original scope remains in the [Farm plan](../../reports/2026-11-12-agent-farm-plan.md).

## Initial identity and review

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

| Boundary | Candidate behavior | Initial behavioral evidence |
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

At that initial checkpoint, no Dune build, OCaml typecheck, executable OCaml
suite, provider call, PDF/STT integration, installed binary, restart or browser
screenshot had run. The later Core-only execution is recorded below.

Focused OCaml targets for subsequent execution are
`test_runtime_provider_auth_headers`, `test_model_capability_presence`,
`test_runtime_toml_wrong_typed_keys`, `test_runtime_config_validity`,
`test_runtime_modality_reroute`, `test_gate_keeper_backend`,
`test_keeper_turn_driver_failover`, and Agent Core's
`test_media_document_admission` / `test_provider_agnostic_reasoning_replay`.
These were planned targets. Only the later Core media suite below has now run;
the other targets remain unexecuted in this record.

## Publication and remaining product work

The local native stack uses `fix/farm-document-capabilities-20261116`,
`fix/farm-document-input-20261116`, then `docs/farm-document-evidence-20261116`.
Local GitHub CLI authentication and transport were unavailable in the preceding
work unit. Connector access supports inspection but does not supply native-stack
CLI credentials. PR publication, PR-number changelog fragments, GitHub review,
the remaining consumer execution and deployment remain outstanding. This stack's
`gh stack submit --auto` also exited 4 before publication with
`authentication token not found for host github.com`.

Before committing, connector comparison from the recorded base to remote main
reported six later commits and no overlapping changed paths. This is a scoped
source observation, not proof that every dependency has unchanged behavior.
The open-PR document/capability search returned no result; search is not a full
semantic duplicate audit. Refresh remote scope before integration.

The next implementation boundaries remain:

1. Execute the non-text MCP preservation candidate through the real tool
   consumer; its source implementation is now recorded in the
   [MCP evidence](../2026-11-16-farm-mcp-content/README.md).
2. Feed documents produced during an active tool round through external reading
   when the runtime cannot accept them. Currently Core records an omission on
   Anthropic/Responses/Chat/GLM/Gemini, while native Ollama rejects the document.
3. Give Responses tool output a native document path instead of JSON text where
   the provider protocol permits it, with actual wire tests.
4. Validate real PDF reading, provider failover, restart, UI and multi-Keeper
   operation on an installed candidate. Source review cannot satisfy these.

All other Farm requirements remain in their original plan. This candidate does
not establish full external-tool support, scale, world portability or completion.


## Earlier rebased source checkpoint — 2026-11-16

At that checkpoint the complete document/MCP stack had base
`e0e819e29968366c1dffb59ad625ba4e17d4ac22`. Its first three layer heads are
`8872ec3b9fe89052ce0329e0a4227caf4dbde081` (Core),
`295cb5a23d3eb5c6f45568b7f06f8f53faa46291` (MASC), and
`a7e3f683d30338130ba34829f0a5f17e03ffa5e3` (original evidence).
MCP source and the integrated documentation checkpoint follow at
`23508a998d3b559334c8b127cc14aad7c5244b82` and
`980892260bf73193e8251b0ac1d54bedf6ad76f0`.

Independent review re-read all changed integrations and their current-base
consumers, including conservative Connect_failed/Connection_not_opened handling
and frozen per-candidate document/image admission. No actionable P0/P1/P2 remained
in the 79-path combined scope. The new receipt parses five changed OCaml files;
old byte-identical source/syntax evidence remains bound to its recorded inputs.
Historical Dashboard checks are not a new-base typecheck. Actual provider wire,
PDF/STT, UI, restart and full-runtime evidence remain unrun. No PR or GitHub
approval was created by this local rebase.


## Current committed Core correction and execution — 2026-11-16

The reviewed base remains `e0e819e29968366c1dffb59ad625ba4e17d4ac22`.
Current layer heads are:

- Core: `db69904f29c6f4a6166957fbdffa4f7e8e910a7a`.
- MASC: `01c94838471b1cbff986e5a78f2c14597a8df564`.
- Original evidence: `5363a4d944f704962f4ea47623d29640cd0f1711`.
- MCP: `e392aa3a7f8fafdfe18045c92bc0fe1d023e44b5`.
- Integrated top before this documentation update:
  `6134e0a42aae676f63143d1473aaeca7fb99053f`.

Actual compilation exposed a generic history contract narrowed by the document
degrader. `api_common.ml` and `api_common.mli` now preserve the media-source type
parameter; representable source values remain untouched and the placeholder is
Text. The test also needed obsolete Yojson 3 constructors removed and an explicit
projection-record annotation. All assertions and 18 registrations were retained.
These three files received separate independent source review. The new
`api_common.mli` path was not part of the earlier 79-path review: the current
80-path union relies on that earlier review plus these narrow corrections, not
a newly claimed review of the entire union. The fixes were amended into the
owning Core layer, then the complete five-layer stack was restacked with
`gh stack rebase --no-trunk`. This did not integrate newer main or publish a PR.

The complete existing `test_media_document_admission` suite passed: 18 passed,
0 failed, 0 skipped. It exercises local admission, supported codec forms,
capability-dependent user/tool input, nested ToolResult degradation, and image/
audio preservation. It is not an actual provider request or the separate
65-case reasoning-replay suite, Keeper planner/token-counting tests, or MASC's
runtime materialization/H5 suites.

The actual OCaml 5.5.2 closure used 118 source inputs, normal generated catalog
code and namespace aliases to real modules. Failures from run-1 through run-5
remain retained, including the production generic mismatch, test type errors
and external archive ordering. Run-6 verified the same sources and 189 inherited
objects, linked afresh with corrected Digestif.c archive order, and ran all 18
cases; all six final commands exited 0. The test correction was uncommitted at
execution time. After its owning-layer commit and restack, all 118 source files
and nine metadata inputs match the final committed leaf above.
Independent receipt review confirmed that binding without rerunning tests; it
is not a formal GitHub approval.

Receipts in the document worktree:
`artifacts/farm-core-media-document-20261116/final-summary.json`,
`run-6/source-manifest.json`, `run-6/results.json`, and
`restack-3/terminal.json`. Source manifest SHA-256 is
`715c55b1679ba25023e0e0d42771929a5ebbd3f1643a251a28580fa801f395e7`;
results SHA-256 is
`67f5d9c7adffc749dd5cecee37dde4c790b590f0d9da37f1a04167f4801e6f3d`.
This is a focused actual-source compile/link/run, not full Dune, MASC whole-graph,
MCP-consumer, installed-binary, PDF/STT, HTTP/provider, restart or UI evidence.
Historical Dashboard results retain their original source scope.

Next execution remains the MASC capability/materialization and modality-reroute
consumers, MCP normal/replay ownership, and actual provider/media integration.
The full Farm requirements and scale matrix are unchanged. A fresh `gh api user`
again exited 1 with an API connection error in the agent command environment;
that does not establish an invalid user account. Remote publication, GitHub
review, installed behavior and original-request recovery remain unconfirmed.

## MASC test correction and consumer source audit — 2026-11-16

The subsequent audit found obsolete `Tuple` and `Variant` patterns in the
declaration-to-wire test's `Yojson.Safe.t` match. The installed public type has
neither constructor. The owning MASC layer was amended to
`be648b8e1bfe796c250ddb37fab6c9b00f03ccb6`, removing only those two patterns.
All assertions remain. The whole five-layer native stack was restacked without
changing its base; the resulting leaf is `d18a8aa8eeb625087e8862fd4140efc23d658483`.
MCP's unchanged patch is now `4202159afd7cdbc9259296ceb09f7fa8f6c0d05f`.

Independent review confirmed that this one-line correction is the complete tree
delta from `d1ede6aa`. The other 16 commits have unchanged patches. Whole-file
parsing with OCaml 5.5.2 and `git diff --check` passed. This is a source-corrected
type defect, not a typecheck or execution of the maintained materialization suite.
The earlier Core118 and MCP239 source inputs still match the new leaf; neither
suite was rerun for this test-only change.

The fixed-head consumer audit traced actual TOML materialization, candidate H5,
canonical checkpoint restoration and native continuation. It found no additional
P0–P2 in that scope. Late/carried and active-tool-round documents remain outside
initial H5. Actual PDF/STT, provider acceptance and these MASC consumer suites
remain unexecuted. The complete materialization suite also uses runtime creation,
resume, dashboard probes and loopback HTTP; the small document test section does
not make its full implementation dependency graph small.

Local receipts: `artifacts/farm-document-materialization-fix-20261116/restack-1/`
and `artifacts/farm-document-consumer-audit-20261116/`. The one-line diff SHA-256
is `9512cb0cc8299ffc052f798716789077c732907cd36ab06188ffd57ef05298f6`;
independent correction review SHA-256 is
`767395815fbdbdfc7e3a6e2f604981969760679057a9f06894c51ad5e9af1dfe`.
No publication, installation or runtime change occurred.

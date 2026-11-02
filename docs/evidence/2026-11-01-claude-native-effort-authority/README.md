# Native Claude effort follows its selected intent

PR [#47179](https://github.com/jeong-sik/masc/pull/47179) removes HTTP catalog
effort admission from native Claude execution, capability probes and readiness.
Fusion also carries the selected model's effort instead of omitting it. Native
CLI admission remains explicit: Minimal maps to low, Ultra maps to max, absent
effort emits no flag, and explicit None disables thinking. Keeper hook changes
are applied before that native admission. HTTP capability validation remains a
separate contract.

This follows the [selected inference repair](../2026-11-01-claude-selected-inference/README.md).
It does not complete #27898's catalog hard cut, all native authentication scopes,
strict parsing, atomic runtime construction or remaining timeout ownership.

## Actual executions

Both executions are workflow **Test**, ref
`fix/claude-native-effort-authority-20261101`, `minimal=true`. Both explicitly
use the existing `suite_timeout_sec=900` workflow input. No product timeout or
new workflow knob is introduced.

| Role | Run | Actual checkout | Actual conclusion |
| --- | --- | --- | --- |
| Baseline | [41289637482](https://github.com/jeong-sik/masc/actions/runs/41289637482) | `5b1206e3f18bb0d41f86a20ed2f463293b268d48` | FAILURE: 9 PASS / 21 FAIL, all 30 selected cases completed |
| Candidate | [41291441388](https://github.com/jeong-sik/masc/actions/runs/41291441388) | `0446daea23c42f5f944a7e2f810fec99abfd8cb6` | SUCCESS: 42 PASS / 0 FAIL, all selected cases completed |

The common baseline/candidate targets are exactly
`test_keeper_claude_effort_authority,test_claude_probe_effort_authority,test_fusion_claude_effort_authority`.
The candidate additionally selects `test_runtime_claude_effort_admission` and
`test_keeper_claude_selected_inference`. The workflow executes the selected
inference alias before the direct argv executable; logs preserve actual order.

| Common cases | Baseline | Candidate |
| --- | --- | --- |
| Keeper native authority, 11 | 4 PASS / 7 FAIL | 11 PASS |
| Capability and readiness, 5 each | 4 PASS / 6 FAIL | 10 PASS |
| Fusion panel, 9 | 1 PASS / 8 FAIL | 9 PASS |

All 30 common cases retain the same complete fixture files and case identities:
nine PASS remain PASS, 21 FAIL become PASS, and no PASS regresses. The other
twelve candidate PASS are ten selected-inference controls and two native argv
cases. They are candidate-only selections, not additional baseline repairs.
No result from another execution is added to the candidate's 42.

The test-runner behavior summaries are 31.503/45.231 seconds for Keeper,
20.487/20.512 for probes and 18.423/18.451 for Fusion. The candidate selected
inference controls take 42.597 seconds and argv cases 0.000 seconds at runner
precision. The first candidate alias takes 562 seconds including cold
compilation and startup. These are distinct measurements, not live Claude
latency, fleet performance or a product timeout recommendation.

## What the cases establish

The fixture installs a colliding HTTP model that accepts only Low while
reporting reasoning support. Keeper covers omission and all eight declared
tiers, plus hook override and clear. Passing Keeper cases inspect fresh and
resume child argv, callback counts and session markers. Probe cases exercise
both capability and readiness through an actual controlled native child and
MCP tool-result roundtrip. Fusion covers omission and all eight tiers through
its controlled native child. The argv cases reject unadmitted raw Minimal and
Ultra and verify the native admission for all nine intents.

Failed baseline Keeper cases stop at their first fresh-argv assertion; their
later resume or disabled-thinking assertions are not established. Candidate
PASS reaches those later assertions. The controlled Python children do not
establish real Claude account entitlement, service behavior or model support.

## Provenance and publication delta

[manifest.json](manifest.json) records exact run/ref/head/checkout receipts,
actual conclusions, targets, guard inputs and separate raw/retained sizes and
SHA-256 digests. [baseline.txt](baseline.txt) and [candidate.txt](candidate.txt)
are ANSI/BOM-normalized derivatives retaining every completed timestamped
case row, selected target, checkout, summary and captured failure assertion.
Routine build output is omitted. Full raw captures remain in ignored
`artifacts/issues-oldest-20261101/claude-native-effort-authority/`.

[case-comparison.json](case-comparison.json) identifies all cases by exact test
source SHA-256 plus suite/group/index and supplies every full literal name.
Ordered common keys are compact UTF-8 JSON
`[test source path,group,index,source SHA256]` arrays, `ensure_ascii=false`,
comma/colon separators and one LF: SHA-256
`2094c08d7b786ce6fa518a170ed0058f6ce1b6d6a055a5da7657f053014bb817`.
The corresponding 42-key candidate digest is
`78a31908439b5f819ca37415c52de606aa593d062e2d7a85a6306a8cc0b7017a`.

[fixture-comparison.json](fixture-comparison.json) records the byte-identical
three complete common test files and Keeper alias file. It retains the exact
two module-name replacements in test/dune and lists every baseline/candidate
changed path. A separate unselected package Pipeline fixture was corrected to
public Agent.run; Agent Core production and config trees are unchanged across
this pair. Whole test-tree or whole package-tree identity is not claimed.

[source-sha256.json](source-sha256.json) seals 24 inputs and four trees at the
actual successful checkout. Publication corrects two stale comments, in
models.toml and runtime_inference.ml, and appends evidence. The exact two
comment blocks and before/after hashes are retained in
[publication-comment-delta.json](publication-comment-delta.json). TOML parsing
is semantically identical and all bytes outside the two comments remain
unchanged. The other 22 named inputs remain byte-identical. These corrections
change two recorded trees; the final publication SHA is not the CI checkout
and does not claim all-four-tree identity.

## Limits

The five focused targets do not certify the large original suites, full
repository regression, installed runtime, restart behavior, deployment or
whole-stack integration. No local Dune build/typecheck ran. The manifest
records the observed prior scheduled Test attempt separately; candidate full
regression is not run. Independent source review, formal non-author approval
and complete issue acceptance remain separate. No issue is closed.

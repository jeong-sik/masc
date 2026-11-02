# Muse reasoning request authority

Issue [#27898](https://github.com/jeong-sik/masc/issues/27898), Native Stack
[PR #47132](https://github.com/jeong-sik/masc/pull/47132), base
`e1be96703b5239392f9c7569c5e7063a8c421936`.

The four Muse producers used the mutable bare HTTP model catalog to change a
native MSP reasoning request. They now use one exhaustive typed translation of
the eight tiers. Keeper uses its hook-prepared effort. Omission and explicit
`none` remain distinct; the selected Muse host owns admission and refusal.

The [pinned official schema](https://github.com/meta-models/muse-code-sdk/blob/42c7658789a2491580658158d2092b2bbca4118b/schema/msp/msp.d.ts)
defines that vocabulary and distinguishes explicit `none` from absence. Its
digest, Git blob and selected declarations are retained in [upstream.txt](upstream.txt).
This verifies a request contract, not an account's model entitlement.

## Actual comparison

All executions use workflow **Test**, ref
`fix/muse-reasoning-authority-20261101`, with `minimal=true`.

| Execution | Exact head | Actual conclusion | PASS / FAIL |
| --- | --- | --- | --- |
| [Baseline 41279813704](https://github.com/jeong-sik/masc/actions/runs/41279813704) | `4912b2428aede0febe67db37094ecb9df7052b66` | FAILURE | **149 / 17** |
| [Candidate 41279990328](https://github.com/jeong-sik/masc/actions/runs/41279990328) | `18ebea801c69340008481185bb8371e173cf65ac` | FAILURE | **163 / 3** |

Both explicitly select `test_keeper_muse_runtime`,
`test_fusion_official_client_panel`, `test_runtime_verification`, and
`test_keeper_capability_probe`. Baseline `lib/`, `packages/agent_core/` and
`config/` trees equal the PR parent. Their entire `test/` tree is identical:
`07788d36e8fc0bafaf912b154ce7fc944840f420`.

| Suite | Baseline PASS / FAIL | Candidate PASS / FAIL |
| --- | --- | --- |
| Keeper | 73 / 13 | 83 / 3 |
| Fusion | 35 / 2 | 37 / 0 |
| Verification | 21 / 1 | 22 / 0 |
| Capability | 20 / 1 | 21 / 0 |

All 166 ordered case identities match: 149 PASS-to-PASS, 14 FAIL-to-PASS,
three FAIL-to-FAIL, and zero PASS-to-FAIL. Both workflow failures remain failures.

Twelve Keeper/Fusion baseline cases directly record received `low` instead of
the requested tier. The four omission/Low controls pass. The cases cover all
eight tiers, hook-time catalog replacement, hook override precedence and the
native refusal of explicit `none`. The refusal baseline stops at its first
wire-value assertion; its later typed-error/no-replay assertions are reached
only by the candidate.

The other two transitions are existing process/MCP probe cases. Baseline
verification fails its first `muse-success` verdict with `provider_rejected`;
capability fails its first exhausted-scope observation with `None`. Source puts
a child `high` assertion before those observations. Attributing those failures
to the old clamp combines source with execution: their raw logs contain neither
captured low-effort JSON nor a printed child assertion. Candidate execution
reaches the probes' remaining real MCP, terminal, model, quota and cleanup checks.
Later loop assertions are not claimed as baseline observations.

## Remaining three expectations and focused follow-up

The same three Keeper host-stop expectations fail in both valid runs. The test
helper had replaced the raw SDK result with caller admission. Native
`Yielded_after_repeated_tool_call` is legitimately rejected by that caller as
the private carried `Host_stopped_turn(Repeated_tool_call)` error.

Source `292ea623091b0a3ae25872f670a98f015f69a450` passively retains both results
and asserts both contracts. Acceptance and receipt settlement remain unchanged;
the existing SSE, session/count, impossible-count, held-context and resume checks
remain present. Its three production trees and six production blobs are
byte-identical to executed `18e`. Both new reasoning test helpers are unchanged.
Its complete test tree differs because of this fixture correction.

[Follow-up Test 41280919612](https://github.com/jeong-sik/masc/actions/runs/41280919612)
at exact `292ea623091b0a3ae25872f670a98f015f69a450` selects only
`test_keeper_muse_runtime`. Its actual conclusion is **SUCCESS, 86 PASS / 0 FAIL**.
All 86 Keeper case identities match the earlier candidate: its three remaining
failures become passes. Their later native count, held-context and resume
assertions are now reached. This is separate from the two failed four-suite
executions; no aggregate green execution is claimed. The final source keeps 31
of the comparison manifest's 32 inputs unchanged; the only changed input is the
Keeper fixture. Its two additional recorded inputs expose the typed error carrier.

## Earlier invalid iterations

[invalid-iterations.txt](invalid-iterations.txt) preserves their actual summaries
and representative fixture failures. All three workflows failed: initial
`9c0d0b8` had an empty Keeper prompt and ineffective collision rows; `ab72750`
and `db9cdea` omitted `supports_reasoning=true`, so projection erased their
effort ladders. Their original fixture-validity review was withdrawn. These
runs establish no intended effort reproduction or successful repair. The five
corrected collision declarations explicitly enable reasoning.

## Provenance and scope

[manifest.json](manifest.json) binds exact checkout receipts, requested suites,
actual conclusions and case counts to raw-log and selected-capture digests.
Selected captures keep focused cases, every failure, assertions' expected/received
details, summaries and runner receipts. Unrelated passing case rows are omitted;
the aggregate counts derive from the full raw logs and their suite summaries.
Invalid iterations retain a smaller representative derivative. Raw and selected
digests describe different bytes. Full raw captures remain in ignored
`artifacts/issues-oldest-20261101/muse-effort-authority/`.

[source-sha256.json](source-sha256.json) records 32 inputs and four trees for
the executed comparison candidate. [source-final-sha256.json](source-final-sha256.json)
records the later fixture source, with two additional typed-error inputs. These
are selected input manifests, not an exhaustive build dependency list.

Syntax-only parsing, whitespace and changelog validation were performed. No
local Dune build/typecheck or full regression was run. Controlled process/MCP
evidence does not verify actual Muse account/model support, installed runtime,
whole-stack integration, deployment or full issue acceptance. Issue #27898 stays
OPEN. Independent source/evidence review and formal non-author approval remain
separate evidence layers.

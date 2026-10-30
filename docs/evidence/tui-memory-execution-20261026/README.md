# Memory roster execution-field regression

Issue [#46142](https://github.com/jeong-sik/masc/issues/46142), code PR
[#46146](https://github.com/jeong-sik/masc/pull/46146), MASC Task `task-2716`.
Evidence PR [#46147](https://github.com/jeong-sik/masc/pull/46147) is the top
of Native Stack #46148.

## Observed failure

On 2026-10-26 the operator's Memory pane displayed
`memory health snapshot fields mismatch (unknown=[execution])`.
An authenticated read of `/api/v1/dashboard/keeper-memory-health` returned
`keeper.memory_os.current_health.v8` with these root keys:

```text
schema, generated_at, execution, keepers, totals, alert_summary
```

The response contained 40 Keeper rows. Its `execution` object used
`keeper.memory_execution_availability.v1`, with aggregate status `ok` and
both operations `serving`. These observations do not prove that a provider
answered, that any source was consumed, or that Memory committed.
The server's full-health identity reported executable commit
`bc3038a22374705db648bebd7f556223b3e84727`. This is a server identity, not a
measurement of the operator's TUI executable. Private Keeper rows are not
copied into this record.

## Cause and repair

The producer added `execution` in #45619. The TUI's exact root-field decoder
omitted that field and therefore refused the entire response before reading
the roster. This error alone does not indicate lost stored Memory.

The decoder now requires an object-valued `execution` carrier. Its `.mli`
states that stored-memory decoding does not interpret this separate
availability diagnostic. Missing, unknown, duplicate and wrong-typed root
fields remain errors; existing row, totals and independent store-read
validation are unchanged. No Memory store or runtime setting is rewritten.

## Verification boundary

Code head: `03128e8b222b35d70ccb7be33550e24a42c017f2`.
The complete five-file diff was independently source-reviewed by
`memory_contract_review` against current REST base
`13635d158569f8827853f7027a22b89ee3eae3d5`:
`4be7b2f770d7905a69558b6d6d7368097adacb9efa0fd9779bbb77854966b9e9`, PASS,
no P0–P2 findings. This is not a formal GitHub approval or execution result.

OCaml 5.5.1 parser-only checks passed for the four changed OCaml files.
Whitespace and the code PR's changelog checks passed. No local Dune build ran.

The explicit [Test run 40318190019](https://github.com/jeong-sik/masc/actions/runs/40318190019)
uses the code head above, ref `fix/tui-memory-execution-contract-20261026`,
`minimal=true`, and only `test_server_dashboard_http_keeper_memory_health`
and `test_tui_decode`. It completed successfully at 2026-10-26T11:58:59Z
(attempt 1, job `121556012059`): 24 Memory-health cases and 378 TUI-decoder
cases, **402 passed, 0 failed**. The actual job log contains:

```text
2026-10-26T11:58:54.9300546Z Test Successful in 0.126s. 24 tests run.
2026-10-26T11:58:55.1820753Z Test Successful in 0.033s. 378 tests run.
```

[receipt.json](receipt.json) retains the initial in-progress observation,
completed result and nine selected-source SHA-256 values. Evidence-layer
changes are confined to documentation and changelog; no executable input was
changed after the checked code head.

The existing HTTP-producer-to-TUI-decoder scenario checks retained unread
evidence and unchanged stored files. It now also refuses missing, duplicate,
null, scalar and array execution carriers and an unknown root field. Three
valid v8 fixture roots and the stale-schema fixture use the real producer's
disabled diagnostic, preserving their original test purposes.

Installed-TUI recovery, visible UI verification and full regression remain
unverified by these two selected suites and source review.

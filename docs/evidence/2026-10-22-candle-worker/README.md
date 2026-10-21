# Candle Addon worker qualification · published 2026-10-22 KST

## Executed source and result

This publishes an already completed focused check; it is not a new rerun.
The original execution was 2026-10-21 14:58:58–14:59:02 UTC on frozen Browser
source `d35d2559c56814b38615545a5f4f081304bccc05` (Native Stack #44168,
top [#44702](https://github.com/jeong-sik/masc/pull/44702)).
The existing Python worker suite passed **13 tests in 3.547 seconds**, exit 0.
`receipt.json` and `test-candle-appraiser.log` preserve the original bytes.
The receipt records the exact five source files, Git blob IDs, SHA-256 hashes,
Python version, command, execution times and verification limits.

The minimal source export retained its package-relative paths. The command was
`python3 -m unittest -v test_candle_appraiser` in `addons/tests`, using the
Python executable recorded in the original receipt. The test source is
[addons/tests/test_candle_appraiser.py at the frozen source](https://github.com/jeong-sik/masc/blob/d35d2559c56814b38615545a5f4f081304bccc05/addons/tests/test_candle_appraiser.py).
No product code or new assertion is added by this evidence PR.

## Boundaries actually exercised

The existing suite runs real MCP stdio worker subprocesses with a temporary
persistent state directory. Its restart scenario retains the exact original
request across different worker incarnation values, delivers a scripted model
answer, reads it after restart and prevents an already finished request from
being listed for dispatch again. Other cases refuse reused IDs with changed
input or result, keep equal relation titles distinct by task identity, retain
terminal unknown outcomes, enforce caller authority, refuse corrupt/replaced/
missing state, and defer new requests at the protocol frame capacity while
keeping admitted work accessible. Focused persistence and nesting cases use
direct worker imports and injected faults; not every case is a subprocess case.
The original log names every case.

These checks prove worker/MCP and durable-state behavior for this frozen source.
Model answers are scripted. A changed incarnation string and process restart are
not a real host-managed Addon Off/On cycle.

## Remaining E01 work

This is not execution proof for the OCaml host adapter, actual provider/model,
Docker Off/reconnect, host payout obligations, host ledger settlement or its
end-to-end idempotence, Dashboard/TUI, current main, the entire 67-layer Browser
stack, operator installation or all 54 tasks. The package and host adapter
already exist in that unmerged Browser source, so no second wrapper is needed.

Next checks must join the existing host request/Exact/domain-decoder consumer
with the original obligation, actual same-installation Off/On, the new worker
incarnation and exactly one authoritative Paid result. Credential/provider
admission and final ledger authority remain in the host. Worker-only success
cannot substitute for that scenario or for both UI observations.

## Separately requested compiled host consumers

[Run 39624635082](https://github.com/jeong-sik/masc/actions/runs/39624635082)
selects the same frozen d35 source and the existing
`test_candle_appraiser_contract,test_candle_appraisal_flow` suites with
`minimal=true,eio_backend=posix`. `host-check-dispatch.json` preserves the
accepted request and `host-check-run-identification.json` the initial run
identity. Its result has not been read at this publication boundary.
The contract suite joins actual worker stdio/restart with host Grade decoding;
the flow suite joins the production payout worker and all appraisal stages to
host settlement with a scripted Addon port. Even their eventual success would
not prove actual host-managed Addon Off/On followed by real-provider settlement.

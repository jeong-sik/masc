# Preserve absent cost-latency readings

Residual #25852 / consolidated #25558, based on main
8e85e45ecc8c853fead4734439cf1e67e57728f3.

The cost-latency export replaced unreported token/cost fields with numeric zero,
dropped explicit all-zero lanes, and published partial sums as complete totals.
Its Dashboard decoder independently coerced missing fields and matrix cells to
zero, so changing the server alone would still lose absence.

This change retains every observed lane, renders unreported or incomplete token
and cost totals as null, and retains explicitly reported zero. Coverage is per
field and successful sample, matching the existing aggregate's outcome set.
The export groups source samples once by model; generic model aggregates remain
unchanged. Global cost is null for no samples or any lane with incomplete cost.
The Dashboard response types and decoder preserve null, including each matrix
column with any missing contribution. Latency, redacted identity and ledger read
diagnostics retain their existing contract. Pricing remains observation only.

The server control writes actual decision JSONL and reads through the public
compute_cost_latency_json entrypoint: cost-only, token-only, explicit zero,
partial same-lane samples, matrix/global values and an all-zero complete window.
The Dashboard control calls the actual fetchCostLatency decoder on a response
containing those distinctions and missing matrix contributions.

Dashboard baseline at test-only 79557e50352: actual 2 PASS / 1 FAIL (277 unrelated
cases not selected). New absence control failed because null became zero.
Corrected Dashboard: actual 3 PASS (277 unrelated not selected), command:
`pnpm --dir dashboard test src/api/dashboard.test.ts -t fetchCostLatency`.
Saved raw logs: /tmp/masc-cost-latency-dashboard-{baseline,corrected}.log.

Server baseline selected run:
https://github.com/jeong-sik/masc/actions/runs/40236517831
at test-only 79557e50352; its actual outcome is unverified at creation. Corrected
server execution and independent source review are pending. Local OCaml parsing
is separate from typechecking or execution; no local Dune was run.

This is the export/decoder slice. It does not repair or prove upstream provider
omission preservation, cost-ledger producer semantics, all 11 retained #25852
members, a visible browser dashboard, full regression, installation or deployment.

Full Dashboard typecheck was attempted and failed: TS2532 at
src/api/keeper.test.ts:687 and TS2322 at src/keeper-stream.test.ts:1862,1873.
These files are outside this diff; no baseline typecheck was run, so this is
recorded as a failed full check rather than a passing or proven pre-existing one.
Corrected selected server run:
https://github.com/jeong-sik/masc/actions/runs/40236647411
at a3d6cd09380529b2fa8e36e146b1e18db7421cd0, outcome unverified.

Both initial server runs 40236517831/40236647411 failed compilation before any
case ran: a local `open Yojson.Safe.Util` shadowed the control's `path` filename
with the library function. The fixture now names that file `decisions_file`.
Earlier source reviews missed this type error and do not establish execution.
Corrected test-only baseline and corrected producer runs must be read separately.

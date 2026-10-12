# Provider retry versus deferred reasoning publication

## Executed counterexample

At base `e0373a0236c8ea414d7b27d79fe1e299ebb73494`, add an owned unsequenced exposed Thinking delta, then a matching provider retry, then advance the existing production Thinking publication timer using Vitest fake timers. The targeted state test exited 1: expected `retrying`, received `thinking`. The delayed preview was still authorized for the response and overwrote newer retry progress.

This executes the real stream handler, batching buffer, scheduled callback and atomic entry publication. The provider frames are synthetic; this does not prove a live Claude/MASC/browser incident.

## Correction

After checking that retry owns the running operation and observed runtime attempt, commit previously buffered Thinking and cancel its pending preview before publishing retry progress. Recheck ownership after that effect boundary. No new ordering registry or content matching is introduced; exposed reasoning remains in the trace. Later accepted Thinking can resume activity and append to the preserved prefix.

## Executed verification

From dashboard:

- Before fix: `vitest run src/keeper-stream.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1 -t 'real thinking publication timer'`: exit 1, 1 failed and 126 skipped; expected retrying, received thinking.
- Corrected: `vitest run src/keeper-stream.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1`: exit 0, 127 tests, final 960 ms. The new test verifies timer ordering, retained exposed reasoning, and later reasoning recovery without duplicate prefix.
- `tsc --noEmit`: exit 0 after production correction.
- `git diff --check`: exit 0.

No build, CI, real socket, provider turn, installation, browser or screenshot validation. Prior source PASS for #42490 did not establish this timer boundary; the separate review-response HOLD and executed failure remain part of the evidence.

## Executed reentrant replacement counterexample

At intermediate head `1d01519a09efee377809595f7cc2f713aa73a866`, a real Preact signals observer replaces the assistant row with another operation during the Thinking flush. The replacement intentionally retains the same runtime ID and attempt index. Targeted `-t 'same-runtime operation replaced'` exited 1: expected replacement `opening`, received original operation `retrying`. This is an actual state/publication counterexample with synthetic operation data.

The final correction captures the existing immutable publication owner before flushing and verifies operation delivery identity, target source/turn and credential generation after that effect boundary, as well as runtime/phase. It reuses existing ownership logic rather than creating a parallel registry.

Final corrected stream suite: exit 0, 128 tests, 835 ms. Final `tsc --noEmit`: exit 0. These supersede the earlier 127-test pass for the corrected scope; both failures remain recorded.

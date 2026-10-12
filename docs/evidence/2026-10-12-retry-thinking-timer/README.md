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

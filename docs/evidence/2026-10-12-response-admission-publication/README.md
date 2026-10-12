# Common response admission after reactive effects

Base `daa2b29da282f55c3423d1af19a564e7619c7f7e`.

The common response-admission function computed generation2/scope1 from a generation1 snapshot, then flushed earlier Thinking. A real signals observer used the production reducer to admit generation3/scope2 during that flush. The common function blindly published its earlier decision, rolling the canonical state back to generation2 and permitting older header metadata to replace newer activity.

Executed parent targeted test `-t 'roll back response admission'`: exit 1, one failed and130 skipped. Expected current generation3/scope2, received generation2/scope1. Synthetic frames execute actual admission, reducer, deferred Thinking publication and reactive observers; not a live provider incident.

The correction captures existing publication ownership and immutable pre-admission state. After Thinking flush, verify them before clearing per-response buffers. Recheck inside atomic state publication, and after publication before returning an accepted decision. A newer admission or target/auth replacement refuses the stale frame, so its caller cannot publish metadata/body on that authority. No independent ownership registry or string heuristics.

Final corrected stream suite: `vitest run src/keeper-stream.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1`, exit0, 132 tests, 988ms. Two scenarios cover observation replacement during Thinking publication and during response-state publication. Both preserve newer response owner/activity/body and refuse old provider header metadata.

Production-correction `tsc --noEmit`: exit0. `git diff --check`: exit0. No local build, CI, installation, provider turn, browser or screenshot evidence.

Metadata-only model activity projection remains a separate pending task. This finding was repaired first because the shared admission boundary governs every such consumer.

# Retry publication across response admission

Base `4c42ef88bd4a94b871b9a2365746ee6b7018d2c9`.

A real signals observer admits a newer response through the production response reducer during the retry handler's Thinking flush. The operation delivery key, runtime ID and attempt index remain unchanged. The old retry incorrectly replaces newer opening progress because the post-effect check previously tested only target identity/runtime/phase.

Executed parent counterexample with `vitest run src/keeper-stream.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1 -t 'newer response admitted during retry'`: exit 1, one failed and 129 skipped. New response owner remains generation2/scope1, but expected opening becomes retrying.

The correction captures the existing immutable response state before flushing and refuses progress publication if its reference changed. The reducer's immutable SSOT determines this boundary; no extra epoch, registry, text matching or numeric policy is introduced. Earlier reasoning remains recorded.

Executed corrected stream suite: same command without test selection, exit 0, 130 tests, 968 ms. `tsc --noEmit`: exit 0. `git diff --check`: exit 0.

Synthetic event data and a real reactive observer exercise production state admission/publication. This is not an actual provider, browser, installed UI or screenshot reproduction. Independent source review and runtime/UI evidence remain separate.

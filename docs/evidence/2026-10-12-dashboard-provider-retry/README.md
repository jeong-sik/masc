# Dashboard provider retry progress

The SSE retry contract is connected to a distinct `retrying` progress state. The conversation entry owns its observed runtime ID and attempt index; no additional global runtime registry is introduced. Only a matching retry within a running, live assistant operation updates progress. Provider retry counts do not impose MASC budgets or a promised countdown.

Repeated known attempt headers preserve response ownership and bytes. Older known attempts cannot clear current activity. A real accepted response body returns to streaming. Terminal operations reject late retry progress.

Executed on 2026-10-12, in the isolated publication worktree:

- `dashboard/node_modules/.bin/tsc --noEmit` from dashboard: exit 0.
- `vitest run src/keeper-stream.test.ts src/keeper-chat-operations-local.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1`: exit 0, 2 files, 145 tests, final 1.28 s. Includes two new state-only retry/attempt ownership scenarios.
- `git diff --check`: exit 0.

No build, CI, installation, browser execution or screenshot was performed. Stored drafts retain the observed retrying state, but do not restore privileged runtime-attempt ownership: a fresh runtime observation is required before a new retry updates progress. No provider retry body or private error text is inserted into conversation content. Actual runtime/browser evidence remains required.

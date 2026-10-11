# Stream authentication admission and observation withdrawal

Two initial scenarios failed before repair: a late HTTP response acquired under superseded credentials still emitted its terminal event, and the action callback applied late stream content to the conversation. A hostile review found two more response-resource gaps; actual ReadableStream fixtures reproduced missing cancellation at delayed headers and at the helper-to-caller microtask handoff.

Each POST captures an immutable Keeper/operation/token-revision admission alongside its exact request headers, after initial dev-token bootstrap and again for an authorized 401 retry. The same admission reaches the action consumer. API checks cover HTTP response handoff, first and subsequent reads, parsing/diagnostics, each event callback and terminal settlement. A token listener cancels an acquired quiet reader. Superseded response bodies are cancelled before reader acquisition, and listeners/locks are released.

The action checks event/decode callbacks, returned outcomes and queued-liveness observations. Authentication withdrawal retains received partial content and accepted operation tracking, ends local stream activity, and does not publish old errors or perform history reconciliation/server cancellation under replacement credentials. Existing exact-operation cleanup preserves a newer concurrent send.

Direct fixtures cover late HTTP response, old Text/Thinking/Tools callbacks, quiet-reader withdrawal, header/handoff cancellation, callback frame-batch withdrawal, retained accepted partial drafts, initial bootstrap admission and an older send settling after a newer send. Existing actual API tests also exercise dev-token bootstrap and typed 401 retry. No hidden chain-of-thought is synthesized.

Validation: `pnpm exec vitest run src/keeper-actions.test.ts src/api/keeper.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1` passed all 154 tests. TypeScript noEmit and whitespace checks passed. One intermediate typed tool fixture lacked occurrence coordinates; its fields were corrected to the actual protocol before the final passing typecheck. The hostile review's response-resource findings were reproduced and repaired.

This is source and focused behavioral evidence. Complete account isolation, provider/runtime execution, installed behavior, actual screenshots and the full chat goal remain unproven. A pending fetch is checked when its response arrives; this change does not claim proactive token-change abort of a fetch that has not produced headers.

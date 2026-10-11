# Explicit operation lookup errors

Two actual recovery scenarios failed before repair: a transport error mentioning `/chat/operations/` and `unknown_operation`, and an unclassified route-level 404, were both treated as a missing operation and described as a server restart. Neither observation proves that claim.

The operation lookup acquisition now interprets only HTTP 404 with the backend's explicit `masc.keeper_chat_operation.error.v1` schema and `unknown_operation` error member as a scoped `KeeperChatOperationMissingError`. Wire discriminators are decoded at this HTTP boundary. Other errors retain their original `ApiRequestError` and response data. The domain error retains its original cause and exact requested Keeper/operation identity.

Recovery consumes that domain type and exact identity. It no longer searches method/path/prose for words to determine state. An explicit missing-operation receipt also does not prove a server restart; the notice states only that the server could not find the request. Tracking and retained terminal receipts survive lookup failures.

Focused action and actual-fetch API fixtures cover misleading prose, unclassified 404, matching/foreign domain identities, correct wire receipts, missing/wrong schema, wrong code and wrong HTTP status. The final focused run passed all 145 tests, including a retained terminal receipt followed by an explicit domain error. TypeScript noEmit and whitespace checks passed. The command was `pnpm exec vitest run src/keeper-actions.test.ts src/api/keeper.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1`.

No runtime, provider execution, installation, merge, full CI or actual screenshot evidence is claimed. The full chat goal remains active.

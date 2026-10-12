# Credential notification owns its audience and registrations

Parent: `f781d0ce509535dcfee5a640219b1b6bb6243e91` (#42443).

Three real credential API fixtures reproduced notification ownership failures (`/tmp/auth-notification-ownership-red-20261012.log`): a newly registered listener received an ongoing event; releasing one of two registrations of the same callback removed the other; and a nested credential replacement delivered the newer event followed by the stale older event to a later observer.

Each subscription now has an immutable registration record owned by its returned release capability. Notification captures its admitted registration list before callback execution, skips removed registrations and stops delivery when a nested publication supersedes its revision. New registrations receive future notifications. The original publication receipt retains its exact original revision even when a callback causes a newer publication.

A further positive fixture removes and re-registers the same callback during delivery. The removed registration is skipped, the replacement receives only the next event, and releasing the old capability again leaves the replacement alive. Existing token semantic-change, bootstrap publication, MCP admission/recovery and operator refresh interleaving cases remain in the focused scope.

Focused validation completed: `npx vitest run src/api/core.test.ts src/api/dev-token.test.ts src/api/mcp-admission-ownership.test.ts src/operator-refresh-http-ownership.test.ts src/operator-actions.test.ts` passed five suites / 146 tests (`/tmp/auth-notification-ownership-focused-20261012.log`), and `npx tsc --noEmit` exited 0. All fixture subscriptions are released in finally.

This repairs the central notification delivery contract. It does not partition existing UI caches/projections/pending/log data or establish other HTTP resource lifetimes. No live provider/server, screenshot, installation, CI or formal approval is claimed. The full chat goal remains active.

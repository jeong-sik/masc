# Previous-credential action completions do not publish shared effects

Parent branch: fix/operator-action-pending-ownership-20261012 (#42436).

Four real action-boundary fixtures reproduced late dispatch/confirmation success/failure writing previous-account logs and errors or starting refreshes after credential replacement (`/tmp/operator-action-auth-publication-red-20261012.log`). Only transports are mocked; real credential revisions, action effects and signals are used. New-account error state is explicitly seeded before resolving the old operation.

Dispatch and confirmation capture their original credential revision. A superseded completion returns its original result, or rethrows its original error, without appending shared logs, changing shared errors or initiating post-action refresh. Their pending release remains unconditional and removes only their own identity. This guard does not imply that a server-side action was rolled back or failed.

Focused validation completed: `npx vitest run src/operator-actions.test.ts` passed 29 tests (`/tmp/operator-action-auth-publication-focused-20261012.log`), and `npx tsc --noEmit` exited 0. Existing current-owner success/error/confirmation and overlapping lifetime scenarios remain covered.

This is the late action-receipt publication boundary. Already-started snapshot/digest refreshes, credential partition of pending state, previously visible logs and downstream callers' own UI effects remain separate work. No whole-account isolation, CI, installation, live provider/server, screenshot, TUI runtime or formal approval is claimed. The full chat goal remains active.

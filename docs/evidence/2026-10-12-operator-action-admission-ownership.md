# Initial operator state observers cannot replace request admission

Parent: `54eca1cfa6f933df1114337a236826c00a927133` (#42438).

Six actual action-boundary failures reproduced dispatch and confirmation running after a real reactive observer replaced credentials during busy publication, error reset or status reset (`/tmp/operator-action-admission-red-20261012.log`). Only transport is mocked. Real Preact effects change the real credential revision and seed replacement-account error state. The parent still called the old request's transport under the replacement account.

Both action entrypoints now place error resets inside their owned try/finally. They validate the original revision after acquiring pending ownership, after clearing error and after clearing status, before invoking the transport. A mismatch throws the typed OperatorActionAuthenticationSupersededError, skips shared failure publication and releases only the original pending identity. The replacement error/status remain intact. Current-owner action behavior is preserved.

Focused validation completed: `npx vitest run src/operator-actions.test.ts` passed 41 tests (`/tmp/operator-action-admission-focused-20261012.log`); `npx tsc --noEmit` exited 0. The six negative cases assert no dispatch or confirmation transport call, typed refusal, replacement error/status preservation and pending cleanup.

This covers initial reactive state publication before transport invocation. HTTP bootstrap/admission inside transport, already-started snapshot/digest refreshes, pending/log auth partition and downstream UI effects remain separate work. No server rollback, whole-account isolation, CI, installation, live provider/server, screenshot, TUI runtime or formal approval is claimed. The full chat goal remains active.

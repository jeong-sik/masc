# Reentrant credential notification preserves the newly admitted refresh

Parent: `4c18a125e373388b9544d54af6d130617f8c7df7` (#42442).

A prior source review identified an unverified public API composition: the credential listener Set is live during notification, so a callback starting a new-owner refresh adds its cancellation listener to the ongoing iteration. Two actual core/API/refresh fixtures now reproduce the bug (`/tmp/operator-refresh-reentrant-auth-red-20261012.log`). The old read is correctly aborted and the new HTTP request uses credential B, but the new B request is also immediately aborted by the original A-to-B notification. This is a controlled public API witness, not a claim of an installed UI incident. Earlier acquisition SOURCE PASS excludes this newly confirmed composition; the independent finding is preserved separately.

Both refresh cancellation listeners now compare the current credential revision to their own admitted revision before aborting. A listener reached by the event under which its read was created therefore leaves that read alive; a later replacement still cancels it. No credential values or prose are used for production branching.

Four final fixtures cover snapshot/digest survival and a subsequent B-to-C replacement. They observe actual fetch signals and Authorization headers, require the A read to cancel and B read to survive the original event, and require the later C event to cancel B. All remaining deferred responses are completed and awaited in finally.

Focused checks completed: `npx vitest run src/operator-refresh-http-ownership.test.ts src/operator-actions.test.ts` passed two suites / 59 tests (`/tmp/operator-refresh-reentrant-auth-focused-20261012.log`), and `npx tsc --noEmit` exited 0. An initial Array indexing type error in the fixture was fixed by checking both request records, without casts or product changes.

This repairs the refresh listener ownership composition, not the global notification contract or all other subscribers. Other HTTP verbs/getWithResponse, account projection/pending/log partition and downstream UI remain separate work. No live provider/server, screenshot, installation, CI or formal approval is claimed. The full chat goal remains active.

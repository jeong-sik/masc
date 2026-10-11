# Preserve known approval retirement during inventory replay

Base: 240355516a29901f59a31df4ce7d7512adedf96b.

Actual API/fetch + applyKeeperStreamEvent reproduction: a known approval wait is settled while the global inventory request is pending. The late listing recreated an actionable wait. Before fix: 1 failed / 12 passed; /tmp/chat-tool-approval-retirement-red.log.

Stream SETTLED now uses the same terminal-row writer as HTTP answer completion. The known terminal fact remains in the existing approval state, so gap hydration skips it. UI pending selection already excludes settled rows. New REQUESTED replaces that row normally. Removed the unused deletion writer; no parallel retirement mirror was introduced.

Focused stream and approval suites: 133 tests passed; /tmp/chat-tool-approval-retirement-green.log. TypeScript noEmit exit 0 before removal of the unused deletion export; final validation recorded separately. No runtime, screenshots, CI or formal approval claimed.

Remaining: settlement for a wait never seen locally has no row to retire; server identity/frontier must resolve this without invented prompt data. Same-ID producer incarnation and account partition remain incomplete. This repair does not claim those are solved.

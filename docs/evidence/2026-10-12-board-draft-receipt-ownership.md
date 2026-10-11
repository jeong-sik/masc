# Board draft ownership at asynchronous receipts

Parent #42425 clears the composer unconditionally after an accepted request. Actual component DOM events reproduced two failures: a new ComposerV2 broadcast body and a new desktop Board title/body authored while a deferred request was pending were cleared to empty by the earlier receipt. Measured RED output: /tmp/board-draft-red-20261012.log.

Both components now hold their draft fields in one immutable reactive signal snapshot. Each authoring update replaces the snapshot; receipt cleanup compares object identity with the admitted snapshot. This preserves later edits including ABA edits back to the originally submitted text. Existing broadcast ok:false receipt interpretation remains unchanged; it can represent persisted workspace content with unsuccessful Keeper delivery and is not generic proof that nothing was sent.

Independent hostile review found an initial candidate P2: render-captured payload A was paired with current snapshot B as its clear token. A native input then native send before rerender reproduced old body in createPost instead of current body. Measured RED output: /tmp/board-draft-native-red-20261012.log. Historical source FAIL: /tmp/masc-board-draft-snapshot-finding-20261012/report.md, SHA256 7a8ea263e9b024e85aeaf21d2b066c24285b5d2711da6e978381912930d04830.

All three send handlers now derive payload, recipient and cleanup token from the same current snapshot. Existing operator mention resolution is extracted into a pure function consumed by both the render hook and synchronous send. Mobile mention recipient projection also shares its existing parser and roster rules; no new text heuristic controls receipt ownership.

Focused verification: npx vitest run src/components/board/composer-v2.test.ts src/components/board/board-surface.test.ts src/components/board/voice-context-ownership.test.ts src/components/common/use-operator-mention-context.test.ts. Four suites, 101 tests passed. The later fixture scheduling-only cleanup passed its one affected test using act to flush completion. TypeScript noEmit passed. Tests cover accepted and persisted negative broadcast receipts, ABA edits, next desktop input, and native same-frame payload/recipient selection for broadcast, DM, desktop post and mobile mention.

These are synthetic actual DOM events with mocked transport. No physical browser screenshot, installed TUI, provider runtime, CI, merge or formal approval is established. Complete auth/mode/workspace request ownership and unknown-outcome recovery remain separate outstanding goal work.

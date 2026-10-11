# Board submission admission

Two native send events dispatched before a component rerender invoked the mocked transport twice on the parent: ComposerV2 broadcast and BoardSurface mobile post. The candidate admits one invocation. Both components now use one reactive submitting signal for synchronous admission and the displayed busy state; it is set before effects and released in finally.

An independent hostile review found a candidate regression: checking global operatorActionBusy in desktop submitPost ignored an enabled post button during an unrelated operator action. The actual DOM fixture failed with zero createPost invocations instead of one. Removing only that extra condition restores independent desktop posting while keeping the local duplicate guard. The historical source FAIL is preserved at /tmp/masc-board-post-admission-finding-20261012/report.md (SHA-256 165b0c77c5b189cb6946bf259b402981ed2a7a49ac86ab5147c895602f6a5eb8).

A synthetic transport exception also verifies that an explicit subsequent user attempt can send its new text. This does not prove safe replay of an outcome-unknown request. Broadcast ok:false can coexist with workspace persistence; receipt interpretation and draft clearing are unchanged.

Verification: npx vitest run src/components/board/composer-v2.test.ts src/components/board/board-surface.test.ts src/components/board/voice-context-ownership.test.ts: 3 suites, 85 tests passed. npx tsc --noEmit passed. Tests use actual component DOM events and mocked transport, not a physical browser/device or a running server. No browser screenshot, installed TUI, provider runtime, CI, merge or formal approval is established by these checks.

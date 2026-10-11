# Chat approval receipts retain their admission owner

Base: `a41182c560985fd3e6cba3cc482c9a225c469579`.

Source inspection found that delayed chat approval results reconstructed the tool label from the current global live transcript using provider call ID. After a live-turn change or provider-ID reuse, that transcript may represent a different tool. The result now carries the immutable typed awaiting-approval value captured at dispatch alongside the original chat request. Its tool name supplies the receipt label; completion does not inspect the current live transcript. The answer still posts the captured admission ID.

Chat approval dispatch also uses the existing shared Approval.Flow action owner. A second approval while an action is in flight is refused by the existing typed state. Completion carries the generation and applies all result/history/refresh effects only when that generation still owns the action, releasing the slot once. Workspace-scoped dispatch/result authority remains in place. The existing Flow feature tests cover duplicate admission and stale completion semantics; those tests were inspected, not executed in this unit.

Validation: OCaml 5.5.1 syntax-only parsing of the two protocol files and TUI shell succeeded with no diagnostics. Source hashes/exits `/tmp/chat-tui-approval-receipt-owner-syntax.json`. `git diff --check` passed. All constructor producers and the one consumer were inspected; the executable already directly depends on transcript and operator-projection libraries. No functional test, OCaml typecheck, local Dune build or CI was run.

The preceding navigation unit has an independent source PASS at its own exact head. This unit awaits independent review. No formal GitHub approval, merge, installed binary, actual provider continuity or screenshot proof is claimed. Timeout-to-late-store ordering, unseen terminal/frontier/resource retirement and the broader Thinking/tools/saying/interleaving/broadcast/runtime goal remain incomplete.

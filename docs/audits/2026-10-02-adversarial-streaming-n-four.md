# Adversarial streaming review: four consecutive requests

Reviewed 2026-10-02 against PR #40715 (0f1038327cba77396394863356b065afcfab60eb), #40732 (8f1b39068f205e9424996cd21a46974bbeb75d9b), and #40736 (601a14d2a503cb980ab64f4d94c624efc397ebde). Findings below are repaired by this child PR. Source review is separate from executable/provider evidence.

| Boundary | Counterexample | Repair / regression |
| --- | --- | --- |
| TUI source selection | Partial canonical source hides complete batch sibling; observed source is richer than msg_live | Complete authority, then retained sequence, then stable canonical tie |
| TUI history suppression | Observed reply suppresses durable FINAL while a competing inflight source without that reply wins rendering | Renderer and suppression select from the same held/inflight/live pool; memo includes selected transcript revisions |
| Codex n → n+1 | Blank completion leaves old identity open; next anonymous delta belongs to wrong message | Reconcile raw completion before filtering nonblank answers; 16 named/anonymous/blank combinations followed by n+2 and n+3 |
| Antigravity n … n+3 | Presentation paragraph separators invalidate raw final prefix; distinct authoritative final disappears | Separate raw provider accumulator; reconcile final suffix or new final; skip earlier delivered final |
| Claude block / message boundary | Pending text discarded on tool/message boundary, empty block consumes later block, citation metadata rejected | Pending buffers keyed by message and block; empty blocks do not consume pending text; inert citation metadata accepted |

The TUI fixture covers old inflight preservation, different executions and Keeper isolation, canonical/complete siblings, richer observed streams, late partials, competing inflight streams, late lower-sequence Reply_details, memo invalidation, and catch-up. A greatest retained sequence is a selection heuristic, not proof of gap-free delivery. Adversarial missing-prefix states exercise defensive display behavior; actual production occurrence was not established.

Claude's documented default is per-block complete delivery. Delayed aggregate envelopes are accepted-protocol robustness scenarios, not claimed observations of the current CLI. Official protocol references: [SDK streaming output](https://code.claude.com/docs/en/agent-sdk/streaming-output), [citation deltas](https://platform.claude.com/docs/en/build-with-claude/citations), inspected 2026-10-02. Configured CLI citation emission remains unverified.

## Executed evidence

The actual shared text helper was evaluated through the OCaml interpreter, without Dune:

```sh
ocaml -noinit -I . docs/evidence/2026-10-02-adversarial-streaming/text-reconciliation-check.ml
```

The pinned pre-fix helper loses both the raw multi-step final suffix and a different authoritative final (`text-reconciliation-before.txt`). The repaired implementation passes 51 assertions (`text-reconciliation-after.txt`), including every one of the 16 tool-boundary masks across four messages. This proves those string-reconciliation cases only.

Touched OCaml source/interfaces pass syntax parsing; diff whitespace checks pass. Added native runtime/TUI fixtures were not executed in this external coding-agent lane. No integrated PTY, installed binary, live provider, screenshot, or production restart claim is made. Muse and shared conservative remainder callers were source-inspected; provider behavior remains an integration follow-up.

Review used three specialist agents of the inherited model for structural, flow, and implementation counterexamples. This is independent source scrutiny, not cross-model review or author approval. Follow-up issues #40714 and #40735 retain real TUI/provider verification scope. Rollback: revert this child PR while retaining the parent stack.

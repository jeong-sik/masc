# Slack durable ingress before transport ACK

Event delivery carries the original envelope ID from the FSM into the socket
callback. The socket ACK follows typed durable host acceptance or an explicit
closed ignore reason. A refusal or callback exception sends no ACK; cancellation
propagates. A lost ACK does not roll back the durable original.

Ambient admission requires the actual original attention, append-once chat row
and one-shot durable queue entry. The queue's existing strict original/terminal
evidence prevents reenqueue after consumption. A typed Connector transcript key
uses the producer's original event ID and grants no operation or turn ownership.
Its OCaml, TUI and Dashboard direct consumers preserve that distinction.

Triggered admission requires a confirmed durable Keeper operation receipt with
the exact operation, Keeper and channel. Missing, lost or uncertain receipts
withhold ACK. The subsequent connector lane only projects its status notice.

Redelivery after a trigger-policy change follows the earliest original route,
not today's policy. The producer's bounded dedup tail is not absence authority:
the host resolves the original through the existing strict complete-log reader.
Unknown route/mention facts, malformed history, absent originals or mismatched
source identities refuse admission. The live socket also retains its original
served workspace and refuses callbacks after a workspace switch.

Independent nonauthor source review found and repaired two concrete route
issues: ambient/triggered reclassification and a source older than the 64KiB
dedup tail. The final source review has no remaining P0–P2 finding. This is
separate from formal GitHub approval and compiled execution.

Dashboard provenance **30 cases passed in 0.861 s**, and TypeScript checking
passed. That execution used base73028; all19 reviewed source files were byte
unchanged when applied to current mainf5998357. TypeScript checking also passed
on that new combination. [The exact source hashes and tool-result receipt](dashboard-execution.json)
retain this scope. No rendered Dashboard or TUI was exercised.

The OCaml regressions use actual attention/chat/queue files, real terminal
consumption, complete-log fault injection and the SQLite operation store.
Triggered dispatch is injected, so this does not establish full production
Gate/Owner/provider execution. Changed OCaml sources passed parser-only checks;
compiled execution is requested separately and has no observed result yet.

The Keeper-scoped attention store still cannot discover an original belonging
to a different Keeper after channel rebinding. Global original-owner discovery
and binding serialization remain separate work. This bounded repair does not
extract all Connector executors into Addon workers or complete E10/the original
54 acceptance criteria. No live Slack send, server replacement or installation
was performed.

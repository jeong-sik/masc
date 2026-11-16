# History Cut effect fence

This source unit follows the callback-scoped Exact claim at
`2d99eba17959832b6bec3f6c828670552c09063c`. It retains the existing ten-layer
declaration-replacement candidate and does not change its `Replaced` rule.
The existing open recovery issue is #50828.

A host or worker replacement can leave an original with a terminal Cut while
the semantic destination stays the same. Unknown execution does not authorize
replay. The new `preview_cut` and `fence_cut_serialized` APIs accept only an
execution-stage Cut with no gate, replacement preparation or source settlement.
They hold the same nonblocking original claim used by Exact execution, inside
the existing source, aggregate Memory and snapshot critical section. Fence
creation reconfirms the live witness. Publication and strict readback finish
before that witness expires.

The durable fence preserves the entire original owner record and its Unknown.
Its closed Cut schema additionally binds declaration, request ID, Exact digest,
positive attempt ordinal and canonical record/proof hashes. These stored facts
describe publication-time exclusion; they are not a live claim. The existing
absence fence keeps its original wire schema and its separate entry points.

The existing source-position, receipt and pending-publication checks remain in
the critical section. This path neither recovers a Memory publication nor
advances source cursors. It refuses a busy original, contradictory host proof,
an existing source receipt or moved source positions.

The Cut APIs are not connected to HTTP submission or automatic recovery in this
unit. The existing continuation worker explicitly refuses a Cut fence as a
successor grant. Its body-staging crash window and descendant completion contract
must be addressed before this authority can enter automatic recovery. No worker
or provider call, child creation, Memory publication, source ACK or live recovery
is claimed by the new fence API.

Five authored scenarios use the existing process-backed worker fixture and
actual host cancellation/join: atom and mixed-source fence preservation, busy
claim and changed proof, a genuine range receipt, and moved source positions.
They assert retained parent/host state and no new effects. They have not been
executed. OCaml 5.5.1 parsing and whitespace checks do not prove typing or behavior;
the repository toolchain is pinned to 5.5.2.

The running instance and the two retained production Cut originals are unchanged
by this source unit. Publication, current-main integration, focused behavioral
execution, independent approval, installation and actual original Memory/ACK
recovery require separate evidence.

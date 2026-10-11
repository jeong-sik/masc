# Approval timeout and answer arbitration

Base: `689aa5f08344a4c54de7618de97aba6676081815`.

Source inspection found that timeout returned its own outcome before final removal, whereas settlement independently removed the waiter and resolved its promise. Across domains, settlement could claim the waiter after the timer had returned but before final cleanup. The successful settlement receipt then contradicted the timeout outcome. `Watched_work` prefers a work result only if that arm actually returns; it cannot restore a cancelled work arm whose promise was resolved later. This is a source-derived race, not an executed failure reproduction.

The timer now claims its exact waiter under the registry lock, increments its terminal counter there, and publishes timeout through the same promise that answers and displacement use. If another claimant already removed the waiter, the timer awaits that claimant's promise instead of inventing timeout. Settlement claims and increments under the same lock; promise resolution stays outside the lock. Timeout cannot remove a replacement waiter with a reused provider ID because it uses exact resolver identity. Both counters now use the lock that readers already use.

The existing mock-clock answer race test now asserts actual outcome alongside counters. A timeout-first case checks that a later answer is rejected and exactly one timeout is counted. These test sources were not executed.

Validation: OCaml 5.5.1 `ocamlc -stop-after parsing` on the interface, implementation and changed test: three successful exits, no diagnostics. Source hashes and commands are represented in `/tmp/chat-approval-arbitration-syntax-20261012.json`. `git diff --check` passed. Syntax parsing is not OCaml typechecking or functional execution. No local Dune build, CI, runtime, installed binary or screenshot verification occurred.

Provider-keyed HTTP settlement and late-answer correlation still require the admission identity authority switch. This bounded race repair does not certify that broader work or the full chat goal. The preceding Web wire repair has an independent source PASS at its own exact head; that is not GitHub approval or merge admission.

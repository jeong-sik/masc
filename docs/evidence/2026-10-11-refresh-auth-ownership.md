# Authentication ownership of scheduled history refresh

Confirmed red: a broadcast refresh queued before authentication changed started a fetch under the replacement authentication. Capture authRevision in typed scheduled/running scheduler state; old queued callbacks and invalidated follow-ups cannot initiate new-auth work. A new-auth notification replaces stale scheduler ownership; old completion cannot delete its token.

Further red fixtures exposed busy state remaining after auth cancelled a running invalidated refresh, and after auth cancelled a queued replacement for an explicit read. Both paths settle busy only when no current history request exists. New explicit reads retain ownership of their busy state.

Validation: deferred fixtures cover queued/running auth replacement, new notification present/absent, old invalidation, and new explicit read present/absent. keeper-actions passed85tests; TypeScript noEmit and diffcheck passed. Independent source reviewers PASS after resolving queued-cancel P2. No formal approval, merge, installed runtime, actual transport or screenshot proof. Cached transcript/draft account isolation remains separate unresolved scope. Physical old-auth reads may overlap new-auth reads.

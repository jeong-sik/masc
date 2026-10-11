# Authentication-bound history admission

Confirmed red: a deferred history request begun under authentication revision A completed after setStoredToken changed revision to B and merged A's rows into the current transcript.

Fix: ChatHistoryRequest captures readonly authRevision; one ownership predicate checks both request token identity and current revision before history merge, successful hydration settlement or error publication. A stale request releases only its own busy/cache guard, so a normal new-revision request can retry.

Validation: deferred action fixtures cover superseded success and failure, reject old rows/errors, and allow subsequent new-revision hydration. Full keeper-actions suite passed80tests; TypeScript noEmit and diffcheck passed. Source reviews are distinct from formal approval and execution. No actual network/provider/runtime/screenshot evidence.

Remaining scope: previously cached conversation state, durable operation drafts, scheduled pre-change callbacks and separately launched journal/tool recovery require their own ownership audit. This change does not establish full account isolation or complete the chat edge-case goal.

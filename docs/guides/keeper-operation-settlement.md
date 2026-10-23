# Keeper operation settlement and projections

The operation store owns the terminal verdict for a submitted operation. Provider
completion, a persisted assistant message, and host acceptance are separate facts.
For example, an official client can return a reply before host reconciliation
rejects an unresolved native effect. The reply remains visible; it cannot stand in
for the operation's final accepted outcome.

After a chat execution ends, the Keeper Owner commits its accepted verdict and
reads the complete batch directly from its store. It passes those immutable rows
to the settlement callback. This callback does not acquire a new admission handle
or query the Owner. During server shutdown, admission can already be closed while
the existing Owner still has authority to settle all claimed batch members.

For each failed operation, the projection writes two records idempotently:

- A `request_failure` transcript row keyed by the operation and the
  `settled_failure` slot. Earlier assistant or per-attempt failure rows in
  `terminal_result` remain separate evidence.
- A journal error carrying the operation ID and durable completion timestamp.
  The timestamp identifies the accepted settlement; recovery does not invent a
  new completion time.

These writes are not an atomic transaction with the operation store. The immutable
failed row is the retained recovery intent. When the Owner starts, the registry
reprojects every durable failed row, including cancellations committed during a
prior shutdown. If either projection fails, its error is logged and the original
failed operation remains available for the next recovery pass. No queue is cleared
and no operation is rerun to repair a missing projection.

A deferred operation has no terminal verdict. A native effect that still requires
reconciliation remains Running and is not converted into a completed operation
merely because the execution fiber ended.

The lifecycle tests exercise the actual Owner/Registry shutdown path with a
multi-operation batch, plus restart projection and transcript/journal idempotency.
Parser and source review results do not establish that those lifecycle tests ran
or that a running deployment contains this change.

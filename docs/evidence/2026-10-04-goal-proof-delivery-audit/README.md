# Goal proof effect recovery (audit D1)

Product source: `5b722747ec1178708d3e4cd864a4f1e65b8718f1`.
Direct parent: `7384d0168833dbea38664ab079f64960b9e31247` (#41042).

A committed proof phase now includes audit and notification intents in the same
Goal-state write. Direct commits, proof-only reconciliation and explicit repeated
completion requests use that projection. Exact verdict replays drain retained
work without creating another intent or repeating the passing-proof precommit
step. Audit and notification delivery settle separately, so an audit append
failure does not suppress transcript delivery.

Notification content and identity are frozen at commit. The first successful
recipient snapshot is the canonical metadata filenames of persisted Keepers,
including stopped/unbooted Keepers; it is not the transient running registry.
An absent metadata directory is a valid empty fleet, while inaccessible or
non-directory roots remain errors. This is name-based audience discovery, not a
claim that all metadata payloads or current runtime owners are healthy. Newly
materialized Keepers after that snapshot are not retroactive recipients.

The host writes the exact workspace message without immediate fanout or mention
interpretation, then uses the existing durable append-once transcript boundary
for each recipient. Title/evidence text such as `@beta` remains literal. No
Keeper queue admission, wake or evaluator call occurs in this delivery path.
The verifier has external/system speaker authority even when a Keeper has the
same name. Each successful recipient acknowledgement persists independently;
failures retain the obligation for replay. The separate process/fiber delivery
lock is acquired outside Goal transactions. Normal Goal mutations preserve
pending notifications, including after a Goal is renamed or removed.

## Checks actually run

- 18 changed OCaml files pass `ocamlc -stop-after parsing` (see log).
- `git diff --check` passes.
- Source review is independent of the author; final review identity/history is
  recorded separately. No native compilation, behavior execution, CI, server
  restart or deployment has been performed. Parsing does not establish types or
  runtime recovery.

## Authored regressions (not executed)

`test_goal_verification_gate` adds eight scenarios within three test cases:

- Proven/refuted × recipient failure before append/after durable append: an
  unavailable audit path retains its exact event while healthy recipients still
  receive the notification. Exact-verdict replay does not rerun the precommit
  step. A simulated audit append-before-ack and recipient acknowledgement loss
  must both deduplicate at the real storage boundaries.
- Scan reconciliation, explicit completion repeat and direct proof-only commit
  retry: retained notices survive backend absence, Goal rename and Goal delete,
  then use the original content with the actual production recipient adapter.
- A failed metadata directory read remains uncaptured until repair, instead of
  committing a zero-recipient snapshot.

The actual recipient fixtures cover a 65-character name, a leading-dot name and
`verifier_exact` as a Keeper name, checking that the system speaker remains
External. Recipients are persisted without live registry registration.

`test_broadcast_stores_raw_text` adds a ninth scenario: passive publication and
replay preserve literal mention bytes and one authoritative sequence, never call
the inline handler, retain the ordinary Deferred mode's mention rejection and
reject conversion of an active mention row into a passive notification.

Existing Goal tool/agent fixtures register and restore the real delivery backend.
These are authored integration tests with injected failures. Replacing a host
callback or replaying a captured outbox is not an actual process/power-loss run.

## Integration and remaining qualification

- Run the focused native Goal gate/tools/agent/store and broadcast suites in an
  authorized validation lane. The shared recipient adapter also needs its
  existing broadcast wakeup-policy suite.
- Review interaction with #40958 (proof phase/confirmation wording) and #41003
  (pending-verifier scheduling) when integrating. This change does not rerun the
  model to deliver an already-committed proof.
- Obtain current-head independent GitHub approval and integrate the stack before
  claiming the audit item complete. Source review is not a GitHub approval.

The transaction/outbox approach follows the repository's existing audit outbox.
Its general design basis is the transactional outbox pattern, with idempotent
consumers needed for a replay after an unacknowledged write:
https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/transactional-outbox.html

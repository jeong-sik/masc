# Keeper native execution associations

A direct chat operation can publish several Core calls while waiting for an
approval, retrying a provider, or continuing input. Its semantic execution keeps
every call's immutable association in admission order. Each association contains
the call ID, runtime, admitted operation digest, original trace ID and opaque
Core locator. The trace ID locates the original session's `native-executions`
directory even when the Keeper now uses a different session.

The existing Owner transaction publishes the live call and its association
together. Repeated Bind acknowledgements and checkpoint updates do not add a
second association. A retired call ID or locator cannot become a fresh call.
Retire acknowledgement, deferral and final operation settlement preserve the
associations. A failed transaction publishes neither change; an uncertain
native-only commit is confirmed by rereading the complete semantic record.
The input-owner Bind path keeps its existing uncertain-commit error and requires
the caller to reconcile both authorities.

These references are for observation. They contain no checkpoint payloads,
terminal state, execution events or tool results. They never authorize resume,
retry or effect replay, and do not keep released checkpoint files alive. Core
owns the journal's recursive events and lifecycle. The current-call
`request_evidence` accessor retains its live-attempt meaning.

## Stored record contract

The semantic execution codec is `masc.keeper_semantic_execution.v3` and requires
the `native_calls` and `receipt_obligations` lists, including explicit empty
lists. Other record versions
are rejected. An older record cannot prove that an absent association list
means no calls occurred. There is no inferred empty-history conversion.

The SQLite database schema remains `masc.keeper_chat_operations.v3`.
Both ordinary store open functions decode every saved semantic execution,
including settled rows, and validate its indexed scope, revision and phase
before configuring an existing database or returning an Owner handle. A
record error names its saved scope and the exact codec or index failure.
`open_or_create` repeats the check under its existing writer lock. The scan
discards each decoded record without collecting the history in memory.
Deployment preflight already performs the full read-only durable-record scan;
the open check also prevents startup settlement or admission from reaching an
unsupported record. Individual record lookups keep their existing validation.

An existing store containing earlier semantic records requires fresh state;
there is no conversion. The affected file is
`<base-path>/.masc/keepers/<keeper>/chat-operations.sqlite3` and its SQLite
sidecars. Choosing a separate fresh base path preserves the old workspace.
For the exact per-store fresh-state scope and checkpoint ownership effects,
see [the stored-state guide](../guides/DURABLE-STORE-HARD-CUT.md#keeper-chat-operation-journals)
and [the #50583 fresh-state entry](../../changelog.d/50583.md).
This source change does not reset or alter an installed workspace.

## Read-only HTTP inspection

Both endpoints require a token-bound Admin identity, including when ordinary
operation reads allow anonymous local access:

- `GET /api/v1/keepers/:name/chat/operations/:operation/native-calls`
  accepts `limit` (1–200, default 50) and optional `after_call_id`. The response
  contains `calls`, `execution_operation_id` and `next_after_call_id`. The latter
  is present only when another call page remains. A foreign cursor is refused.
- `GET /api/v1/keepers/:name/chat/operations/:operation/native-calls/:call/events`
  accepts `limit` within the chat event API's page boundary, default 200, and
  optional JSON `after` and `through` Core cursors. Feed `next_cursor` back as
  `after` and `high_watermark` as `through` to keep one fixed committed prefix.

The operation store is opened read-only. A batch member resolves through its
stored execution leader. This does not require a running Keeper or install an
Owner. Each call opens the original trace directory through Core's public
projection API; current Keeper session metadata does not select its history.
Missing, damaged and mismatched evidence produces an error, without a trajectory
fallback or a cursor reset.

`masc.native_execution_events.v1` presents every selected event with its exact
event/run/correlation/node/parent/cause identities and source sequence. The
presentation includes node kinds, lifecycle, output/tool deltas and snapshots.
Content is redacted separately from protocol identities. Checkpoint and provider
request/response bodies stay in their dedicated inspection APIs; this response
is not a full raw-event export.

## Remaining product integration

The conversation view offers a **Core 실행 이력** card for a message with an
explicit operation delivery identity. It reads the endpoints above, pages one
fixed Core prefix, and uses canonical node/parent IDs for the tree. A Keeper,
operation or credential change drops the previous observation and cancels its
request through body consumption. Missing or damaged evidence is displayed as
an error.

The separate conversation/tool observations remain available. A delivery key
does not identify the historical runtime driver; neither an empty native call
list nor the Keeper's current runtime proves an official-client-only execution.
Core evidence does not replace the valid observations of official clients or
mixed-runtime failover. These surfaces are selected independently; a Core error
does not activate a fallback.

Issue [#25338](https://github.com/jeong-sik/masc/issues/25338) continues to track
the full history transition, historical driver provenance, unbound calls and
aggregate consumers. The direct-operation endpoints do not index unbound calls.
Source checks and the synthetic browser fixture do not prove installed-server
or completed-call process-restart behavior. That boundary has a regression
scenario in `test_keeper_ingress_native_restart.ml`; its execution result must
be reported separately.

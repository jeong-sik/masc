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

The semantic execution codec is `masc.keeper_semantic_execution.v2` and requires
the `native_calls` list, including an explicit empty list. Other record versions
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

## Remaining product integration

Issue [#25338](https://github.com/jeong-sik/masc/issues/25338) also tracks bounded,
read-only association/Core projection reads and the actual Dashboard consumer.
Retaining associations alone does not implement that HTTP or UI contract or
prove completed-call journal reads after a process restart.

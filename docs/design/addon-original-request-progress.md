# Original request progress

`Lane_addon_tool_request_owner` stores the immutable original input and its
host-owned execution/commit history in one keyed, atomic record. The first
publication contains both the complete captured request and Captured (an empty
event array). There is no second journal whose initial absence might be mistaken
for a request that has never run.

`Lane_addon_request_progress` is a pure typed event fold. Dispatch intent precedes
the actual RPC. Waiting, outcome unknown and worker absence retain their original
evidence. None allows another dispatch. A verified late original answer may add
a judgment after those observations without deleting them. Refusal distinguishes
the before-dispatch boundary from an original execution's refusal.

The host records a judgment before a commit intent binds it to the complete
before-state and expected after-state. After an uncertain commit, a fresh exact
before-state observation can record a retry; an exact after-state observation
confirms it. A different observed state can be retained as a terminal conflict.
An unchanged before/after is confirmed rather than retried. Finished, conflicted
and refused histories cannot dispatch again or replace the judgment.

These are trusted host facts, not assertions from a model or worker. The generic
module cannot establish semantic validity, observation freshness, ownership or
domain commit identity. The actual Curator owner must validate the full captured
answer, reload authoritative state and bind its target before recording them.
The module performs no RPC, Ledger/Briefing save, publication or observer finish.

Retain compares only immutable scope/request/destination/canonical input and
digest, preserving any existing history. Advance rereads and compares the entire
expected record. A different tail conflicts; an exact already-stored next
history returns `Already_stored` without a write. `Stored` and `Already_stored`
are distinct, and acknowledging a previously saved intent never authorizes
another RPC or effect. This expected-record check requires the caller's existing
workspace process lease and owner serialization. It is not a filesystem or
cross-process compare-and-swap.

An advance save error is `Unconfirmed`: rename may have succeeded. Initial
retain reports `Store_unavailable` and likewise does not establish absence.
The caller reloads
the original key instead of declaring absence, rolling back or minting a new ID.
Cancellation propagates with the same uncertainty about publication. Known-ID
reads strictly fold the entire history; unknown fields, duplicate members,
invalid JSON, invalid ordering and mismatched state observations are refused.

Six `test_lane_addon_request_progress` scenarios use actual Store files and new
handles for unknown/late-result recovery, immutable retain, stale writers and
exact acknowledgements, original before/after commit recovery, terminal conflict
and refusal, malformed history and a removed original. The commit scenario uses
a separate real state file to distinguish recording observations from writing
domain state. They do not inject post-rename durability failure or prove a
production Curator recovery. Parser/source results are separate from execution.

Next E02 boundaries are strict restart discovery anchored to the original store,
physical record/durability identity, production metadata capture and serialized
owner integration, semantic acceptance inside the original HTTP/CLI flow,
Addon wake/worker delivery and actual Off/reconnect with both UIs. This history
is the known-ID persistence foundation for that work, not completed extraction.

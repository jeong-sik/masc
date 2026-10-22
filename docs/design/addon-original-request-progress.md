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

An explicit worker capacity reply immediately after a newly published admission
intent records `Admission_declined` and `Admission_wait`. It proves no admission
for that RPC; a later pass may read first and publish another admission intent
for the **same** original ID/input. This exception cannot follow pending,
unknown or absence observations, and it cannot replace an uncertain admission.
An acknowledged old intent still grants no new RPC. The added seventh Store
scenario covers this distinction; the historical six-scenario receipt below
remains bound to its original source.

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

The [observer receipt axis](addon-original-observer-receipts.md) retains first
registration/terminal intents and exact acknowledgements alongside execution.
It preserves the original primary phase and never authorizes an effect. Actual
domain receipt validation and registry reconcile/delivery remain separate work.

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
domain state. Exact `c231ab19f12981429a7442696c9f2c02c81104d5` run
[39657204150](https://github.com/jeong-sik/masc/actions/runs/39657204150)
completed successfully: these six scenarios and four directly related suites,
70 tests total. They do not inject post-rename durability failure or prove a
production Curator recovery. The following discovery implementation was not
part of that source; it needs its own execution evidence.

The [original request discovery](addon-original-request-discovery.md) follow-up
adds scoped inventory and physical record/durability identity. It does not wire
production recovery. Next E02 boundaries are production metadata capture and serialized
owner integration, semantic acceptance inside the original HTTP/CLI flow,
Addon wake/worker delivery and actual Off/reconnect with both UIs. This history
is the known-ID persistence foundation for that work, not completed extraction.

# Chat row contract

Keeper speech and a server-owned failed request are different records.
The current representation uses a single closed `role` classification:
`user`, `assistant`, `system`, `tool`, `request_failure`.

`assistant` means the Keeper actually spoke. Its readable answer may acknowledge
its causal input. `request_failure` belongs to the server; it does not acknowledge
input, enter conversation memory or count as a delegate reply. It retains already
completed tool/media evidence and can be rendered after history reload.

Both terminal rows use one `terminal_result` provenance slot and the same
store-owned append-once mechanism. They cannot create two terminal authorities
for one operation. Operation status is a separate fact: a later delivery failure
can coexist with persisted real speech, which remains intact.

There is no independent row `kind` or optional `assistant_kind`. Producers choose
`append_assistant_message_once` or `append_request_failure_once`; runtime terminal
settlement is a closed `Reply | Request_failed` sum. Unknown row metadata is
refused rather than becoming assistant speech. This development contract has no
compatibility/migration path and requires fresh transcripts when deployed.
No live data is changed by this source refactor.

Consumers updated together: strict store decoding and provenance scanning,
terminal journal audit, pending-input acknowledgement, conversation memory,
delegate selection, lane reads, turn inspector, dashboard REST/schema/actions,
and TUI history/replay. [Measured evidence](failure-row/README.md) records the
checks and exact remaining display obligations. The full campaign remains active.

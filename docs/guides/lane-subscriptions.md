# Read subscribed Lane observations in the next Keeper turn

Subscriptions belong to the resolved workspace config root's
`lane-subscriptions.toml`. Each table names `keeper_name`, `run_id`,
`installation_id`, and `output_id`. A run is an observation scope; workspace
isolation still requires a separate base path and server configuration.

```toml
[[subscriptions]]
keeper_name = "researcher"
run_id = "study"
installation_id = "documents"
output_id = "changes"
```

The direct and autonomous turn paths discover unread observation references,
not source bodies. A subscription does not wake a Keeper. Already acknowledged
output does not add context. A missing installation, invalid config, or replaced
instance remains visible; it is not a successful empty observation. The producer
phase must decode through the Lane lifecycle contract before reading or
acknowledging. Unknown or malformed phases, and detaching or detached workers,
remain unavailable without advancing the cursor. Attached, observing and failed
workers may still expose their retained observations.

`masc_lane_updates` has four operations:

- `inspect`: read the whole workspace subscription config and source revision.
- `save`: replace it with `subscriptions`, using `expected_source_revision` from
  inspect. Omit the revision only when no file exists. This is configuration
  management, not reading or acknowledging another Keeper's observations.
- `read`: provide `run_id`, `installation_id`, `output_id`. The caller must be
  subscribed. Returns the next retained record's selected rows, whole-source
  coverage, and exact receipt. It does not advance the reading position.
- `acknowledge`: provide the same selection and returned `receipt` after reading.
  This acknowledges receipt, not semantic use, source completeness, or a project
  result. Missing/unreadable records cannot be acknowledged. A successfully read
  record reporting incomplete upstream coverage can be acknowledged; that gap
  remains in the retained record and must not be described as complete input.

The HTTP endpoint is `POST /api/v1/lane-addons/subscriptions` with the same body.

A subscription names the installation/run/output and continues to apply after
worker replacement. Reading and acknowledgement use the authenticated actor;
operator configuration changes do not consume a Keeper's output.

Reader position is persisted under the workspace Lane store and belongs to an
installation/output/run/Keeper tuple. A new worker incarnation starts its own
sequence. A stale receipt cannot acknowledge the replacement or another record.
Repeated reads before acknowledgement return the same record, allowing recovery
when a tool response is lost. Original row evidence remains accessible through
the existing Lane evidence and artifact paths.

Acknowledgement publication distinguishes a failure before rename from one
following rename. Before rename, the next unread receipt remains unchanged.
After rename, the response reports `acknowledged=false`, `published=true`, and
`durability="unconfirmed"`, including any visible-file verification failure.
Every subsequent reader validates the cursor identity and strictly syncs the
exact file and its parent directory before accepting its position. A failed sync
makes the subscription unavailable, including after process restart. No cursor
payload is rewritten by this verification.

Retrying the exact currently published receipt revalidates its producer,
incarnation, sequence, and retained output digest before returning an
acknowledgement. It never consumes the following observation. An older receipt
cannot move a later cursor backwards. These filesystem guarantees address
process restart; they do not promise recovery from hardware or power loss.

(** Captured-scope owner of the default Operator Snapshot.

    Snapshot's process epoch, mutation generation and ordered compute/terminal
    sequences remain distinct from source-read debt. The mutation generation
    is the existing [Dashboard_projection_cache] approval invalidation fence;
    no request or source completion may cross it or a retired workspace scope.

    Canonical JSON retains [snapshot_epoch], [snapshot_generation],
    [snapshot_compute_sequence] and [snapshot_terminal_sequence], and includes
    the captured [observer_instance_id]. [snapshot_fresh_until_unix] is the
    original read's next semantic transition, or [null] when none exists.
    It is not an elapsed-time freshness window. [snapshot_observation_state]
    is [initializing], [invalidated], [ready], or [error]. Parameterized HTTP
    requests keep their original actor/query ownership and do not install
    their rows into this default publication. *)

type owner
type attempt
type publication
type origin = Source_read | Default_request
type completion = Installed of origin | Failed of origin | Source_changed | Invalidated
type publication_status = Current | Superseded | Source_pending | Retired

val owner_for_scope :
  state:Mcp_server.server_state -> Mcp_server.workspace_scope -> owner
(** A delayed lookup of a retired scope gets a private owner and cannot
    replace the current workspace's owner. Admission/terminal guards do not
    perform filesystem or transport operations. *)

val cache_snapshot : owner -> Server_dashboard_http_cache.surface_snapshot
(** Immutable cache diagnostics; consumers cannot install a body outside the
    typed owner admission boundary. *)
val is_current : owner -> bool
val has_observation : owner -> bool
val observation_is_usable : owner -> bool
(** Complete and partial actual bodies satisfy a cold request. A healthy
    observation with no semantic deadline is usable. Source debt, a passed
    semantic deadline, a mutation invalidation or scope retirement is not.
    Reading this predicate does not create a timer or authorize an action. *)

val begin_attempt : owner -> origin:origin -> attempt
val publish_observation : attempt -> Dashboard_projection_read.observation -> bool
val publish_failure_message : attempt -> string -> bool
(** Admit only the captured scope, mutation generation and ordered attempt.
    Each attempt terminalizes once; its full/partial result cannot later
    degrade because an outer timeout also closes. Partial reads retain the
    original readable rows without stamping full success. A failed read with
    no result replaces the body with unavailable, so an earlier approval row
    is never presented as the failed read's answer. Cancellation is propagated
    by the compute caller and is not published as a read failure. *)

val source_changed : owner -> unit
(** Fence prepared payloads and leave trailing read debt. A same-owner read
    completing after this notice may publish its actual observation, while
    the worker's bounded input mailbox retains one subsequent read. Source
    generation does not assert an atomic read of every input store. *)

val synchronize_invalidation : unit -> unit
(** Synchronize the active owner with the authoritative mutation generation.
    Called after the original generation lock is released; delayed callbacks
    read the current authority instead of fabricating an older tombstone.
    This only notifies metadata listeners; it does not publish SSE inline. *)

val next_deadline_unix : owner -> float option
val subscribe_completed : owner -> (completion -> unit) -> (unit -> unit)
(** Synchronous non-I/O listeners may enqueue bounded debt. Listener exceptions
    cannot replace the original completion, failure or cancellation. *)

val publication : owner -> publication
val publication_json : publication -> Yojson.Safe.t
(** Frozen canonical bytes from one terminal observation. Attempt stamps or
    elapsed diagnostic age do not mutate the same publication identity. *)
val publication_status : owner -> publication -> publication_status
val publication_is_current : owner -> publication -> bool
(** Source_pending is an original-input frontier that no subsequent read has
    settled. Once a later read completes an old preparation is Superseded,
    retaining publication debt without a source-pending busy loop. Mutation
    tombstones can be published while their replacement read is owed. *)

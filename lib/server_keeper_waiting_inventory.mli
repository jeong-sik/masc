type request_observation
(** Immutable request-scoped observation shared by dashboard projections. It
    captures the schedule store, metadata Keeper-name discovery, durable queue
    snapshot discovery, and each unioned Keeper event queue exactly once. *)

val capture_request_observation :
  ?additional_queue_keeper_names:
    ((Schedule_store.state, Schedule_store.read_error) result -> string list) ->
  Workspace.config ->
  request_observation
(** Captures the stores shared by scheduled-automation and Keeper-waiting
    projections. [additional_queue_keeper_names], when supplied, is evaluated
    against the already-captured schedule result; it must only derive Keeper
    names and must not reread stores. Its result is unioned with Keeper metadata
    names and typed durable queue-snapshot discovery before every event queue is
    read once. Snapshot-only unregistered Keeper lanes therefore remain visible;
    discovery failures are projected as explicit global read-error evidence. *)

val workspace_config : request_observation -> Workspace.config
val schedule_state_result :
  request_observation -> (Schedule_store.state, Schedule_store.read_error) result
val captured_at_unix : request_observation -> float
val generated_at : request_observation -> string
(** Exact completion timestamp of the immutable request observation. Dashboard
    projections use it instead of manufacturing a newer timestamp when an old
    observation is rendered or served from cache. *)

val event_queue_snapshot :
  request_observation ->
  keeper_name:string ->
  Keeper_event_queue_persistence.snapshot_observation option
(** [None] means that [keeper_name] was not part of the captured request
    observation. Queue read and parse failures remain present in the returned
    snapshot's typed [read_errors]; successful reads retain the snapshot/WAL
    [source_generation] that produced the in-memory projection. Repeated calls
    for one request return the same immutable captured value. *)

val dashboard_json_of_observation : request_observation -> Yojson.Safe.t
(** Projects the Keeper waiting/deferred model from the captured shared stores.
    Other subsystem observations are still read once by this projection. *)

val dashboard_json : Workspace.config -> Yojson.Safe.t
(** Cross-subsystem keeper waiting/deferred read model for dashboard tools.
    This parent-library module is shared by server and tool entrypoints; it may
    join MASC stores, but it does not add a dashboard dependency to lower
    keeper/runtime libraries. *)

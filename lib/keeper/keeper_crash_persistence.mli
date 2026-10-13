(** Keeper_crash_persistence -- Durable crash event store.

    Non-yielding enqueue + background drain fiber.
    Dated_jsonl under [<cluster root>/keepers/<name>/crash-events/].
    Callers pass the cluster's root
    ([Workspace.dated_store_cluster_root config]).
    Separate from Keeper_registry to preserve its non-yielding contract.

    @since 3.0.0 *)

(** Non-yielding: Queue.push only. Safe to call from keeper_registry
    or keeper_supervisor catch blocks without breaking fiber atomicity.
    [cluster_root] is the root of the cluster the keeper runs in. *)
val enqueue_record :
  cluster_root:Dated_jsonl.Store.cluster_root ->
  name:string ->
  ts:float ->
  reason:string ->
  restart_count:int ->
  unit

(** Start the background drain fiber and the flush that runs when [sw] closes.
    Call once from server bootstrap.

    The fiber drains the queue on its own interval and writes to Dated_jsonl.
    It is a daemon, so the switch cancels it; the switch's release hook writes
    whatever is still queued at that point. Both write one event per
    cancellation-protected step, so a record is never taken from the queue
    without reaching the store. *)
val start_drain_fiber : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> unit

(** Read recent crash events from disk. Performs I/O -- call from
    dashboard handlers, not from keeper_registry context.
    [cluster_root] is the root of the cluster the keeper runs in. *)
val recent_crashes :
  cluster_root:Dated_jsonl.Store.cluster_root ->
  name:string ->
  max_entries:int ->
  Yojson.Safe.t list

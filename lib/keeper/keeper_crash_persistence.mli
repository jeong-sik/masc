(** Keeper_crash_persistence -- Durable crash event store.

    Non-yielding enqueue + background drain fiber.
    Dated_jsonl under [masc_root/keepers/<name>/crash-events/].
    Callers must pass [Room.masc_root_dir config] as [~masc_root]
    to ensure cluster-scoped paths.
    Separate from Keeper_registry to preserve its non-yielding contract.

    @since 3.0.0 *)

(** Non-yielding: Queue.push only. Safe to call from keeper_registry
    or keeper_supervisor catch blocks without breaking fiber atomicity.
    [~masc_root] must be [Room.masc_root_dir config] (cluster-aware). *)
val enqueue_record :
  masc_root:string ->
  name:string ->
  ts:float ->
  reason:string ->
  restart_count:int ->
  unit

(** Start background drain fiber. Call once from server bootstrap.
    Drains the internal queue and writes to Dated_jsonl. *)
val start_drain_fiber : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> unit

(** Read recent crash events from disk. Performs I/O -- call from
    dashboard handlers, not from keeper_registry context.
    [~masc_root] must be [Room.masc_root_dir config] (cluster-aware). *)
val recent_crashes :
  masc_root:string ->
  name:string ->
  max_entries:int ->
  Yojson.Safe.t list

(** Keeper_crash_persistence -- Durable crash event store.

    Non-yielding enqueue + background drain fiber.
    Dated_jsonl under [keepers_dir]/<name>/crash-events/.
    Callers must pass the cluster-scoped keepers directory
    (e.g. [Filename.concat (Coord.masc_root_dir config) "keepers"]).
    Separate from Keeper_registry to preserve its non-yielding contract.

    @since 3.0.0 *)

(** Non-yielding: Queue.push only. Safe to call from keeper_registry
    or keeper_supervisor catch blocks without breaking fiber atomicity.
    [keepers_dir] is the cluster-scoped keepers root directory. *)
val enqueue_record
  :  keepers_dir:string
  -> name:string
  -> ts:float
  -> reason:string
  -> restart_count:int
  -> unit

(** Start background drain fiber. Call once from server bootstrap.
    Drains the internal queue and writes to Dated_jsonl. *)
val start_drain_fiber : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> unit

(** Read recent crash events from disk. Performs I/O -- call from
    dashboard handlers, not from keeper_registry context.
    [keepers_dir] is the cluster-scoped keepers root directory. *)
val recent_crashes
  :  keepers_dir:string
  -> name:string
  -> max_entries:int
  -> Yojson.Safe.t list

(** Non-yielding: record a self-preservation suppression event. *)
val enqueue_sp_event
  :  keepers_dir:string
  -> ts:float
  -> suppressed_count:int
  -> total:int
  -> ratio:float
  -> dominant_cohort:string
  -> unit

(** Read recent self-preservation events from disk. *)
val recent_sp_events : keepers_dir:string -> max_entries:int -> Yojson.Safe.t list
